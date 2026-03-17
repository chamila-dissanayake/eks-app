variable "env" {
  description = "The common environmet variables"
  type        = map(any)
  default     = {}
}

variable "tags" {
  description = "Common tags for the environment"
  type        = map(any)
  default     = {}
}

variable "distro" {
  description = "The CloudFront distribution configuration"
  type        = map(any)
  default = {
    ingress_prefix = "app-ui"
    s3_origin_id   = "s3-static"
    alb_origin_id  = "alb-ingress"
  }
}

variable "logging" {
  description = "CloudFront logging configuration"
  type        = map(any)
  default = {
    enabled         = false
    bucket          = ""
    include_cookies = false
  }
}

variable "cache_behaviors" {
  type = list(object({
    path_pattern           = string
    target_origin_id       = string
    viewer_protocol_policy = string
    allowed_methods        = list(string)
    cached_methods         = list(string)
  }))
  default = [
    {
      path_pattern           = "/static/*"
      target_origin_id       = "s3-static" // Same as var.distro.s3_origin_id or var.distro.alb_origin_id
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
    },
    {
      path_pattern           = "/animation/*"
      target_origin_id       = "s3-static" // Same as var.distro.s3_origin_id or var.distro.alb_origin_id
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
    },
    {
      path_pattern           = "/images/*"
      target_origin_id       = "s3-static" // Same as var.distro.s3_origin_id or var.distro.alb_origin_id
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
    },
    {
      path_pattern           = "/notification/*"
      target_origin_id       = "s3-static" // Same as var.distro.s3_origin_id or var.distro.alb_origin_id
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
    },
    {
      path_pattern           = "/tap-training/*"
      target_origin_id       = "s3-static" // Same as var.distro.s3_origin_id or var.distro.alb_origin_id
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
    },
    {
      path_pattern           = "/video/*"
      target_origin_id       = "s3-static" // Same as var.distro.s3_origin_id or var.distro.alb_origin_id
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
    },
    {
      path_pattern           = "/css/*"
      target_origin_id       = "s3-static" // Same as var.distro.s3_origin_id or var.distro.alb_origin_id
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
    }
  ]
}

variable "s3_custom_headers" {
  description = "Custom headers for S3 origin"
  type        = list(any)
  default = [
    {
      "name" : "Access-Control-Allow-Methods"
      "value" : "GET,POST"
    },
    {
      "name" : "Access-Control-Allow-Headers"
      value : "UNSIGNED-PAYLOAD"
    },
    {
      "name" : "Access-Control-Allow-Origin"
      "value" : "*"
    },
    {
      "name" : "Vary"
      "value" : "Origin"
    }
  ]
}
