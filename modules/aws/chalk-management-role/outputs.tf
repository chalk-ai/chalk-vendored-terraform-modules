output "role_arn" {
  description = "ARN of the Chalk management role."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the Chalk management role."
  value       = aws_iam_role.this.name
}

output "policy_arn" {
  description = "ARN of the policy attached to the Chalk management role."
  value       = aws_iam_policy.this.arn
}

output "restricted_permissions" {
  description = "Whether the attached policy uses restricted ongoing-management permissions."
  value       = var.restricted_permissions
}
