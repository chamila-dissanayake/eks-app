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

provider "aws" {
  alias  = "virginia"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

locals {
  role             = "waf"
  short_identifier = "${var.tags.environment}-${local.role}"

  account_name = var.env.account_name
}

data "aws_lb" "alb_ingress" {
  tags = {
    "ingress.k8s.aws/stack" = "${var.tags.environment}-app/user-web-app-ingress"
  }
}

//GLOBAL waf for CloudFront
resource "aws_wafv2_web_acl" "global" {
  count       = var.waf.cloudfront ? 1 : 0
  provider    = aws.virginia
  name        = "${local.short_identifier}-acl-global"
  description = "WAFv2 CloudFront ACL for ${var.tags.Name} CF distro"
  scope       = "CLOUDFRONT"

  default_action {
    dynamic "allow" {
      for_each = var.default_action == "allow" ? [1] : []
      content {}
    }

    dynamic "block" {
      for_each = var.default_action == "block" ? [1] : []
      content {}
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = "${local.short_identifier}-acl-global"
  }

  dynamic "rule" {
    for_each = var.managed_rules
    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = rule.value.override_action == "none" ? [1] : []
          content {}
        }

        dynamic "count" {
          for_each = rule.value.override_action == "count" ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"

          dynamic "rule_action_override" {
            for_each = rule.value.excluded_rules
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = rule.value.name
      }

    }
  }

  dynamic "rule" {
    for_each = var.group_rules
    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = rule.value.override_action == "none" ? [1] : []
          content {}
        }

        dynamic "count" {
          for_each = rule.value.override_action == "count" ? [1] : []
          content {}
        }
      }

      statement {
        rule_group_reference_statement {
          arn = rule.value.arn_cf

          dynamic "excluded_rule" {
            for_each = rule.value.excluded_rules
            content {
              name = excluded_rule.value
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = rule.value.name
      }
    }
  }

  rule {
    name     = "DDoS-rule"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.ip-limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "${local.short_identifier}-ddos-rule"
    }
  }

  lifecycle {
    ignore_changes = [tags]
  }

  tags = merge(var.tags, { Name = "${local.short_identifier}-acl-global" })

}

# -----------------------------------------------------------------------------
# Creates a CloudWatch Log Group for WAFv2 Web ACL logs and configures logging
# for the global (CloudFront) WAFv2 Web ACL.
#
# Resources:
# - aws_cloudwatch_log_group.waf_logs_global: Creates a log group for WAF logs
#   if both CloudFront WAF and logging are enabled.
#   - Name is based on the associated WAFv2 Web ACL.
#   - Retention period is configurable via variable.
#
# - aws_wafv2_web_acl_logging_configuration.global: Configures logging for the
#   WAFv2 Web ACL if both CloudFront WAF and logging are enabled.
#   - Sends logs to the created CloudWatch Log Group.
#   - Logging filters are set to drop logs for COUNT and ALLOW actions,
#     keeping only logs for BLOCK actions.
#
# Variables:
# - var.waf.cloudfront: Enables/disables CloudFront WAF resources.
# - var.logs.enabled: Enables/disables logging.
# - var.logs.retention_period: Sets log retention period in days.
#
# Usage:
# Include this module to enable WAF logging for CloudFront distributions,
# with configurable log retention and filtering.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "waf_logs_global" {
  count = var.waf.cloudfront && var.logs.enabled ? 1 : 0

  name              = "aws-waf-logs-${aws_wafv2_web_acl.global[count.index].name}"
  retention_in_days = var.logs.retention_period

  depends_on = [aws_wafv2_web_acl.global]

  tags = merge(var.tags, { Name = "aws-waf-logs-${aws_wafv2_web_acl.global[count.index].name}" })
}

resource "aws_wafv2_web_acl_logging_configuration" "global" {
  count = var.waf.cloudfront && var.logs.enabled ? 1 : 0

  resource_arn = aws_wafv2_web_acl.global[count.index].arn

  log_destination_configs = [
    aws_cloudwatch_log_group.waf_logs_global[count.index].arn
  ]

  logging_filter {
    default_behavior = "KEEP"

    filter {
      behavior = "DROP"

      condition {
        action_condition {
          action = "COUNT"
        }
      }
      requirement = "MEETS_ALL"
    }

    filter {
      behavior = "DROP"

      condition {
        action_condition {
          action = "ALLOW"
        }
      }
      requirement = "MEETS_ALL"
    }
  }

  depends_on = [aws_wafv2_web_acl.regional]
}

