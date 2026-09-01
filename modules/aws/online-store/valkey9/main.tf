locals {
  subnet_group_name   = "${var.cluster_id}-subnet"
  security_group_name = "${var.cluster_id}-sg"

  valkey_endpoint_redis_secret_name = "${var.cluster_id}-redis-uri"

  # "default" and "disabled" are valid durability values that do not turn durability on, so they
  # must not drag the prerequisites in with them.
  durability_enabled = var.durability != null && contains(["async", "sync"], coalesce(var.durability, "disabled"))

  engine_major = tonumber(split(".", var.engine_version)[0])

  # cache.r7g.4xlarge -> r7g
  node_family = lower(split(".", var.node_type)[1])

  # ElastiCache durability is supported only on Graviton families.
  durability_node_families = ["r8g", "r7g", "r6g", "m8g", "m7g", "m6g", "c8gn", "c7gn"]

  # Major version of a default.valkey<N>.* parameter group, or null for a custom group.
  parameter_group_major = can(regex("^default\\.valkey(\\d+)", var.parameter_group_name)) ? tonumber(regex("^default\\.valkey(\\d+)", var.parameter_group_name)[0]) : null
}

# Cache subnet group for multi-AZ deployment
resource "aws_elasticache_subnet_group" "valkey" {
  name       = local.subnet_group_name
  subnet_ids = var.subnet_ids

  tags = var.tags
}

# Security group for Valkey cluster
resource "aws_security_group" "valkey" {
  name_prefix = "${local.security_group_name}-"
  vpc_id      = var.vpc_id
  description = "Security group for Valkey cluster ${var.cluster_id}"

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# Ingress rule for allowed CIDR blocks
resource "aws_security_group_rule" "valkey_ingress_cidr" {
  count = length(var.allowed_cidr_blocks) > 0 ? 1 : 0

  type              = "ingress"
  from_port         = var.port
  to_port           = var.port
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidr_blocks
  security_group_id = aws_security_group.valkey.id
  description       = "Allow Valkey access from specified CIDR blocks"
}

# Self-referential rule for inter-cluster communication
resource "aws_security_group_rule" "valkey_ingress_self" {
  type              = "ingress"
  from_port         = var.port
  to_port           = var.port
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.valkey.id
  description       = "Allow inter-cluster communication"
}

# Egress rule (allow all outbound)
resource "aws_security_group_rule" "valkey_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks = ["0.0.0.0/0"]
  security_group_id = aws_security_group.valkey.id
  description       = "Allow all outbound traffic"
}

# ElastiCache Valkey cluster
resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id = var.cluster_id
  description = "Valkey cluster ${var.cluster_id}"

  # Valkey engine configuration
  engine               = "valkey"
  engine_version       = var.engine_version
  parameter_group_name = var.parameter_group_name
  port = var.port

  # Node and cluster configuration
  node_type       = var.node_type
  num_node_groups = var.num_node_groups
  replicas_per_node_group = var.replicas_per_node_group

  # Network configuration
  subnet_group_name = aws_elasticache_subnet_group.valkey.name
  security_group_ids = [aws_security_group.valkey.id]

  # Availability and failover
  multi_az_enabled = var.multi_az_enabled
  automatic_failover_enabled = var.automatic_failover_enabled

  # Encryption
  transit_encryption_enabled = var.transit_encryption_enabled
  at_rest_encryption_enabled = var.at_rest_encryption_enabled

  # Maintenance and backups
  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  maintenance_window         = var.maintenance_window
  snapshot_retention_limit   = var.snapshot_retention_limit
  snapshot_window = var.snapshot_window

  # Restore and durability. Both are create-only (ForceNew) on the AWS provider.
  snapshot_name = var.snapshot_name
  durability = var.durability

  # Apply mode must be specified for cluster mode
  apply_immediately = false

  tags = var.tags

  depends_on = [
    aws_elasticache_subnet_group.valkey,
    aws_security_group.valkey
  ]

  lifecycle {
    # The AWS provider writes snapshot_name on create but never refreshes it, so without this a
    # caller who later drops the argument from their config gets a ForceNew diff and replaces a
    # cluster that may hold terabytes. No-op for callers who never set it. To restore from a
    # different snapshot, replace the resource explicitly.
    ignore_changes = [snapshot_name]

    # Durability prerequisites. All are required at creation and none can be added afterwards, so
    # they are checked at plan time rather than discovered when AWS rejects the create.
    precondition {
      condition     = !local.durability_enabled || local.engine_major >= 9
      error_message = "durability requires Valkey 9.0 or later; engine_version is \"${var.engine_version}\"."
    }

    precondition {
      condition     = !local.durability_enabled || var.multi_az_enabled
      error_message = "durability requires multi_az_enabled = true."
    }

    precondition {
      condition     = !local.durability_enabled || var.replicas_per_node_group >= 1
      error_message = "durability requires at least one replica per shard; replicas_per_node_group is ${var.replicas_per_node_group}."
    }

    precondition {
      condition     = !local.durability_enabled || var.transit_encryption_enabled
      error_message = "durability requires transit_encryption_enabled = true at creation."
    }

    precondition {
      condition     = !local.durability_enabled || contains(local.durability_node_families, local.node_family)
      error_message = "durability requires a Graviton node family (${join(", ", local.durability_node_families)}); node_type is \"${var.node_type}\"."
    }

    # Not gated on durability: mismatching a default.valkey<N> parameter group against the engine
    # major is a footgun for every caller now that the engine default is 9.
    precondition {
      condition     = local.parameter_group_major == null || local.parameter_group_major == local.engine_major
      error_message = "parameter_group_name \"${var.parameter_group_name}\" does not match engine_version \"${var.engine_version}\". Use a default.valkey${local.engine_major} group, or a custom parameter group."
    }
  }
}

# Connection string generation
locals {
  configuration_endpoint = aws_elasticache_replication_group.valkey.configuration_endpoint_address

  # Connection string following GCP patterns
  redis_connection_string = var.transit_encryption_enabled ? "rediss://${local.configuration_endpoint}:${var.port}?clustered=true#insecure" : "redis://${local.configuration_endpoint}:${var.port}?clustered=true#insecure"
}

# AWS Secrets Manager secret for Redis-compatible endpoint
resource "aws_secretsmanager_secret" "valkey_endpoint_redis" {
  name        = local.valkey_endpoint_redis_secret_name
  description = "Redis-compatible endpoint connection string for ${var.cluster_id}"

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "valkey_endpoint_redis" {
  secret_id     = aws_secretsmanager_secret.valkey_endpoint_redis.id
  secret_string = local.redis_connection_string
}