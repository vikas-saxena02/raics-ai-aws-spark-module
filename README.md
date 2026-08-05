# raics-ai-aws-spark-module

Installs the [Kubeflow Spark Operator](https://github.com/kubeflow/spark-operator)
onto an existing EKS cluster via `helm_release`.

Consumed by `raics-ai-platform-infra` (not `raics-ai-aws-infra`) — Spark jobs run
inside Kubeflow Profile namespaces, which that state owns.

## What it does

- Installs the `spark-operator` Helm chart into a dedicated namespace
- Enables the mutating admission webhook (required for Spark pod customisation)
- Watches **all** namespaces for `SparkApplication` resources by default
- Leaves Prometheus metrics **disabled** by default (see Multi-tenancy notes)

The module is self-contained: it declares its own `helm` provider using
exec-based `aws eks get-token` auth, mirroring `raics-ai-aws-eks-module`.
Consuming states do **not** need a `helm` provider configured.

## Usage

```hcl
module "spark" {
  source = "git::https://github.com/vikas-saxena02/raics-ai-aws-spark-module.git?ref=v1.0.0"

  cluster_name           = data.terraform_remote_state.base.outputs.cluster_name
  cluster_endpoint       = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = data.aws_eks_cluster.this.certificate_authority[0].data
}
```

> `cluster_ca_certificate` must be passed **base64-encoded (raw)**. The module
> decodes it internally — double-decoding causes a silent auth failure at apply.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `cluster_name` | `string` | — | EKS cluster name, used for the exec auth token |
| `cluster_endpoint` | `string` | — | EKS cluster API endpoint |
| `cluster_ca_certificate` | `string` | — | Base64-encoded cluster CA cert (pass raw) |
| `chart_version` | `string` | `"2.3.0"` | spark-operator Helm chart version |
| `operator_namespace` | `string` | `"spark-operator"` | Namespace for controller + webhook |
| `job_namespaces` | `list(string)` | `[]` | Namespaces watched for SparkApplications. `[]` = all |
| `enable_metrics` | `bool` | `false` | Expose operator Prometheus metrics |

## Outputs

None. The operator is a cluster-wide singleton with no values downstream
components need.

## Version pinning

`chart_version` is pinned to `2.3.0` — the version the Spark Connect demo
(19 Aug 2026) is verified against. Do not bump before that date.

Chart `2.4.0` adds Kueue integration, `SparkApplication` suspend/resume, and
`SparkConnect` service customisation. Its CRD update runs via a Helm
**pre-upgrade hook**, so verify CRDs applied cleanly after any upgrade to
2.4.0 or later.

Upgrading is a one-line change in the consuming state:

```hcl
chart_version = "2.4.0"
```

## Multi-tenancy notes

`job_namespaces` defaults to `[]` (watch all) so that Kubeflow Profile
namespaces created **after** the operator is installed are picked up without a
Terraform change. A fixed list would require an apply per new org.

`enable_metrics` defaults to `false` because watch-all is precisely the
condition that activates a known isolation gap:

> Kubeflow's default `ns-owner-access-istio` AuthorizationPolicy permits
> `/healthz`, `/metrics`, and `/wait-for-drain` from **any** source, including
> other org namespaces. This is benign only while no workload serves real data
> on those paths.

Before setting `enable_metrics = true`, curl those paths from one org namespace
to another and confirm no data is returned.

## Running Spark in a Kubeflow Profile namespace

SparkApplications run in a Profile namespace with no special configuration.
Use the Profile's built-in ServiceAccount:

```yaml
  driver:
    serviceAccount: default-editor
```

`default-editor` is created automatically by the Kubeflow Profile controller
and already carries the pod, service, and configmap permissions a Spark driver
needs. No additional Role or RoleBinding is required.

Executors should **not** set `sidecar.istio.io/inject: "false"`, and the driver
should **not** set `traffic.sidecar.istio.io/excludeInboundPorts`. Both are
workarounds for classic Istio sidecars and are unnecessary here.

### Why native sidecars matter

Verified on Istio 1.26.1 with `ENABLE_NATIVE_SIDECARS=true`, which the
vendored Kubeflow manifests set by default.

A classic Istio sidecar never exits, so a Spark executor that finishes its work
would hang forever with a running proxy. The usual workaround is to disable
injection on executors — but that strips their mTLS identity, and Kubeflow's
`ns-owner-access-istio` AuthorizationPolicy allows same-namespace traffic via
`source.namespace`, which is *derived from* that identity. Sidecar-less
executors therefore fail to reach the driver, exiting with ExitCode 1.

Native sidecars (Kubernetes 1.29+) are init containers with
`restartPolicy: Always`. They start before the app container and terminate with
the pod, so executors both exit cleanly and carry a real SPIFFE identity.
`source.namespace` matches, the policy permits the traffic, and Spark's
driver↔executor RPC stays **inside** the mesh under normal policy enforcement.

This is preferable to excluding Spark's ports from the mesh: tenant traffic
remains authenticated and policy-covered, which matters for IRAP evidence.

### If native sidecars are unavailable

On a cluster without `ENABLE_NATIVE_SIDECARS=true`, executors need
`sidecar.istio.io/inject: "false"` and the driver needs
`traffic.sidecar.istio.io/excludeInboundPorts: "7078,7079"` (7078 is
`sparkDriver`, 7079 the block manager). That configuration works but takes
Spark traffic outside mesh enforcement.