# Baseline behaviour of the ec2nodeclass module: the API surface, the defaults, the fields that must
# NOT be emitted, and the output seam that orders a consuming NodePool after this node class.
#
# `mock_provider "kubectl" {}` configures no provider and makes no cluster calls, so this suite runs
# with no kubeconfig, no cluster and no AWS credentials.
#
# Every manifest assertion goes through `yamldecode(output.rendered_manifest)`. templatefile output
# is whitespace- and key-order-sensitive, so string matching would fail the suite on cosmetic edits.

mock_provider "kubectl" {}

variables {
  cluster_name          = "example-cluster"
  node_role_name        = "example-cluster-Managed-Node-Role"
  subnet_selector_terms = [{ id = "subnet-xxxxx" }]
}

# --------------------------------------------------------------------------------------------------
# API surface. Karpenter v1 only -- v1beta1 renamed nodeClassRef.apiVersion to .group and is not a
# target of this module.
# --------------------------------------------------------------------------------------------------

run "api_version_and_kind_are_karpenter_v1" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).apiVersion == "karpenter.k8s.aws/v1"
    error_message = "the manifest no longer renders apiVersion karpenter.k8s.aws/v1"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).kind == "EC2NodeClass"
    error_message = "the manifest no longer renders kind EC2NodeClass"
  }
  assert {
    condition     = kubectl_manifest.this.yaml_body == output.rendered_manifest
    error_message = "the applied yaml_body is no longer the rendered template"
  }
}

# --------------------------------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------------------------------

run "defaults_are_pinned" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "al2023"
    error_message = "default name changed"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.amiSelectorTerms == [{ alias = "al2023@latest" }]
    error_message = "default ami_alias changed"
  }
  # 50Gi is what deployed customer node classes run. Chalk's internal stack sets 200Gi; adopting
  # that here would quadruple a customer's root-volume bill on every node without them asking.
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].ebs.volumeSize == "50Gi"
    error_message = "default boot_volume_size is no longer 50Gi"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.tags == { "karpenter.sh/discovery" = "example-cluster" }
    error_message = "the default instance tag set is no longer just the discovery tag keyed on cluster_name"
  }
}

# --------------------------------------------------------------------------------------------------
# Fields that must NOT appear.
#
# Optionality is asserted through the rendered manifest with `!can(...)` rather than through a
# resource attribute: the mock fabricates a value for every computed attribute, so an
# `attribute == null` assertion fails against correct code.
# --------------------------------------------------------------------------------------------------

run "alias_implies_ami_family_so_ami_family_is_never_emitted" {
  command = plan

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.amiFamily)
    error_message = "amiFamily is being emitted; an amiSelectorTerms alias already implies it, and setting both is mutually exclusive"
  }
}

run "unset_optionals_are_absent_not_defaulted" {
  command = plan

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.instanceStorePolicy)
    error_message = "instanceStorePolicy is emitted when the caller set nothing"
  }
  # kubelet configuration moved from NodePool to EC2NodeClass in v1, but this module exposes no
  # input for it, so it must not appear. Karpenter's own defaults are left to the API server.
  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.kubelet)
    error_message = "a kubelet block is emitted when the module exposes no input for one"
  }
  assert {
    condition     = !can(yamldecode(output.rendered_manifest).metadata.labels)
    error_message = "metadata.labels is emitted when the module exposes no input for it"
  }
  assert {
    condition     = !can(yamldecode(output.rendered_manifest).metadata.annotations)
    error_message = "metadata.annotations is emitted when the module exposes no input for it"
  }
  # EC2NodeClass is cluster-scoped. A namespace would be silently ignored at best.
  assert {
    condition     = !can(yamldecode(output.rendered_manifest).metadata.namespace)
    error_message = "metadata.namespace is emitted on a cluster-scoped resource"
  }
}

# --------------------------------------------------------------------------------------------------
# The seam. `output.name` must derive from the APPLIED resource, never from var.name.
#
# Both forms render the identical string in production, so this is the only place the difference is
# observable: the mock fabricates a random value for the computed `name` attribute, while var.name
# is "al2023". An output written as `value = var.name` therefore fails the first assertion below.
# Without the graph edge that output carries, Terraform is free to create a consuming NodePool
# before its node class exists.
# --------------------------------------------------------------------------------------------------

