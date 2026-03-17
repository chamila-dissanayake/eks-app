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
  region = "us-east-1"
}

locals {
  identifier_short = format("%s-${var.role}", var.tags.environment)
}

data "aws_sns_topic" "sns_topic" {
  name = "${var.env.account_name}-notifications"
}

resource "aws_route53_health_check" "this" {
  count = length(var.health_checks)

  disabled          = var.health_checks[count.index].disabled
  fqdn              = var.health_checks[count.index].fqdn
  port              = var.health_checks[count.index].port
  type              = var.health_checks[count.index].type
  resource_path     = var.health_checks[count.index].resource_path
  failure_threshold = var.health_checks[count.index].failure_threshold
  request_interval  = var.health_checks[count.index].request_interval
  regions           = length(var.health_checks[count.index].regions) > 0 ? var.health_checks[count.index].regions : [var.env.region]
  measure_latency   = var.health_checks[count.index].measure_latency


  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s", var.health_checks[count.index].name) })
  )
}


resource "aws_cloudwatch_metric_alarm" "this" {
  count = length(var.alarms)

  alarm_name          = "${var.alarms[count.index].name}"
  comparison_operator = var.alarms[count.index].comparison_operator
  evaluation_periods  = var.alarms[count.index].evaluation_periods
  metric_name         = var.alarms[count.index].metric_name
  namespace           = "AWS/Route53"
  period              = var.alarms[count.index].period
  statistic           = var.alarms[count.index].statistic
  threshold           = var.alarms[count.index].threshold
  alarm_description   = "${var.health_checks[count.index].fqdn}${var.health_checks[count.index].resource_path}'s ${var.alarms[count.index].metric_name} < ${var.alarms[count.index].threshold} for ${var.alarms[count.index].evaluation_periods} datapoints within ${var.alarms[count.index].period*var.alarms[count.index].evaluation_periods/60} minutes"
  actions_enabled     = var.alarms[count.index].actions_enabled
  alarm_actions       = length(var.alarms[count.index].alarm_actions) == 0 ? [ data.aws_sns_topic.sns_topic.arn ] : var.alarms[count.index].alarm_actions
  ok_actions          = length(var.alarms[count.index].ok_actions) == 0 ? [ data.aws_sns_topic.sns_topic.arn ] : var.alarms[count.index].ok_actions
  treat_missing_data  = var.alarms[count.index].treat_missing_data

  dimensions = {
    HealthCheckId = aws_route53_health_check.this[count.index].id
  }

  depends_on = [aws_route53_health_check.this]

  tags = merge(
    var.tags,
    tomap({ "Name" = format("%s", var.alarms[count.index].name) })
  )
}
