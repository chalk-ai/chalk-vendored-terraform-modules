# Chalk Vendored Terraform Modules

Terraform modules for deploying auxiliary infrastructure alongside Chalk deployments. These modules provision online stores and automatically create secrets containing connection URIs that Chalk can consume.

## Overview

Self-contained modules for deploying infrastructure components used by Chalk. Each module creates the necessary resources and an AWS Secrets Manager secret containing the connection URI.

## Available Modules

### AWS IAM Modules

#### Chalk Management Role (`modules/aws/chalk-management-role`)

Creates the cross-account IAM role Chalk uses to deploy and manage customer-cloud infrastructure. It supports broad initial-deployment permissions and a flag that switches the role to restricted ongoing-management permissions without replacing the role.

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

#### Valkey 9 (`modules/aws/online-store/valkey9`)

Redis-compatible in-memory data store using AWS ElastiCache. **Recommended for all new clusters.**

**Features**:
- Cluster mode with sharding and replication
- Multi-AZ deployment with automatic failover
- Encryption in transit and at rest
- VPC security group configuration
- **Multi-AZ transactional log durability** (`durability`) — create-only, with plan-time preconditions for every prerequisite
- **Restore from an ElastiCache snapshot** (`snapshot_name`), including into a different shard count

**Requires** AWS provider `>= 6.51.0`.

**Key Outputs**:
- `valkey_endpoint_redis_secret_name`: Secret name to configure in Chalk dashboard
- `security_group_id`: Security group for network access

See [`modules/aws/online-store/valkey9/README.md`](modules/aws/online-store/valkey9/README.md).

#### Valkey 8 (`modules/aws/online-store/valkey8`)

**Deprecated / frozen.** An unmodified copy of the original `valkey` module — same resources, same
defaults, same outputs — kept only so that existing Valkey 8 clusters have a stable home. No new
features will be added. Use `valkey9` for new clusters.

See [`modules/aws/online-store/valkey8/README.md`](modules/aws/online-store/valkey8/README.md).

### AWS Karpenter Modules

#### Chalk Standard Karpenter Set (`modules/aws/karpenter/chalk-standard`)

Chalk's **standard** Karpenter node resources for an EKS cluster that Chalk does not
manage: three `EC2NodeClass` objects, six `NodePool` objects and one `RuntimeClass`, from
one module. Pool names, labels, taints, requirements and limits are all fixed.

Use it when you want Chalk's standard node set on a cluster Chalk does not manage. It is
deliberately not a generic node-pool builder: if you need node pools that are *not*
Chalk's standard set, declare them yourself against the Karpenter CRDs.

**Features**:
- All ten standard objects from one module -- no nested modules
- Karpenter **v1** schemas only (`karpenter.sh/v1`, `karpenter.k8s.aws/v1`)
- Exactly two inputs, both required: `subnets` and `cluster_name`
- Creates the `EC2NodeClass` and `RuntimeClass` objects the Chalk UI cannot create at all

**Requires** the `alekc/kubectl` provider `~> 2.3`, and a working Karpenter controller --
the Helm releases, controller IAM and interruption queue are deliberately out of scope.

**Key Outputs**:
- `node_pool_names`: names of every NodePool created
- `node_role_name`: the IAM role name assigned to launched nodes

See [`modules/aws/karpenter/chalk-standard/README.md`](modules/aws/karpenter/chalk-standard/README.md).

## Usage

### Chalk Management Role

```hcl
module "chalk_management_role" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/chalk-management-role?ref=v0.2.0"

  external_id = var.chalk_external_id
}
```

### Chalk Standard Karpenter Set

```hcl
module "chalk_karpenter" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/chalk-standard?ref=v0.3.0"

  cluster_name = "example-cluster"
  subnets      = ["subnet-xxxxx", "subnet-yyyyy", "subnet-zzzzz"]
}

output "karpenter_node_pools" {
  value = module.chalk_karpenter.node_pool_names
}
```

### DynamoDB

```hcl
module "chalk_online_store" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/online-store/dynamodb?ref=v0.2.0"

  table_name   = "chalk_online_store"
  billing_mode = "PAY_PER_REQUEST"
}

output "secret_name" {
  value = module.chalk_online_store.online_store_secret
}
```

### Valkey 9

```hcl
module "chalk_valkey_store" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/online-store/valkey9?ref=v0.2.0"

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

## Versioning

Modules are consumed by git tag. **Always pin `?ref=<tag>`** — never `?ref=main`.

| Tag | Notes |
|-----|-------|
| `v0.1.0` | Last release containing `modules/aws/online-store/valkey` |
| `v0.2.0` | Removed `modules/aws/online-store/valkey` in favour of `valkey8` / `valkey9` |

## Migrating from the `valkey` module

`modules/aws/online-store/valkey` was removed in `v0.2.0`. Pick a target:

| From | To | Effect |
|------|----|--------|
| `.../online-store/valkey?ref=v0.1.0` | `.../online-store/valkey8?ref=v0.2.0` | Stay on Valkey 8. Plans as a **no-op**. |
| `.../online-store/valkey?ref=v0.1.0` | `.../online-store/valkey9?ref=v0.2.0` | Move to Valkey 9. **One-way engine upgrade** — it cannot be downgraded — and the parameter group family changes too. |

Either way the migration is a **source-string change only**. A module's `source` is not part of its
resource addresses, so no `moved` blocks and no state surgery are required.

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
