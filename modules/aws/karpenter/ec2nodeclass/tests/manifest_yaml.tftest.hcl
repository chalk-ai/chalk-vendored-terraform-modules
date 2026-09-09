# YAML mode: the caller hands the module a finished EC2NodeClass document instead of a template.
#
#   In YAML mode the module overrides only what cannot be portable between clusters. Everything else
#   in the caller's document is emitted unchanged.
#
# Everything below exists to pin one half of that sentence or the other.
#
# `mock_provider "kubectl" {}` configures no provider and makes no cluster calls, so this suite runs
# with no kubeconfig, no cluster and no AWS credentials.
#
# Two constraints shape the negative runs, both inherited from the rest of the suite:
#
#   * `expect_failures` proves REJECTION and not which rule fired. So every negative run contains
#     exactly one violation -- with one deliberate exception, `several_ignored_inputs_...`, which
#     exists precisely to show that several inputs each report themselves.
#   * The address differs by rule kind. Shape rules live in `validation` blocks and fail at
#     `var.<name>`; every cross-variable rule -- mode selection, template-mode requiredness, and the
#     rejection of inputs YAML mode cannot act on -- is a `lifecycle` precondition and fails at
#     `kubectl_manifest.this`, because a validation may only reference its own variable.
#
# Assertions go through `yamldecode(output.rendered_manifest)`, never the raw string: in YAML mode
# the output is `yamlencode()` of a decoded document, so key order and quoting are the encoder's and
# not the caller's.

mock_provider "kubectl" {}

variables {
  cluster_name          = "example-cluster"
  node_role_name        = "example-cluster-Managed-Node-Role"
  subnet_selector_terms = [{ id = "subnet-xxxxx" }]

  # The canonical document under test. Every value in it is deliberately DIFFERENT from what the
  # module would produce in template mode and from the file-level inputs above, so that "the
  # override fired" and "the document survived" are distinguishable rather than coincidentally equal.
  #
  # The five overridable fields carry `document-*` values. The passthrough fields carry values the
  # module's own template would never emit: a bottlerocket alias, /dev/xvdb, gp2, deleteOnTermination
  # false, IMDSv1-permitting metadataOptions and a hop limit of 1.
  manifest_yaml = <<-EOT
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: document-name
    spec:
      role: document-role
      subnetSelectorTerms:
        - id: subnet-ddddd
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: document-cluster
      tags:
        karpenter.sh/discovery: document-cluster
        DocumentOnly: kept
      amiSelectorTerms:
        - alias: bottlerocket@v1.20.4
      blockDeviceMappings:
        - deviceName: /dev/xvdb
          ebs:
            deleteOnTermination: false
            volumeSize: 123Gi
            volumeType: gp2
      metadataOptions:
        httpEndpoint: enabled
        httpProtocolIPv6: enabled
        httpPutResponseHopLimit: 1
        httpTokens: optional
      instanceStorePolicy: RAID0
      userData: |
        apiVersion: node.eks.aws/v1alpha1
        kind: NodeConfig
        spec:
          kubelet:
            config:
              maxPods: 110
  EOT
}

# --------------------------------------------------------------------------------------------------
# Mode selection. `manifest_yaml` selects YAML mode, `manifest_path` selects a custom template,
# neither renders the bundled template, and both is an error.
# --------------------------------------------------------------------------------------------------

run "neither_manifest_input_set_renders_the_bundled_template" {
  command = plan

  variables {
    manifest_yaml = null
    manifest_path = null
  }

  # `al2023` is the bundled template's default name and nothing else in this file produces it, so
  # this distinguishes template mode from both of the other two paths.
  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "al2023"
    error_message = "with neither manifest input set the module no longer renders the bundled template"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.amiSelectorTerms[0].alias == "al2023@latest"
    error_message = "the bundled template's defaults are no longer resolved once the variables default to null"
  }
}

