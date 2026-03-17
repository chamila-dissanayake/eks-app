variable "env" {
  description = "The common environmet variables"
  type        = map(any)
  default     = {}
}

variable "tags" {
  description = "Common tags for the environment"
  type        = map(any)
  default     = {}
}

variable "lambda" {
  description = "Lambda function configuration"
  type = object(
    {
      function_name          = string
      artifact_version       = string
      ephemeral_storage_size = number
      handler                = string
      memory_size            = number
      publish                = bool
      runtime                = string
      s3_bucket              = string
      s3_directory           = string
      timeout                = number
      architectures          = list(string)
      enable_vpc             = bool
      environment_variables  = map(any)
      custom_policy_file     = optional(string, "")
      layers                 = list(string)

    }
  )
  default = {
    function_name          = ""
    artifact_version       = "1.00"
    ephemeral_storage_size = 512
    handler                = ""
    memory_size            = 128
    publish                = true
    runtime                = "python3.8"
    s3_bucket              = ""
    s3_directory           = ""
    timeout                = 60
    architectures          = ["x86_64"]
    enable_vpc             = true
    environment_variables  = {}
    custom_policy_file     = "s3_access.json"
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
    "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  ]
}