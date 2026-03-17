output "sheild_drt_role_arn" {
  description = "The shield DRT role arn"
  value       = aws_iam_role.drt_role.arn
}