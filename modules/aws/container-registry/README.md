# AWS ECR Container Registry Module

Terraform module for provisioning an AWS ECR repository used as a Chalk
[compute](https://docs.chalk.ai/docs/compute/compute-setup) container registry.

## Why this module exists

When Chalk runs in a customer's AWS account with a scoped-down management role,
the role is typically restricted via attribute-based access control (ABAC) to
resources tagged `chalk.ai/managed-by = chalk`. Chalk's image-push pipeline can
push to a repository carrying that tag, but the scoped role generally cannot
**create** the repository itself.

This module is what you hand to the customer's infra team so they create the
repository with the correct tag baked in -- avoiding the `AccessDenied` failures
that occur when the tag is missing.

## Features

- ECR repository pre-tagged with `chalk.ai/managed-by = chalk` (cannot be omitted)
- Immutable image tags by default
- Scan-on-push enabled by default

## Usage

```hcl
module "chalk_compute_registry" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/container-registry?ref=main"

  repository_name = "chalk-snrn-prod/compute"
}

output "compute_registry_url" {
  value = module.chalk_compute_registry.repository_url
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| repository_name | string | _(required)_ | ECR repository name, e.g. `chalk-snrn-prod/compute` |
| image_tag_mutability | string | `"IMMUTABLE"` | `IMMUTABLE` or `MUTABLE` |
| scan_on_push | bool | `true` | Scan images for vulnerabilities on push |
| force_delete | bool | `false` | Delete repo even if it contains images |
| tags | map(string) | `{}` | Additional tags; `chalk.ai/managed-by = chalk` is always merged in |

## Outputs

| Name | Description |
|------|-------------|
| repository_url | Full repository URL for `docker push` / Chalk config |
| repository_arn | Repository ARN |
| repository_name | Repository name |
| registry_id | AWS account ID of the registry |

## IAM permissions for the Chalk role

The repository must be reachable by Chalk's management role. Grant these to the
role, ideally conditioned on `aws:ResourceTag/chalk.ai/managed-by = chalk`:

- Account-level: `ecr:GetAuthorizationToken`
- Pull: `ecr:DescribeImages`, `ecr:BatchCheckLayerAvailability`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`
- Push: `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage`
