# YAML mode: manifest_yaml, the two overrides it honours, and everything it refuses to touch.
#
# This suite deliberately sets NO file-level defaults for name and ec2nodeclass_name. Half of it is
# about those inputs being null -- inheritance from the document, and the template-mode requiredness
# precondition -- so a file-level default would silently defeat those runs.
#
# `mock_provider "kubectl" {}` configures no provider and makes no cluster calls, so this suite runs
# with no kubeconfig, no cluster and no AWS credentials.
#
# Assertions go through yamldecode(output.rendered_manifest), never the raw string: yamlencode picks
# its own quoting and key order, and string equality would make the suite fail on cosmetic changes.
#
# Two objects can report a failure here. Structural rules about the document itself are `validation`
# blocks on var.manifest_yaml. Rules that span inputs -- mode selection, per-mode requiredness, the
# ignored-input rejection, the node class lookup and the 100-entry cap -- are `precondition`s on
# kubectl_manifest.this, so those runs name the resource.

mock_provider "kubectl" {}

# --------------------------------------------------------------------------------------------------
# Mode selection: neither / manifest_path / manifest_yaml / both
# --------------------------------------------------------------------------------------------------

run "mode_neither_set_uses_the_bundled_template" {
  command = plan

  variables {
    name              = "example-pool"
    ec2nodeclass_name = "al2023"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "example-pool"
    error_message = "with neither manifest_yaml nor manifest_path set the module no longer renders the bundled template"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.requirements == []
    error_message = "template mode no longer emits the empty requirements list, so requirements defaulting to null did not resolve back to [] for the template"
  }
}

run "mode_manifest_path_only_renders_that_template" {
  command = plan

  variables {
    name              = "example-pool"
    ec2nodeclass_name = "al2023"
    manifest_path     = "./templates/nodepool.yaml.tftpl"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).kind == "NodePool"
    error_message = "manifest_path on its own no longer selects template mode"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "example-pool"
    error_message = "a template supplied by manifest_path no longer receives the module's variables"
  }
}

run "mode_manifest_yaml_only_emits_the_document" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
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
    condition     = yamldecode(output.rendered_manifest).metadata.name == "document-pool"
    error_message = "manifest_yaml on its own no longer selects YAML mode"
  }
  assert {
    condition     = kubectl_manifest.this.yaml_body == output.rendered_manifest
    error_message = "in YAML mode the resource no longer submits the manifest exposed by the rendered_manifest output"
  }
}

run "mode_both_manifest_yaml_and_manifest_path_rejected" {
  command = plan

  variables {
    manifest_path = "./templates/nodepool.yaml.tftpl"
    manifest_yaml = <<-EOT
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

  expect_failures = [kubectl_manifest.this]
}

# --------------------------------------------------------------------------------------------------
# Decode: the document must be parseable YAML and must be a mapping
# --------------------------------------------------------------------------------------------------

run "decode_valid_mapping_accepted" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
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
    condition     = yamldecode(output.rendered_manifest).kind == "NodePool"
    error_message = "a well-formed NodePool mapping is no longer accepted"
  }
}

run "decode_unparseable_rejected" {
  command = plan

  variables {
    manifest_yaml = "spec: [unclosed"
  }

  expect_failures = [var.manifest_yaml]
}

run "decode_scalar_rejected" {
  command = plan

  variables {
    manifest_yaml = "just-a-scalar"
  }

  expect_failures = [var.manifest_yaml]
}

run "decode_sequence_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
      - apiVersion: karpenter.sh/v1
        kind: NodePool
    EOT
  }

  expect_failures = [var.manifest_yaml]
}

run "decode_empty_string_rejected" {
  command = plan

  variables {
    manifest_yaml = ""
  }

  expect_failures = [var.manifest_yaml]
}

# --------------------------------------------------------------------------------------------------
# kind and apiVersion. One violation per run: each document below breaks exactly one of these rules
# and is otherwise well-formed, so a run that starts passing for a different reason still fails.
# --------------------------------------------------------------------------------------------------

run "kind_nodepool_accepted" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
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
    condition     = yamldecode(output.rendered_manifest).apiVersion == "karpenter.sh/v1"
    error_message = "a karpenter.sh/v1 NodePool is no longer accepted in YAML mode"
  }
}

run "kind_wrong_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
      apiVersion: karpenter.k8s.aws/v1
      kind: EC2NodeClass
      metadata:
        name: al2023
      spec:
        role: example-cluster-Managed-Node-Role
    EOT
  }

  expect_failures = [var.manifest_yaml]
}

