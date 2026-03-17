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
  short_identifier = "${var.tags.environment}-${var.lambda.function_name}"
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
  function_name = "${local.short_identifier}"
  description   = "Lambda function ${local.short_identifier}"
  handler       = var.lambda.handler
  role          = aws_iam_role.lambda.arn
  runtime       = var.lambda.runtime
  memory_size   = var.lambda.memory_size
  timeout       = var.lambda.timeout
  architectures = var.lambda.architectures
  publish       = var.lambda.publish

  # get the source code from an S3 bucket instead of a local file
  s3_bucket = var.lambda.s3_bucket
  s3_key    = "${var.lambda.s3_directory}/${var.lambda.function_name}/${var.lambda.artifact_version}.zip"

  ephemeral_storage {
    size = var.lambda.ephemeral_storage_size
  }

  # attach the Lambda function to a VPC
  # Conditionally include vpc_config
  dynamic "vpc_config" {
    for_each = var.lambda.enable_vpc ? [1] : []
    content {
      subnet_ids         = data.aws_subnets.private.ids
      security_group_ids = [ data.aws_security_group.rds_sg.id, data.aws_security_group.eks_node_sg.id ]
    }
  }

  # attach multiple layers to the Lambda function using toset() function
  layers = toset(var.lambda.layers)

  # add multiple environment variables to the Lambda function
  environment {
    variables = {
      for k, v in var.lambda.environment_variables : k => v
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
  name               = "${local.short_identifier}-role"
  description        = "Role for lambda function ${var.lambda.function_name}"
  assume_role_policy = file("${path.module}/policies/aws_lambda_iam_role.json")
}
#==============================================================================
# Attach multiple AWS managed IAM policies to the Lambda IAM role
#==============================================================================
resource "aws_iam_role_policy_attachment" "lambda" {
  for_each   = toset(var.iam_role_managed_policies)
  role       = aws_iam_role.lambda.name
  policy_arn = each.value
}
#==============================================================================
# Create a Custom IAM Policy for the Lambda IAM role
#==============================================================================
resource "aws_iam_policy" "lambda_custom" {
  name        = "${local.short_identifier}-policy"
  description = "Policy for lambda function ${aws_lambda_function.main.function_name}"

  policy = templatefile("${path.module}/policies/lambda.json", {
    aws_account    = data.aws_caller_identity.current.account_id
    aws_region     = var.env.region
    s3_bucket_name = var.lambda.s3_bucket
    function_name  = "${aws_lambda_function.main.function_name}"
  })
}
#==============================================================================
# Attach custom IAM policy to the Lambda IAM role
#==============================================================================
resource "aws_iam_role_policy_attachment" "lambda_custom_attach" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_custom.arn

  depends_on = [
    aws_iam_policy.lambda_custom,
    aws_iam_role.lambda
  ]
}

#==============================================================================
# Create a Custom IAM Policy II for the Lambda IAM role
#==============================================================================
resource "aws_iam_policy" "lambda_custom_2" {
  count = var.lambda.custom_policy_file != "" ? 1 : 0

  name        = "${local.short_identifier}-policy-II"
  description = "Customizable policy for lambda function ${aws_lambda_function.main.function_name}"

  policy = templatefile(var.lambda.custom_policy_file, {
    aws_account    = data.aws_caller_identity.current.account_id
    aws_region     = var.env.region
    environment    = var.tags.environment
  })
}
#==============================================================================
# Attach custom IAM policy II to the Lambda IAM role
#==============================================================================
resource "aws_iam_role_policy_attachment" "lambda_custom_attach_2" {
  count = var.lambda.custom_policy_file != "" ? 1 : 0

  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_custom_2[0].arn

  depends_on = [
    aws_iam_policy.lambda_custom_2,
    aws_iam_role.lambda
  ]
}

#==============================================================================
# Manage CloudWatch Logs Group retention policy for the Lambda function
#==============================================================================
resource "aws_cloudwatch_log_group" "main" {
  name              = "/aws/lambda/${aws_lambda_function.main.function_name}"
  retention_in_days = var.cloudwatch_logs_retention_in_days
}
#==============================================================================
# Lambda function event invoke config
#==============================================================================
/*
resource "aws_lambda_function_event_invoke_config" "main" {
  function_name                = aws_lambda_function.main.function_name
  qualifier                    = "$LATEST"
  maximum_event_age_in_seconds = var.maximum_event_age_in_seconds
  maximum_retry_attempts       = var.maximum_retry_attempts
}*/
#==============================================================================