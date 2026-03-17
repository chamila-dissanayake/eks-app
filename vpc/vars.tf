variable "env" {
  description = "Common environment variables"
  type        = map(any)
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(any)
}

variable "vpc" {
  description = "VPC configuration"
  type = object({
    cidr                  = string
    private_subnets       = list(string)
    public_subnets        = list(string)
    azs                   = list(string)
    enable_private_nat_gw = bool
    enable_dns_support       = bool
    enable_dns_hostnames     = bool
    enable_ipv6              = bool
    vpg_asn                  = number
    flow_logs_s3             = map(string)
    flow_logs_cloudwatch     = map(string)
    vpc_endpoints            = map(bool)
  })
  default = {
    cidr                  = "10.1.0.0/16"
    private_subnets       = ["10.1.1.0/24", "10.1.2.0/24"]
    public_subnets        = ["10.1.10.0/24", "10.1.11.0/24"]
    azs                   = ["us-east-1a", "us-east-1b"]
    enable_private_nat_gw = false
    enable_dns_support    = true
    enable_dns_hostnames  = true
    enable_ipv6           = true
    vpg_asn               = 64523
    flow_logs_s3 = {
      enabled                       = true
      expiration_days               = 90
      permanently_delete_after_days = 90
    }
    flow_logs_cloudwatch = {
        enabled        = false
        retention_days = 30
    }
    vpc_endpoints = {
      acm               = true
      api_gw            = true
      cloud_formation   = true
      cloudwatch_logs   = true
      directory_service = false
      dynamodb          = true
      ec2               = true
      ec2messages       = true
      ecr_api           = true
      ecr_dkr           = true
      efs               = false
      eks               = true
      kinesis           = false
      lambda            = true
      s3                = true
      secrets_manager   = true
      sns               = true
      sqs               = false
      ssm               = true
      ssmmessages       = true
    }
  }
}
