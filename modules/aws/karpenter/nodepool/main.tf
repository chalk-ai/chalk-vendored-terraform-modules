# Two input modes, one manifest.
#
#   manifest_yaml == null  -> TEMPLATE MODE. The manifest is rendered from a template file: the one
#                             bundled with this module, or var.manifest_path. Byte-identical to the
#                             module's original and only behaviour.
#   manifest_yaml != null  -> YAML MODE. The caller hands the module a finished NodePool document.
#                             The module overrides only what cannot be portable between clusters --
#                             metadata.name and spec.template.spec.nodeClassRef.name -- and emits
#                             everything else verbatim. Requirements, limits, taints, labels, weight
#                             and disruption all move between clusters unchanged, which is why the
#                             override set is this thin.
#
#                             ONE NAMED EXCEPTION to "everything else verbatim":
#                             spec.template.metadata.labels["chalk.ai/managed-by"], which
#                             var.chalk_managed writes when true. It is a functional switch read by
#                             Chalk's control plane, not a portable value, so it belongs to the
#                             cluster the pool lands in rather than to the document. Set
#                             chalk_managed = false and the module does not touch that key.
#
# Every optional input defaults to null, so "the caller set this" is exactly "non-null". That is what
# lets YAML mode REJECT an input it would otherwise silently ignore, and it is why the real
# template-mode defaults ([] and {}) are resolved here rather than in the variable blocks.

