terraform {
  required_version = ">= 1.11.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

locals {
  role             = "cloudfront"
  short_identifier = "${var.tags.environment}-${local.role}"

  account_name = var.env.account_name

  prd_dns_entry = var.env.domain

  dns_entry = (
    lower(var.tags.t_environment) == "dev" ? "${lower(var.tags.t_environment)}.${var.env.domain}" :
    lower(var.tags.t_environment) == "qa" ? "${lower(var.tags.t_environment)}.${var.env.domain}" :
    lower(var.tags.t_environment) == "stg" ? "${var.env.domain}" :
    lower(var.tags.t_environment) == "prd" ? local.prd_dns_entry :
    "${lower(var.tags.t_environment)}.${var.env.domain}" # Default case
  )
}

data "aws_lb" "alb_ingress" {
  tags = {
    "ingress.k8s.aws/stack" = "${var.tags.environment}-app/${var.distro.ingress_prefix}-ingress"
  }
}

data "aws_acm_certificate" "ext" {
  domain = var.env.domain
  types  = ["IMPORTED"]
}

data "aws_caller_identity" "current" {}

// ========== s3 bucket lookup ==========
data "aws_s3_bucket" "s3_cf" {
  bucket = var.tags.environment
}

# // ======== Create R53 Record ========

data "aws_route53_zone" "hosted_ext_zone" {
  name = var.env.domain
}


data "aws_wafv2_web_acl" "global" {
  name     = "${var.tags.Name}-waf-acl-global"
  scope    = "CLOUDFRONT"
  provider = aws.virginia
}

data "aws_wafv2_web_acl" "regional" {
  name     = "${var.tags.Name}-waf-acl-regional"
  scope    = "REGIONAL"
}

// ========== CloudFront =================
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.tags.Name}-front-office-cf-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

/*
resource "aws_cloudfront_function" "index_redirection" {
  name    = "${local.short_identifier}-redirect-to-index-html"
  runtime = "cloudfront-js-2.0"
  comment = ""
  publish = true
  code    = file("${path.module}/add-index-html.js")
}


data "aws_cloudfront_function" "index_redirection" {
  name  = "index-redirection"
  stage = "LIVE"
}*/

resource "aws_cloudfront_cache_policy" "s3_cache_policy" {
  name        = var.tags.t_environment == "PRD" ? "Enable-CORS-PRD" : "Enable-CORS"
  comment     = "Custom cache policy for S3 with CORS enabled"
  default_ttl = 86400
  min_ttl     = 1
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "whitelist"
      headers {
        items = [
          "Origin"
        ]
      }
    }

    query_strings_config {
      query_string_behavior = "none"
    }

    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}


/*
data "aws_cloudfront_cache_policy" "elb_cache_policy" {
  name = "UseOriginCacheControlHeaders-QueryStrings"
}*/

data "aws_cloudfront_origin_request_policy" "s3_origin_request_policy" {
  name = "Managed-CORS-S3Origin"
}

data "aws_cloudfront_response_headers_policy" "s3_cors_headers_policy" {
  name = "Managed-SimpleCORS"
}

data "aws_cloudfront_cache_policy" "alb" {
  name = "UseOriginCacheControlHeaders-QueryStrings"
}

