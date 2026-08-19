variable "role_name" {
  description = "Name of the IAM role created for Chalk."
  type        = string
  default     = "chalk-management-role"

  validation {
    condition     = length(var.role_name) > 0 && length(var.role_name) <= 64 && can(regex("^[A-Za-z0-9_+=,.@-]+$", var.role_name))
    error_message = "role_name must contain between 1 and 64 valid IAM role-name characters."
  }
}

variable "trusted_principal_arns" {
  description = "AWS principal ARNs allowed to assume the management role. Override this for a dedicated Chalk control plane."
  type        = set(string)
  default     = ["arn:aws:iam::754784422779:role/chalk-api-server"]

  validation {
    condition     = length(var.trusted_principal_arns) > 0 && alltrue([for arn in var.trusted_principal_arns : startswith(arn, "arn:")])
    error_message = "trusted_principal_arns must contain at least one AWS ARN."
  }
}

variable "external_id" {
  description = "External ID supplied by Chalk when assuming the management role."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.external_id)) > 0
    error_message = "external_id must not be empty."
  }
}

variable "restricted_permissions" {
  description = "Use the tag- and resource-scoped ongoing-management policy instead of the broad initial-deployment policy."
  type        = bool
  default     = false
}

variable "permissions_boundary_arn" {
  description = "Optional IAM permissions boundary ARN to attach to the management role."
  type        = string
  default     = null

  validation {
    condition     = var.permissions_boundary_arn == null || startswith(var.permissions_boundary_arn, "arn:")
    error_message = "permissions_boundary_arn must be null or an AWS ARN."
  }
}

variable "max_session_duration" {
  description = "Maximum role session duration in seconds."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 and 43200 seconds."
  }
}

variable "tags" {
  description = "Additional tags to apply to the IAM role and policy."
  type        = map(string)
  default     = {}
}
