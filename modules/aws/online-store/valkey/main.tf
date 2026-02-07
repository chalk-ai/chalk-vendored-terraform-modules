locals {
  subnet_group_name   = "${var.cluster_id}-subnet"
  security_group_name = "${var.cluster_id}-sg"

  valkey_endpoint_redis_secret_name = "${var.cluster_id}-redis-uri"
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

  # Apply mode must be specified for cluster mode
  apply_immediately = false

  tags = var.tags

  depends_on = [
    aws_elasticache_subnet_group.valkey,
    aws_security_group.valkey
  ]
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