data "aws_cloudfront_origin_request_policy" "alb" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "app" {
  comment      = "${local.short_identifier}-cfd"
  enabled      = true
  http_version = "http2and3"
  aliases      = [local.dns_entry]
  web_acl_id   = data.aws_wafv2_web_acl.global.arn
  price_class  = "PriceClass_100"

  default_root_object = "index.html"

  // S3 bucket as origin
  origin {
    domain_name              = data.aws_s3_bucket.s3_cf.bucket_domain_name
    origin_id                = var.distro.s3_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id

    dynamic "custom_header" {
      for_each = var.s3_custom_headers
      content {
        name  = custom_header.value["name"]
        value = custom_header.value["value"]
      }
    }
  }

  // ALB as origin
  origin {
    domain_name = data.aws_lb.alb_ingress.dns_name
    origin_id   = var.distro.alb_origin_id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.cache_behaviors
    content {
      path_pattern               = ordered_cache_behavior.value.path_pattern
      target_origin_id           = ordered_cache_behavior.value.target_origin_id
      viewer_protocol_policy     = ordered_cache_behavior.value.viewer_protocol_policy
      allowed_methods            = ordered_cache_behavior.value.allowed_methods
      cached_methods             = ordered_cache_behavior.value.cached_methods
      cache_policy_id            = aws_cloudfront_cache_policy.s3_cache_policy.id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.s3_origin_request_policy.id
      response_headers_policy_id = data.aws_cloudfront_response_headers_policy.s3_cors_headers_policy.id
    }
  }

  default_cache_behavior {
    target_origin_id = var.distro.alb_origin_id
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods   = ["GET", "HEAD"]
    compress         = true

    viewer_protocol_policy = "redirect-to-https"

    cache_policy_id          = data.aws_cloudfront_cache_policy.alb.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.alb.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  dynamic "logging_config" {
    for_each = var.logging.enabled ? [1] : []
    content {
      include_cookies = var.logging.include_cookies
      bucket          = "${var.logging.bucket}.s3.amazonaws.com"
      prefix          = "${local.short_identifier}-cfd-logs/"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.ext.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  #custom_error_response {
  #  error_caching_min_ttl = 10
  #  error_code            = 403
  #  response_code         = 200
  #  response_page_path    = "/index.html"
  #}

  tags = merge(
    var.tags,
    {
      "Name" = format("${local.short_identifier}-cfd")
    }
  )
}

data "aws_s3_bucket" "s3_cf_logs" {
  count = var.logging.enabled ? 1 : 0
  bucket = var.logging.bucket
}

resource "aws_s3_bucket_policy" "log_bucket_policy" {
  count = var.logging.enabled ? 1 : 0
  bucket = data.aws_s3_bucket.s3_cf_logs[count.index].id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontToWritetoS3Bucket",
      "Effect": "Allow",
	    "Principal": {
          "Service": "cloudfront.amazonaws.com"
        },
      "Action": [
          "s3:List*",
          "s3:PutObject"
        ],
      "Resource": [
        "arn:aws:s3:::${data.aws_s3_bucket.s3_cf_logs[count.index].id}",
        "arn:aws:s3:::${data.aws_s3_bucket.s3_cf_logs[count.index].id}/${local.short_identifier}-cfd-logs/*"
      ]
    }
  ]
}
EOF
}

resource "aws_route53_record" "ext_record" {
  depends_on = [aws_cloudfront_distribution.app]
  name       = local.dns_entry
  zone_id    = data.aws_route53_zone.hosted_ext_zone.zone_id
  type       = "A"

  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_s3_bucket_policy" "s3_policy" {
  bucket = data.aws_s3_bucket.s3_cf.id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontServicePrincipalReadOnly",
      "Effect": "Allow",
	    "Principal": {
          "Service": "cloudfront.amazonaws.com"
        },
      "Action": [
          "s3:GetObject"
        ],
      "Resource": "${data.aws_s3_bucket.s3_cf.arn}/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceArn": "arn:aws:cloudfront::${data.aws_caller_identity.current.id}:distribution/${aws_cloudfront_distribution.app.id}"
        }
      }
    }
  ]
}
EOF
}

resource "aws_s3_bucket_versioning" "s3_versioning" {
  bucket = data.aws_s3_bucket.s3_cf.id
  versioning_configuration {
    status = "Suspended"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "s3_lifecycle" {
  count = aws_s3_bucket_versioning.s3_versioning.versioning_configuration[0].status == "Enabled" ? 0 : 1

  bucket = data.aws_s3_bucket.s3_cf.id

  rule {
    id     = "delete-non-current-objects"
    status = "Enabled"

    filter {}  # Applies to all objects

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

// ========== Add CFD to shield ==========
data "aws_cloudfront_distribution" "data_cfd_app" {
  id = aws_cloudfront_distribution.app.id
}

resource "aws_shield_protection" "cfd_fo_shield" {
  name         = "${var.tags.Name}-cfd-fo-shield"
  resource_arn = data.aws_cloudfront_distribution.data_cfd_app.arn

  tags = merge(var.tags, { "Name" = format("${var.tags.Name}-${local.role}-shield") })
}

// ========== Add ALB to shield ==========

resource "aws_shield_protection" "alb" {
  name         = "${var.tags.Name}-alb-shield"
  resource_arn = data.aws_lb.alb_ingress.arn

  tags = merge(var.tags, { "Name" = format("${var.tags.Name}-${local.role}-shield") })
}

// ========== Add ALB to WAF Regional==========
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = data.aws_lb.alb_ingress.arn
  web_acl_arn  = data.aws_wafv2_web_acl.regional.arn

  lifecycle {
    ignore_changes = [web_acl_arn]
  }
}