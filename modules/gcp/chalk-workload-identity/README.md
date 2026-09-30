# GCP Chalk workload identity

Creates a Workload Identity Pool, a Chalk OIDC provider, and a service account.
Only tokens whose `environment_id` claim matches this module's environment are
accepted by the provider and allowed to impersonate the service account. The
token's `sub` combines the environment, caller type, and caller ID. The OIDC
audience must match this module's `audience` output.

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

Set `issuer_url` to the exact `iss` claim from a Chalk workload identity token;
the example in `chalk-cloud-cost` uses `https://api.staging.chalk.ai`. The
Workload Identity Federation and IAM Credentials APIs must be enabled in the
project. Grant the service account only the GCP permissions the workload needs;
this module grants it no project roles.

Enable Chalk identity on the scaling group's container spec. Inside the
workload, request a short-lived federation token with
`chalkcompute.ConnectClient().get_workload_identity_token(audience)` using the `audience`
output, and use that token with Google Workload Identity Federation to
impersonate `service_account_email`. The injected
`CHALK_WEB_IDENTITY_TOKEN_FILE` is a Chalk API credential; it is not the
audience-specific token to send directly to Google.

The pool is dedicated to one environment. Use distinct `pool_id` and
`service_account_id` values for each environment in the same project.
The current high-level `chalkcompute.ScalingGroup` constructor does not expose
the identity flag; set `container_spec.chalk_workload_identity` through the
scaling group API when deploying.

## Outputs

| Name | Description |
|---|---|
| `service_account_email` | Service account to grant GCP permissions. |
| `provider_name` | Fully qualified OIDC provider name. |
| `audience` | Audience to request from Chalk. |
