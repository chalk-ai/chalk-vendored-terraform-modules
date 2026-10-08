# AWS Chalk workload identity

```hcl
module "chalk_workload_identity" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/chalk-workload-identity?ref=<release-tag>"

  issuer_url     = "https://api.chalk.ai"
  environment_id = "chlk618429b5"
  role_name      = "chalk-chlk618429b5"
}
```

- `issuer_url`: exact Chalk token `iss` claim.
- Role trust: `aud = sts.amazonaws.com`; `sub = v1:env:<environment_id>:*`.
- Workload setup: enable `container_spec.chalk_workload_identity`.
- Token exchange: pass `ConnectClient().get_workload_identity_token("sts.amazonaws.com")` to STS `AssumeRoleWithWebIdentity` with `role_arn`.
- Role permissions: attach IAM policies separately.
