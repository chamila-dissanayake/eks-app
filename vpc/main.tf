terraform {
  required_version = ">= 1.14.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.35.0"
    }
  }
}

provider "aws" {
  region = var.env.region

  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  role = "vpc"

  len_public_subnets  = length(var.vpc.public_subnets)
  len_private_subnets = length(var.vpc.private_subnets)
  len_azs             = length(var.vpc.azs)
  natgw_count         = local.len_public_subnets > 0 && local.len_private_subnets > 0 ? local.len_public_subnets : local.len_private_subnets

  short_identifier = format("%s", var.tags.Name)
}

/*
** VPC and Subnets
*/

resource "aws_vpc" "this" {
  cidr_block                       = var.vpc.cidr
  enable_dns_support               = var.vpc.enable_dns_support
  enable_dns_hostnames             = var.vpc.enable_dns_hostnames
  assign_generated_ipv6_cidr_block = var.vpc.enable_ipv6

  tags = {
    "Name" = format("%s", local.short_identifier)
  }
}

resource "aws_subnet" "public" {
  count = local.len_public_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.vpc.public_subnets[count.index]
  availability_zone = var.vpc.azs[count.index]

  tags = {
    "Name" = format("%s-public-%s", local.short_identifier, "${count.index}"),
    "Tier" = "public"
    # "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count = local.len_private_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.vpc.private_subnets[count.index]
  availability_zone = var.vpc.azs[count.index]

  tags = {
    "Name" = format("%s-private-%s", local.short_identifier, "${count.index}"),
    "Tier" = "private"
    # "kubernetes.io/role/internal-elb" = "1"
  }
}

/*
** Gateways and EIPs
*/

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    "Name" = format("%s-igw", local.short_identifier)
  }
}

resource "aws_egress_only_internet_gateway" "this" {
  count  = local.len_private_subnets > 0 && aws_vpc.this.assign_generated_ipv6_cidr_block ? 1 : 0
  vpc_id = aws_vpc.this.id
}


resource "aws_eip" "this" {
  count      = local.natgw_count
  depends_on = [aws_internet_gateway.this]

  tags = {
    "Name" = format("%s-eip-%s", local.short_identifier, "${count.index}")
  }
}

resource "aws_shield_protection" "ngw_eips_shield" {
  count        = local.natgw_count
  name         = format("%s-ngw-eip-%s", local.short_identifier, "${count.index}")
  resource_arn = "arn:aws:ec2:${var.env.region}:${data.aws_caller_identity.current.account_id}:eip-allocation/${aws_eip.this[count.index].id}"

  tags = {
    "Name" = format("%s-eip-%s-shield", local.short_identifier, "${count.index}")
  }
}

resource "aws_nat_gateway" "this" {
  count         = local.natgw_count
  subnet_id     = aws_subnet.public[count.index].id
  allocation_id = aws_eip.this[count.index].id
  depends_on    = [aws_internet_gateway.this]

  tags = {
    "Name" = format("%s-natgw", local.short_identifier)
  }
}

resource "aws_vpn_gateway" "this" {
  #count = var.vpc.vpg_asn > 0 ? 1 : 0

  vpc_id          = aws_vpc.this.id
  amazon_side_asn = var.vpc.vpg_asn

  tags = {
    "Name"       = format("%s-vpgw", local.short_identifier)
    "naas:spoke" = "awsu2"
  }
}


/*
** Route Tables
*/

# Public Route Table

resource "aws_route_table" "public" {
  count = local.len_public_subnets > 0 ? 1 : 0

  vpc_id           = aws_vpc.this.id
  propagating_vgws = [var.vpc.vpg_asn > 0 ? aws_vpn_gateway.this.id : ""]

  tags = {
    "Name" = format("%s-pub-rt", local.short_identifier)
  }
}

resource "aws_route_table_association" "public" {
  count          = local.len_public_subnets
  route_table_id = aws_route_table.public[0].id
  subnet_id      = aws_subnet.public[count.index].id
}