run "kind_missing_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
      apiVersion: karpenter.sh/v1
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

  expect_failures = [var.manifest_yaml]
}

run "api_version_v1beta1_group_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
      apiVersion: karpenter.sh/v1beta1
      kind: NodePool
      metadata:
        name: document-pool
      spec:
        template:
          spec:
            nodeClassRef:
              apiVersion: karpenter.k8s.aws/v1beta1
              kind: EC2NodeClass
              name: document-class
    EOT
  }

  expect_failures = [var.manifest_yaml]
}

run "api_version_missing_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
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

  expect_failures = [var.manifest_yaml]
}

run "spec_missing_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-pool
    EOT
  }

  expect_failures = [var.manifest_yaml]
}

# --------------------------------------------------------------------------------------------------
# The override set: metadata.name and spec.template.spec.nodeClassRef.name, and nothing else. Each
# override is exercised on its own, with the other input null, so neither can be carrying the other.
# --------------------------------------------------------------------------------------------------

run "override_metadata_name_only" {
  command = plan

  variables {
    name              = "override-pool"
    ec2nodeclass_name = null
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
    condition     = yamldecode(output.rendered_manifest).metadata.name == "override-pool"
    error_message = "var.name no longer overrides metadata.name in YAML mode"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef.name == "document-class"
    error_message = "overriding metadata.name also changed nodeClassRef.name, which the caller left to the document"
  }
}

run "override_node_class_ref_name_only" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = "override-class"
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
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef.name == "override-class"
    error_message = "var.ec2nodeclass_name no longer overrides nodeClassRef.name in YAML mode"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "document-pool"
    error_message = "overriding nodeClassRef.name also changed metadata.name, which the caller left to the document"
  }
  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef == {
      group = "karpenter.k8s.aws"
      kind  = "EC2NodeClass"
      name  = "override-class"
    }
    error_message = "retargeting nodeClassRef.name disturbed the group or kind beside it"
  }
}

run "override_both_applied" {
  command = plan

  variables {
    name              = "override-pool"
    ec2nodeclass_name = "override-class"
    manifest_yaml     = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        labels:
          example.com/team: platform
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
    condition     = yamldecode(output.rendered_manifest).metadata.name == "override-pool"
    error_message = "metadata.name is no longer overridden when both overrides are set"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef.name == "override-class"
    error_message = "nodeClassRef.name is no longer overridden when both overrides are set"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.labels == { "example.com/team" = "platform" }
    error_message = "overriding metadata.name dropped the rest of the document's metadata"
  }
}

# --------------------------------------------------------------------------------------------------
# Inheritance: a null override input means "whatever the document says", never "".
# --------------------------------------------------------------------------------------------------

run "inheritance_null_name_keeps_the_documents_name" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = "override-class"
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
    condition     = yamldecode(output.rendered_manifest).metadata.name == "document-pool"
    error_message = "a null name no longer inherits the document's metadata.name"
  }
}

run "inheritance_null_ec2nodeclass_name_keeps_the_documents_reference" {
  command = plan

  variables {
    name              = "override-pool"
    ec2nodeclass_name = null
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
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef.name == "document-class"
    error_message = "a null ec2nodeclass_name no longer inherits the document's nodeClassRef.name"
  }
}

run "inheritance_both_null_emits_the_document_unchanged" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = null
    manifest_yaml     = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-pool
      spec:
        limits:
          cpu: "500"
        template:
          metadata:
            labels:
              example.com/managed-by: terraform
          spec:
            expireAfter: 720h
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: document-class
            requirements:
              - key: kubernetes.io/arch
                operator: In
                values:
                  - amd64
        weight: 12
    EOT
  }

  assert {
    condition = yamldecode(output.rendered_manifest) == yamldecode(<<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-pool
      spec:
        limits:
          cpu: "500"
        template:
          metadata:
            labels:
              example.com/managed-by: terraform
          spec:
            expireAfter: 720h
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: document-class
            requirements:
              - key: kubernetes.io/arch
                operator: In
                values:
                  - amd64
        weight: 12
    EOT
    )
    error_message = "with both overrides null the document no longer round-trips unchanged"
  }
}

# --------------------------------------------------------------------------------------------------
# Passthrough: every field this module does NOT own survives decode/merge/re-encode untouched. These
# are the fields that are portable between clusters, which is why the override set excludes them.
# --------------------------------------------------------------------------------------------------

