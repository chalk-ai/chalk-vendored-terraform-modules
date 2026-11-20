variable "environment_id" {
  description = "Chalk environment ID allowed to assume the role."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.environment_id))
    error_message = "environment_id must contain only letters, numbers, underscores, or hyphens."
  }
}

variable "issuer_url" {
  description = "Exact Chalk OIDC issuer URL, for example https://api.chalk.ai."
  type        = string

  validation {
    condition     = startswith(var.issuer_url, "https://") && !endswith(var.issuer_url, "/")
    error_message = "issuer_url must be an HTTPS URL without a trailing slash."
  }
}

variable "role_name" {
  description = "Name of the IAM role assumed by the Chalk environment."
  type        = string
}

variable "tags" {
  description = "Tags for the OIDC provider and IAM role."
  type        = map(string)
  default     = {}
}
