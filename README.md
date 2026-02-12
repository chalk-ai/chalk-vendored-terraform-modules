# Chalk Vendored Terraform Modules

Terraform modules for deploying auxiliary infrastructure alongside Chalk deployments. These modules provision online stores and automatically create secrets containing connection URIs that Chalk can consume.

## Overview

Self-contained modules for deploying infrastructure components used by Chalk. Each module creates the necessary resources and an AWS Secrets Manager secret containing the connection URI.

## Available Modules

### AWS Online Store Modules

#### DynamoDB (`modules/aws/online-store/dynamodb`)

Managed NoSQL database for Chalk's online feature store.

**Features**:
- Configurable billing mode (PAY_PER_REQUEST or PROVISIONED)
- Optional autoscaling for provisioned capacity
- TTL enabled for automatic expiration
- AWS Secrets Manager integration

**Key Outputs**:
- `online_store_secret`: Secret name to configure in Chalk dashboard
- `table_uri`: DynamoDB connection URI

#### Valkey (`modules/aws/online-store/valkey`)

Redis-compatible in-memory data store using AWS ElastiCache.

**Features**:
- Cluster mode with sharding and replication
- Multi-AZ deployment with automatic failover
- Encryption in transit and at rest
- VPC security group configuration

**Key Outputs**:
- `valkey_endpoint_redis_secret_name`: Secret name to configure in Chalk dashboard
- `security_group_id`: Security group for network access

## Usage

### DynamoDB

```hcl
module "chalk_online_store" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/online-store/dynamodb?ref=main"

  table_name   = "chalk_online_store"
  billing_mode = "PAY_PER_REQUEST"
}

output "secret_name" {
  value = module.chalk_online_store.online_store_secret
}
```

### Valkey

```hcl
module "chalk_valkey_store" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/online-store/valkey?ref=main"

  cluster_id              = "chalk-valkey"
  vpc_id                  = "vpc-xxxxx"
  subnet_ids              = ["subnet-xxxxx", "subnet-yyyyy"]
  allowed_cidr_blocks     = ["10.0.0.0/16"]

  num_node_groups         = 3
  replicas_per_node_group = 1
  node_type              = "cache.m5.large"

  tags = {
    Environment = "production"
  }
}

output "secret_name" {
  value = module.chalk_valkey_store.valkey_endpoint_redis_secret_name
}
```

## Integration with Chalk

### 1. Deploy the Module

```bash
terraform init
terraform apply
```

### 2. Configure Chalk Dashboard

**For DynamoDB**:
- Navigate to **Integrations > Online Store > DynamoDB**
- Set **Secret Name** to the `online_store_secret` output value

**For Valkey/Redis**:
- Navigate to **Integrations > Online Store > Redis**
- Set **Secret Name** to the `valkey_endpoint_redis_secret_name` output value
