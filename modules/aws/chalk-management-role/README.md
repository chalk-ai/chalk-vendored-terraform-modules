# AWS Chalk Management Role

Creates the IAM role that Chalk assumes to deploy and manage a customer-cloud installation.

The module defaults to the broad permissions needed for initial deployment. After the deployment is established, set `restricted_permissions = true` to replace the attached policy with an ongoing-management policy scoped to Chalk-tagged resources and Chalk resource-name patterns. The role and policy ARNs remain stable when switching modes.

Restricted mode is intended for ongoing management, not bootstrapping a new VPC or cluster: AWS resources do not have Chalk tags until they have been created.

## Usage

```hcl
module "chalk_management_role" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/chalk-management-role?ref=main"

  external_id = var.chalk_external_id
}

output "chalk_management_role_arn" {
  value = module.chalk_management_role.role_arn
}
```

For a dedicated Chalk control plane or an additional trusted principal:

```hcl
module "chalk_management_role" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/chalk-management-role?ref=main"

  external_id = var.chalk_external_id
  trusted_principal_arns = [
    "arn:aws:iam::123456789012:role/chalk-api-server",
  ]

  permissions_boundary_arn = "arn:aws:iam::111122223333:policy/RequiredBoundary"
  tags = {
    Environment = "production"
  }
}
```

To switch an existing role to restricted ongoing permissions:

```hcl
module "chalk_management_role" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/chalk-management-role?ref=main"

  external_id            = var.chalk_external_id
  restricted_permissions = true
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `external_id` | `string` | Required | External ID supplied by Chalk for `sts:AssumeRole`. |
| `trusted_principal_arns` | `set(string)` | Chalk production API-server role | Principals allowed to assume the role. |
| `restricted_permissions` | `bool` | `false` | Replace deployment permissions with restricted ongoing permissions. |
| `role_name` | `string` | `"chalk-management-role"` | IAM role name. |
| `permissions_boundary_arn` | `string` | `null` | Optional IAM permissions boundary. |
| `max_session_duration` | `number` | `3600` | Maximum session duration in seconds. |
| `tags` | `map(string)` | `{}` | Additional role and policy tags. |

The AWS account ID and partition are derived from the module's configured AWS provider.

## Outputs

| Name | Description |
|---|---|
| `role_arn` | ARN of the Chalk management role. |
| `role_name` | Name of the Chalk management role. |
| `policy_arn` | ARN of the attached policy. |
| `restricted_permissions` | Whether restricted permissions are enabled. |
