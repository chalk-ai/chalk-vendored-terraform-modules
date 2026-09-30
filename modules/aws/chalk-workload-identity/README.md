# AWS Chalk workload identity

Creates an IAM OIDC provider for the Chalk issuer and an IAM role that trusts
only tokens with `aud = sts.amazonaws.com` and
`sub = env:<environment_id>`. The role has no permissions until you attach
application-specific policies.

```hcl
module "chalk_workload_identity" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/chalk-workload-identity?ref=<release-tag>"

  issuer_url     = "https://api.chalk.ai"
  environment_id = "chlk618429b5"
  role_name      = "chalk-chlk618429b5"
}

resource "aws_iam_role_policy_attachment" "chalk_read_only" {
  role       = module.chalk_workload_identity.role_name
  policy_arn = aws_iam_policy.read_only.arn
}
```

Set `issuer_url` to the exact `iss` claim from a Chalk workload identity token;
the example in `chalk-cloud-cost` uses `https://api.staging.chalk.ai`.
An AWS account can have only one OIDC provider for a given issuer URL. Create
this module once per issuer per account; additional environment-specific roles
can trust the resulting `oidc_provider_arn` with their own exact `sub` condition.

Enable Chalk identity on the scaling group's container spec. Inside the
workload, request a short-lived federation token with
`chalkcompute.ConnectClient().get_workload_identity_token("sts.amazonaws.com")`, then pass
it to AWS STS `AssumeRoleWithWebIdentity` for `role_arn`. The injected
`CHALK_WEB_IDENTITY_TOKEN_FILE` is a Chalk API credential; it is not the
audience-specific token to send directly to AWS.
The current high-level `chalkcompute.ScalingGroup` constructor does not expose
the identity flag; set `container_spec.chalk_workload_identity` through the
scaling group API when deploying.

## Outputs

| Name | Description |
|---|---|
| `role_arn` | Role to grant AWS permissions. |
| `role_name` | Role name for IAM policy attachments. |
| `oidc_provider_arn` | Chalk OIDC provider ARN. |
| `audience` | Audience to request from Chalk. |
