variable "env" {
  description = "Common environment variables"
  type        = map(any)
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "ami" {
  description = "Configuration for the AMI to be copied"
  type        = map(any)
  default = {
    ami_name            = ""
    eks_cluster_version = "1.33"
    source_owner        = ""
    date                = "20250621"
    operating_system    = "amzn2023"
    architecture        = "x86_64"
    kms_key_id          = ""
    encrypted          = true
  }
}