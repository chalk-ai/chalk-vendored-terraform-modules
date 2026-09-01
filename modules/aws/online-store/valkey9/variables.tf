variable "cluster_id" {
  description = "ID for the Valkey cluster"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the Valkey cluster will be deployed"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the cache subnet group (must span multiple AZs)"
  type        = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "At least 2 subnet IDs must be provided for high availability."
  }
}

variable "num_node_groups" {
  description = "Number of node groups (shards) for the cluster"
  type        = number
  default     = 3
}

variable "replicas_per_node_group" {
  description = "Number of replica nodes in each node group"
  type        = number
  default     = 1
}

variable "node_type" {
  description = "Instance class for cache nodes"
  type        = string
  default     = "cache.m5.large"
}

variable "engine_version" {
  description = "Valkey engine version"
  type        = string
  default     = "9.0"
}

variable "parameter_group_name" {
  description = "Name of the parameter group to associate with this cluster"
  type        = string
  default     = "default.valkey9.cluster.on"
}

variable "port" {
  description = "Port number on which the cache accepts connections"
  type        = number
  default     = 6379
}

variable "multi_az_enabled" {
  description = "Enable Multi-AZ deployment"
  type        = bool
  default     = true
}

variable "automatic_failover_enabled" {
  description = "Enable automatic failover for the cluster"
  type        = bool
  default     = true
}

variable "transit_encryption_enabled" {
  description = "Enable encryption in transit"
  type        = bool
  default     = true
}

variable "at_rest_encryption_enabled" {
  description = "Enable encryption at rest"
  type        = bool
  default     = true
}


variable "auto_minor_version_upgrade" {
  description = "Enable automatic minor version upgrades"
  type        = bool
  default     = true
}

variable "maintenance_window" {
  description = "Weekly time range for system maintenance"
  type        = string
  default     = "sun:05:00-sun:06:00"
}

variable "snapshot_retention_limit" {
  description = "Number of days for which ElastiCache retains automatic cache cluster snapshots"
  type        = number
  default     = 5
}

variable "snapshot_window" {
  description = "Daily time range for taking snapshots"
  type        = string
  default     = "03:00-04:00"
}

variable "allowed_cidr_blocks" {
  description = "List of CIDR blocks that are allowed to access the cluster"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "snapshot_name" {
  description = "Name of an ElastiCache snapshot to restore this cluster from. Create-only: changing it replaces the cluster. The restore may target a different shard count than the snapshot was taken at; ElastiCache redistributes slots."
  type        = string
  default     = null
}

variable "durability" {
  description = "ElastiCache Multi-AZ transactional log durability: default, async, sync or disabled. Create-only, and cannot be disabled once enabled. async or sync additionally require Valkey 9.0+, Multi-AZ, at least one replica, transit encryption, and a Graviton node family."
  type        = string
  default     = null

  validation {
    # coalesce, not a null guard, because Terraform does not reliably short-circuit || here.
    condition     = contains(["default", "async", "sync", "disabled"], coalesce(var.durability, "default"))
    error_message = "durability must be one of: default, async, sync, disabled."
  }
}