# `path.module` is not in scope in a test file, so the path is relative to the process working
# directory -- this module's directory, where `tofu test` is run.
run "manifest_path_only_selects_template_mode" {
  command = plan

  variables {
    manifest_yaml = null
    manifest_path = "tests/fixtures/nodeclass-al2023.yaml"
  }

  # The substituted file pins three subnet ids of its own and contains no template directives, so
  # rendering three terms while the caller passed one can only happen if manifest_path won.
  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.subnetSelectorTerms) == 3
    error_message = "manifest_path no longer selects template mode with a substituted file"
  }
}

run "manifest_yaml_only_selects_yaml_mode" {
  command = plan

  # A bottlerocket alias is a value the bundled template never produces on its own, and ami_alias is
  # rejected in YAML mode, so it can only have come from the document.
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.amiSelectorTerms[0].alias == "bottlerocket@v1.20.4"
    error_message = "manifest_yaml no longer selects YAML mode; the bundled template rendered instead"
  }
}

# The two inputs name two different things -- a finished document and a template to render -- so
# there is no sensible way to honour both.
run "both_manifest_inputs_set_rejected" {
  command = plan

  variables {
    manifest_path = "templates/ec2nodeclass.yaml.tftpl"
  }

  expect_failures = [kubectl_manifest.this]
}

# --------------------------------------------------------------------------------------------------
# Decode. The document must parse, and it must parse to a MAPPING -- which is what a Kubernetes
# object is. A scalar and a sequence both parse perfectly well and are neither.
# --------------------------------------------------------------------------------------------------

run "a_minimal_valid_mapping_is_accepted" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
      apiVersion: karpenter.k8s.aws/v1
      kind: EC2NodeClass
      metadata:
        name: minimal
      spec:
        role: document-role
    EOT
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).kind == "EC2NodeClass"
    error_message = "a minimal but valid EC2NodeClass document was not accepted"
  }
}

run "unparseable_yaml_rejected" {
  command = plan

  variables {
    manifest_yaml = "a: [1, 2\n  b: }{"
  }

  expect_failures = [var.manifest_yaml]
}

run "scalar_document_rejected" {
  command = plan

  variables {
    manifest_yaml = "al2023"
  }

  expect_failures = [var.manifest_yaml]
}

run "sequence_document_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
      - apiVersion: karpenter.k8s.aws/v1
        kind: EC2NodeClass
    EOT
  }

  expect_failures = [var.manifest_yaml]
}

# The empty string does not decode to an empty mapping -- yamldecode rejects it outright -- so it is
# the parse rule and not the mapping rule that catches this one.
run "empty_string_rejected" {
  command = plan

  variables {
    manifest_yaml = ""
  }

  expect_failures = [var.manifest_yaml]
}

# --------------------------------------------------------------------------------------------------
# kind, apiVersion and spec. Each rule below is predicated on the earlier ones having passed, so
# every negative run here trips exactly one.
# --------------------------------------------------------------------------------------------------

run "correct_kind_and_api_version_accepted" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).apiVersion == "karpenter.k8s.aws/v1"
    error_message = "the document's apiVersion did not survive"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).kind == "EC2NodeClass"
    error_message = "the document's kind did not survive"
  }
}

run "wrong_kind_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: document-name
      spec:
        role: document-role
    EOT
  }

  expect_failures = [var.manifest_yaml]
}

run "missing_kind_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
      apiVersion: karpenter.k8s.aws/v1
      metadata:
        name: document-name
      spec:
        role: document-role
    EOT
  }

  expect_failures = [var.manifest_yaml]
}

# The likely paste. v1beta1 is what most clusters ran before Karpenter v1.0, and the schemas differ
# by more than the group version, so relabelling one is not a conversion.
run "v1beta1_api_version_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
      apiVersion: karpenter.k8s.aws/v1beta1
      kind: EC2NodeClass
      metadata:
        name: document-name
      spec:
        role: document-role
    EOT
  }

  expect_failures = [var.manifest_yaml]
}

