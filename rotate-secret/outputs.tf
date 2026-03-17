output "qualified_arn" {
  description = "The qualified ARN of the Lambda function"
  value       = aws_lambda_function.main.qualified_arn
}

output "qualified_invoke_arn" {
  description = "The qualified invoke ARN of the Lambda function"
  value       = aws_lambda_function.main.qualified_invoke_arn
}

output "version" {
  description = "The version of the Lambda function"
  value       = aws_lambda_function.main.version
}