resource "aws_route" "public" {
  count          = length(aws_route_table.public)
  route_table_id = aws_route_table.public[count.index].id
  gateway_id     = aws_internet_gateway.this.id

  destination_cidr_block = "0.0.0.0/0"
}

# Private Route Table

resource "aws_route_table" "private" {
  count = local.len_private_subnets

  vpc_id           = aws_vpc.this.id
  propagating_vgws = [var.vpc.vpg_asn > 0 ? aws_vpn_gateway.this.id : ""]

  tags = {
    "Name"              = format("%s-pvt-rt", local.short_identifier),
    "availability-zone" = aws_subnet.private[count.index].availability_zone
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_route_table.private)

  route_table_id = aws_route_table.private[count.index].id
  subnet_id      = aws_subnet.private[count.index].id
}

resource "aws_route" "private" {
  count = length(aws_route_table.private) > 0 && local.natgw_count > 0 ? length(aws_route_table.private) : 0

  route_table_id = aws_route_table.private[count.index].id
  nat_gateway_id = aws_nat_gateway.this[count.index].id

  destination_cidr_block = "0.0.0.0/0"
}

/*
** VPC gateway endpoints
*/

# S3 Gateway Endpoint
resource "aws_vpc_endpoint" "s3" {
  #count        = var.vpc.vpc_endpoints.s3 ? 1 : 0
  service_name = "com.amazonaws.${var.env.region}.s3"
  vpc_id       = aws_vpc.this.id

  tags = {
    "Name" = format("%s-endpoint-s3", local.short_identifier)
  }
}

resource "aws_vpc_endpoint_route_table_association" "s3_public" {
  count = length(aws_route_table.public) #&& var.vpc.vpc_endpoints.s3 ? length(aws_route_table.public) : 0

  route_table_id  = aws_route_table.public[count.index].id
  vpc_endpoint_id = aws_vpc_endpoint.s3.id
}

resource "aws_vpc_endpoint_route_table_association" "s3_private" {
  count = length(aws_route_table.private) #&& var.vpc.vpc_endpoints.s3 ? length(aws_route_table.private) : 0

  route_table_id  = aws_route_table.private[count.index].id
  vpc_endpoint_id = aws_vpc_endpoint.s3.id
}

# DynamoDB Gateway Endpoint
resource "aws_vpc_endpoint" "dynamodb" {
  #count        = var.vpc.vpc_endpoints.dynamodb ? 1 : 0
  service_name = "com.amazonaws.${var.env.region}.dynamodb"
  vpc_id       = aws_vpc.this.id
  tags = {
    "Name" = format("%s-endpoint-dynamodb", local.short_identifier)
  }
}

resource "aws_vpc_endpoint_route_table_association" "dynamodb_public" {
  count           = length(aws_route_table.public) #&& var.vpc.vpc_endpoints.dynamodb ? length(aws_route_table.public) : 0
  route_table_id  = aws_route_table.public[count.index].id
  vpc_endpoint_id = aws_vpc_endpoint.dynamodb.id
}

resource "aws_vpc_endpoint_route_table_association" "dynamodb_private" {
  count           = length(aws_route_table.private) #&& var.vpc.vpc_endpoints.dynamodb ? length(aws_route_table.private) : 0
  route_table_id  = aws_route_table.private[count.index].id
  vpc_endpoint_id = aws_vpc_endpoint.dynamodb.id
}

# Security Group for VPC Endpoints
resource "aws_security_group" "vpce_sg" {
  vpc_id = aws_vpc.this.id
  name   = format("%s-sg-vpc-endpoints", var.tags.Name)

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.vpc.private_subnets
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    "Name" = format("%s-sg-vpc-endpoints", var.tags.Name)
  }
}

# API Gateway Endpoint
resource "aws_vpc_endpoint" "api_gw" {
  count               = var.vpc.vpc_endpoints.api_gw ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.execute-api"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-apigw", local.short_identifier)
  }
}

