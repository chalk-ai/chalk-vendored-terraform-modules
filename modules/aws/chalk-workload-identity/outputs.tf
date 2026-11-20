output "role_arn" {
  description = "IAM role to grant application-specific AWS permissions."
  value       = aws_iam_role.chalk.arn
}

output "role_name" {
  description = "IAM role name for policy attachments."
  value       = aws_iam_role.chalk.name
}

output "oidc_provider_arn" {
  description = "ARN of the Chalk OIDC provider."
  value       = aws_iam_openid_connect_provider.chalk.arn
}

output "audience" {
  description = "Audience to request from Chalk when minting an AWS federation token."
  value       = "sts.amazonaws.com"
}
