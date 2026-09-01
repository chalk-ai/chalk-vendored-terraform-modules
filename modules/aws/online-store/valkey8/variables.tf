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
  default     = "8.0"
}

variable "parameter_group_name" {
  description = "Name of the parameter group to associate with this cluster"
  type        = string
  default     = "default.valkey8.cluster.on"
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