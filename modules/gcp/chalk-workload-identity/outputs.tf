output "service_account_email" {
  description = "Service account to grant application-specific GCP permissions."
  value       = google_service_account.chalk.email
}

output "provider_name" {
  description = "Fully qualified workload identity provider name."
  value       = google_iam_workload_identity_pool_provider.chalk.name
}

output "audience" {
  description = "Audience to request from Chalk when minting a GCP federation token."
  value       = local.audience
}
