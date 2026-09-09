locals {
  # ------------------------------------------------------------------------------------------------
  # Mode
  #
  # `manifest_yaml` selects YAML mode. `manifest_path` selects a custom template. Both unset renders
  # the template bundled here. Both SET is an error, enforced as a precondition below because a
  # validation block may only reference its own variable.
  # ------------------------------------------------------------------------------------------------
  yaml_mode = var.manifest_yaml != null

  # A variable default cannot reference path.module, so the bundled template is resolved here.
  manifest_path = coalesce(var.manifest_path, "${path.module}/templates/ec2nodeclass.yaml.tftpl")

  # ------------------------------------------------------------------------------------------------
  # Template-mode defaults.
  #
  # These live here rather than on the variables because every optional input now defaults to null.
  # That is what makes "did the caller set this?" answerable, and answering it is what lets YAML mode
  # REJECT an input it cannot act on instead of silently dropping it. The values are exactly the ones
  # the variables used to carry, so template-mode output is byte-identical to before.
  #
  # Written as an explicit null conditional rather than coalesce(): coalesce() also skips the empty
  # string, so it would quietly substitute a default for a value the validations exist to reject.
  # ------------------------------------------------------------------------------------------------
  effective_name             = var.name == null ? "al2023" : var.name
  effective_ami_alias        = var.ami_alias == null ? "al2023@latest" : var.ami_alias
  effective_boot_volume_size = var.boot_volume_size == null ? "50Gi" : var.boot_volume_size

  # karpenter.sh/discovery is the tag Karpenter's own selector terms key on, so a node class that
  # launches instances without it produces a fleet that the next node class cannot discover.
  # Caller tags are merged last and therefore win, which is the conventional Terraform idiom.
  instance_tags = merge(
    { "karpenter.sh/discovery" = var.cluster_name },
    var.tags,
  )

  # Requiredness is now a precondition, and a precondition can only report if evaluating the
  # resource's arguments has not already thrown. `for term in null` inside the template would throw
  # first and put a templatefile stack trace on screen instead of this module's message, so the list
  # is made total here. In template mode with a null value the precondition fires immediately after.
  subnet_selector_terms_or_empty = var.subnet_selector_terms == null ? [] : var.subnet_selector_terms

  # ------------------------------------------------------------------------------------------------
  # Template mode.
  #
  # The manifest is rendered from a template file rather than yamlencode()d from an HCL map so that
  # the YAML stays the reviewable artefact and a caller with an exotic node class can substitute
  # their own file through var.manifest_path.
  # ------------------------------------------------------------------------------------------------
  templated_manifest = templatefile(local.manifest_path, {
    name                  = local.effective_name
    ami_alias             = local.effective_ami_alias
    node_role_name        = var.node_role_name
    cluster_name          = var.cluster_name
    subnet_selector_terms = local.subnet_selector_terms_or_empty
    boot_volume_size      = local.effective_boot_volume_size
    instance_store_policy = var.instance_store_policy
    tags                  = local.instance_tags
  })

  # ------------------------------------------------------------------------------------------------
  # YAML mode.
  #
  #   In YAML mode the module overrides only what cannot be portable between clusters. Everything
  #   else in the caller's document is emitted unchanged.
  #
  # Subnet IDs, security group discovery, the node role and the discovery tag are all cluster-bound;
  # amiSelectorTerms, blockDeviceMappings, metadataOptions, instanceStorePolicy and userData are not,
  # so the module never touches them.
  #
  # Each patch below is EMPTY when its input is null, and an empty patch merges to nothing. That is
  # what makes "the document's value survives" the default rather than a special case, and it is why
  # a patch is skipped entirely rather than emitted as an empty mapping -- writing `tags: {}` into a
  # document that carried no tags would not be emitting it unchanged.
  # ------------------------------------------------------------------------------------------------

  # try() and not `local.yaml_mode ? yamldecode(...) : {}`: a conditional requires its two result
  # expressions to unify, and a decoded EC2NodeClass has no common type with `{}`, so the conditional
  # form fails to evaluate in TEMPLATE mode -- where the document is irrelevant. try() needs no
  # unification, and yamldecode(null) throwing is exactly the template-mode case.
  #
  # try() also keeps this total. The shape rules on var.manifest_yaml have already rejected anything
  # that would throw here, but locals carry no documented ordering against validations, and a raw
  # parser error would replace this module's own message.
  document = try(yamldecode(var.manifest_yaml), {})

  # Terms are rebuilt rather than passed through. The input's object type carries BOTH optional
  # attributes on every element, so yamlencode()ing the variable verbatim would emit `tags: null`
  # beside every id and `id: null` beside every tag map.
  #
  # Built with merge() of two single-key patches rather than `t.id != null ? {id=...} : {tags=...}`:
  # a conditional requires its two result expressions to unify, and `{id = string}` and
  # `{tags = map(string)}` have no common type, so that form fails to even evaluate. Each conditional
  # here is instead `{}` against ONE attribute, which unifies cleanly.
  subnet_selector_terms_yaml = [
    for t in local.subnet_selector_terms_or_empty :
    merge(
      t.id == null ? {} : { id = t.id },
      t.tags == null ? {} : { tags = t.tags },
    )
  ]

  # Two terms, ORed: the Karpenter discovery tag and the tag the EKS control plane applies to the
  # cluster security group. Matching either is enough, which tolerates clusters carrying only one.
  security_group_selector_terms_yaml = [
    { tags = { "karpenter.sh/discovery" = var.cluster_name } },
    { tags = { "aws:eks:cluster-name" = var.cluster_name } },
  ]

  # The discovery tag plus caller tags. Empty when the caller supplied neither, in which case the
  # document's own tags are left exactly as written -- including absent.
  yaml_tag_override = merge(
    var.cluster_name == null ? {} : { "karpenter.sh/discovery" = var.cluster_name },
    var.tags,
  )

  yaml_metadata_patch = var.name == null ? {} : { name = var.name }

  yaml_spec_patch = merge(
    var.node_role_name == null ? {} : { role = var.node_role_name },
    # Replaced wholesale, not merged: subnet selection is a single decision and a half-overridden
    # term list would select subnets from two different clusters.
    var.subnet_selector_terms == null ? {} : { subnetSelectorTerms = local.subnet_selector_terms_yaml },
    var.cluster_name == null ? {} : { securityGroupSelectorTerms = local.security_group_selector_terms_yaml },
    length(local.yaml_tag_override) == 0 ? {} : { tags = merge(try(local.document.spec.tags, {}), local.yaml_tag_override) },
  )

  # merge() is shallow, so metadata and spec are merged a level down explicitly; merging only at the
  # top level would replace the whole of spec with the four keys this module knows about.
  merged = merge(
    local.document,
    length(local.yaml_metadata_patch) == 0 ? {} : { metadata = merge(try(local.document.metadata, {}), local.yaml_metadata_patch) },
    length(local.yaml_spec_patch) == 0 ? {} : { spec = merge(try(local.document.spec, {}), local.yaml_spec_patch) },
  )

  # yamlencode() re-serialises a parsed document, so comments and the caller's key order are lost.
  # That is inherent to merging into a decoded document rather than a defect, and it is the reason
  # template mode stays the default.
  rendered_manifest = local.yaml_mode ? yamlencode(local.merged) : local.templated_manifest
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

  # Every rule here is cross-variable, which is precisely why it is not a validation block: a
  # validation may only reference the variable it is attached to, and all of these depend on
  # var.manifest_yaml as well as on their own input.
  lifecycle {
    # ---------------------------------------------------------------------------------------------
    # Mode selection
    # ---------------------------------------------------------------------------------------------

    # This also covers "manifest_path set in YAML mode". It is deliberately ONE rule and not two:
    # `expect_failures` does not match on error_message, so two rules firing on one input would make
    # a failing run undiagnosable.
    precondition {
      condition     = var.manifest_yaml == null || var.manifest_path == null
      error_message = "manifest_yaml and manifest_path select different input modes and cannot both be set. manifest_yaml hands this module a finished EC2NodeClass document to merge into; manifest_path hands it a template to render. Pass one."
    }

    # ---------------------------------------------------------------------------------------------
    # Required in template mode.
    #
    # These were `variable` blocks with no default until YAML mode existed. Requiredness is
    # module-wide in Terraform and cannot be made conditional, so it lives here instead. The failure
    # is now this message at plan rather than Terraform's `No value for required variable`.
    # ---------------------------------------------------------------------------------------------

    precondition {
      condition     = var.manifest_yaml != null || var.subnet_selector_terms != null
      error_message = "subnet_selector_terms is required in template mode. Karpenter requires subnetSelectorTerms on every EC2NodeClass and this module cannot guess them; a wrong or absent selector produces nodes that never launch rather than a clear error. It becomes optional only in YAML mode, where the document supplies its own."
    }

    precondition {
      condition     = var.manifest_yaml != null || var.cluster_name != null
      error_message = "cluster_name is required in template mode. It keys both securityGroupSelectorTerms and the default karpenter.sh/discovery instance tag. It becomes optional only in YAML mode, where the document supplies its own."
    }

    precondition {
      condition     = var.manifest_yaml != null || var.node_role_name != null
      error_message = "node_role_name is required in template mode. It is Karpenter's spec.role, the IAM role name launched nodes assume. It becomes optional only in YAML mode, where the document supplies its own."
    }

    # ---------------------------------------------------------------------------------------------
    # Rejected in YAML mode.
    #
    # YAML mode emits these fields from the caller's document verbatim, so any value passed here
    # would be silently dropped. Rejecting is the whole point: a caller who sets boot_volume_size
    # alongside manifest_yaml has a wrong mental model, and a 50Gi root volume that quietly stayed
    # 200Gi is not something they would notice until the bill.
    #
    # One rule per input, so the message names the input. A caller who sets several therefore sees
    # several errors -- deliberate, and pinned by a test.
    # ---------------------------------------------------------------------------------------------

    precondition {
      condition     = var.manifest_yaml == null || var.ami_alias == null
      error_message = "ami_alias has no effect in YAML mode and is rejected rather than silently ignored. spec.amiSelectorTerms is emitted from your document verbatim; set the alias there."
    }

    precondition {
      condition     = var.manifest_yaml == null || var.boot_volume_size == null
      error_message = "boot_volume_size has no effect in YAML mode and is rejected rather than silently ignored. spec.blockDeviceMappings is emitted from your document verbatim; set the root volume size there."
    }

    precondition {
      condition     = var.manifest_yaml == null || var.instance_store_policy == null
      error_message = "instance_store_policy has no effect in YAML mode and is rejected rather than silently ignored. spec.instanceStorePolicy is emitted from your document verbatim; set it there."
    }
  }

  # Karpenter puts a finalizer on an EC2NodeClass and holds the delete until every NodeClaim that
  # references it has drained, which is bounded by the pools' terminationGracePeriod rather than by
  # anything this module controls. The provider's default delete timeout is far shorter than that.
  timeouts {
    delete = "45m"
  }
}