run "missing_api_version_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
      kind: EC2NodeClass
      metadata:
        name: document-name
      spec:
        role: document-role
    EOT
  }

  expect_failures = [var.manifest_yaml]
}

run "missing_spec_rejected" {
  command = plan

  variables {
    manifest_yaml = <<-EOT
      apiVersion: karpenter.k8s.aws/v1
      kind: EC2NodeClass
      metadata:
        name: document-name
    EOT
  }

  expect_failures = [var.manifest_yaml]
}

# --------------------------------------------------------------------------------------------------
# Override applied. Five fields, one run each; the document carries a `document-*` value for every
# one of them, so an assertion that finds the caller's value can only mean the override fired.
# --------------------------------------------------------------------------------------------------

run "name_overrides_the_documents_metadata_name" {
  command = plan

  variables {
    name = "overridden-name"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "overridden-name"
    error_message = "var.name no longer overrides metadata.name in YAML mode"
  }
}

run "node_role_name_overrides_the_documents_spec_role" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.role == "example-cluster-Managed-Node-Role"
    error_message = "var.node_role_name no longer overrides spec.role in YAML mode"
  }
}

run "cluster_name_overrides_the_documents_security_group_selector_terms" {
  command = plan

  # Both terms, in order. The document carries only the discovery form, so the second term appearing
  # at all proves the whole list was replaced rather than the first entry patched.
  assert {
    condition = yamldecode(output.rendered_manifest).spec.securityGroupSelectorTerms == [
      { tags = { "karpenter.sh/discovery" = "example-cluster" } },
      { tags = { "aws:eks:cluster-name" = "example-cluster" } },
    ]
    error_message = "var.cluster_name no longer replaces spec.securityGroupSelectorTerms in YAML mode"
  }
}

run "cluster_name_and_tags_merge_over_the_documents_spec_tags" {
  command = plan

  variables {
    tags = { Team = "infra" }
  }

  # MERGED over, not replaced: DocumentOnly is the document's and must survive, while the discovery
  # tag is the module's and must win.
  assert {
    condition = yamldecode(output.rendered_manifest).spec.tags == {
      "karpenter.sh/discovery" = "example-cluster"
      "DocumentOnly"           = "kept"
      "Team"                   = "infra"
    }
    error_message = "spec.tags is no longer the document's tags with the discovery tag and caller tags merged over them"
  }
}

# --- subnet_selector_terms: the full single / multi / mixed treatment, again. This is the field a
# --- customer cannot be told how to fill in prose, and YAML mode rebuilds the terms rather than
# --- passing the variable through, so the rebuild needs the same coverage as the template branch.

run "subnet_terms_single_id_replaces_the_documents_terms" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == [{ id = "subnet-xxxxx" }]
    error_message = "a single id term no longer replaces the document's subnetSelectorTerms"
  }
}

run "subnet_terms_single_tag_term_replaces_the_documents_terms" {
  command = plan

  variables {
    subnet_selector_terms = [{ tags = { "karpenter.sh/discovery" = "example-cluster" } }]
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == [{ tags = { "karpenter.sh/discovery" = "example-cluster" } }]
    error_message = "a single tag-discovery term no longer replaces the document's subnetSelectorTerms"
  }
}

run "subnet_terms_multi_id_replace_the_documents_terms_wholesale" {
  command = plan

  variables {
    subnet_selector_terms = [{ id = "subnet-xxxxx" }, { id = "subnet-yyyyy" }, { id = "subnet-zzzzz" }]
  }

  # Exactly three, in caller order. The document's own `subnet-ddddd` must be gone: the terms are
  # replaced wholesale, because a half-overridden list would select subnets from two clusters.
  assert {
    condition = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == [
      { id = "subnet-xxxxx" },
      { id = "subnet-yyyyy" },
      { id = "subnet-zzzzz" },
    ]
    error_message = "multiple id terms no longer replace the document's subnetSelectorTerms wholesale and in caller order"
  }
}