# CloudWatch Logs Gateway Endpoint
resource "aws_vpc_endpoint" "cloudwatch_logs" {
  count               = var.vpc.vpc_endpoints.cloudwatch_logs ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.logs"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-cloudwatch-logs", local.short_identifier)
  }
}

# Certificate Manager Gateway Endpoint
resource "aws_vpc_endpoint" "acm" {
  count               = var.vpc.vpc_endpoints.acm ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.acm"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-acm", local.short_identifier)
  }
}

# SNS Gateway Endpoint
resource "aws_vpc_endpoint" "sns" {
  count               = var.vpc.vpc_endpoints.sns ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.sns"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-sns", local.short_identifier)
  }
}

# SQS Gateway Endpoint
resource "aws_vpc_endpoint" "sqs" {
  count               = var.vpc.vpc_endpoints.sqs ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.sqs"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-sqs", local.short_identifier)
  }
}

# Lambda Gateway Endpoint
resource "aws_vpc_endpoint" "lambda" {
  count               = var.vpc.vpc_endpoints.lambda ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.lambda"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-lambda", local.short_identifier)
  }
}

# Secrets Manager gateway Endpoint
resource "aws_vpc_endpoint" "secrets_manager" {
  count               = var.vpc.vpc_endpoints.secrets_manager ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.secretsmanager"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-secrets-manager", local.short_identifier)
  }
}

# Systems Manager gateway Endpoint
resource "aws_vpc_endpoint" "ssm" {
  count               = var.vpc.vpc_endpoints.ssm ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.ssm"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-ssm", local.short_identifier)
  }
}

# EC2 Messages gateway Endpoint
resource "aws_vpc_endpoint" "ec2_messages" {
  count               = var.vpc.vpc_endpoints.ec2messages ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.ec2messages"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-ec2-messages", local.short_identifier)
  }
}

# EC2 gateway Endpoint
resource "aws_vpc_endpoint" "ec2" {
  count               = var.vpc.vpc_endpoints.ec2 ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.ec2"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-ec2", local.short_identifier)
   }
}

# ECR API gateway Endpoint
resource "aws_vpc_endpoint" "ecr_api" {
  count               = var.vpc.vpc_endpoints.ecr_api ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.ecr.api"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-ecr-api", local.short_identifier)
  }
}

# ECR DKR gateway Endpoint
resource "aws_vpc_endpoint" "ecr_dkr" {
  count               = var.vpc.vpc_endpoints.ecr_dkr ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.ecr.dkr"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-ecr-dkr", local.short_identifier)
  }
}

# EKS gateway Endpoint
resource "aws_vpc_endpoint" "eks" {
  count               = var.vpc.vpc_endpoints.eks ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.eks"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-eks", local.short_identifier)
  }
}

# SSM Messages gateway Endpoint
resource "aws_vpc_endpoint" "ssmmessages" {
  count               = var.vpc.vpc_endpoints.ssmmessages ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.ssmmessages"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-ssm-messages", local.short_identifier)
  }
}

# CloudFormation Gateway Endpoint
resource "aws_vpc_endpoint" "cloud_formation" {
  count               = var.vpc.vpc_endpoints.cloud_formation ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.cloudformation"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-cloudformation", local.short_identifier)
  }
}

# EFS Gateway Endpoint
resource "aws_vpc_endpoint" "efs" {
  count               = var.vpc.vpc_endpoints.efs ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.elasticfilesystem"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-efs", local.short_identifier)
  }
}

# Kinesis Gateway Endpoint
resource "aws_vpc_endpoint" "kinesis" {
  count               = var.vpc.vpc_endpoints.kinesis ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.kinesis-streams"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-kinesis", local.short_identifier)
  }
}

# Directory Service Endpoint
resource "aws_vpc_endpoint" "directory_service" {
  count               = var.vpc.vpc_endpoints.directory_service ? 1 : 0
  service_name        = "com.amazonaws.${var.env.region}.ds"
  vpc_id              = aws_vpc.this.id
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sg.id]
  subnet_ids          = aws_subnet.private.*.id

  tags = {
    "Name" = format("%s-endpoint-directory-service", local.short_identifier)
  }
}

