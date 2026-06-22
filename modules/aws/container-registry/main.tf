// Configure an AWS ECR repository for use as a Chalk compute container registry.
//
// Chalk's scoped-down management role is permitted to push/pull only against
// repositories carrying the `chalk.ai/managed-by = chalk` tag (ABAC). This
// module bakes that tag in so it cannot be omitted -- a repository created
// without it will reject Chalk's image pushes with AccessDenied.

variable "repository_name" {
  description = "Name of the ECR repository (e.g. \"chalk-snrn-prod/compute\")"
  type        = string
}

variable "force_delete" {
  description = "Delete the repository even if it contains images when destroyed."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags. The chalk.ai/managed-by tag is always added."
  type        = map(string)
  default     = {}
}

resource "aws_ecr_repository" "this" {
  name         = var.repository_name
  force_delete = var.force_delete

  # REQUIRED: this tag is what Chalk's scoped-down role keys off of (ABAC).
  # Without it, the Chalk management role gets AccessDenied on push.
  tags = merge(var.tags, {
    "chalk.ai/managed-by" = "chalk"
  })
}

output "repository_url" {
  value = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  value = aws_ecr_repository.this.arn
}

output "repository_name" {
  value = aws_ecr_repository.this.name
}

output "registry_id" {
  value = aws_ecr_repository.this.registry_id
}
