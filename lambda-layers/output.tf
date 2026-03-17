output "layer_arns" {
  value = {
    for k, layer in aws_lambda_layer_version.lambda_layers :
    k => layer.arn
  }
  description = "ARNs of all the Lambda layers created"
}