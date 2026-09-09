# var.chalk_managed -- the chalk.ai/managed-by label, in both input modes.
#
# The label is a functional switch, not decoration. Chalk's control plane reads
# spec.template.metadata.labels["chalk.ai/managed-by"] off the NodePool and treats the pool as
# Chalk-manageable -- creatable, updatable and deletable from the dashboard -- only when it equals
# exactly "chalk". Chalk billing reads the same key to classify nodes as Chalk-managed. So these runs
# assert on that ONE key at that ONE path: not the NodePool's own metadata.labels, which is a
# different map the module still passes through untouched.
#
# The toggle OWNS the key. When it is true the label is forced over whatever the caller's `labels` or
# the manifest_yaml document says for that key, which is why the "conflict" runs below expect an
# overwrite rather than a merge in the caller's favour. When it is false the module writes nothing at
# that key and any pre-existing value survives.
#
# `mock_provider "kubectl" {}` configures no provider and makes no cluster calls, so this suite runs
# with no kubeconfig, no cluster and no AWS credentials.
#
# Assertions go through yamldecode(output.rendered_manifest), never the raw string: templatefile is
# whitespace-sensitive and yamlencode picks its own quoting and key order, so string equality would
# make the suite fail on cosmetic edits.
#
# The YAML-mode runs set name and ec2nodeclass_name to null explicitly rather than inheriting the
# file-level defaults, so the document's own metadata.name and nodeClassRef.name stand and the
# whole-object comparisons are not perturbed by an override this file is not about.
#
# file() resolves relative paths against the process working directory, so run `tofu test` from the
# module directory.

mock_provider "kubectl" {}

variables {
  name              = "example-pool"
  ec2nodeclass_name = "al2023"
}

# --------------------------------------------------------------------------------------------------
# Template mode: unset / true / false. Unset must behave as true -- the default is the whole point of
# the input, so "the default stamps" is asserted separately from "true stamps" and not inferred.
# --------------------------------------------------------------------------------------------------

run "template_default_stamps_the_label" {
  command = plan

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.labels == {
      "chalk.ai/managed-by" = "chalk"
    }
    error_message = "chalk_managed left unset no longer stamps chalk.ai/managed-by: chalk. The default is true, so a pool authored with no labels at all must still be Chalk-manageable."
  }
}

run "template_true_stamps_the_label" {
  command = plan

  variables {
    chalk_managed = true
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.labels == {
      "chalk.ai/managed-by" = "chalk"
    }
    error_message = "chalk_managed = true no longer stamps chalk.ai/managed-by: chalk into spec.template.metadata.labels"
  }
}

run "template_false_does_not_stamp" {
  command = plan

  variables {
    chalk_managed = false
  }

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.template.metadata)
    error_message = "chalk_managed = false still emits spec.template.metadata. With no labels of the caller's own and the toggle off, the module must write nothing there at all."
  }
}

# --------------------------------------------------------------------------------------------------
# Template mode, caller conflict: the caller sets the same key to something else. true must WIN --
# this mirrors Chalk's own AddChalkManagedLabelToLabels, which overwrites a non-chalk value rather
# than backing off, and a merge that let the caller's value stand would silently produce a pool the
# dashboard refuses to manage while the module reported success.
# --------------------------------------------------------------------------------------------------

run "template_true_forces_over_a_conflicting_caller_value" {
  command = plan

  variables {
    chalk_managed = true
    labels        = { "chalk.ai/managed-by" = "other" }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.metadata.labels["chalk.ai/managed-by"] == "chalk"
    error_message = "chalk_managed = true no longer overwrites a conflicting caller value for chalk.ai/managed-by. The toggle owns the key; a caller value that survived would leave the pool unmanageable from the dashboard."
  }
  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.metadata.labels) == 1
    error_message = "forcing the label over a conflicting caller value produced more than one label, so the key was duplicated rather than overwritten"
  }
}

run "template_false_leaves_a_conflicting_caller_value" {
  command = plan

  variables {
    chalk_managed = false
    labels        = { "chalk.ai/managed-by" = "other" }
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.labels == {
      "chalk.ai/managed-by" = "other"
    }
    error_message = "chalk_managed = false altered the caller's own value for chalk.ai/managed-by. Off means the module never touches that key, including when the caller deliberately sets it to something else."
  }
}

# --------------------------------------------------------------------------------------------------
# YAML mode, document carries no such label. This is the named exception to "everything else
# verbatim": the one key the module writes into a caller's finished document beyond the two names.
# --------------------------------------------------------------------------------------------------

