variable "env" {
  description = "A map of environment variables to be used in the workload"
  type        = map(string)
  default     = {}
}
variable "tags" {
  description = "A map of tags to be applied to the workload resources"
  type        = map(string)
  default     = {}
}

variable "namespace" {
  description = "The namespace in which the workload will be deployed."
  type        = string
}

variable "secret" {
  description = "A map of objects to be used in the workload"
  type = object({
    service_account_name = string
    object_name          = string
    object_type          = string
    file                 = optional(string, null)
    keys                 = list(string)
  })
}

variable "deployment" {
  description = "Attributes related to the application deployment"
  type        = map(any)
  default = {
    name                           = ""
    replicas                       = 2
    ecr                            = ""
    image_version                  = ""
    port                           = 80
    port_name                      = "http"
    requests_cpu                   = "500m"
    requests_memory                = "512Mi"
    limits_cpu                     = "1000m"
    limits_memory                  = "1024Mi"
    health_check_path              = "/"
    health_check_delay             = 30
    health_check_interval          = 30
    health_check_timeout           = 5
    health_check_failure_threshold = 3
    env_var_secret                 = ""
  }
}

variable "ingress" {
  description = "Ingress configuration for the workload"
  type        = map(any)
  default = {
    stickiness_enabled             = true
    lb_cookie_duration             = "3600"
    tg_health_check_path           = ""
    health_check_interval          = "15"
    health_check_timeout           = "5"
    health_check_failure_threshold = "2"
    unhealthy_threshold            = "2"
    idle_timeout                   = "60"
    ssl_redirect_port              = "443"
    health_check_port              = "80"
    backend_protocol               = "HTTP"
    preserve_client_ip             = true
  }
}

variable "apm" {
  description = "NewRelic APM configuration for the application"
  type        = map(any)
  default = {
    enabled                     = false
    newrelic_namespace          = "newrelic"
    newrelic_secret_name        = "newrelic"
    template_file_path          = "templates/newrelic.js.tpl"
    log_level                   = "info" # valid values are: 'trace', 'debug', 'info', 'warn', 'error', 'fatal', 'unknown'
    distributed_tracing_enabled = true
    transaction_tracer_enabled  = true
    error_collector_enabled     = true
    browser_monitoring_enabled  = true
    application_logging_enabled = true
  }
}

variable "hpa" {
  description = "Horizontal Pod Autoscaler configuration"
  type = object({
    enabled = bool
    #min_replicas              = number
    max_replicas              = number
    target_cpu_utilization    = number
    target_memory_utilization = number
    custom_metrics = map(object({
      name         = string
      target_value = string
    }))
    scale_up_stabilization_window   = number
    scale_up_percent                = number
    scale_up_pods                   = number
    scale_up_period                 = number
    scale_down_stabilization_window = number
    scale_down_percent              = number
    scale_down_period               = number
  })
  default = {
    enabled = false
    #min_replicas                    = 1
    max_replicas                    = 2
    target_cpu_utilization          = 70
    target_memory_utilization       = 70
    custom_metrics                  = {}
    scale_up_stabilization_window   = 0
    scale_up_percent                = 100
    scale_up_pods                   = 2
    scale_up_period                 = 60
    scale_down_stabilization_window = 300
    scale_down_percent              = 100
    scale_down_period               = 60
  }
}

variable "restart_schedule" {
  description = "Configuration for restarting the deployment on a schedule"
  type = object({
    enabled                       = bool
    successful_jobs_history_limit = number
    failed_jobs_history_limit     = number
    cron_expression               = string
    timezone                      = string
    concurrency_policy            = optional(string, "Forbid")
    active_deadline_seconds       = optional(number, 300)
    backoff_limit                 = optional(number, 2)
    restart_policy                = optional(string, "Never")
    image                         = optional(string, "bitnami/kubectl:latest")
  })
  default = {
    enabled                       = false
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 1
    cron_expression               = "0 6 * ? *"
    timezone                      = "UTC"
    concurrency_policy            = "Forbid" # "Allow", "Forbid" or "Replace"
    active_deadline_seconds       = 300
    backoff_limit                 = 2
    restart_policy                = "Never"
    image                         = "bitnami/kubectl:latest"
  }
}
