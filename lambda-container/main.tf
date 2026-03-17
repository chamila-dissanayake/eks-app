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

#==============================================================================
# Secret Manager secret read for Newrelic License Key
#==============================================================================
data "aws_secretsmanager_secret_version" "newrelic" {
  count     = var.lambda.newrelic_apm_enabled ? 1 : 0
  secret_id = var.lambda.newrelic_secret_id == "" ? "${lower(var.tags.t_environment)}/newrelic" : var.lambda.newrelic_secret_id
}

locals {
  short_identifier = "${var.tags.environment}-${var.lambda.function_name}"
  newrelic_secrets = var.lambda.newrelic_apm_enabled ? jsondecode(data.aws_secretsmanager_secret_version.newrelic[0].secret_string) : {}

  env_vars = merge(
    var.lambda.environment_variables,
    var.lambda.newrelic_apm_enabled ? {
      "NEW_RELIC_ACCOUNT_ID"                   = local.newrelic_secrets.account_id
      "NEW_RELIC_LICENSE_KEY"                  = local.newrelic_secrets.license_key
      "NEW_RELIC_APP_NAME"                     = local.short_identifier
      "NEW_RELIC_LAMBDA_HANDLER"               = var.lambda.handler
      "NEW_RELIC_EXTENSION_SEND_FUNCTION_LOGS" = true
      "NEW_RELIC_LAMBDA_EXTENSION_ENABLED"     = true
      "NEW_RELIC_DATA_COLLECTION_TIMEOUT"      = "10s"
    } : {}
  )
}

data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = [var.env.account_name]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.vpc.id]
  }

  tags = {
    Tier = "private"
  }
}

data "aws_security_group" "rds_sg" {
  filter {
    name   = "tag:Name"
    values = ["${var.tags.environment}-rds-sg"]
  }
}

data "aws_security_group" "eks_node_sg" {
  filter {
    name   = "tag:Name"
    values = ["${var.tags.environment}-eks-node-sg"]
  }
}

#==============================================================================
# Data AWS Caller Identity to get the AWS Account ID
#=============================================================================
data "aws_caller_identity" "current" {}

#==============================================================================
# AWS Lambda Function
#==============================================================================
resource "aws_lambda_function" "main" {
  function_name = local.short_identifier
  description   = "Lambda function ${local.short_identifier}"
  role          = aws_iam_role.lambda.arn
  memory_size   = var.lambda.memory_size
  timeout       = var.lambda.timeout
  package_type  = "Image"
  image_uri     = "${var.env.ecr_account}.dkr.ecr.${var.env.region}.amazonaws.com/${var.lambda.image.repo}:${var.lambda.image.tag}"
  architectures = var.lambda.architectures

  #image_config {
  #  entry_point = var.lambda.image_entry_point
  #  command     = var.lambda.image_command
  #}

  # attach the Lambda function to a VPC
  # Conditionally include vpc_config
  dynamic "vpc_config" {
    for_each = var.lambda.enable_vpc ? [1] : []
    content {
      subnet_ids         = data.aws_subnets.private.ids
      security_group_ids = [data.aws_security_group.rds_sg.id, data.aws_security_group.eks_node_sg.id]
    }
  }

  # add multiple environment variables to the Lambda function
  environment {
    variables = {
      for k, v in local.env_vars : k => v
    }
  }

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s", "${local.short_identifier}") })
  )
}
#==============================================================================
# IAM role for AWS Lambda Function
#==============================================================================
resource "aws_iam_role" "lambda" {
  name        = "${local.short_identifier}-role"
  description = "Role for lambda function ${var.lambda.function_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      },
    ]
  })
}

data "aws_iam_policy_document" "basic_policy_doc" {
  statement {
    sid    = "1"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:${var.env.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.short_identifier}:*"
    ]
  }
  statement {
    sid    = "2"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ]
    resources = [
      "arn:aws:ecr:${var.env.region}:${var.env.ecr_account}:repository/${var.lambda.image.repo}"
    ]
  }
  statement {
    sid    = "3"
    effect = "Allow"
    actions = [
      "secretsmanager:Describe*",
      "secretsmanager:Get*",
      "secretsmanager:List*"
    ]
    resources = ["arn:aws:secretsmanager:${var.env.region}:${data.aws_caller_identity.current.account_id}:secret:*"]
  }
}

resource "aws_iam_policy" "basic_policy" {
  name        = "${local.short_identifier}-policy"
  description = "Basic policy for lambda function ${var.lambda.function_name}"

  policy = data.aws_iam_policy_document.basic_policy_doc.json
}

resource "aws_iam_policy_attachment" "attach_basic_policy" {
  name       = "${local.short_identifier}-attach-basic-policy"
  policy_arn = aws_iam_policy.basic_policy.arn
  roles      = [aws_iam_role.lambda.name]
}

#==============================================================================
# Attach multiple AWS managed IAM policies to the Lambda IAM role
#==============================================================================
resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.iam_role_managed_policies)
  role       = aws_iam_role.lambda.name
  policy_arn = each.value
}

#==============================================================================
# Manage CloudWatch Logs Group retention policy for the Lambda function
#==============================================================================
resource "aws_cloudwatch_log_group" "main" {
  name              = "/aws/lambda/${aws_lambda_function.main.function_name}"
  retention_in_days = var.cloudwatch_logs_retention_in_days
}

