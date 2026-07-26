variable "cluster_name" {
  description = "EKS cluster name — used for the exec auth token."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API endpoint."
  type        = string
}

variable "cluster_ca_certificate" {
  description = "Base64-encoded EKS cluster CA certificate."
  type        = string
}

variable "chart_version" {
  description = "spark-operator Helm chart version. Pinned to the version the 19 Aug demo is verified on."
  type        = string
  default     = "2.3.0"
}

variable "operator_namespace" {
  description = "Namespace the Spark Operator controller and webhook run in."
  type        = string
  default     = "spark-operator"
}

variable "job_namespaces" {
  description = "Namespaces the operator watches for SparkApplications. Empty list = all namespaces, so org Profiles created after install are picked up."
  type        = list(string)
  default     = []
}

variable "enable_metrics" {
  description = "Expose operator Prometheus metrics. Leave false until the W19 ns-owner-access-istio /metrics cross-org path is closed."
  type        = bool
  default     = false
}
