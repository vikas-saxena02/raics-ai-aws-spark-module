variables {
  cluster_name           = "test-cluster"
  cluster_endpoint       = "https://example.eks.amazonaws.com"
  cluster_ca_certificate = "dGVzdC1jYQ==" # base64 "test-ca"
}

run "defaults_are_safe" {
  command = plan

  assert {
    condition     = helm_release.spark_operator.version == "2.3.0"
    error_message = "chart_version must default to 2.3.0 (the version the 19 Aug demo is verified against)"
  }

  assert {
    condition     = helm_release.spark_operator.namespace == "spark-operator"
    error_message = "operator_namespace must default to spark-operator"
  }

  assert {
    condition     = helm_release.spark_operator.atomic == true
    error_message = "atomic must be true so failed installs roll back cleanly"
  }
}

run "metrics_off_by_default" {
  command = plan

  assert {
    condition     = var.enable_metrics == false
    error_message = "enable_metrics must default to false until the W19 cross-org metrics check is closed"
  }
}

run "watches_all_namespaces_by_default" {
  command = plan

  assert {
    condition     = length(var.job_namespaces) == 0
    error_message = "job_namespaces must default to [] so Profile namespaces created after install are picked up"
  }
}