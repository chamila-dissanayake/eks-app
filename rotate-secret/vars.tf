variable "env" {
  description = "Environment name"
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "lambda" {
  description = "Lambda function configuration"
  type = object(
    {
      function_name          = string
      script_name            = string
      ephemeral_storage_size = number
      memory_size            = number
      publish                = bool
      runtime                = string
      timeout                = number
      architectures          = list(string)
      environment_variables  = map(any)
      layers                 = list(string)

    }
  )
  default = {
    function_name          = ""
    script_name            = "rotate_secret"
    ephemeral_storage_size = 512
    memory_size            = 128
    publish                = true
    runtime                = "python3.13"
    timeout                = 60
    architectures          = ["x86_64"]
    environment_variables  = {}
    layers                 = []
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
    "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole",
    "arn:aws:iam::aws:policy/AWSLambdaExecute"
  ]
}