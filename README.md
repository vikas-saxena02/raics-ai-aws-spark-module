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

SparkApplications in a Profile namespace **must** set an annotation on the
driver, or every executor fails with `ExitCode: 1`:

```yaml
  driver:
    annotations:
      traffic.sidecar.istio.io/excludeInboundPorts: "7078,7079"
```

7078 is `sparkDriver`, 7079 is the block manager.

### Why

Executors are created by the driver at runtime, and carry
`sidecar.istio.io/inject: "false"` so they can terminate after shuffles
(a classic sidecar never exits, so the pod would hang forever).

No sidecar means no mTLS identity. Kubeflow's `ns-owner-access-istio`
AuthorizationPolicy — created automatically for every Profile — allows
same-namespace traffic via:

```yaml
- when:
  - key: source.namespace
    values: [org-alpha]
```

`source.namespace` is *derived from the peer's mTLS identity*. A sidecar-less
executor presents none, so the value is empty, the rule never matches, and no
other rule covers a plaintext Spark RPC. The driver's proxy accepts the TCP
connection and immediately closes it.

Symptom in the executor log: connection to the driver succeeds in ~75ms, then
`Still have 1 requests outstanding when connection ... is closed`, repeated
until `Max number of executor failures (3) reached`.

Excluding the ports takes that traffic out of the mesh entirely, so no policy
is evaluated against it.

### Not reproducible locally

A kind cluster without Kubeflow Profiles has no `ns-owner-access-istio`
policy, so Spark works there without the annotation. This only appears on a
Profile-enabled cluster.

### Open item

Kubernetes native sidecars (1.29+, `restartPolicy: Always` init containers)
terminate with the pod and would let executors join the mesh with a real
identity — removing the need for both `inject: "false"` and this annotation,
and bringing Spark traffic back under policy enforcement. Verify whether
Istio's `ENABLE_NATIVE_SIDECARS` is set before building any mutating-webhook
or Kyverno workaround.

## Tests

```bash
terraform test
```

Requires Terraform 1.6+.

The tests are **plan-only** and assert the module's input contract: the chart
version default, the operator namespace, `atomic = true`, and the two
safety-relevant defaults (`enable_metrics = false`, `job_namespaces = []`).

### What they do not cover

Plan-only tests never contact a cluster, so they cannot verify:

- that the chart version exists in the upstream repository
- that the operator actually installs, or that its pods reach Ready
- that the webhook issues certificates correctly
- that a `SparkApplication` is picked up in any namespace

Those require a live EKS cluster and are verified manually — see
"Running Spark in a Kubeflow Profile namespace" for the failure mode most
likely to appear there.

A `command = apply` test would cover them, but needs a cluster, so it is not
part of the default test run.

## Requirements

| Name | Version |
|---|---|
| terraform | tested on 1.15.x |
| helm provider | `~> 3.0` (v3.2.0) |

Helm provider v3 syntax differs from v2 — provider auth uses a flat
`kubernetes = { ... }` attribute, and `helm_release` takes `set` as a list
attribute rather than repeated blocks.