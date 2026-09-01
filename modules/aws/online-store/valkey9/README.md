# AWS Valkey 9 Online Store Module

Terraform module for provisioning an AWS ElastiCache Valkey 9 cluster configured as a Chalk online feature store. This is the module where all new Valkey work lands; use it for all new clusters.

## Features

- Cluster-mode ElastiCache replication group running the `valkey` engine
- Multi-AZ deployment with automatic failover
- Encryption in transit and at rest
- Dedicated cache subnet group and VPC security group (CIDR ingress, self-ingress, egress-all)
- **Multi-AZ transactional log durability** (`durability`) for durable writes
- **Restore from an ElastiCache snapshot** (`snapshot_name`), including into a different shard count
- Plan-time `precondition` guards for every durability prerequisite and for engine/parameter-group family mismatch
- AWS Secrets Manager secret with the connection URI

## Requirements

| Name | Version |
|------|---------|
| aws provider | `>= 6.51.0` |

The `durability` argument on `aws_elasticache_replication_group` shipped in AWS provider v6.51.0, so
the module declares that floor in `versions.tf`. A root module pinned below it fails at `init` with an
unresolvable provider constraint. This floor is the reason `valkey8` declares no provider requirement
at all — it needs nothing newer than what its callers already run.

## Usage

### Basic

```hcl
module "chalk_valkey_store" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/online-store/valkey9?ref=v0.2.0"

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

### Restore from a snapshot, with durability

```hcl
module "chalk_valkey_durable" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/online-store/valkey9?ref=v0.2.0"

  cluster_id          = "chalk-valkey-durable"
  vpc_id              = "vpc-xxxxx"
  subnet_ids          = ["subnet-xxxxx", "subnet-yyyyy"]
  allowed_cidr_blocks = ["10.0.0.0/16"]

  # Graviton node family is required for durability.
  node_type               = "cache.r7g.4xlarge"
  num_node_groups         = 18
  replicas_per_node_group = 1

  # multi_az_enabled and transit_encryption_enabled default to true,
  # which is what durability requires.
  durability    = "async"
  snapshot_name = "my-valkey-snapshot"

  tags = {
    Environment = "staging"
  }
}
```

## Durability

`durability` enables ElastiCache Multi-AZ transactional log durability, which persists writes to a
replicated transaction log rather than relying solely on in-memory replication.

### Durability is create-only

`durability` is **ForceNew**. It cannot be enabled on an existing non-durable cluster. The only way to
make an existing cluster durable is to take a snapshot and restore it into a **new** cluster that is
created durable — that is what `snapshot_name` is for.

After creation:

- `sync` <-> `async` can be changed in place.
- Durability **cannot be disabled** once enabled.

### Modes

| Value | Behaviour |
|-------|-----------|
| `sync` | The write is persisted to the transaction log **before** the client is acked. Write latency rises to single-digit milliseconds. |
| `async` | The write is persisted **after** the ack. Keeps microsecond write latency, but up to ~10s of writes can be lost on failure. If the primary cannot persist for more than 10s it starts **rejecting writes**. |
| `disabled` | Durability off. |
| `default` | Let ElastiCache choose the mode. |

`disabled` and `default` do not turn durability on, so they do not trigger the prerequisite
preconditions below.

### Prerequisites

All of the following are required **at creation** when `durability` is `async` or `sync`. The module
enforces each with a `precondition`, so a violation fails at **plan** time rather than partway through
an apply:

- Valkey engine **9.0 or later**
- **Cluster mode enabled** — implicit; this module only builds cluster-mode replication groups
- **Multi-AZ enabled** (`multi_az_enabled = true`)
- **At least one replica per shard** (`replicas_per_node_group >= 1`)
- **Transit encryption enabled at creation** (`transit_encryption_enabled = true`)
- A **Graviton node family**: R8g, R7g, R6g, M8g, M7g, M6g, C8gn, C7gn

> The module default for `node_type` is `cache.m5.large`, which is **not** a Graviton family. A caller
> enabling durability must also set `node_type`.

### Limitations

- Not supported with ElastiCache Serverless, Global Datastore, Outposts, Local Zones, or data tiering.
- Write throughput is capped at **100 MiBps per primary node**.

## Engine / parameter group precondition

Independent of durability, the module asserts that the parameter group family matches the engine major
version. If `parameter_group_name` matches `default.valkey<N>...`, then `<N>` must equal the major
version of `engine_version`. Custom (non-`default.valkey*`) parameter group names skip this check.

This catches the classic mismatch of engine `9.0` with `default.valkey8.cluster.on`.

## `ignore_changes = [snapshot_name]`

The replication group carries `lifecycle { ignore_changes = [snapshot_name] }`.

The AWS provider writes `snapshot_name` at create time but never refreshes it. Without this guard,
removing the `snapshot_name` line from your config after the cluster exists would render a **ForceNew**
diff and **replace** the cluster — potentially a multi-terabyte one.

- It is a no-op for callers who never set `snapshot_name`.
- Consequence: to restore from a *different* snapshot you must explicitly `-replace` the resource.

## Restoring into a different shard count

You may restore into a different `num_node_groups` than the snapshot was taken at. ElastiCache
redistributes slots across the new shard count during the restore.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| cluster_id | string | _required_ | ID for the Valkey cluster |
| vpc_id | string | _required_ | VPC ID where the Valkey cluster will be deployed |
| subnet_ids | list(string) | _required_ | List of subnet IDs for the cache subnet group (must span multiple AZs); at least 2 required |
| num_node_groups | number | `3` | Number of node groups (shards) for the cluster |
| replicas_per_node_group | number | `1` | Number of replica nodes in each node group |
| node_type | string | `"cache.m5.large"` | Instance class for cache nodes |
| engine_version | string | `"9.0"` | Valkey engine version |
| parameter_group_name | string | `"default.valkey9.cluster.on"` | Name of the parameter group to associate with this cluster |
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
| snapshot_name | string | `null` | Name of an ElastiCache snapshot to restore the new cluster from. Create-only / ForceNew |
| durability | string | `null` | Multi-AZ transactional log durability: `default`, `async`, `sync`, `disabled`. Create-only / ForceNew |

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
| snapshot_name | Snapshot the cluster was created from, if any |
| durability | Durability setting on the replication group |
| durability_input | Input echo of `var.durability`; distinguishes "caller set nothing" from a provider-computed value |

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
