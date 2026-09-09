# `name` must derive from the applied resource, not from var.name. Both render the identical string,
# but only this form creates a graph edge, so a consumer of this output is ordered after the NodePool
# exists. The provider documents `name` as "Extracted object name from yaml_body".
output "name" {
  description = "metadata.name of the applied NodePool, read back off the resource so that consumers of this output are ordered after it exists."
  value       = kubectl_manifest.this.name
}

output "uid" {
  description = "metadata.uid of the applied NodePool. For debugging and for explicit depends_on."
  value       = kubectl_manifest.this.uid
}

output "id" {
  description = "Terraform resource ID of the applied NodePool. For debugging and for explicit depends_on."
  value       = kubectl_manifest.this.id
}

output "rendered_manifest" {
  description = "The templated NodePool YAML exactly as it is submitted. Known at plan time, so tests and reviewers can assert on it without applying."
  value       = local.rendered_manifest
}