run "name_output_derives_from_the_applied_resource" {
  command = plan

  assert {
    condition     = output.name == kubectl_manifest.this.name
    error_message = "output.name no longer derives from kubectl_manifest.this.name -- a consuming NodePool has lost its ordering edge"
  }
  assert {
    condition     = output.node_class_ref.name == kubectl_manifest.this.name
    error_message = "node_class_ref.name no longer derives from the applied resource"
  }
  assert {
    condition     = output.uid == kubectl_manifest.this.uid
    error_message = "output.uid no longer derives from the applied resource"
  }
  assert {
    condition     = output.id == kubectl_manifest.this.id
    error_message = "output.id no longer derives from the applied resource"
  }
}

# group and kind became strictly required alongside name in Karpenter v1.1.0.
run "node_class_ref_carries_group_and_kind" {
  command = plan

  assert {
    condition     = output.node_class_ref.group == "karpenter.k8s.aws"
    error_message = "node_class_ref.group is no longer karpenter.k8s.aws"
  }
  assert {
    condition     = output.node_class_ref.kind == "EC2NodeClass"
    error_message = "node_class_ref.kind is no longer EC2NodeClass"
  }
  assert {
    condition     = length(keys(output.node_class_ref)) == 3
    error_message = "node_class_ref is no longer exactly {group, kind, name}, so it is no longer a drop-in nodeClassRef"
  }
}

# --------------------------------------------------------------------------------------------------
# Manifest content the module fixes rather than exposing. Each of these is a security or performance
# decision, so a silent change to any of them is a regression.
# --------------------------------------------------------------------------------------------------

run "imdsv2_is_enforced" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.metadataOptions.httpTokens == "required"
    error_message = "httpTokens is no longer `required`; IMDSv1 credentials would be reachable from any pod"
  }
  # 2, not 1: a pod on the host network needs the extra hop to reach IMDS at all.
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.metadataOptions.httpPutResponseHopLimit == 2
    error_message = "httpPutResponseHopLimit is no longer 2"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.metadataOptions.httpProtocolIPv6 == "disabled"
    error_message = "httpProtocolIPv6 is no longer disabled"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.metadataOptions.httpEndpoint == "enabled"
    error_message = "httpEndpoint is no longer enabled; nodes could not reach IMDS"
  }
}

run "security_group_selector_terms_are_keyed_on_cluster_name" {
  command = plan

  assert {
    condition = yamldecode(output.rendered_manifest).spec.securityGroupSelectorTerms == [
      { tags = { "karpenter.sh/discovery" = "example-cluster" } },
      { tags = { "aws:eks:cluster-name" = "example-cluster" } },
    ]
    error_message = "the two cluster-name security group selector terms changed; terms are ORed, so both forms are matched to tolerate clusters carrying only one"
  }
}

run "root_volume_is_a_gp3_dev_xvda_that_is_deleted_on_termination" {
  command = plan

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.blockDeviceMappings) == 1
    error_message = "the node class no longer renders exactly one block device mapping"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].deviceName == "/dev/xvda"
    error_message = "the root device is no longer /dev/xvda"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].ebs.volumeType == "gp3"
    error_message = "the root volume type is no longer gp3"
  }
  # Without this, every terminated node leaves an orphaned EBS volume behind, billed indefinitely.
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].ebs.deleteOnTermination
    error_message = "deleteOnTermination is no longer true; terminated nodes would strand their root volumes"
  }
}

run "user_data_disables_the_kubelet_image_pull_rate_limit" {
  command = plan

  assert {
    condition     = yamldecode(yamldecode(output.rendered_manifest).spec.userData).apiVersion == "node.eks.aws/v1alpha1"
    error_message = "userData is no longer a node.eks.aws/v1alpha1 document"
  }
  assert {
    condition     = yamldecode(yamldecode(output.rendered_manifest).spec.userData).kind == "NodeConfig"
    error_message = "userData is no longer a NodeConfig"
  }
  assert {
    condition     = yamldecode(yamldecode(output.rendered_manifest).spec.userData).spec.kubelet.config.registryPullQPS == 0
    error_message = "registryPullQPS is no longer 0; Chalk images are large and the default rate limit materially delays first-pod-ready"
  }
}

# --------------------------------------------------------------------------------------------------
# role takes the IAM role NAME, not an ARN. Asserted here as well as in identifiers.tftest.hcl
# because it is what the rendered manifest must carry, not just what the input must accept.
# --------------------------------------------------------------------------------------------------

run "role_is_rendered_as_a_bare_name" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.role == "example-cluster-Managed-Node-Role"
    error_message = "spec.role no longer renders var.node_role_name verbatim"
  }
}