run "subnet_terms_multi_tag_terms_replace_the_documents_terms" {
  command = plan

  variables {
    subnet_selector_terms = [
      { tags = { "karpenter.sh/discovery" = "example-cluster" } },
      { tags = { "Tier" = "private" } },
    ]
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == [
      { tags = { "karpenter.sh/discovery" = "example-cluster" } },
      { tags = { "Tier" = "private" } },
    ]
    error_message = "multiple tag terms no longer render as separate ORed terms in YAML mode"
  }
}

# Conditions inside one term are ANDed, so a two-key term is one term and not two.
run "subnet_terms_multi_key_tag_term_stays_one_anded_term" {
  command = plan

  variables {
    subnet_selector_terms = [{ tags = { "karpenter.sh/discovery" = "example-cluster", "Tier" = "private" } }]
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.subnetSelectorTerms) == 1
    error_message = "a two-key tag term is being split into two terms in YAML mode, which changes AND semantics into OR"
  }
  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.subnetSelectorTerms[0].tags) == 2
    error_message = "a two-key tag term no longer renders both keys in YAML mode"
  }
}

# Cross-form. This is also the run that pins the term rebuild's shape: a term must carry exactly the
# key it was given, so an id term must NOT acquire a null `tags` alongside it.
run "subnet_terms_mixed_id_and_tag_forms_are_both_valid" {
  command = plan

  variables {
    subnet_selector_terms = [
      { id = "subnet-xxxxx" },
      { tags = { "karpenter.sh/discovery" = "example-cluster" } },
    ]
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == [
      { id = "subnet-xxxxx" },
      { tags = { "karpenter.sh/discovery" = "example-cluster" } },
    ]
    error_message = "id and tag terms no longer coexist in one list in YAML mode, or a term acquired the key it was not given"
  }
}

# Mixed, invalid element LAST. The shape rules are variable validations and apply in both modes; a
# rule written against element [0] would pass every run above and fail only here.
run "subnet_terms_valid_ids_followed_by_a_vpc_id_rejected_in_yaml_mode" {
  command = plan

  variables {
    subnet_selector_terms = [
      { id = "subnet-xxxxx" },
      { id = "subnet-yyyyy" },
      { id = "vpc-xxxxx" },
    ]
  }

  expect_failures = [var.subnet_selector_terms]
}

# --------------------------------------------------------------------------------------------------
# Inheritance. Each override input null in turn, and the document's own value survives. This is the
# half of the rule that says the module overrides ONLY what cannot be portable.
# --------------------------------------------------------------------------------------------------

run "null_name_leaves_the_documents_metadata_name" {
  command = plan

  variables {
    name = null
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "document-name"
    error_message = "a null name no longer leaves the document's metadata.name alone; the template-mode default leaked into YAML mode"
  }
}

run "null_node_role_name_leaves_the_documents_spec_role" {
  command = plan

  variables {
    node_role_name = null
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.role == "document-role"
    error_message = "a null node_role_name no longer leaves the document's spec.role alone"
  }
}

run "null_subnet_selector_terms_leave_the_documents_terms" {
  command = plan

  variables {
    subnet_selector_terms = null
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == [{ id = "subnet-ddddd" }]
    error_message = "null subnet_selector_terms no longer leave the document's own terms alone"
  }
}

run "null_cluster_name_leaves_the_documents_security_group_selector_terms" {
  command = plan

  variables {
    cluster_name = null
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.securityGroupSelectorTerms == [
      { tags = { "karpenter.sh/discovery" = "document-cluster" } },
    ]
    error_message = "a null cluster_name no longer leaves the document's securityGroupSelectorTerms alone"
  }
}

