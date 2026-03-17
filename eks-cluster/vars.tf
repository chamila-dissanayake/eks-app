variable "env" {
  description = "Common environment variables"
  type        = map(any)
}

variable "eks" {
  description = "EKS Cluster configurations"
  type        = map(any)
  default = {
    cluster_version          = "1.33"
    endpoint_private_access  = true
    endpoint_public_access   = false
    desired_size             = "2"
    max_size                 = "4"
    min_size                 = "1"
    instance_type            = "t3.medium"
    capacity_type            = "ON_DEMAND"
    disk_size                = "50"
    metrics_server_enabled   = true
    metrics_server_pod_count = 1 # Set to 0 to disable metrics server
  }
}

variable "eks_access_entry_points" {
  description = "List of CIDR blocks allowed to access the EKS API server"
  type        = list(object({
    principal_arn     = string
    type              = string
    kubernetes_groups = list(string)
    user_name          = string
  }))
  default     = [
    {
      principal_arn     = "arn:aws:iam::aws:policy/ReadOnlyAccess"
      type              = "IAM"
      kubernetes_groups = ["system:masters"]
      user_name         = "readonly-user"
    }
  ]
}

variable "eks_access_policy_assoc" {
  description = "List of IAM policies to associate with the EKS cluster"
  type        = list(object({
    eks_policy_arn = string
    principal_arn  = string
    username       = string
    groups         = list(string)
  }))
}

variable "endpoint_private_access" {
  description = "Enable private API server endpoint access"
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Enable public API server endpoint access"
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "Clinical Jenkins public IPs to whitelist"
  type        = list(string)
  default = [

  ]
}

variable "security_group_ids" {
  description = "List of security group IDs for the EKS cluster"
  type        = list(string)
  default     = []
}

variable "enabled_cluster_log_types" {
  description = "List of desired control plane logging to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "labels" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