run "yaml_true_stamps_a_document_without_the_label" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = null
    chalk_managed     = true
    manifest_yaml     = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-pool
      spec:
        template:
          spec:
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: document-class
    EOT
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.labels == {
      "chalk.ai/managed-by" = "chalk"
    }
    error_message = "chalk_managed = true no longer stamps the label into a YAML-mode document that lacks it, so the toggle is unreachable from YAML mode"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef.name == "document-class"
    error_message = "stamping the label into a document disturbed nodeClassRef, which sits under spec.template.spec and must be untouched by a metadata write"
  }
}

run "yaml_false_leaves_the_label_absent" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = null
    chalk_managed     = false
    manifest_yaml     = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-pool
      spec:
        template:
          spec:
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: document-class
    EOT
  }

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.template.metadata)
    error_message = "chalk_managed = false invented spec.template.metadata in a document that had none. Off must leave the document exactly as verbatim as it was before this input existed."
  }
}

# --------------------------------------------------------------------------------------------------
# YAML mode, document already carries chalk.ai/managed-by: chalk. This is the fleet's actual state --
# both captured fixtures look like this -- so BOTH settings must be no-ops on that key, and false
# must not be read as "remove it".
# --------------------------------------------------------------------------------------------------

run "yaml_true_keeps_an_already_stamped_document" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = null
    chalk_managed     = true
    manifest_yaml     = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-pool
      spec:
        template:
          metadata:
            labels:
              chalk.ai/managed-by: chalk
          spec:
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: document-class
    EOT
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.labels == {
      "chalk.ai/managed-by" = "chalk"
    }
    error_message = "chalk_managed = true against an already-stamped document is not idempotent"
  }
}

run "yaml_false_keeps_an_already_stamped_document" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = null
    chalk_managed     = false
    manifest_yaml     = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-pool
      spec:
        template:
          metadata:
            labels:
              chalk.ai/managed-by: chalk
          spec:
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: document-class
    EOT
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.labels == {
      "chalk.ai/managed-by" = "chalk"
    }
    error_message = "chalk_managed = false STRIPPED a label the document set itself. Off means the module does not write that key; it does not mean the module deletes it."
  }
}

# --------------------------------------------------------------------------------------------------
# YAML mode, document sets the key to a different value. The pair that shows the toggle really does
# own the key in YAML mode too, and that off really is hands-off rather than merely additive.
# --------------------------------------------------------------------------------------------------

run "yaml_true_overwrites_a_different_document_value" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = null
    chalk_managed     = true
    manifest_yaml     = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-pool
      spec:
        template:
          metadata:
            labels:
              chalk.ai/managed-by: other
          spec:
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: document-class
    EOT
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.labels == {
      "chalk.ai/managed-by" = "chalk"
    }
    error_message = "chalk_managed = true no longer overwrites a different value the document set for chalk.ai/managed-by"
  }
}

run "yaml_false_preserves_a_different_document_value" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = null
    chalk_managed     = false
    manifest_yaml     = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-pool
      spec:
        template:
          metadata:
            labels:
              chalk.ai/managed-by: other
          spec:
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: document-class
    EOT
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.labels == {
      "chalk.ai/managed-by" = "other"
    }
    error_message = "chalk_managed = false changed a value the document set for chalk.ai/managed-by. This is the opt-out a caller uses to keep a pool out of Chalk's hands, so it must be exact."
  }
}

# --------------------------------------------------------------------------------------------------
# Stamping writes ONE key. Everything else in the label map -- and everything else under
# spec.template.metadata, such as annotations -- must come through untouched.
# --------------------------------------------------------------------------------------------------

run "template_stamping_preserves_the_callers_other_labels" {
  command = plan

  variables {
    chalk_managed = true
    labels = {
      "chalk.ai/resource-group" = "default"
      "team"                    = "infra"
      "example.com/tier"        = "online"
    }
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.labels == {
      "chalk.ai/managed-by"     = "chalk"
      "chalk.ai/resource-group" = "default"
      "team"                    = "infra"
      "example.com/tier"        = "online"
    }
    error_message = "stamping the managed-by label disturbed the caller's other labels: the module must add exactly one key and leave the rest of the map alone"
  }
}

run "yaml_stamping_preserves_the_documents_other_labels" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = null
    chalk_managed     = true
    manifest_yaml     = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-pool
      spec:
        template:
          metadata:
            annotations:
              example.com/owner: platform
            labels:
              example.com/resource-group: default
              team: infra
          spec:
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: document-class
    EOT
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.labels == {
      "chalk.ai/managed-by"        = "chalk"
      "example.com/resource-group" = "default"
      "team"                       = "infra"
    }
    error_message = "stamping the managed-by label disturbed the document's other labels"
  }
  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.annotations == {
      "example.com/owner" = "platform"
    }
    error_message = "stamping a label dropped spec.template.metadata.annotations. The rebuild of that mapping must carry every sibling key, not just labels."
  }
}