# With no cluster name and no caller tags there is nothing to merge, so spec.tags must be exactly
# what the document said -- including the document's own discovery value.
run "null_cluster_name_and_empty_tags_leave_the_documents_spec_tags" {
  command = plan

  variables {
    cluster_name = null
    tags         = {}
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.tags == {
      "karpenter.sh/discovery" = "document-cluster"
      "DocumentOnly"           = "kept"
    }
    error_message = "with nothing to merge, spec.tags is no longer the document's tags verbatim"
  }
}

# The whole rule in one assertion: every override input null, and the document round-trips.
run "all_override_inputs_null_emit_the_document_unchanged" {
  command = plan

  variables {
    name                  = null
    node_role_name        = null
    cluster_name          = null
    subnet_selector_terms = null
    tags                  = {}
  }

  assert {
    condition     = yamldecode(output.rendered_manifest) == yamldecode(var.manifest_yaml)
    error_message = "with every override input null the module no longer emits the caller's document unchanged"
  }
}

# A document that never carried spec.tags must not acquire an empty `tags: {}` mapping, which would
# not be emitting it unchanged. The naive implementation always emits the merged map.
run "a_document_without_tags_does_not_acquire_an_empty_tags_mapping" {
  command = plan

  variables {
    cluster_name  = null
    tags          = {}
    manifest_yaml = <<-EOT
      apiVersion: karpenter.k8s.aws/v1
      kind: EC2NodeClass
      metadata:
        name: document-name
      spec:
        role: document-role
    EOT
  }

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.tags)
    error_message = "a document with no spec.tags acquired one; the module is emitting a key the caller never wrote"
  }
}

# --------------------------------------------------------------------------------------------------
# Passthrough. These are the fields the module has no business touching, because none of them is
# cluster-bound. Every value here is one the bundled template would never produce.
# --------------------------------------------------------------------------------------------------

run "user_data_survives_the_round_trip_unchanged" {
  command = plan

  # Compared as a string first: userData is a block scalar and a decode/re-encode that dropped the
  # trailing newline or re-indented the body would still parse as a valid NodeConfig.
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.userData == yamldecode(var.manifest_yaml).spec.userData
    error_message = "spec.userData did not survive the decode/re-encode byte for byte"
  }
  assert {
    condition     = yamldecode(yamldecode(output.rendered_manifest).spec.userData).spec.kubelet.config.maxPods == 110
    error_message = "the document's userData no longer parses as its own NodeConfig after the round trip"
  }
}

run "block_device_mappings_survive_the_round_trip_unchanged" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings == yamldecode(var.manifest_yaml).spec.blockDeviceMappings
    error_message = "spec.blockDeviceMappings did not survive unchanged"
  }
  # Spelled out as well as compared, so a failure says which of the module's template-mode opinions
  # leaked in: /dev/xvda, gp3, deleteOnTermination true and 50Gi are all wrong here.
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].deviceName == "/dev/xvdb"
    error_message = "the module overwrote the document's root device name"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].ebs.volumeSize == "123Gi"
    error_message = "the module overwrote the document's root volume size"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].ebs.volumeType == "gp2"
    error_message = "the module overwrote the document's root volume type"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].ebs.deleteOnTermination == false
    error_message = "the module overwrote the document's deleteOnTermination"
  }
}

# The document permits IMDSv1 and sets a hop limit of 1, both the opposite of the module's
# template-mode opinion. YAML mode is the caller's document, so the caller's choice stands.
run "metadata_options_survive_the_round_trip_unchanged" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.metadataOptions == yamldecode(var.manifest_yaml).spec.metadataOptions
    error_message = "spec.metadataOptions did not survive unchanged"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.metadataOptions.httpTokens == "optional"
    error_message = "the module imposed its own httpTokens on the caller's document"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.metadataOptions.httpPutResponseHopLimit == 1
    error_message = "the module imposed its own httpPutResponseHopLimit on the caller's document"
  }
}

