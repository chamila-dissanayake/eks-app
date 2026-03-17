variable "env" {
  description = "Common environment variables"
  type        = map(any)
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(any)
}

variable "ami_owners" {
  description = "Owner of the AMI"
  type        = list(string)
  default     = ["self", ""]
}

variable "bastion" {
  description = "Default values for bastion host"
  type        = map(any)
  default = {
    instance_type        = "t2.micro"
    instance_arch        = "x86_64"
    ami_name_filter      = ""
    key_name             = ""
    use_eip              = false
    root_vol_type        = "gp3"
    root_vol_size        = 40
    root_vol_del_on_term = true
    dns_record_ttl       = 60
  }
}

variable "forward_only_sshkey" {
  type        = string
  description = "Path to the forward-only SSH private key"
  default     = ""
}

variable "ssh_ingress_cidr" {
  description = "CIDRs allowed to SSH into bastion host"
  type        = list(string)
  default     = []
}

variable "ipv6_ingress_cidrs" {
  type        = list(any)
  description = "IPv6 CIDR blocks allowed to connect to the bastion host"
  default     = []
}

variable "eks" {
  description = "EKS cluster configuration"
  type        = map(any)
  default = {
    cluster_name = ""
    namespace    = ""
  }
}