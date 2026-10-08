# GCP Chalk workload identity

Creates a Workload Identity Pool, Chalk OIDC provider, and service account for
one environment. The provider checks the signed `environment_id` claim; the
service account has no application permissions until you grant them.

```hcl
module "chalk_workload_identity" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/gcp/chalk-workload-identity?ref=<release-tag>"

  project_id         = "my-project"
  issuer_url         = "https://api.chalk.ai"
  environment_id     = "chlk618429b5"
  pool_id            = "chalk-chlk618429b5"
  service_account_id = "chalk-chlk618429b5"
}
```

Use the token's exact `iss` claim for `issuer_url`, enable Google's Workload
Identity Federation and IAM Credentials APIs, and use distinct pool and service
account IDs per environment.

Enable `container_spec.chalk_workload_identity` on the scaling group. In the
workload, call `chalkcompute.ConnectClient().get_workload_identity_token(audience)`
using the module's `audience` output. Exchange that token with Google WIF to
impersonate `service_account_email`. The injected
`CHALK_WEB_IDENTITY_TOKEN_FILE` is a Chalk API credential, not the
audience-specific Google token.
