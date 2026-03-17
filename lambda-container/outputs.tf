output "arn" {
    description = "The ARN of the Lambda function"
    value       = aws_lambda_function.main.arn
}

output "image_uri" {
    description = "The image URI of the Lambda function"
    value       = aws_lambda_function.main.image_uri
}