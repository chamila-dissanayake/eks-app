variable "env" {
  description = "Environment variables"
  type        = map(any)
}

variable "tags" {
  description = "Tags for the resources"
  type        = map(any)
}

variable "newrelic" {
  description = "New Relic configuration"
  type        = object({
    secret_name                    = optional(string)
    helm_chart                     = optional(string, "nri-bundle")
    helm_chart_repo                = optional(string, "https://helm-charts.newrelic.com")
    helm_chart_name                = optional(string, "newrelic-infrastructure")
    helm_chart_version             = optional(string, "6.0.25")
    infrastructure_enabled         = optional(bool, true)
    nri_prometheus_enabled         = optional(bool, false)
    nri_metadata_injection_enabled = optional(bool, true)
    kube_state_metrics_enabled     = optional(bool, true)
    nri_kube_events_enabled        = optional(bool, true)
    logging_enabled                = optional(bool, true)
    pixie_enabled                  = optional(bool, false)
    pixie_chart_enabled            = optional(bool, false)
    infra_operator_enabled         = optional(bool, false)
    prometheus_agent_enabled       = optional(bool, true)
    eapm_agent_enabled             = optional(bool, false)
    k8s_agents_operator_enabled    = optional(bool, true)
    k8s_metrics_adapter_enabled    = optional(bool, false)
    verbose_log_enabled            = optional(bool, false)
    privileged_enabled             = optional(bool, true)
  })
}

variable "apm" {
  description = "APM configuration"
  type        = map(any)
  default = {
    enabled                     = false
    kubernetes_deployment_name  = "user-web-app"
    log_level                   = "info"    # valid values are: 'trace', 'debug', 'info', 'warn', 'error', 'fatal', 'unknown'
    distributed_tracing_enabled = true
    transaction_tracer_enabled  = true
    error_collector_enabled     = true
    browser_monitoring_enabled  = true
    application_logging_enabled = true
  }
}