//Regional waf for ALBs
resource "aws_wafv2_web_acl" "regional" {
  count       = var.waf.alb || var.waf.api_gateway ? 1 : 0
  name        = "${local.short_identifier}-acl-regional"
  description = "WAFv2 Regional ACL for ${var.tags.Name} ALB"
  scope       = "REGIONAL"

  default_action {
    dynamic "allow" {
      for_each = var.default_action == "allow" ? [1] : []
      content {}
    }

    dynamic "block" {
      for_each = var.default_action == "block" ? [1] : []
      content {}
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = var.tags.t_environment == "PRD" ? true : false
    sampled_requests_enabled   = true
    metric_name                = "${local.short_identifier}-acl-regional"
  }

  dynamic "rule" {
    for_each = var.managed_rules
    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = rule.value.override_action == "none" ? [1] : []
          content {}
        }

        dynamic "count" {
          for_each = rule.value.override_action == "count" ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"

          dynamic "rule_action_override" {
            for_each = rule.value.excluded_rules
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = var.tags.t_environment == "PRD" ? true : false
        sampled_requests_enabled   = true
        metric_name                = rule.value.name
      }

    }
  }

  dynamic "rule" {
    for_each = var.group_rules
    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = rule.value.override_action == "none" ? [1] : []
          content {}
        }

        dynamic "count" {
          for_each = rule.value.override_action == "count" ? [1] : []
          content {}
        }
      }

      statement {
        rule_group_reference_statement {
          arn = rule.value.arn_regional

          dynamic "excluded_rule" {
            for_each = rule.value.excluded_rules
            content {
              name = excluded_rule.value
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = var.tags.t_environment == "PRD" ? true : false
        sampled_requests_enabled   = true
        metric_name                = rule.value.name
      }
    }
  }

  rule {
    name     = "DDoS-rule"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.ip-limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = var.tags.t_environment == "PRD" ? true : false
      sampled_requests_enabled   = true
      metric_name                = "${var.tags.Name}-DDoS-rule"
    }
  }


  lifecycle {
    ignore_changes = [tags]
  }

  tags = merge(var.tags, { Name = "${local.short_identifier}-acl-regional" })
}



resource "aws_cloudwatch_log_group" "waf_logs_regional" {
  count = (var.waf.alb || var.waf.api_gateway) && var.logs.enabled ? 1 : 0

  name              = "aws-waf-logs-${aws_wafv2_web_acl.regional[0].name}"
  retention_in_days = var.logs.retention_period

  depends_on = [aws_wafv2_web_acl.regional]

  tags = merge(var.tags, { Name = "aws-waf-logs-${aws_wafv2_web_acl.regional[count.index].name}" })
}

resource "aws_wafv2_web_acl_logging_configuration" "regional" {
  count = (var.waf.alb || var.waf.api_gateway) && var.logs.enabled ? 1 : 0

  resource_arn = aws_wafv2_web_acl.regional[count.index].arn

  log_destination_configs = [
    aws_cloudwatch_log_group.waf_logs_regional[count.index].arn
  ]

  logging_filter {
    default_behavior = "KEEP"

    filter {
      behavior = "DROP"

      condition {
        action_condition {
          action = "COUNT"
        }
      }
      requirement = "MEETS_ALL"
    }

    filter {
      behavior = "DROP"

      condition {
        action_condition {
          action = "ALLOW"
        }
      }
      requirement = "MEETS_ALL"
    }
  }

  depends_on = [aws_cloudwatch_log_group.waf_logs_regional]
}

// ========= Associate ALb with WAFv2 Web ACL regional ==========

resource "aws_wafv2_web_acl_association" "alb" {
  count        = var.waf.alb ? 1 : 0
  resource_arn = data.aws_lb.alb_ingress.arn
  web_acl_arn  = aws_wafv2_web_acl.regional[0].arn
}