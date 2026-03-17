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

data "aws_security_group" "vpc_endpoints_sg" {
  filter {
    name   = "tag:Name"
    values = ["${var.tags.environment}-vpc-endpoints-sg"]
  }
}

data "aws_secretsmanager_secret" "secret" {
  name = var.lambda.environment_variables["SECRET_ID"]
}

#==============================================================================
# Data AWS Caller Identity to get the AWS Account ID
#=============================================================================
data "aws_caller_identity" "current" {}

#==============================================================================
# AWS Lambda Function
#==============================================================================
data "archive_file" "lambda_zip" {
  type       = "zip"
  source_file = "${path.module}/source/${var.lambda.script_name}.py"
  output_path = "${path.module}/source/${var.lambda.script_name}.zip"
}

resource "aws_lambda_function" "main" {
  filename      = data.archive_file.lambda_zip.output_path
  function_name = "${local.short_identifier}"
  description   = "Lambda function ${local.short_identifier}"
  handler       = "${var.lambda.script_name}.lambda_handler"
  role          = aws_iam_role.lambda.arn
  runtime       = var.lambda.runtime
  memory_size   = var.lambda.memory_size
  timeout       = var.lambda.timeout
  architectures = var.lambda.architectures
  package_type  = "Zip"
  publish       = var.lambda.publish

  ephemeral_storage {
    size = var.lambda.ephemeral_storage_size
  }

  # attach the Lambda function to a VPC
  # Conditionally include vpc_config
  vpc_config {
    subnet_ids         = data.aws_subnets.private.ids
    security_group_ids = [ data.aws_security_group.vpc_endpoints_sg.id ]
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
    tomap({ "Name" = format("%s", "${local.short_identifier}") }),
  )
}

resource "aws_lambda_permission" "allow_secretsmanager" {
  statement_id  = "AllowExecutionFromSecretsManager"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.main.function_name
  principal     = "secretsmanager.amazonaws.com"

  # Optional but recommended for security
  source_account = data.aws_caller_identity.current.account_id
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
    function_name  = "${aws_lambda_function.main.function_name}"
    secret_arn    = data.aws_secretsmanager_secret.secret.arn
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
# Manage CloudWatch Logs Group retention policy for the Lambda function
#==============================================================================
resource "aws_cloudwatch_log_group" "main" {
  name              = "/aws/lambda/${aws_lambda_function.main.function_name}"
  retention_in_days = var.cloudwatch_logs_retention_in_days
}