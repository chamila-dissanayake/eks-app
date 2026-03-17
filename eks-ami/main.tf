terraform {
  required_version = ">= 1.14.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.env.region
}

locals {
  kms_key_id = var.ami.kms_key_id == "" ? "${var.tags.environment}-eks-key" : var.ami.kms_key_id
  date       = chomp(formatdate("YYYYMMDD", timestamp()))
}

# Find the EKS node group KMS key
data "aws_kms_alias" "kms_key" {
  name = "alias/${var.tags.environment}-eks-key"
}

# Find the PCM EKS AMI
data "aws_ami" "source_ami" {
  owners      = ["${var.ami.source_owner}"]
  most_recent = true

  filter {
    name   = "name"
    values = ["*${var.ami.ami_name}*"]
  }
  filter {
    name  = "architecture"
    values = [var.ami.architecture]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Copy the AMI to the destination region
resource "aws_ami_copy" "copied_ami" {
  name              = "${data.aws_ami.source_ami.name}-${local.date}"
  description       = "Copy of ${data.aws_ami.source_ami.id} from ${var.env.region}"
  source_ami_id     = data.aws_ami.source_ami.id
  source_ami_region = var.env.region
  encrypted         = var.ami.encrypted
  kms_key_id        = var.ami.kms_key_id == "" ? data.aws_kms_alias.kms_key.id : var.ami.kms_key_id

  tags = merge(
    var.tags,
    {
      Name = "${data.aws_ami.source_ami.name}-${local.date}"
    }
  )
}

# Output the new AMI ID
output "copied_ami_id" {
  value = aws_ami_copy.copied_ami.id
}