run "ami_selector_terms_and_instance_store_policy_survive_the_round_trip_unchanged" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.amiSelectorTerms == yamldecode(var.manifest_yaml).spec.amiSelectorTerms
    error_message = "spec.amiSelectorTerms did not survive unchanged"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.instanceStorePolicy == "RAID0"
    error_message = "the document's spec.instanceStorePolicy did not survive"
  }
  # The alias implies amiFamily in both modes, so neither the caller nor the module may add one.
  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.amiFamily)
    error_message = "amiFamily appeared in the YAML-mode output"
  }
}

# The document's spec keys, all of them, and no others. The strongest single passthrough assertion:
# it catches a key silently added as well as one silently dropped.
run "the_yaml_mode_output_has_exactly_the_documents_spec_keys" {
  command = plan

  assert {
    condition     = keys(yamldecode(output.rendered_manifest).spec) == keys(yamldecode(var.manifest_yaml).spec)
    error_message = "the YAML-mode output's spec key set differs from the document's; the module added or dropped a field"
  }
  assert {
    condition     = keys(yamldecode(output.rendered_manifest)) == keys(yamldecode(var.manifest_yaml))
    error_message = "the YAML-mode output's top-level key set differs from the document's"
  }
}

# --------------------------------------------------------------------------------------------------
# Inputs YAML mode cannot act on are REJECTED, not silently dropped.
#
# The point is that silence is the dangerous outcome. A caller who passes boot_volume_size = "50Gi"
# alongside a document whose blockDeviceMappings say 200Gi has a wrong mental model, and nothing
# about the applied object would tell them so.
# --------------------------------------------------------------------------------------------------

run "ami_alias_in_yaml_mode_rejected" {
  command = plan

  variables {
    ami_alias = "al2023@latest"
  }

  expect_failures = [kubectl_manifest.this]
}

run "boot_volume_size_in_yaml_mode_rejected" {
  command = plan

  variables {
    boot_volume_size = "50Gi"
  }

  expect_failures = [kubectl_manifest.this]
}

run "instance_store_policy_in_yaml_mode_rejected" {
  command = plan

  variables {
    instance_store_policy = "RAID0"
  }

  expect_failures = [kubectl_manifest.this]
}

# manifest_path is the fourth template-only input. It is caught by the SAME rule as
# `both_manifest_inputs_set_rejected` above rather than by a rule of its own -- deliberately, so that
# one input trips one rule -- and is repeated here because it belongs to both groups.
run "manifest_path_in_yaml_mode_rejected" {
  command = plan

  variables {
    manifest_path = "templates/ec2nodeclass.yaml.tftpl"
  }

  expect_failures = [kubectl_manifest.this]
}

# The one deliberate multi-violation run in the file: three ignored inputs, three preconditions, all
# reported at the same address. One rule per input is what makes the error name the input.
run "several_ignored_inputs_at_once_rejected" {
  command = plan

  variables {
    ami_alias             = "al2023@latest"
    boot_volume_size      = "50Gi"
    instance_store_policy = "RAID0"
  }

  expect_failures = [kubectl_manifest.this]
}

# One legitimate override alongside one ignored input. The valid input must not excuse the invalid
# one -- a caller half-way through converting from template mode hits exactly this.
run "one_valid_override_plus_one_ignored_input_rejected" {
  command = plan

  variables {
    name             = "overridden-name"
    boot_volume_size = "50Gi"
  }

  expect_failures = [kubectl_manifest.this]
}

# --------------------------------------------------------------------------------------------------
# Template mode is still required to have its three inputs.
#
# They now default to null, so Terraform no longer refuses the run itself; the module does, at plan,
# through a precondition. These runs are the ones that prove the requiredness did not simply
# evaporate when the defaults were added.
# --------------------------------------------------------------------------------------------------

run "template_mode_without_subnet_selector_terms_rejected" {
  command = plan

  variables {
    manifest_yaml         = null
    subnet_selector_terms = null
  }

  expect_failures = [kubectl_manifest.this]
}