/*
** VPC flow logs S3
*/

resource "aws_s3_bucket" "vpc_flow_log" {
  count  = var.vpc.flow_logs_s3.enabled ? 1 : 0
  bucket = "prsn-vpc-flow-logs-${var.env.region}-${data.aws_caller_identity.current.account_id}"

  tags = {
    "Name" = format("%s-vpc-flow-logs", local.short_identifier)
  }
}

resource "aws_s3_bucket_ownership_controls" "vpc_flow_log" {
  count  = var.vpc.flow_logs_s3.enabled ? 1 : 0
  bucket = aws_s3_bucket.vpc_flow_log[0].id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "vpc_flow_log" {
  count      = var.vpc.flow_logs_s3.enabled ? 1 : 0
  depends_on = [aws_s3_bucket_ownership_controls.vpc_flow_log]

  bucket = aws_s3_bucket.vpc_flow_log[0].id
  acl    = "private"
}


resource "aws_s3_bucket_versioning" "vpc_flow_log" {
  count  = var.vpc.flow_logs_s3.enabled ? 1 : 0
  bucket = aws_s3_bucket.vpc_flow_log[0].id
  versioning_configuration {
    status = "Suspended"
  }
}

resource "aws_s3_bucket_logging" "vpc_flow_log" {
  count  = var.vpc.flow_logs_s3.enabled ? 1 : 0
  bucket = aws_s3_bucket.vpc_flow_log[0].id

  target_bucket = "prsn-s3-access-logs-${var.env.region}-${data.aws_caller_identity.current.account_id}"
  target_prefix = "log/"
}

resource "aws_s3_bucket_lifecycle_configuration" "bucket_config" {
  bucket = aws_s3_bucket.vpc_flow_log[0].id

  rule {
    id     = "log"
    status = "Enabled"
    expiration {
      days = var.vpc.flow_logs_s3.expiration_days
    }
    noncurrent_version_expiration {
      newer_noncurrent_versions = 1
      noncurrent_days           = var.vpc.flow_logs_s3.permanently_delete_after_days
    }
  }
}

resource "aws_flow_log" "vpc_flow_log_s3" {
  count = var.vpc.flow_logs_s3.enabled ? 1 : 0

  log_destination      = aws_s3_bucket.vpc_flow_log[0].arn
  log_destination_type = "s3"
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.this.id

  tags = {
    "Name" = format("%s-vpc-flow-logs", local.short_identifier)
  }
}

/*
** vpc flow logs cloudwatch
*/

resource "aws_cloudwatch_log_group" "vpc_flow_log" {
  count = var.vpc.flow_logs_cloudwatch.enabled ? 1 : 0

  name              = "${var.tags.Name}-vpc-flow-logs"
  retention_in_days = var.vpc.flow_logs_cloudwatch.retention_days
}


resource "aws_flow_log" "vpc_flow_log" {
  count = var.vpc.flow_logs_cloudwatch.enabled ? 1 : 0

  iam_role_arn         = aws_iam_role.vpc_flow_role_cloudwatch[0].arn
  log_destination      = aws_cloudwatch_log_group.vpc_flow_log[0].arn
  log_destination_type = "cloud-watch-logs"
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.this.id
}

resource "aws_iam_role" "vpc_flow_role_cloudwatch" {
  count = var.vpc.flow_logs_cloudwatch.enabled ? 1 : 0

  name = "${var.tags.Name}-vpc-flow"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "vpc_flow_cloudwatch" {
  count = var.vpc.flow_logs_cloudwatch.enabled ? 1 : 0
  name  = "${var.tags.Name}-vpc-flow"
  role  = aws_iam_role.vpc_flow_role_cloudwatch[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "${aws_cloudwatch_log_group.vpc_flow_log[0].arn}:*"
      }
    ]
  })
}