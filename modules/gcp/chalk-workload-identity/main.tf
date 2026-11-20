data "google_project" "current" {
  project_id = var.project_id
}

locals {
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
    "google.subject"           = "assertion.sub"
    "attribute.environment_id" = "assertion.environment_id"
  }
  attribute_condition = "assertion.environment_id == ${jsonencode(var.environment_id)}"

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
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.chalk.workload_identity_pool_id}/attribute.environment_id/${var.environment_id}"

  depends_on = [google_iam_workload_identity_pool_provider.chalk]
}
