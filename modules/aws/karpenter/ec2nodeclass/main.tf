locals {
  # A variable default cannot reference path.module, so the bundled template is resolved here.
  manifest_path = coalesce(var.manifest_path, "${path.module}/templates/ec2nodeclass.yaml.tftpl")

  # karpenter.sh/discovery is the tag Karpenter's own selector terms key on, so a node class that
  # launches instances without it produces a fleet that the next node class cannot discover.
  # Caller tags are merged last and therefore win, which is the conventional Terraform idiom.
  instance_tags = merge(
    { "karpenter.sh/discovery" = var.cluster_name },
    var.tags,
  )

  # The manifest is rendered from a template file rather than yamlencode()d from an HCL map so that
  # the YAML stays the reviewable artefact and a caller with an exotic node class can substitute
  # their own file through var.manifest_path.
  rendered_manifest = templatefile(local.manifest_path, {
    name                  = var.name
    ami_alias             = var.ami_alias
    node_role_name        = var.node_role_name
    cluster_name          = var.cluster_name
    subnet_selector_terms = var.subnet_selector_terms
    boot_volume_size      = var.boot_volume_size
    instance_store_policy = var.instance_store_policy
    tags                  = local.instance_tags
  })
}

# One EC2NodeClass. Karpenter v1 accepts subnets only here and not on a NodePool, so callers who
# need different subnets per pool instantiate this module more than once.
#
# Provider arguments deliberately NOT set, having been checked against the pinned 2.x line rather
# than copied from Chalk's internal stack:
#
#   wait_for_rollout  Applies only to Deployment, DaemonSet, StatefulSet and APIService. A no-op for
#                     a custom resource, so setting it would only imply a guarantee that is absent.
#   sensitive_fields  Documented default on 2.x is ["data"], and only for Secrets. An EC2NodeClass
#                     carries no secret material, so the field needs no override.
resource "kubectl_manifest" "this" {
  yaml_body = local.rendered_manifest

  # Karpenter puts a finalizer on an EC2NodeClass and holds the delete until every NodeClaim that
  # references it has drained, which is bounded by the pools' terminationGracePeriod rather than by
  # anything this module controls. The provider's default delete timeout is far shorter than that.
  timeouts {
    delete = "45m"
  }
}
