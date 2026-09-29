output "secret_id" {
  description = "Short ID of the Secret Manager secret holding the connection URI. This is the value to paste into the Chalk dashboard under Integrations > Online Store > Redis."
  value       = google_secret_manager_secret.redis_uri.secret_id
}

output "secret_name" {
  description = "Fully qualified name of the connection-URI secret, in the form projects/<number>/secrets/<id>. Use this when granting roles/secretmanager.secretAccessor to Chalk's service account."
  value       = google_secret_manager_secret.redis_uri.name
}

output "instance_id" {
  description = "Instance ID of the Memorystore instance."
  value       = google_memorystore_instance.valkey.instance_id
}

output "endpoint_host" {
  description = "IP address of the instance's first Private Service Connect auto-created endpoint, or an empty string if none has been created yet."
  value       = local.endpoint_host
}

output "endpoint_port" {
  description = "Port of the instance's first Private Service Connect auto-created endpoint, or 0 if none has been created yet."
  value       = local.endpoint_port
}

output "shard_count" {
  description = "Number of shards on the instance."
  value       = google_memorystore_instance.valkey.shard_count
}

output "replica_count" {
  description = "Number of replica nodes per shard."
  value       = google_memorystore_instance.valkey.replica_count
}

output "node_type" {
  description = "Machine type of the individual nodes."
  value       = google_memorystore_instance.valkey.node_type
}

output "engine_version" {
  description = "Valkey engine version the instance is running."
  value       = google_memorystore_instance.valkey.engine_version
}

output "state" {
  description = "Current state of the instance as reported by the Memorystore API."
  value       = google_memorystore_instance.valkey.state
}

output "service_connection_policy_name" {
  description = "Name of the service connection policy this module created, or null when create_service_connection_policy is false and the policy is managed elsewhere."
  value       = one(google_network_connectivity_service_connection_policy.valkey[*].name)
}
