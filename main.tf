resource "helm_release" "spark_operator" {
  name             = "spark-operator"
  repository       = "https://kubeflow.github.io/spark-operator"
  chart            = "spark-operator"
  version          = var.chart_version
  namespace        = var.operator_namespace
  create_namespace = true
  atomic           = true

  values = [
    yamlencode({
      spark = {
        jobNamespaces = var.job_namespaces
      }
      webhook = {
        enable = true
      }
      prometheus = {
        metrics = {
          enable = var.enable_metrics
        }
      }
    })
  ]
}
