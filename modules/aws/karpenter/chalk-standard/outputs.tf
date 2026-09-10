# These outputs are derived from locals, not from kubectl_manifest attributes.
# alekc/kubectl marks `yaml_body` sensitive at the schema level, so any output
# reading it back would itself have to be `sensitive = true` -- which would make
# the module's own object names unusable by a caller. Note that the provider's
# `sensitive_fields` argument does not change this: it controls redaction of
# `yaml_body_parsed`, not the sensitivity of `yaml_body`.

output "node_role_name" {
  description = "IAM role name assigned to launched nodes -- either var.node_role_name or the derived \"<cluster_name>-Managed-Node-Role\"."
  value       = local.node_role_name
}

output "ec2_node_class_names" {
  description = "Names of the EC2NodeClass objects this module creates."
  value       = concat(["al2023", "al2023-offline-lssd"], local.create_gvisor_nodeclass ? ["gvisor"] : [])
}

output "node_pool_names" {
  description = "Names of every NodePool this module creates. Contains chalk-nap only when chalk_dataplane_version is CHALK_DATAPLANE_VERSION_V2."
  value = sort(concat(
    ["oss-controllers", "chalk-compute-gpu"],
    keys(local.all_internal_node_pools),
    local.create_gvisor_nodeclass ? ["chalk-compute"] : [],
  ))
}

output "runtime_class_name" {
  description = "Name of the gVisor RuntimeClass, or null when the gVisor objects are not created."
  value       = local.create_gvisor_nodeclass ? "gvisor" : null
}

output "chalk_nap_enabled" {
  description = "Whether the dataplane-v2 chalk-nap fallback NodePool was created."
  value       = contains(keys(local.all_internal_node_pools), "chalk-nap")
}

output "subnet_selector_terms" {
  description = "The subnetSelectorTerms rendered into every EC2NodeClass, one term per element of var.subnets."
  value       = local.subnet_selector_terms
}

output "max_cpu" {
  description = "Aggregate vCPU limit applied to every Chalk NodePool. oss-controllers is the one pool that does not use it."
  value       = local.max_cpu
}

output "boot_volume_size" {
  description = "Boot volume size on the al2023 and gvisor node classes."
  value       = local.boot_volume_size
}

output "offline_boot_volume_size" {
  description = "Boot volume size on the al2023-offline-lssd node class. Local NVMe, not this volume, provides offline scratch space."
  value       = local.offline_boot_volume_size
}

output "cluster_name" {
  description = "Input echo of var.cluster_name, for callers wiring this module's identity into other resources."
  value       = var.cluster_name
}