locals {
  yaml_mode = var.manifest_yaml != null

  # path.module cannot appear in a variable default, so the bundled template is resolved here.
  manifest_template = var.manifest_path == null ? "${path.module}/templates/nodepool.yaml.tftpl" : var.manifest_path

  # The Chalk-managed stamp, shared by both modes. Chalk's control plane gates create/update/delete
  # on spec.template.metadata.labels["chalk.ai/managed-by"] == "chalk", and Chalk billing reads the
  # same key, so this label is a functional switch rather than decoration.
  #
  # It is merged OVER the caller's labels and over the document's, so a pre-existing value for this
  # key is overwritten rather than preserved. That is deliberate and matches Chalk's own
  # AddChalkManagedLabelToLabels, which also overwrites a non-chalk value: the toggle owns the key.
  # An empty map when the toggle is off, which is what makes "off touches nothing" a merge no-op.
  chalk_managed_label = var.chalk_managed ? { "chalk.ai/managed-by" = "chalk" } : {}

  # Template-mode defaults. An empty collection is indistinguishable from "unset" at the variable
  # level, so requirements/limits/taints/labels default to null and the empty collection is restored
  # here, for template mode only.
  #
  # `labels` is the one entry that is not a plain null-to-empty restore: the stamp is folded in HERE,
  # upstream of cap_label_count below, so the 100-entry cap counts the emitted label set rather than
  # the caller's and needs no special case for the stamp. A consequence worth stating plainly: with
  # chalk_managed on, a caller with no labels of their own still renders spec.template.metadata.
  template_vars = {
    name                     = var.name == null ? "" : var.name
    ec2nodeclass_name        = var.ec2nodeclass_name == null ? "" : var.ec2nodeclass_name
    requirements             = var.requirements == null ? [] : var.requirements
    limits                   = var.limits == null ? {} : var.limits
    taints                   = var.taints == null ? [] : var.taints
    labels                   = merge(var.labels == null ? {} : var.labels, local.chalk_managed_label)
    weight                   = var.weight
    disruption               = var.disruption
    expire_after             = var.expire_after
    termination_grace_period = var.termination_grace_period
  }

  # ------------------------------------------------------------------------------------------------
  # YAML mode: decode, override two paths, re-encode.
  # ------------------------------------------------------------------------------------------------

  # Shape is enforced by the validation blocks on var.manifest_yaml; try() here only keeps this
  # expression total, so a rejected document produces the variable's message rather than a crash
  # somewhere further down.
  decoded = var.manifest_yaml == null ? null : try(yamldecode(var.manifest_yaml), null)

  # Each level of the path the overrides touch, read back as a mapping or as {} when it is absent.
  # merge({}, x) is the total "is x a mapping" test: it errors for a scalar or a sequence and try()
  # turns that into {}, so a pathological document cannot crash the rebuild.
  doc_metadata          = try(merge({}, local.decoded.metadata), {})
  doc_spec              = try(merge({}, local.decoded.spec), {})
  doc_template          = try(merge({}, local.decoded.spec.template), {})
  doc_template_metadata = try(merge({}, local.decoded.spec.template.metadata), {})
  doc_template_labels   = try(merge({}, local.decoded.spec.template.metadata.labels), {})
  doc_template_spec     = try(merge({}, local.decoded.spec.template.spec), {})
  doc_node_class_ref    = try(merge({}, local.decoded.spec.template.spec.nodeClassRef), {})

  # The override set. Each override applies only when its input is non-null: a null input means
  # "inherit whatever the document says". The `length(...) == 0 ? {}` guards keep the rebuild from
  # inventing an empty parent -- a document with no spec.template gains one only if an override
  # actually needs to live there.
  yaml_metadata = merge(
    local.doc_metadata,
    var.name == null ? {} : { name = var.name },
  )

  yaml_node_class_ref = merge(
    local.doc_node_class_ref,
    var.ec2nodeclass_name == null ? {} : { name = var.ec2nodeclass_name },
  )

  yaml_template_spec = merge(
    local.doc_template_spec,
    length(local.yaml_node_class_ref) == 0 ? {} : { nodeClassRef = local.yaml_node_class_ref },
  )

  # The stamp over the document's own labels. Only the one key is touched: every other label, and
  # every other key under spec.template.metadata such as annotations, comes through doc_* untouched.
  yaml_template_labels   = merge(local.doc_template_labels, local.chalk_managed_label)
  yaml_template_metadata = merge(local.doc_template_metadata, { labels = local.yaml_template_labels })

  # `var.chalk_managed ? ... : {}` rather than the length() guard the other overrides use, so that
  # chalk_managed = false does not rebuild this subtree AT ALL -- doc_template already carries the
  # document's metadata through, so "off never touches that key" is structural here rather than a
  # merge that happens to be an identity. When it is on the rebuilt metadata always holds at least
  # the stamp, so it needs no emptiness guard.
  yaml_template = merge(
    local.doc_template,
    var.chalk_managed ? { metadata = local.yaml_template_metadata } : {},
    length(local.yaml_template_spec) == 0 ? {} : { spec = local.yaml_template_spec },
  )

  yaml_spec = merge(
    local.doc_spec,
    length(local.yaml_template) == 0 ? {} : { template = local.yaml_template },
  )

  merged = merge(
    try(merge({}, local.decoded), {}),
    length(local.yaml_metadata) == 0 ? {} : { metadata = local.yaml_metadata },
    length(local.yaml_spec) == 0 ? {} : { spec = local.yaml_spec },
  )

  # ------------------------------------------------------------------------------------------------
  # The manifest
  # ------------------------------------------------------------------------------------------------

  # The conditional short-circuits, so templatefile() is not called in YAML mode and yamlencode() is
  # not called in template mode. template_vars is null-safe regardless, so neither branch can error
  # on the other mode's inputs.
  #
  # yamlencode round-trips through a decode, so comments and key order in the caller's document are
  # lost. That is inherent to any merge-then-emit path and is the reason template mode stays the
  # default: it is the reviewable-artefact path.
  rendered_manifest = local.yaml_mode ? yamlencode(local.merged) : templatefile(local.manifest_template, local.template_vars)

  # ------------------------------------------------------------------------------------------------
  # Cross-input rules, evaluated as preconditions on the resource below
  # ------------------------------------------------------------------------------------------------

  # Inputs YAML mode would ignore. Rejected rather than silently dropped: with every optional input
  # defaulting to null, "set in YAML mode" is simply "non-null". manifest_path is absent from this
  # list on purpose -- it is a mode selector, not a value, and gets its own precondition. So is
  # chalk_managed, for the opposite reason: YAML mode does NOT ignore it. It is the one input that
  # takes effect in both modes, so rejecting it here would make the label unreachable from YAML mode.
  yaml_mode_ignored_inputs = local.yaml_mode ? compact([
    var.requirements != null ? "requirements" : "",
    var.limits != null ? "limits" : "",
    var.taints != null ? "taints" : "",
    var.labels != null ? "labels" : "",
    var.weight != null ? "weight" : "",
    var.disruption != null ? "disruption" : "",
    var.expire_after != null ? "expire_after" : "",
    var.termination_grace_period != null ? "termination_grace_period" : "",
  ]) : []

  # The node class the pool actually references, whichever mode produced it. In YAML mode the caller
  # may omit ec2nodeclass_name entirely and let the document's own nodeClassRef.name stand; the
  # lookup then reads that name. try() around coalesce() because coalesce errors when every argument
  # is null, and "neither yields a name" is a case this module reports itself.
  nodeclass_lookup_name = try(
    coalesce(var.ec2nodeclass_name, try(local.decoded.spec.template.spec.nodeClassRef.name, null)),
    null,
  )

  # The requirements-plus-labels cap counts what is actually emitted. In YAML mode that is the
  # document's own requirements and labels -- neither is an override, so they survive to the merged
  # manifest untouched -- not the (null) variables.
  #
  # Both counts read the EMITTED label set, which is why neither expression mentions the stamp: it is
  # folded into template_vars.labels and into merged in both branches above, so it is already inside
  # cap_label_count and the arithmetic below stays correct without a special case.
  cap_requirement_count = local.yaml_mode ? try(length(local.merged.spec.template.spec.requirements), 0) : length(local.template_vars.requirements)
  cap_label_count       = local.yaml_mode ? try(length(local.merged.spec.template.metadata.labels), 0) : length(local.template_vars.labels)
}