# --------------------------------------------------------------------------------------------------
# The 100-entry cap. Karpenter counts spec.template.metadata.labels toward the SAME MaxItems=100 cap
# as spec.requirements, because labels propagate onto every NodeClaim as requirements. The stamped
# label is one of those 100 entries -- it is folded into the label set upstream of the count, so the
# arithmetic needs no special case -- and the consequence is that chalk_managed = true leaves the
# caller 99, not 100.
#
# Each pair straddles the moved boundary. The runs that measure the cap WITHOUT the stamp live in
# requirements.tftest.hcl, combinations.tftest.hcl and manifest_yaml.tftest.hcl, and opt out there.
# --------------------------------------------------------------------------------------------------

run "cap_ninety_nine_requirements_plus_the_stamp_accepted" {
  command = plan

  variables {
    chalk_managed = true
    requirements  = [for i in range(99) : { key = "k${i}", operator = "Exists" }]
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.spec.requirements) == 99
    error_message = "99 requirements plus the stamped label is exactly the combined cap of 100 and must be accepted"
  }
  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.labels == {
      "chalk.ai/managed-by" = "chalk"
    }
    error_message = "the run that proves the stamp fits in the hundredth slot must actually emit the stamp; without it this asserts nothing about the cap"
  }
}

run "cap_one_hundred_requirements_plus_the_stamp_rejected" {
  command = plan

  variables {
    chalk_managed = true
    requirements  = [for i in range(100) : { key = "k${i}", operator = "Exists" }]
  }

  # 100 requirements passes var.requirements' own MaxItems validation, so the only rule broken here
  # is the combined cap -- a precondition on the resource, which is what expect_failures names.
  expect_failures = [kubectl_manifest.this]
}

run "cap_sixty_requirements_plus_thirty_nine_labels_plus_the_stamp_accepted" {
  command = plan

  variables {
    chalk_managed = true
    requirements  = [for i in range(60) : { key = "k${i}", operator = "Exists" }]
    labels        = { for i in range(39) : "label-${i}" => "v" }
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.metadata.labels) == 40
    error_message = "39 caller labels plus the stamp must emit 40 labels; if it emits 39 the stamp was dropped and this no longer sits on the boundary"
  }
  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.spec.requirements) == 60
    error_message = "60 requirements alongside 39 labels and the stamp is exactly the combined cap and must be accepted"
  }
}

run "cap_sixty_requirements_plus_forty_labels_plus_the_stamp_rejected" {
  command = plan

  variables {
    chalk_managed = true
    requirements  = [for i in range(60) : { key = "k${i}", operator = "Exists" }]
    labels        = { for i in range(40) : "label-${i}" => "v" }
  }

  # 60 + 40 is the cap with the stamp off, and this is the same input with it on: one entry over.
  expect_failures = [kubectl_manifest.this]
}

run "yaml_cap_sixty_requirements_plus_thirty_nine_labels_plus_the_stamp_accepted" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = null
    chalk_managed     = true
    manifest_yaml = yamlencode({
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata   = { name = "document-pool" }
      spec = {
        template = {
          metadata = { labels = { for i in range(39) : "label-${i}" => "v" } }
          spec = {
            nodeClassRef = { group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = "document-class" }
            requirements = [for i in range(60) : { key = "k${i}", operator = "Exists" }]
          }
        }
      }
    })
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.metadata.labels) == 40
    error_message = "39 document labels plus the stamp must emit 40 labels in YAML mode too"
  }
  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.spec.requirements) == 60
    error_message = "60 document requirements alongside 39 document labels and the stamp is exactly the combined cap and must be accepted"
  }
}

run "yaml_cap_sixty_requirements_plus_forty_labels_plus_the_stamp_rejected" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = null
    chalk_managed     = true
    manifest_yaml = yamlencode({
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata   = { name = "document-pool" }
      spec = {
        template = {
          metadata = { labels = { for i in range(40) : "label-${i}" => "v" } }
          spec = {
            nodeClassRef = { group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = "document-class" }
            requirements = [for i in range(60) : { key = "k${i}", operator = "Exists" }]
          }
        }
      }
    })
  }

  # The cap counts the EMITTED label set, so the stamp must push this document over even though the
  # document itself is exactly at 100. A cap that counted only the document would wave this through.
  expect_failures = [kubectl_manifest.this]
}

