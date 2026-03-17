provider "aws" {
  region = var.env.region
}

provider "aws" {
  alias  = "virginia"
  region = "us-east-1"
}

locals {
  role             = "shield"
  short_identifier = format("%s-%s", var.tags.environment, local.role)
}


data "aws_iam_policy" "drt_policy" {
  name = var.drt_policy
}

# Create SRT IAM role
resource "aws_iam_role" "drt_role" {
  name = "${var.tags["Name"]}-shield-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "drt.shield.amazonaws.com"
        }
      },
    ]
  })

  #tags = var.tags
  tags = merge(var.tags,
    tomap({ Name = "${local.short_identifier}-iam-role" })
  )
}

#Attach policy for SRT access
resource "aws_iam_role_policy_attachment" "srt" {
  role       = aws_iam_role.drt_role.name
  policy_arn = data.aws_iam_policy.drt_policy.arn
}

# Associate drt role to shield 
resource "null_resource" "associate_drt_role" {
  triggers = {
    drt_role_arn = aws_iam_role.drt_role.arn
  }

  provisioner "local-exec" {
    command = "aws shield associate-drt-role --role-arn ${aws_iam_role.drt_role.arn}"
  }
}

resource "aws_shield_protection_group" "group_eip" {
  protection_group_id = "${local.short_identifier}-eip-grp"
  aggregation         = "SUM"
  pattern             = "BY_RESOURCE_TYPE"
  resource_type       = "ELASTIC_IP_ALLOCATION"

  tags = merge(var.tags, { Name = "${local.short_identifier}-eip-grp" })
}

resource "aws_shield_protection_group" "group_alb" {
  protection_group_id = "${local.short_identifier}-alb-grp"
  aggregation         = "MEAN"
  pattern             = "BY_RESOURCE_TYPE"
  resource_type       = "APPLICATION_LOAD_BALANCER"

  tags = merge(var.tags, { Name = "${local.short_identifier}-alb-grp" })
}

resource "aws_shield_protection_group" "group_r53" {
  protection_group_id = "${local.short_identifier}-r53-grp"
  aggregation         = "SUM"
  pattern             = "BY_RESOURCE_TYPE"
  resource_type       = "ROUTE_53_HOSTED_ZONE"

  tags = merge(var.tags, { Name = "${local.short_identifier}-r53-grp" })
}

resource "aws_shield_protection_group" "group_cfd" {
  protection_group_id = "${local.short_identifier}-cfd-grp"
  aggregation         = "MAX"
  pattern             = "BY_RESOURCE_TYPE"
  resource_type       = "CLOUDFRONT_DISTRIBUTION"

  tags = merge(var.tags, { Name = "${local.short_identifier}-cfd-grp" })
}

data "aws_route53_zone" "zone" {
  name         = var.env.domain
  private_zone = false
}

resource "aws_shield_protection" "route53_zone" {
  name = "${local.short_identifier}-r53-zone"
  resource_arn = data.aws_route53_zone.zone.arn

  tags = merge(var.tags, { Name = "${local.short_identifier}-r53-zone" })
}