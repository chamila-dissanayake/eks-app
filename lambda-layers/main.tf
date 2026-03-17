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

resource "aws_lambda_layer_version" "lambda_layers" {
  for_each = var.layers

  layer_name               = each.key
  description              = "Lambda layer ${each.key}"
  s3_bucket                = each.value.s3_bucket
  s3_key                   = "${each.value.s3_directory}/${each.value.filename}"
  compatible_runtimes      = each.value.runtimes
  compatible_architectures = each.value.architectures
}
