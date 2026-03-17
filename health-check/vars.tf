variable "env" {
  description = "Environment variables for the CloudFront module"
  type        = any
}

variable "tags" {
  description = "Tags to be applied to the CloudFront resources"
  type        = any
}

variable "role" {
  description = "Role of the CloudFront module, e.g., 'front-office-ui'"
  type        = string
  default     = "health-check"
}

variable "health_checks" {
  description = "Health checks configuration for the CloudFront module"
  type = list(object({
    disabled          = bool
    name              = string
    fqdn              = string
    port              = number
    type              = string
    resource_path     = string
    failure_threshold = number
    request_interval  = number
    regions           = list(string)
    measure_latency   = bool
  }))
}

variable "alarms" {
  description = "Alarms configuration for the CloudFront module"
  type = list(object({
    name                = string
    comparison_operator = string
    evaluation_periods  = number
    metric_name         = string
    period              = number
    statistic           = string
    threshold           = number
    alarm_description   = string
    actions_enabled     = bool
    alarm_actions       = list(string)
    ok_actions          = list(string)
    treat_missing_data  = string
    dimensions          = map(string)
  }))
}
