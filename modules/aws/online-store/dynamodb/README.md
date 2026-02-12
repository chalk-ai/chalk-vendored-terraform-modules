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

| Name | Type | Default | Description |
|------|------|---------|-------------|
| table_name | string | `"chalk_online_store"` | DynamoDB table name |
| billing_mode | string | `"PAY_PER_REQUEST"` | PROVISIONED or PAY_PER_REQUEST |
| read_capacity | number | `null` | Read capacity units (PROVISIONED mode only) |
| write_capacity | number | `null` | Write capacity units (PROVISIONED mode only) |
| autoscaling_read | map(string) | See below | Read autoscaling configuration |
| autoscaling_write | map(string) | See below | Write autoscaling configuration |

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