run "passthrough_every_unowned_field_survives_the_round_trip" {
  command = plan

  variables {
    ec2nodeclass_name = "override-class"
    manifest_yaml     = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-pool
      spec:
        disruption:
          budgets:
            - nodes: 10%
              schedule: 0 9 * * mon-fri
              duration: 8h
              reasons:
                - Underutilized
          consolidateAfter: 0s
          consolidationPolicy: WhenEmptyOrUnderutilized
        limits:
          cpu: 1k
          memory: 5000Gi
        template:
          metadata:
            labels:
              example.com/managed-by: terraform
              example.com/resource-group: default
          spec:
            expireAfter: 720h0m0s
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: document-class
            requirements:
              - key: karpenter.k8s.aws/instance-family
                operator: In
                values:
                  - c7a
              - key: karpenter.sh/capacity-type
                operator: In
                values:
                  - on-demand
            taints:
              - effect: NoSchedule
                key: example.com/managed-by
                value: terraform
            terminationGracePeriod: 1h
        weight: 12
    EOT
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.spec.requirements == [
      { key = "karpenter.k8s.aws/instance-family", operator = "In", values = ["c7a"] },
      { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
    ]
    error_message = "requirements did not survive the YAML-mode round trip unchanged"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.limits == { cpu = "1k", memory = "5000Gi" }
    error_message = "limits did not survive the YAML-mode round trip unchanged -- note that 1k must stay the string \"1k\""
  }
  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.spec.taints == [
      { effect = "NoSchedule", key = "example.com/managed-by", value = "terraform" },
    ]
    error_message = "taints did not survive the YAML-mode round trip unchanged"
  }
  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.labels == {
      "example.com/managed-by"     = "terraform"
      "example.com/resource-group" = "default"
    }
    error_message = "labels did not survive the YAML-mode round trip unchanged"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.weight == 12
    error_message = "weight did not survive the YAML-mode round trip unchanged, or stopped being a number"
  }
  assert {
    condition = yamldecode(output.rendered_manifest).spec.disruption == {
      consolidationPolicy = "WhenEmptyOrUnderutilized"
      consolidateAfter    = "0s"
      budgets = [
        { nodes = "10%", schedule = "0 9 * * mon-fri", duration = "8h", reasons = ["Underutilized"] },
      ]
    }
    error_message = "disruption did not survive the YAML-mode round trip unchanged"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.expireAfter == "720h0m0s"
    error_message = "expireAfter did not survive the YAML-mode round trip unchanged"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.terminationGracePeriod == "1h"
    error_message = "terminationGracePeriod did not survive the YAML-mode round trip unchanged"
  }
}

# --------------------------------------------------------------------------------------------------
# Inputs YAML mode would ignore are rejected, not silently dropped. One run per input, then several
# at once, then a mixed run pairing a valid override with an ignored input -- the ignored one last.
# --------------------------------------------------------------------------------------------------

run "ignored_requirements_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
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
    requirements  = [{ key = "kubernetes.io/arch", operator = "In", values = ["amd64"] }]
  }

  expect_failures = [kubectl_manifest.this]
}

run "ignored_limits_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
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
    limits        = { cpu = "500" }
  }

  expect_failures = [kubectl_manifest.this]
}

run "ignored_taints_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
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
    taints        = [{ key = "example.com/managed-by", value = "terraform", effect = "NoSchedule" }]
  }

  expect_failures = [kubectl_manifest.this]
}

run "ignored_labels_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
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
    labels        = { "example.com/managed-by" = "terraform" }
  }

  expect_failures = [kubectl_manifest.this]
}

run "ignored_weight_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
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
    weight        = 12
  }

  expect_failures = [kubectl_manifest.this]
}

run "ignored_disruption_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
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
    disruption    = { consolidationPolicy = "WhenEmpty" }
  }

  expect_failures = [kubectl_manifest.this]
}

run "ignored_expire_after_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
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
    expire_after  = "720h"
  }

  expect_failures = [kubectl_manifest.this]
}

run "ignored_termination_grace_period_rejected" {
  command = plan

  variables {
    manifest_yaml            = <<-EOT
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
    termination_grace_period = "1h"
  }

  expect_failures = [kubectl_manifest.this]
}

