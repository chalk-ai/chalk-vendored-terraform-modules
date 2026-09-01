# AWS Valkey 8 Online Store Module

> **Deprecated** — use [`valkey9`](../valkey9) for new clusters. `valkey8` exists only so that
> existing Valkey 8 clusters have a stable home. It is frozen: no new features will be added.

Terraform module for provisioning an AWS ElastiCache Valkey 8 cluster configured as a Chalk online
feature store. This is a frozen copy of the original `valkey` module: same resources, same defaults,
same outputs, verified by running that module's characterization suite against this one unchanged.

## Features

- Cluster-mode ElastiCache replication group running the `valkey` engine
- Multi-AZ deployment with automatic failover
- Encryption in transit and at rest
- Dedicated cache subnet group and VPC security group (CIDR ingress, self-ingress, egress-all)
- AWS Secrets Manager secret with the connection URI

Not available in this module: `durability`, `snapshot_name`, and the plan-time preconditions. Those
are `valkey9` features.

## Usage

```hcl
module "chalk_valkey_store" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/online-store/valkey8?ref=v0.2.0"

  cluster_id          = "chalk-valkey"
  vpc_id              = "vpc-xxxxx"
  subnet_ids          = ["subnet-xxxxx", "subnet-yyyyy"]
  allowed_cidr_blocks = ["10.0.0.0/16"]

  num_node_groups         = 3
  replicas_per_node_group = 1
  node_type               = "cache.m5.large"

  tags = {
    Environment = "production"
  }
}

output "secret_name" {
  value = module.chalk_valkey_store.valkey_endpoint_redis_secret_name
}
```

## Migrating from `valkey`

The old `modules/aws/online-store/valkey` path was removed in `v0.2.0`.

To stay on Valkey 8, the migration is a **source-string change only**:

```diff
- source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/online-store/valkey?ref=v0.1.0"
+ source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/online-store/valkey8?ref=v0.2.0"
```

This plans as a **no-op**: a module's `source` is not part of its resource addresses, so every resource
keeps the same address in state. No `moved` blocks and no state surgery are required.

Callers who instead want Valkey 9 should move to [`valkey9`](../valkey9). Be aware that an ElastiCache
engine upgrade is **one-way** — it cannot be downgraded — and that the parameter group family changes
along with it.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| cluster_id | string | _required_ | ID for the Valkey cluster |
| vpc_id | string | _required_ | VPC ID where the Valkey cluster will be deployed |
| subnet_ids | list(string) | _required_ | List of subnet IDs for the cache subnet group (must span multiple AZs); at least 2 required |
| num_node_groups | number | `3` | Number of node groups (shards) for the cluster |
| replicas_per_node_group | number | `1` | Number of replica nodes in each node group |
| node_type | string | `"cache.m5.large"` | Instance class for cache nodes |
| engine_version | string | `"8.0"` | Valkey engine version |
| parameter_group_name | string | `"default.valkey8.cluster.on"` | Name of the parameter group to associate with this cluster |
| port | number | `6379` | Port number on which the cache accepts connections |
| multi_az_enabled | bool | `true` | Enable Multi-AZ deployment |
| automatic_failover_enabled | bool | `true` | Enable automatic failover for the cluster |
| transit_encryption_enabled | bool | `true` | Enable encryption in transit |
| at_rest_encryption_enabled | bool | `true` | Enable encryption at rest |
| auto_minor_version_upgrade | bool | `true` | Enable automatic minor version upgrades |
| maintenance_window | string | `"sun:05:00-sun:06:00"` | Weekly time range for system maintenance |
| snapshot_retention_limit | number | `5` | Number of days for which ElastiCache retains automatic cache cluster snapshots |
| snapshot_window | string | `"03:00-04:00"` | Daily time range for taking snapshots |
| allowed_cidr_blocks | list(string) | `[]` | List of CIDR blocks that are allowed to access the cluster |
| tags | map(string) | `{}` | Tags to apply to all resources |

## Outputs

| Name | Description |
|------|-------------|
| cluster_id | ID of the Valkey cluster |
| cluster_arn | ARN of the Valkey cluster |
| configuration_endpoint_address | Configuration endpoint for the cluster (cluster mode) |
| primary_endpoint_address | Primary endpoint for the cluster |
| reader_endpoint_address | Reader endpoint for the cluster |
| port | Port number for the cluster |
| security_group_id | ID of the security group for the Valkey cluster |
| security_group_arn | ARN of the security group for the Valkey cluster |
| subnet_group_name | Name of the cache subnet group |
| subnet_group_arn | ARN of the cache subnet group |
| valkey_endpoint_redis_secret_name | Name of the secret containing the Redis-compatible endpoint connection string |
| engine | Engine used by the cluster |
| engine_version | Engine version used by the cluster |
| node_type | Node type used by the cluster |
| num_node_groups | Number of node groups (shards) in the cluster |
| replicas_per_node_group | Number of replicas per node group |
| member_clusters | List of cluster cache cluster IDs |
| cluster_enabled | Whether cluster mode is enabled |
| instance_id | Cluster instance ID |
| subnet_group_id | Generated subnet group name |
| security_group_name | Generated security group name |

## Connection URI

The module creates an AWS Secrets Manager secret named `<cluster_id>-redis-uri` holding:

```
<scheme>://<configuration_endpoint>:<port>?clustered=true#insecure
```

The scheme is `rediss://` when `transit_encryption_enabled` is true (the default), otherwise `redis://`.

## Integration with Chalk

1. Deploy the module: `terraform apply`
2. Note the `valkey_endpoint_redis_secret_name` output
3. Configure in Chalk Dashboard: **Integrations > Online Store > Redis**