run "template_mode_without_cluster_name_rejected" {
  command = plan

  variables {
    manifest_yaml = null
    cluster_name  = null
  }

  expect_failures = [kubectl_manifest.this]
}

run "template_mode_without_node_role_name_rejected" {
  command = plan

  variables {
    manifest_yaml  = null
    node_role_name = null
  }

  expect_failures = [kubectl_manifest.this]
}

# Template mode must be BYTE-identical to what it rendered before YAML mode existed, not merely
# structurally equal. Moving the al2023 / al2023@latest / 50Gi defaults off the variables and into
# locals is the change that could silently alter them, and every other assertion in the suite goes
# through yamldecode() and would not notice a changed default that still parsed.
#
# The right-hand side re-renders the same template from an independently written var map carrying
# those three literals, so this fails if a local resolves to anything other than the old default.
run "template_mode_output_is_byte_identical_to_the_pre_yaml_mode_render" {
  command = plan

  variables {
    manifest_yaml = null
  }

  assert {
    condition = output.rendered_manifest == templatefile("templates/ec2nodeclass.yaml.tftpl", {
      name                  = "al2023"
      ami_alias             = "al2023@latest"
      node_role_name        = "example-cluster-Managed-Node-Role"
      cluster_name          = "example-cluster"
      subnet_selector_terms = [{ id = "subnet-xxxxx", tags = null }]
      boot_volume_size      = "50Gi"
      instance_store_policy = null
      tags                  = { "karpenter.sh/discovery" = "example-cluster" }
    })
    error_message = "template mode no longer renders byte-for-byte what it rendered before the defaults moved into locals"
  }
}

run "template_mode_with_all_three_present_accepted" {
  command = plan

  variables {
    manifest_yaml = null
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.role == "example-cluster-Managed-Node-Role"
    error_message = "template mode no longer renders with all three formerly-required inputs present"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == [{ id = "subnet-xxxxx" }]
    error_message = "template mode no longer renders the caller's subnet terms"
  }
}

# --------------------------------------------------------------------------------------------------
# The fixture, fed as a document. tests/fixtures/nodeclass-al2023.yaml is an EC2NodeClass captured
# from a live customer cluster and anonymised, so this is the actual use case end to end: take the
# node class you already run, hand it to the module, and move it to another cluster's subnets.
#
# name, cluster_name and node_role_name are set to the fixture's OWN values, so those three
# overrides are no-ops and the only intended difference is the subnets.
# --------------------------------------------------------------------------------------------------

run "the_captured_node_class_fed_as_a_document_swaps_subnets_and_nothing_else" {
  command = plan

  variables {
    name                  = "al2023"
    cluster_name          = "example-cluster"
    node_role_name        = "example-cluster-Managed-Node-Role"
    subnet_selector_terms = [{ id = "subnet-aaaaa" }, { id = "subnet-bbbbb" }]
    manifest_yaml         = file("tests/fixtures/nodeclass-al2023.yaml")
  }

  # Whole-object: the fixture with its subnetSelectorTerms swapped, and nothing else touched.
  assert {
    condition = yamldecode(output.rendered_manifest) == merge(
      yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")),
      {
        spec = merge(
          yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).spec,
          { subnetSelectorTerms = [{ id = "subnet-aaaaa" }, { id = "subnet-bbbbb" }] },
        )
      },
    )
    error_message = "feeding the captured node class through YAML mode changed something other than its subnets"
  }

  # The comparison above must be able to fail: if the swap did not happen, both sides would still be
  # the fixture and the assertion would pass vacuously.
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms != yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).spec.subnetSelectorTerms
    error_message = "the subnets were not swapped, so the whole-object comparison above is vacuous"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == [{ id = "subnet-aaaaa" }, { id = "subnet-bbbbb" }]
    error_message = "the captured node class's three subnets were not replaced by the caller's two"
  }
}
