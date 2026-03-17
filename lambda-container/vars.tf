variable "env" {
  description = "The environment in which the Lambda function is deployed"
  type        = map(string)
  default = {}
}

variable "tags" {
  description = "A map of tags to assign to the resources"
  type        = map(string)
  default     = {}
}

variable "lambda" {
  description = "A map of Lambda function configuration options"
  type = object({
    function_name          = string
    memory_size            = optional(number, 2250)
    timeout                = optional(number, 60)
    architectures          = optional(list(string), ["x86_64"])
    handler                = optional(string, "lambda_har_3c")
    enable_vpc             = bool
    environment_variables  = map(string)
    image                  = map(string)
    newrelic_apm_enabled   = optional(bool, false)
    newrelic_secret_id     = optional(string, "")
  })
  default = {
    function_name          = ""
    memory_size            = 2250
    timeout                = 60
    architectures          = ["x86_64"]
    enable_vpc             = true
    environment_variables  = {}
    image                  = {
      repo            = ""
      tag             = ""
      entry_point     = ""
      command         = ""
    }
  }
}

variable "cloudwatch_logs_retention_in_days" {
  description = "The number of days to retain logs in CloudWatch"
  type        = number
  default     = 7
}

variable "iam_role_managed_policies" {
  description = "List of AWS managed IAM policies to attach to the Lambda IAM role"
  type        = list(string)
  default = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  ]
}