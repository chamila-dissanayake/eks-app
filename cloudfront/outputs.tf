output "cloudfront_distribution_url" {
  description = "The URL of the CloudFront distribution"
  value       = aws_cloudfront_distribution.app.domain_name
}

output "cloudfront_distribution_dns" {
  description = "The DNS name of the CloudFront distribution"
  value       = aws_route53_record.ext_record.fqdn
}