# --------------------------------------------------------------------------------------------------
# The captured fixtures. Both were taken from live clusters and both already carry
# chalk.ai/managed-by: chalk, which is the evidence that the default is the fleet's real state rather
# than a new policy: the module now reproduces those objects with the label left OUT of the inputs.
#
# These runs are the reason the whole-object round-trips in fixtures.tftest.hcl and
# manifest_yaml.tftest.hcl still hold under the default with no edits -- and they will fail loudly if
# a future change to either fixture drops the label, which would otherwise make those round-trips
# start passing for the wrong reason.
# --------------------------------------------------------------------------------------------------

run "fixture_a_reproduces_with_the_label_left_to_the_default" {
  command = plan

  variables {
    name              = "default-al2023"
    ec2nodeclass_name = "al2023"

    # chalk.ai/managed-by is deliberately ABSENT: the default must put it back.
    labels = {
      "chalk.ai/resource-group" = "default"
    }

    requirements = [
      { key = "karpenter.k8s.aws/instance-family", operator = "In", values = ["c7a"] },
      { key = "karpenter.k8s.aws/instance-hypervisor", operator = "In", values = ["nitro"] },
      { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
      { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
    ]

    limits       = { cpu = "1k" }
    weight       = 12
    expire_after = "720h0m0s"

    disruption = {
      consolidationPolicy = "WhenEmptyOrUnderutilized"
      consolidateAfter    = "0s"
      budgets             = [{ nodes = "10%" }]
    }
  }

  assert {
    condition = yamldecode(output.rendered_manifest) == yamldecode(
      file("./tests/fixtures/nodepool-instance-family-pinned.yaml")
    )
    error_message = "with chalk.ai/managed-by omitted from labels, the default no longer reproduces the captured instance-family-pinned NodePool. Either the stamp stopped firing or the fixture no longer carries the label."
  }
}

run "fixture_b_reproduces_with_no_labels_at_all" {
  command = plan

  variables {
    name              = "chalk-nodepool-al2023"
    ec2nodeclass_name = "al2023"

    # Fixture B's ONLY label is chalk.ai/managed-by, so labels is left unset entirely here: the
    # captured object must be reproducible from the default alone.

    requirements = [
      { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
      { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
    ]

    taints = [
      { key = "chalk.ai/managed-by", value = "chalk", effect = "NoSchedule" },
    ]

    limits       = { cpu = "500", memory = "5000Gi" }
    weight       = 20
    expire_after = "720h0m0s"

    disruption = {
      consolidationPolicy = "WhenEmptyOrUnderutilized"
      consolidateAfter    = "0s"
      budgets             = [{ nodes = "10%" }]
    }
  }

  assert {
    condition = yamldecode(output.rendered_manifest) == yamldecode(
      file("./tests/fixtures/nodepool-taints-and-limits.yaml")
    )
    error_message = "with labels unset entirely, the default no longer reproduces the captured taints-and-limits NodePool, whose only label is chalk.ai/managed-by"
  }
}

run "fixture_a_round_trips_through_yaml_mode_under_the_default" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = null
    manifest_yaml     = file("./tests/fixtures/nodepool-instance-family-pinned.yaml")
  }

  assert {
    condition = yamldecode(output.rendered_manifest) == yamldecode(
      file("./tests/fixtures/nodepool-instance-family-pinned.yaml")
    )
    error_message = "a captured NodePool that already carries chalk.ai/managed-by: chalk no longer round-trips unchanged through YAML mode under the default, so the stamp is not idempotent against the fleet's real objects"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.metadata.labels["chalk.ai/managed-by"] == "chalk"
    error_message = "fixture A no longer carries chalk.ai/managed-by: chalk, which is what makes the round-trip above a no-op rather than a coincidence"
  }
}

run "fixture_b_round_trips_through_yaml_mode_under_the_default" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = null
    manifest_yaml     = file("./tests/fixtures/nodepool-taints-and-limits.yaml")
  }

  assert {
    condition = yamldecode(output.rendered_manifest) == yamldecode(
      file("./tests/fixtures/nodepool-taints-and-limits.yaml")
    )
    error_message = "fixture B no longer round-trips unchanged through YAML mode under the default"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.metadata.labels["chalk.ai/managed-by"] == "chalk"
    error_message = "fixture B no longer carries chalk.ai/managed-by: chalk, which is what makes the round-trip above a no-op rather than a coincidence"
  }
}

# nullable = false on chalk_managed: an explicit null must fall back to the default rather than
# reaching the conditional in main.tf, which fails with a raw "condition value is null".
run "chalk_managed_null_falls_back_to_the_default" {
  command = plan
  variables {
    chalk_managed = null
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.metadata.labels["chalk.ai/managed-by"] == "chalk"
    error_message = "chalk_managed = null did not fall back to the default"
  }
}