# manifest_path is the ninth template-only input. It is rejected by the mode-selection precondition
# rather than the ignored-input list, because it selects a mode instead of carrying a value -- the
# same rule as mode_both_manifest_yaml_and_manifest_path_rejected above, reached from the other side.
run "ignored_manifest_path_rejected" {
  command = plan

  variables {
    manifest_path = "./templates/nodepool.yaml.tftpl"
    manifest_yaml = <<-EOT
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

  expect_failures = [kubectl_manifest.this]
}

run "ignored_several_at_once_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
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
    requirements  = [{ key = "kubernetes.io/arch", operator = "In", values = ["amd64"] }]
    weight        = 12
    expire_after  = "720h"
  }

  expect_failures = [kubectl_manifest.this]
}

# Mixed: a legitimate override alongside an ignored input, the ignored one last. A check written as
# "no input other than manifest_yaml is set" would reject this run for the wrong reason; only a check
# that distinguishes the override set from the ignored set gets both this and the run above right.
run "ignored_mixed_valid_override_plus_ignored_input_rejected" {
  command = plan

  variables {
    name              = "override-pool"
    ec2nodeclass_name = "override-class"
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
    labels            = { "example.com/managed-by" = "terraform" }
  }

  expect_failures = [kubectl_manifest.this]
}

run "override_inputs_alone_are_not_treated_as_ignored" {
  command = plan

  variables {
    name              = "override-pool"
    ec2nodeclass_name = "override-class"
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
    condition     = yamldecode(output.rendered_manifest).metadata.name == "override-pool"
    error_message = "the two override inputs are being rejected as ignored inputs, which would leave YAML mode unable to retarget anything"
  }
}

# --------------------------------------------------------------------------------------------------
# Template mode still requires name and ec2nodeclass_name. The rule moved from Terraform's own
# "No value for required variable" to a precondition, so these runs name the resource, not the
# variable. lookup_ec2nodeclass is switched off in the second run so that exactly one precondition
# fires: with it on, the unresolvable-node-class rule would fire alongside the requiredness rule.
# --------------------------------------------------------------------------------------------------

run "template_mode_name_omitted_rejected" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = "al2023"
  }

  expect_failures = [kubectl_manifest.this]
}

run "template_mode_ec2nodeclass_name_omitted_rejected" {
  command = plan

  variables {
    name                = "example-pool"
    ec2nodeclass_name   = null
    lookup_ec2nodeclass = false
  }

  expect_failures = [kubectl_manifest.this]
}

run "template_mode_both_present_accepted" {
  command = plan

  variables {
    name              = "example-pool"
    ec2nodeclass_name = "al2023"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "example-pool"
    error_message = "template mode with both required inputs present no longer renders"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef.name == "al2023"
    error_message = "template mode with both required inputs present no longer renders the node class reference"
  }
}

# --------------------------------------------------------------------------------------------------
# lookup_ec2nodeclass in YAML mode: the name read is the variable if set, otherwise the document's
# own nodeClassRef.name, and it is an error for neither to yield one while the lookup is on.
# --------------------------------------------------------------------------------------------------

run "lookup_reads_the_name_from_the_variable" {
  command = plan

  variables {
    ec2nodeclass_name = "override-class"
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
    condition     = data.kubectl_manifest.ec2nodeclass[0].name == "override-class"
    error_message = "the lookup no longer reads the node class the override retargets the pool onto"
  }
}

run "lookup_inherits_the_name_from_the_document" {
  command = plan

  variables {
    ec2nodeclass_name = null
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
    condition     = length(data.kubectl_manifest.ec2nodeclass) == 1
    error_message = "the lookup no longer happens when the node class name comes from the document"
  }
  assert {
    condition     = data.kubectl_manifest.ec2nodeclass[0].name == "document-class"
    error_message = "the lookup no longer inherits the node class name from the document's nodeClassRef"
  }
}

run "lookup_with_no_name_from_either_source_rejected" {
  command = plan

  variables {
    ec2nodeclass_name   = null
    lookup_ec2nodeclass = true
    manifest_yaml       = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-pool
      spec:
        template:
          spec:
            requirements: []
    EOT
  }

  expect_failures = [kubectl_manifest.this]
}

run "lookup_off_with_no_name_from_either_source_accepted" {
  command = plan

  variables {
    ec2nodeclass_name   = null
    lookup_ec2nodeclass = false
    manifest_yaml       = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-pool
      spec:
        template:
          spec:
            requirements: []
    EOT
  }

  assert {
    condition     = length(data.kubectl_manifest.ec2nodeclass) == 0
    error_message = "lookup_ec2nodeclass = false no longer opts out of the read, so a document with no nodeClassRef.name could not be applied at all"
  }
  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef)
    error_message = "the module invented a nodeClassRef the document did not carry and the caller did not ask for"
  }
}

