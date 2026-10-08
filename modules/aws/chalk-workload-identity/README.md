# AWS Chalk workload identity

Creates a Chalk OIDC provider and an IAM role for one environment. The role
trusts tokens with `aud = sts.amazonaws.com` and
`sub = v1:env:<environment_id>:*`. Attach application permissions separately.

```hcl
module "chalk_workload_identity" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/chalk-workload-identity?ref=<release-tag>"

  issuer_url     = "https://api.chalk.ai"
  environment_id = "chlk618429b5"
  role_name      = "chalk-chlk618429b5"
}
```

Use the token's exact `iss` claim for `issuer_url`. AWS allows one OIDC provider
per issuer URL in an account; reuse its ARN for other environment-scoped roles.

Enable `container_spec.chalk_workload_identity` on the scaling group. In the
workload, call `chalkcompute.ConnectClient().get_workload_identity_token("sts.amazonaws.com")`
and pass that token to STS `AssumeRoleWithWebIdentity` for `role_arn`. The
injected `CHALK_WEB_IDENTITY_TOKEN_FILE` is a Chalk API credential, not the
audience-specific AWS token.
