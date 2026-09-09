# --------------------------------------------------------------------------------------------------
# The seam between this module and the nodepool module.
# --------------------------------------------------------------------------------------------------

# This value MUST derive from the applied resource and never from var.name.
#
# Both forms render the identical string -- the provider exports `name` as "Extracted object name
# from yaml_body" -- but only this one puts an edge in the dependency graph. Read from var.name, a
# consuming NodePool depends on nothing, Terraform is free to create it first, and it fails against
# a node class that does not exist yet. The defect is invisible in the rendered YAML and shows up
# only as a race, so tests/baseline.tftest.hcl asserts the derivation directly.
output "name" {
  description = "`metadata.name` of the applied EC2NodeClass. Feed this to the nodepool module's `ec2nodeclass_name` input; the value carries the dependency that orders the pool after the class."
  value       = kubectl_manifest.this.name
}

output "node_class_ref" {
  description = "Drop-in value for a NodePool's `spec.template.spec.nodeClassRef`. `group` and `kind` became strictly required alongside `name` in Karpenter v1.1.0, so this exists to stop callers hand-writing the pair."
  value = {
    group = "karpenter.k8s.aws"
    kind  = "EC2NodeClass"
    name  = kubectl_manifest.this.name
  }
}

# --------------------------------------------------------------------------------------------------
# Identifiers and the rendered artefact
# --------------------------------------------------------------------------------------------------

output "uid" {
  description = "`metadata.uid` assigned by the API server. For debugging and for correlating a node class against events; it changes if the object is recreated."
  value       = kubectl_manifest.this.uid
}

output "id" {
  description = "Terraform resource ID of the applied manifest. Useful as an explicit `depends_on` target where a caller needs ordering without consuming a value."
  value       = kubectl_manifest.this.id
}

output "rendered_manifest" {
  description = "The EC2NodeClass YAML exactly as submitted to the cluster: the rendered template in template mode, or `yamlencode()` of the merged document in YAML mode. Exported so tests and reviewers can assert on the manifest without a cluster; parse it with `yamldecode` rather than matching the string, which is whitespace- and key-order-sensitive -- and doubly so in YAML mode, where re-encoding drops the caller's comments and key order."
  value       = local.rendered_manifest
}
