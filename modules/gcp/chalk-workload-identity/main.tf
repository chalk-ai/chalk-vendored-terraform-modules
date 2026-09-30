data "google_project" "current" {
  project_id = var.project_id
}

locals {
  subject  = "env:${var.environment_id}"
  audience = "https://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.pool_id}/providers/${var.provider_id}"
}

resource "google_iam_workload_identity_pool" "chalk" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "Chalk workload identity"
}

resource "google_iam_workload_identity_pool_provider" "chalk" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.chalk.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "Chalk OIDC"

  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }
  attribute_condition = "assertion.sub == ${jsonencode(local.subject)}"

  oidc {
    issuer_uri        = var.issuer_url
    allowed_audiences = [local.audience]
  }
}

resource "google_service_account" "chalk" {
  project      = var.project_id
  account_id   = var.service_account_id
  display_name = "Chalk workload ${var.environment_id}"
}

resource "google_service_account_iam_member" "chalk" {
  service_account_id = google_service_account.chalk.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.chalk.workload_identity_pool_id}/subject/${local.subject}"

  depends_on = [google_iam_workload_identity_pool_provider.chalk]
}
