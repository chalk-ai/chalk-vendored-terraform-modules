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

Karpenter v1 node resources for a customer-managed EKS cluster, so Chalk Resources V2 nodepools can
be created from Terraform instead of hand-authored CRDs. Both modules assume Karpenter v1.x is
already installed; neither installs or manages the controller.

They are split because Karpenter v1 accepts subnets **only** on the EC2NodeClass — the NodePool
schema has no subnet field — and one node class is referenced by many pools.

#### EC2NodeClass (`modules/aws/karpenter/ec2nodeclass`)

Renders one `karpenter.k8s.aws/v1` EC2NodeClass from a YAML template.

**Features**:
- Subnets as a required input, in Karpenter's native `subnetSelectorTerms` shape — explicit IDs or
  `karpenter.sh/discovery` tag discovery
- AL2023 via an `amiSelectorTerms` alias, pinnable to a dated release
- IMDSv2-only metadata options, gp3 root volume, optional RAID0 instance store
- Substitutable manifest template for clusters that need something else

**Key Outputs**:
- `name`: feed to the nodepool module's `ec2nodeclass_name` — carries the dependency edge
- `node_class_ref`: drop-in `{group, kind, name}` for a NodePool's `nodeClassRef`

See [`modules/aws/karpenter/ec2nodeclass/README.md`](modules/aws/karpenter/ec2nodeclass/README.md).

#### NodePool (`modules/aws/karpenter/nodepool`)

Renders one `karpenter.sh/v1` NodePool against a node class created by the module above or one that
already exists in the cluster.

**Features**:
- Caller-supplied `requirements`, `limits`, `taints`, `labels` and `weight` — no hardcoded Chalk
  requirement list, so machine families can be pinned per pool
- Emits no Karpenter default it was not asked for: `disruption` and `expireAfter` stay absent unless set
- Optional plan-time lookup of the referenced node class, to fail before apply when it is missing

**Key Outputs**:
- `name`, `rendered_manifest`

See [`modules/aws/karpenter/nodepool/README.md`](modules/aws/karpenter/nodepool/README.md).

## Usage

### Chalk Management Role

```hcl
module "chalk_management_role" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/chalk-management-role?ref=v0.2.0"

  external_id = var.chalk_external_id
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

### Karpenter node resources

One node class, many pools. The `name` output is what orders the pools after the class.

```hcl
module "karpenter_nodeclass" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/ec2nodeclass?ref=v0.3.0"

  cluster_name   = "example-cluster"
  node_role_name = "example-cluster-Managed-Node-Role"

  subnet_selector_terms = [
    { id = "subnet-xxxxx" },
    { id = "subnet-yyyyy" },
  ]
}

# Latency-sensitive pool pinning a machine family.
module "karpenter_pool_online" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/nodepool?ref=v0.3.0"

  name              = "online-c7a"
  ec2nodeclass_name = module.karpenter_nodeclass.name

  requirements = [
    { key = "karpenter.k8s.aws/instance-family", operator = "In", values = ["c7a"] },
    { key = "kubernetes.io/arch",                operator = "In", values = ["amd64"] },
    { key = "karpenter.sh/capacity-type",        operator = "In", values = ["on-demand"] },
  ]
  limits = { cpu = "500", memory = "5000Gi" }
  weight = 20
}
```

## Versioning

Modules are consumed by git tag. **Always pin `?ref=<tag>`** — never `?ref=main`.

| Tag | Notes |
|-----|-------|
| `v0.1.0` | Last release containing `modules/aws/online-store/valkey` |
| `v0.2.0` | Removed `modules/aws/online-store/valkey` in favour of `valkey8` / `valkey9` |
| `v0.3.0` | Added `modules/aws/karpenter/ec2nodeclass` and `modules/aws/karpenter/nodepool` |

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
