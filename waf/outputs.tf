output "global_acl_arn" {
  description = "The URL of the CloudFront distribution"
  value       = var.waf.cloudfront ? aws_wafv2_web_acl.global[0].arn : null
}

output "regional_acl_arn" {
  description = "The URL of the CloudFront distribution"
  value       = var.waf.alb || var.waf.api_gateway ? aws_wafv2_web_acl.regional[0].arn : null
}
