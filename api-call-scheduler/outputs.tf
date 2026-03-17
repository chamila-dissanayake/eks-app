# Add to your outputs.tf file
output "schedule_rule_arn" {
  description = "ARN of the EventBridge rule"
  value       = var.schedule.enabled ? aws_cloudwatch_event_rule.lambda_schedule[0].arn : null
}

output "schedule_rule_name" {
  description = "Name of the EventBridge rule"
  value       = var.schedule.enabled ? aws_cloudwatch_event_rule.lambda_schedule[0].name : null
}

output "schedule_expression" {
  description = "Cron expression used for scheduling"
  value       = var.schedule.enabled ? var.schedule.cron_expression : null
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.main.arn
}