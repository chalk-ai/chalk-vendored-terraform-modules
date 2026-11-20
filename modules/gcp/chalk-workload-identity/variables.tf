variable "project_id" {
  description = "GCP project that owns the workload identity pool and service account."
  type        = string
}

variable "environment_id" {
  description = "Chalk environment ID allowed to impersonate the service account."
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

variable "pool_id" {
  description = "ID of the new workload identity pool."
  type        = string
}

variable "provider_id" {
  description = "ID of the Chalk OIDC provider in the pool."
  type        = string
  default     = "chalk-oidc"
}

variable "service_account_id" {
  description = "Account ID of the service account that the Chalk environment can impersonate."
  type        = string
}
