output "aws_iam_openid_connect_provider_arn" {
  description = "ARN of the OIDC provider"
  value       = aws_iam_openid_connect_provider.oidc_provider.arn
}

output "aws_iam_openid_connect_provider_url" {
  description = "URL of the OIDC provider"
  value       = aws_iam_openid_connect_provider.oidc_provider.url
}