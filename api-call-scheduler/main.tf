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
  type        = "zip"
  source_file = "${path.module}/source/${var.lambda.script_name}.py"
  output_path = "${path.module}/source/${var.lambda.script_name}.zip"
}

resource "aws_lambda_function" "main" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = local.short_identifier
  description      = "Lambda function ${local.short_identifier}"
  handler          = "${var.lambda.script_name}.lambda_handler"
  role             = aws_iam_role.lambda.arn
  runtime          = var.lambda.runtime
  memory_size      = var.lambda.memory_size
  timeout          = var.lambda.timeout
  architectures    = var.lambda.architectures
  package_type     = "Zip"
  publish          = var.lambda.publish

  ephemeral_storage {
    size = var.lambda.ephemeral_storage_size
  }

  # attach the Lambda function to a VPC
  # Conditionally include vpc_config
  vpc_config {
    subnet_ids         = data.aws_subnets.private.ids
    security_group_ids = [data.aws_security_group.vpc_endpoints_sg.id]
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
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-role", local.short_identifier) }),
  )
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

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Effect   = "Allow"
        Resource = data.aws_secretsmanager_secret.secret.arn
      },
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:logs:${var.env.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${aws_lambda_function.main.function_name}:*"
      }
    ]
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

#==============================================================================
# EventBridge Rule for Lambda Scheduling
#==============================================================================
resource "aws_cloudwatch_event_rule" "lambda_schedule" {
  count               = var.schedule.enabled ? 1 : 0
  name                = "${local.short_identifier}-schedule"
  description         = "Schedule for ${local.short_identifier} Lambda function"
  schedule_expression = var.schedule.cron_expression
  state               = var.schedule.state

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s-schedule", local.short_identifier) }),
  )
}

#==============================================================================
# EventBridge Target - Connect Rule to Lambda
#==============================================================================
resource "aws_cloudwatch_event_target" "lambda_target" {
  count     = var.schedule.enabled ? 1 : 0
  rule      = aws_cloudwatch_event_rule.lambda_schedule[0].name
  target_id = "${local.short_identifier}-target"
  arn       = aws_lambda_function.main.arn

  # Optional: Add input to the Lambda function
  dynamic "input_transformer" {
    for_each = var.schedule.input_transformer != null ? [var.schedule.input_transformer] : []
    content {
      input_paths    = input_transformer.value.input_paths
      input_template = input_transformer.value.input_template
    }
  }

  # Optional: Add retry policy
  retry_policy {
    maximum_retry_attempts       = var.schedule.retry_policy.maximum_retry_attempts
    maximum_event_age_in_seconds = var.schedule.retry_policy.maximum_event_age_in_seconds
  }

  # Optional: Add dead letter queue
  dynamic "dead_letter_config" {
    for_each = var.schedule.dead_letter_queue_arn != null ? [1] : []
    content {
      arn = var.schedule.dead_letter_queue_arn
    }
  }
}

#==============================================================================
# Lambda Permission for EventBridge
#==============================================================================
resource "aws_lambda_permission" "allow_eventbridge" {
  count         = var.schedule.enabled ? 1 : 0
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.main.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_schedule[0].arn
}

#==============================================================================
# CloudWatch Log Metric Filter - Track Lambda failiures
#==============================================================================
resource "aws_cloudwatch_log_metric_filter" "lambda_failure" {
  count          = var.monitoring.enabled ? 1 : 0
  name           = "${local.short_identifier}-failiure"
  log_group_name = aws_cloudwatch_log_group.main.name

  # Pattern to match non-200 status codes in Lambda logs
  pattern = "[time, request_id, level, msg, status_code != 200]"

  metric_transformation {
    name          = "${local.short_identifier}-failiure-count"
    namespace     = var.monitoring.namespace
    value         = "1"
    default_value = 0
    unit          = "Count"
  }

  depends_on = [aws_cloudwatch_log_group.main]
}

#==============================================================================
# CloudWatch Alarm - Alert on Lambda failiure
#==============================================================================
resource "aws_cloudwatch_metric_alarm" "lambda_failiures" {
  count               = var.monitoring.enabled ? 1 : 0
  alarm_name          = "${local.short_identifier}-failiure"
  alarm_description   = "Lambda function ${local.short_identifier} failed!"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.monitoring.alarm_evaluation_periods
  metric_name         = "${local.short_identifier}-failiure"
  namespace           = var.monitoring.namespace
  period              = var.monitoring.alarm_period
  statistic           = "Sum"
  threshold           = var.monitoring.failiure_threshold
  treat_missing_data  = "notBreaching"
  datapoints_to_alarm = var.monitoring.datapoints_to_alarm

  alarm_actions = var.monitoring.alarm_actions
  ok_actions    = var.monitoring.ok_actions

  tags = merge(
    var.tags,
    {
      Name = "${local.short_identifier}-failiure"
    }
  )
}

#==============================================================================
# CloudWatch Alarm - Lambda Errors
#==============================================================================
resource "aws_cloudwatch_metric_alarm" "lambda_error" {
  count               = var.monitoring.enabled ? 1 : 0
  alarm_name          = "${local.short_identifier}-error"
  alarm_description   = "Lambda function ${local.short_identifier} produced error!"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.monitoring.alarm_evaluation_periods
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = var.monitoring.alarm_period
  statistic           = "Sum"
  threshold           = var.monitoring.error_threshold
  treat_missing_data  = "notBreaching"
  datapoints_to_alarm = var.monitoring.datapoints_to_alarm

  dimensions = {
    FunctionName = aws_lambda_function.main.function_name
  }

  alarm_actions = var.monitoring.alarm_actions
  ok_actions    = var.monitoring.ok_actions

  tags = merge(
    var.tags,
    {
      Name = "${local.short_identifier}-error"
    }
  )
}
