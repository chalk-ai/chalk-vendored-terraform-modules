output "cluster_id" {
  description = "ID of the Valkey cluster"
  value       = aws_elasticache_replication_group.valkey.id
}

output "cluster_arn" {
  description = "ARN of the Valkey cluster"
  value       = aws_elasticache_replication_group.valkey.arn
}

output "configuration_endpoint_address" {
  description = "Configuration endpoint for the cluster (cluster mode)"
  value       = aws_elasticache_replication_group.valkey.configuration_endpoint_address
}

output "primary_endpoint_address" {
  description = "Primary endpoint for the cluster"
  value       = aws_elasticache_replication_group.valkey.primary_endpoint_address
}

output "reader_endpoint_address" {
  description = "Reader endpoint for the cluster"
  value       = aws_elasticache_replication_group.valkey.reader_endpoint_address
}

output "port" {
  description = "Port number for the cluster"
  value       = var.port
}

output "security_group_id" {
  description = "ID of the security group for the Valkey cluster"
  value       = aws_security_group.valkey.id
}

output "security_group_arn" {
  description = "ARN of the security group for the Valkey cluster"
  value       = aws_security_group.valkey.arn
}

output "subnet_group_name" {
  description = "Name of the cache subnet group"
  value       = aws_elasticache_subnet_group.valkey.name
}

output "subnet_group_arn" {
  description = "ARN of the cache subnet group"
  value       = aws_elasticache_subnet_group.valkey.arn
}

# Connection string outputs (sensitive)
output "valkey_endpoint_redis_secret_name" {
  description = "Name of the secret containing the Redis-compatible endpoint connection string"
  value       = aws_secretsmanager_secret.valkey_endpoint_redis.name
}

# Cluster information outputs
output "engine" {
  description = "Engine used by the cluster"
  value       = aws_elasticache_replication_group.valkey.engine
}

output "engine_version" {
  description = "Engine version used by the cluster"
  value       = aws_elasticache_replication_group.valkey.engine_version
}

output "node_type" {
  description = "Node type used by the cluster"
  value       = aws_elasticache_replication_group.valkey.node_type
}

output "num_node_groups" {
  description = "Number of node groups (shards) in the cluster"
  value       = aws_elasticache_replication_group.valkey.num_node_groups
}

output "replicas_per_node_group" {
  description = "Number of replicas per node group"
  value       = aws_elasticache_replication_group.valkey.replicas_per_node_group
}

output "member_clusters" {
  description = "List of cluster cache cluster IDs"
  value       = aws_elasticache_replication_group.valkey.member_clusters
}

output "cluster_enabled" {
  description = "Whether cluster mode is enabled"
  value       = aws_elasticache_replication_group.valkey.cluster_enabled
}

# Generated instance identifiers
output "instance_id" {
  description = "Cluster instance ID"
  value       = var.cluster_id
}

output "subnet_group_id" {
  description = "Generated subnet group name"
  value       = local.subnet_group_name
}

output "security_group_name" {
  description = "Generated security group name"
  value       = local.security_group_name
}