locals {
  # path.module cannot appear in a variable default, so the bundled template is resolved here.
  manifest_template = var.manifest_path == null ? "${path.module}/templates/nodepool.yaml.tftpl" : var.manifest_path

  # The manifest is rendered from a template file rather than yamlencode so that it stays a
  # reviewable artefact and a caller with an exotic pool can substitute their own via manifest_path.
  rendered_manifest = templatefile(local.manifest_template, {
    name                     = var.name
    ec2nodeclass_name        = var.ec2nodeclass_name
    requirements             = var.requirements
    limits                   = var.limits
    taints                   = var.taints
    labels                   = var.labels
    weight                   = var.weight
    disruption               = var.disruption
    expire_after             = var.expire_after
    termination_grace_period = var.termination_grace_period
  })
}

# Fail fast when the referenced EC2NodeClass is absent. The 2.x data source has no wait_for: if the
# node class is created elsewhere in the same root module it will not exist when this reads, which is
# what lookup_ec2nodeclass = false is for. When ec2nodeclass_name comes from the node class module's
# `name` output the read is deferred to apply, because the block then depends on a resource that is
# changing in the current plan -- and in that case the dependency edge already guarantees ordering.
data "kubectl_manifest" "ec2nodeclass" {
  count = var.lookup_ec2nodeclass ? 1 : 0

  api_version = "karpenter.k8s.aws/v1"
  kind        = "EC2NodeClass"
  name        = var.ec2nodeclass_name
}

resource "kubectl_manifest" "this" {
  yaml_body = local.rendered_manifest

  # wait_for_rollout defaults to true but applies only to Deployment, DaemonSet, StatefulSet and
  # APIService, so it is a no-op for this CRD. Pinned false so the default does not imply otherwise.
  wait_for_rollout = false

  lifecycle {
    # Cross-variable rule, so it cannot live in a `validation` block: labels propagate onto every
    # NodeClaim as requirements and count toward the same MaxItems=100 cap as spec.requirements.
    precondition {
      condition     = length(var.requirements) + length(var.labels) <= 100
      error_message = "requirements and labels together may define at most 100 entries: labels propagate as NodeClaim requirements and count toward the same cap. Got ${length(var.requirements)} requirements and ${length(var.labels)} labels."
    }
  }
}
