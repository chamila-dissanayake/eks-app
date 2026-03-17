variable "env" {
  description = "Common environment variables"
  type        = map(any)
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(any)
}

variable "drt_policy" {
  description = "The name of the IAM policy to attach to the DRT role"
  type        = string
  default     = "AWSShieldDRTAccessPolicy"
}