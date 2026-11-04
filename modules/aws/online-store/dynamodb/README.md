# AWS DynamoDB Online Store Module

Terraform module for provisioning an AWS DynamoDB table configured as a Chalk online feature store.

## Features

- Pre-configured schema with hash key (`__id__`) and range key (`__ns__`)
- TTL support using `__exp__` attribute
- Pay-per-request or provisioned billing modes
- Optional autoscaling for provisioned capacity
- AWS Secrets Manager secret with connection URI

## Usage

### Basic (Pay-per-request)

```hcl
module "chalk_online_store" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/online-store/dynamodb?ref=main"

  table_name   = "chalk_online_store"
  billing_mode = "PAY_PER_REQUEST"
}
```

### With Autoscaling

```hcl
module "chalk_online_store" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/online-store/dynamodb?ref=main"

  autoscaling_enabled = true
  table_name     = "chalk_online_store"
  billing_mode   = "PROVISIONED"
  read_capacity  = 10
  write_capacity = 10

  autoscaling_read = {
    min_capacity = 10
    max_capacity = 200
    target_value = 70
  }

  autoscaling_write = {
    min_capacity = 10
    max_capacity = 200
    target_value = 70
  }
}
```

## Inputs

### Adopting existing resources

When importing an existing store, set `secret_name`, `read_policy_name`,
`write_policy_name`, `table_tags`, and `secret_tags` to the existing values to
avoid changing names or removing tags. The defaults preserve the module's
existing naming conventions. For a production handoff, pin the Git source to a
reviewed commit or release and require an import-only plan with no resource
changes before applying.

The scaling target minimums come from `read_capacity` and `write_capacity`.
Values named `min_capacity` inside the autoscaling maps do not override those
minimums. Current table throughput can differ from the target minimums because
AWS autoscaling manages it; the module ignores throughput drift on the table.

| Name | Type | Default | Description |
|------|------|---------|-------------|
| table_name | string | `"chalk_online_store"` | DynamoDB table name |
| secret_name | string | `null` | Existing/custom connection secret name; null uses `<table_name>-online-store-secret` |
| table_tags | map(string) | `{}` | Tags to apply to the table |
| secret_tags | map(string) | `{}` | Tags to apply to the connection secret |
| billing_mode | string | `"PAY_PER_REQUEST"` | PROVISIONED or PAY_PER_REQUEST |
| read_capacity | number | `null` | Read capacity units (PROVISIONED mode only) |
| write_capacity | number | `null` | Write capacity units (PROVISIONED mode only) |
| autoscaling_read | map(string) | See below | Read autoscaling configuration |
| autoscaling_write | map(string) | See below | Write autoscaling configuration |
| autoscaling_enabled | bool | `false` | Enable read/write autoscaling resources |
| read_policy_name | string | `null` | Existing/custom read policy name; null retains the generated name |
| write_policy_name | string | `null` | Existing/custom write policy name; null retains the generated name |
| deletion_protection_enabled | bool | `false` | Enable deletion protection for the table |

## Outputs

| Name | Description |
|------|-------------|
| table_uri | DynamoDB URI (format: `dynamodb:///table-name`) |
| online_store_secret | AWS Secrets Manager secret name |
| online_store_kind | Returns "DYNAMODB" |
| table_name | DynamoDB table name |
| arn | Table ARN |

## Integration with Chalk

1. Deploy the module: `terraform apply`
2. Note the `online_store_secret` output
3. Configure in Chalk Dashboard: **Integrations > Online Store > DynamoDB**

## Table Schema

- **Hash Key**: `__id__` (String)
- **Range Key**: `__ns__` (String)
- **TTL Attribute**: `__exp__`
