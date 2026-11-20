# GCP Chalk workload identity

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

- `issuer_url`: exact Chalk token `iss` claim.
- Provider condition: signed `environment_id` claim equals the configured environment.
- Required APIs: Workload Identity Federation and IAM Credentials.
- Workload setup: enable `container_spec.chalk_workload_identity`.
- Token exchange: pass `ConnectClient().get_workload_identity_token(audience)` to Google WIF, using the module's `audience` output and `service_account_email`.
- Service account permissions: grant separately.