# Opt-in fail-fast when the referenced EC2NodeClass is absent. Defaults OFF, and only works when the
# node class ALREADY EXISTS.
#
# An earlier version of this comment claimed that passing the ec2nodeclass module's `name` output
# defers the read to apply, because the block then depends on a resource changing in the plan. That
# is WRONG, and a real plan disproved it (2026-09-09, e2e harness):
#
#   module.pool_template.data.kubectl_manifest.ec2nodeclass[0]: Reading...
#   Error: manifest not found: karpenter.k8s.aws/v1/EC2NodeClass /e2e-inf2110-nc-tpl
#
# kubectl_manifest exports `name` extracted from `yaml_body`, and yaml_body is a templatefile() of
# static inputs, so the provider computes it during PLAN -- the plan shows a concrete string while
# id/uid/namespace show "known after apply". With every argument known, Terraform reads the data
# source eagerly. Graph adjacency alone does not defer a data read; unknown values do. The 2.x
# kubectl data source also has no wait_for to absorb the gap.
#
# Hence the default is false: the canonical two-module example creates the class in the same run,
# and a default of true would break it on first plan.
#
# The count also drops to zero when no name could be resolved at all, so that the unresolvable case
# surfaces as this module's own precondition message instead of a missing-required-argument error.
data "kubectl_manifest" "ec2nodeclass" {
  count = var.lookup_ec2nodeclass && local.nodeclass_lookup_name != null ? 1 : 0

  api_version = "karpenter.k8s.aws/v1"
  kind        = "EC2NodeClass"
  name        = local.nodeclass_lookup_name
}

resource "kubectl_manifest" "this" {
  yaml_body = local.rendered_manifest

  # wait_for_rollout defaults to true but applies only to Deployment, DaemonSet, StatefulSet and
  # APIService, so it is a no-op for this CRD. Pinned false so the default does not imply otherwise.
  wait_for_rollout = false

  lifecycle {
    # Requiredness is per-MODE, and a Terraform variable is required or optional module-wide, so
    # this cannot live in a `validation` block: name and ec2nodeclass_name default to null and are
    # required here instead. Behaviour is preserved and the error surface changes -- omitting `name`
    # in template mode now fails at plan with this message rather than with Terraform's own
    # "No value for required variable". Shape checks stay as `validation` blocks on the variables.
    precondition {
      condition     = var.manifest_yaml != null || var.name != null
      error_message = "name is required in template mode. Set name, or hand the module a finished document with manifest_yaml, which carries its own metadata.name."
    }

    precondition {
      condition     = var.manifest_yaml != null || var.ec2nodeclass_name != null
      error_message = "ec2nodeclass_name is required in template mode. Set ec2nodeclass_name, or hand the module a finished document with manifest_yaml, which carries its own spec.template.spec.nodeClassRef.name."
    }

    # Mode selection. manifest_yaml supplies a finished document; manifest_path supplies a template
    # to render. They are two different modes, so setting both is a mistake rather than a merge.
    precondition {
      condition     = var.manifest_yaml == null || var.manifest_path == null
      error_message = "manifest_yaml and manifest_path select different input modes and are mutually exclusive: manifest_yaml is a finished NodePool document, manifest_path is a template to render. Set exactly one, or neither to use the bundled template."
    }

    # An input YAML mode would ignore is an input the caller believes is taking effect.
    precondition {
      condition     = length(local.yaml_mode_ignored_inputs) == 0
      error_message = "In YAML mode the caller's document is authoritative for everything except metadata.name and spec.template.spec.nodeClassRef.name, so these inputs would have no effect and are rejected rather than silently dropped: ${join(", ", local.yaml_mode_ignored_inputs)}. Put these values in the manifest_yaml document itself, or drop manifest_yaml and use template mode."
    }

    precondition {
      condition     = !var.lookup_ec2nodeclass || local.nodeclass_lookup_name != null
      error_message = "lookup_ec2nodeclass is true but no EC2NodeClass name could be resolved: ec2nodeclass_name is null and the manifest_yaml document sets no spec.template.spec.nodeClassRef.name. Set ec2nodeclass_name, add nodeClassRef.name to the document, or set lookup_ec2nodeclass = false."
    }

    # Cross-variable rule, so it cannot live in a `validation` block: labels propagate onto every
    # NodeClaim as requirements and count toward the same MaxItems=100 cap as spec.requirements.
    precondition {
      condition     = local.cap_requirement_count + local.cap_label_count <= 100
      error_message = "requirements and labels together may define at most 100 entries: labels propagate as NodeClaim requirements and count toward the same cap. Got ${local.cap_requirement_count} requirements and ${local.cap_label_count} labels.${var.chalk_managed ? " That label count INCLUDES the chalk.ai/managed-by entry chalk_managed stamps, so the budget left to the caller is 99, not 100. Drop one entry, or set chalk_managed = false to give the slot back and opt the pool out of Chalk dashboard management." : ""}"
    }
  }
}
