variable "env" {
  description = "Environment name"
  type        = map(any)
}

variable "tags" {
  description = "Tags to be applied to all resources"
  type        = map(any)
}

variable "layers" {
  description = "Configs of the Lambda layer"
  type = map(object({
    filename      = string
    s3_bucket     = string
    s3_directory  = string
    runtimes      = list(string)
    architectures = list(string)
  }))
}
