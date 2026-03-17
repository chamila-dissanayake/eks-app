variable "env" {
  description = "Environment variables for the API call scheduler"
  type        = map(string)
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(any)
}

variable "lambda" {
  description = "Configuration for the Lambda function"
  type = object({
    function_name          = string
    script_name            = string
    ephemeral_storage_size = optional(number, 512)
    publish                = optional(bool, true)
    architectures          = optional(list(string), ["x86_64"])
    runtime                = optional(string, "python3.13")
    timeout                = optional(number, 30)
    memory_size            = optional(number, 512)
    layers                 = list(string)
    environment_variables  = map(string)
  })
}

variable "schedule" {
  description = "Lambda function scheduling configuration"
  type = object({
    enabled         = bool
    cron_expression = string
    state           = optional(string, "ENABLED")
    input_transformer = optional(object({
      input_paths    = optional(map(string), {})
      input_template = string
    }), null)
    retry_policy = optional(object({
      maximum_retry_attempts       = optional(number, 3)
      maximum_event_age_in_seconds = optional(number, 3600)
      }), {
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 3600
    })
    dead_letter_queue_arn = optional(string, null)
  })
  default = {
    enabled         = true
    cron_expression = "cron(0 7 * * ? *)" # Default: 2 AM daily
  }
}

variable "iam_role_managed_policies" {
  description = "List of AWS managed IAM policies to attach to the Lambda IAM role"
  type        = list(string)
  default = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole",
    "arn:aws:iam::aws:policy/AWSLambdaExecute"
  ]
}

variable "cloudwatch_logs_retention_in_days" {
  description = "Number of days to retain CloudWatch logs"
  type        = number
  default     = 7
}

variable "monitoring" {
  description = "CloudWatch monitoring and alerting configuration"
  type = object({
    enabled                  = bool
    namespace                = optional(string, "CustomLambdaMetrics")
    alarm_evaluation_periods = optional(number, 3)
    alarm_period             = optional(number, 60)
    datapoints_to_alarm      = optional(number, 3)
    failiure_threshold       = optional(number, 3)
    error_threshold          = optional(number, 3)
    alarm_actions            = optional(list(string), [])
    ok_actions               = optional(list(string), [])
  })
  default = {
    enabled = false
  }
}
