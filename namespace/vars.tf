variable "env" {
  description = "Environment variables"
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags to be applied to all resources"
  type        = map(string)
  default     = {}
}

variable "namespace" {
  description = "Namespace for the Kubernetes resources"
  type        = string
  default     = ""
}

variable "alb" {
  description = "ALB configuration"
  type        = object({
    service_account_name = optional(string, "load-balancer-controller")
    lb_controller_repo   = optional(string, "https://aws.github.io/eks-charts")
    timeout              = optional(number, 10000)
  })
}

variable "secrets" {
  description = "Secrets configuration"
  type        = object({
    service_account_name               = optional(string, "secrets-provider")
    csi_driver_version                 = optional(string, "1.5.4")
    csi_driver_repo                    = optional(string, "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts")
    csi_driver_provider_aws_version    = optional(string, "2.1.1")
    csi_driver_provider_aws_repo       = optional(string, "https://aws.github.io/secrets-store-csi-driver-provider-aws")
    csi_driver_sync_secret_enabled     = optional(bool, true)
    csi_driver_secret_rotation_enabled = optional(bool, true)
    csi_driver_rotation_poll_interval  = optional(string, "3m")
  })
}