# --------------------------------------------------------------------------------------------------
# The fixtures, fed to YAML mode as documents rather than as unpacked inputs. These are real
# NodePools captured from live clusters, so this is the actual use case end to end: retarget the node
# class, change nothing else.
#
# The expected value is the fixture text with the one nodeClassRef name substituted, not a rebuild of
# the document through the same merge the module performs -- an assertion that re-implemented the
# merge would pass however wrong that merge was. "name: al2023" occurs only inside nodeClassRef in
# both fixtures; each metadata.name is a longer string that does not contain it.
# --------------------------------------------------------------------------------------------------

run "fixture_a_instance_family_pinned_retargeted" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = "example-retarget"
    manifest_yaml     = file("./tests/fixtures/nodepool-instance-family-pinned.yaml")
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef.name == "example-retarget"
    error_message = "fixture A was not retargeted onto the node class the caller named"
  }
  assert {
    condition = yamldecode(output.rendered_manifest) == yamldecode(replace(
      file("./tests/fixtures/nodepool-instance-family-pinned.yaml"),
      "name: al2023",
      "name: example-retarget",
    ))
    error_message = "retargeting fixture A changed something other than nodeClassRef.name"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "default-al2023"
    error_message = "fixture A's metadata.name did not survive: a null name must inherit the document's own"
  }
}

run "fixture_b_taints_and_limits_retargeted" {
  command = plan

  variables {
    name              = null
    ec2nodeclass_name = "example-retarget"
    manifest_yaml     = file("./tests/fixtures/nodepool-taints-and-limits.yaml")
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef.name == "example-retarget"
    error_message = "fixture B was not retargeted onto the node class the caller named"
  }
  assert {
    condition = yamldecode(output.rendered_manifest) == yamldecode(replace(
      file("./tests/fixtures/nodepool-taints-and-limits.yaml"),
      "name: al2023",
      "name: example-retarget",
    ))
    error_message = "retargeting fixture B changed something other than nodeClassRef.name"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "chalk-nodepool-al2023"
    error_message = "fixture B's metadata.name did not survive: a null name must inherit the document's own"
  }
}

# Both fixtures also go through YAML mode with BOTH overrides set, which is how a caller actually
# adopts someone else's document: one pool definition, renamed and repointed per cluster.
run "fixture_a_renamed_and_retargeted" {
  command = plan

  variables {
    name              = "example-pool"
    ec2nodeclass_name = "example-retarget"
    manifest_yaml     = file("./tests/fixtures/nodepool-instance-family-pinned.yaml")
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "example-pool"
    error_message = "fixture A was not renamed by var.name"
  }
  assert {
    condition = yamldecode(output.rendered_manifest).spec == yamldecode(replace(
      file("./tests/fixtures/nodepool-instance-family-pinned.yaml"),
      "name: al2023",
      "name: example-retarget",
    )).spec
    error_message = "renaming fixture A changed its spec, which the caller did not ask to touch"
  }
}

# --------------------------------------------------------------------------------------------------
# The requirements-plus-labels cap holds in YAML mode too, evaluated against the DOCUMENT. The
# variables are null here -- they must be, YAML mode rejects them -- so a cap that still counted
# var.requirements and var.labels would count zero and wave a 101-entry document straight through.
# 60 + 40 is exactly the cap; 60 + 41 is one over, and neither half is over on its own.
#
# The documents are built with yamlencode rather than pasted: 101 hand-written entries would be
# unreadable and would invite a typo that made the run pass for the wrong reason.
# --------------------------------------------------------------------------------------------------

run "yaml_mode_sixty_requirements_plus_forty_labels_accepted" {
  command = plan

  variables {
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

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.spec.requirements) == 60
    error_message = "60 document requirements alongside 40 document labels is exactly the combined cap and must be accepted"
  }
  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.metadata.labels) == 40
    error_message = "40 document labels alongside 60 document requirements is exactly the combined cap and must be accepted"
  }
}

run "yaml_mode_sixty_requirements_plus_forty_one_labels_rejected" {
  command = plan

  variables {
    manifest_yaml = yamlencode({
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata   = { name = "document-pool" }
      spec = {
        template = {
          metadata = { labels = { for i in range(41) : "label-${i}" => "v" } }
          spec = {
            nodeClassRef = { group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = "document-class" }
            requirements = [for i in range(60) : { key = "k${i}", operator = "Exists" }]
          }
        }
      }
    })
  }

  expect_failures = [kubectl_manifest.this]
}
