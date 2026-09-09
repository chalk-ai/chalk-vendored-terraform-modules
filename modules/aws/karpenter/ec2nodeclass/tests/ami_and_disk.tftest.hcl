# The remaining node class properties: ami_alias, boot_volume_size, instance_store_policy, and --
# because the suite is one file per property GROUP rather than per property -- tags and
# manifest_path, each under its own section rule below.
#
# ami_alias, boot_volume_size and instance_store_policy are scalars, so there are no "mixed" cases;
# tags is a map and does have them. Note that a map has no element order, so "invalid element last"
# is meaningless for tags -- the fill characters below are chosen to sort last anyway, since map
# iteration is lexical.

mock_provider "kubectl" {}

variables {
  cluster_name          = "example-cluster"
  node_role_name        = "example-cluster-Managed-Node-Role"
  subnet_selector_terms = [{ id = "subnet-xxxxx" }]
}

# --------------------------------------------------------------------------------------------------
# ami_alias -- single good, multi good
#
# NOTE: the design's per-property matrix lists bare `al2` and `al2023` as valid multi cases while
# also listing `"al2023"` as invalid "(no `@`)". Those contradict. The `@version` half is treated as
# mandatory here, following the design's own prose that an alias is "of the form family@version" and
# the explicit reason attached to the negative case. The multi-good families below are therefore
# spelled with their versions.
# --------------------------------------------------------------------------------------------------

run "ami_alias_representative_value" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.amiSelectorTerms == [{ alias = "al2023@latest" }]
    error_message = "the default ami_alias no longer renders as a single alias term"
  }
}

run "ami_alias_al2_family_accepted" {
  command = plan

  variables {
    ami_alias = "al2@latest"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.amiSelectorTerms[0].alias == "al2@latest"
    error_message = "the al2 alias family was rejected"
  }
}

# The production-safe form: a pinned dated version. `@latest` drifts and replaces every node on each
# AMI release, so a customer pinning a version must be able to.
run "ami_alias_pinned_al2023_version_accepted" {
  command = plan

  variables {
    ami_alias = "al2023@v20240807"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.amiSelectorTerms[0].alias == "al2023@v20240807"
    error_message = "a pinned dated al2023 alias version was rejected"
  }
}

run "ami_alias_bottlerocket_family_accepted" {
  command = plan

  variables {
    ami_alias = "bottlerocket@v1.20.4"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.amiSelectorTerms[0].alias == "bottlerocket@v1.20.4"
    error_message = "the bottlerocket alias family, or a dotted version, was rejected"
  }
}

run "ami_alias_windows2022_family_accepted" {
  command = plan

  variables {
    ami_alias = "windows2022@latest"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.amiSelectorTerms[0].alias == "windows2022@latest"
    error_message = "the windows2022 alias family was rejected"
  }
}

run "ami_alias_windows2019_family_accepted" {
  command = plan

  variables {
    ami_alias = "windows2019@latest"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.amiSelectorTerms[0].alias == "windows2019@latest"
    error_message = "the windows2019 alias family was rejected"
  }
}

# Whatever the alias, amiFamily must stay absent -- the alias implies it and the two are mutually
# exclusive. Re-asserted against a non-default family because that is where a naive implementation
# would be tempted to derive and emit one.
run "a_non_default_alias_still_emits_no_ami_family" {
  command = plan

  variables {
    ami_alias = "bottlerocket@v1.20.4"
  }

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.amiFamily)
    error_message = "amiFamily is emitted for a non-default alias family"
  }
}

# --------------------------------------------------------------------------------------------------
# ami_alias -- single bad
# --------------------------------------------------------------------------------------------------

run "ami_alias_without_a_version_rejected" {
  command = plan

  variables {
    ami_alias = "al2023"
  }

  expect_failures = [var.ami_alias]
}

run "ami_alias_with_an_empty_version_rejected" {
  command = plan

  variables {
    ami_alias = "al2023@"
  }

  expect_failures = [var.ami_alias]
}

# Ubuntu is not an alias family in Karpenter v1; it must be selected with an id, name or ssm term.
run "ami_alias_with_an_unknown_family_rejected" {
  command = plan

  variables {
    ami_alias = "ubuntu@latest"
  }

  expect_failures = [var.ami_alias]
}

run "ami_alias_family_is_case_sensitive" {
  command = plan

  variables {
    ami_alias = "AL2023@latest"
  }

  expect_failures = [var.ami_alias]
}

# --------------------------------------------------------------------------------------------------
# ami_alias -- multi bad. One unknown family per run, because expect_failures proves rejection and
# not which value caused it.
# --------------------------------------------------------------------------------------------------

run "ami_alias_amazon_linux_2023_long_form_rejected" {
  command = plan

  variables {
    ami_alias = "amazon-linux-2023@latest"
  }

  expect_failures = [var.ami_alias]
}

run "ami_alias_windows2016_rejected" {
  command = plan

  variables {
    ami_alias = "windows2016@latest"
  }

  expect_failures = [var.ami_alias]
}

run "ami_alias_bare_at_version_rejected" {
  command = plan

  variables {
    ami_alias = "@latest"
  }

  expect_failures = [var.ami_alias]
}

# --------------------------------------------------------------------------------------------------
# boot_volume_size -- single good, multi good across the domain
# --------------------------------------------------------------------------------------------------

run "boot_volume_size_default_is_50Gi" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].ebs.volumeSize == "50Gi"
    error_message = "boot_volume_size no longer defaults to 50Gi"
  }
}

run "boot_volume_size_20Gi_accepted" {
  command = plan

  variables {
    boot_volume_size = "20Gi"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].ebs.volumeSize == "20Gi"
    error_message = "boot_volume_size 20Gi was rejected"
  }
}

run "boot_volume_size_200Gi_accepted" {
  command = plan

  variables {
    boot_volume_size = "200Gi"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].ebs.volumeSize == "200Gi"
    error_message = "boot_volume_size 200Gi -- Chalk's own internal value -- was rejected"
  }
}

run "boot_volume_size_1Ti_accepted" {
  command = plan

  variables {
    boot_volume_size = "1Ti"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].ebs.volumeSize == "1Ti"
    error_message = "boot_volume_size 1Ti was rejected"
  }
}

# A quantity renders as a YAML string, not a number. If it ever rendered unquoted-and-numeric the
# API server would read it as bytes.
run "boot_volume_size_renders_as_a_string_quantity" {
  command = plan

  assert {
    condition     = can(regex("Gi$", yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].ebs.volumeSize))
    error_message = "volumeSize no longer renders as a unit-suffixed string"
  }
}

# --------------------------------------------------------------------------------------------------
# boot_volume_size -- single bad
# --------------------------------------------------------------------------------------------------

run "boot_volume_size_without_a_unit_rejected" {
  command = plan

  variables {
    boot_volume_size = "50"
  }

  expect_failures = [var.boot_volume_size]
}

run "negative_boot_volume_size_rejected" {
  command = plan

  variables {
    boot_volume_size = "-1Gi"
  }

  expect_failures = [var.boot_volume_size]
}

run "non_numeric_boot_volume_size_rejected" {
  command = plan

  variables {
    boot_volume_size = "abc"
  }

  expect_failures = [var.boot_volume_size]
}

run "zero_boot_volume_size_rejected" {
  command = plan

  variables {
    boot_volume_size = "0Gi"
  }

  expect_failures = [var.boot_volume_size]
}

# --------------------------------------------------------------------------------------------------
# instance_store_policy -- both valid values, then the invalid ones
# --------------------------------------------------------------------------------------------------

run "instance_store_policy_null_omits_the_field" {
  command = plan

  variables {
    instance_store_policy = null
  }

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.instanceStorePolicy)
    error_message = "instanceStorePolicy is emitted when the input is null"
  }
}

run "instance_store_policy_raid0_renders" {
  command = plan

  variables {
    instance_store_policy = "RAID0"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.instanceStorePolicy == "RAID0"
    error_message = "instance_store_policy RAID0 no longer renders"
  }
}

run "instance_store_policy_is_case_sensitive" {
  command = plan

  variables {
    instance_store_policy = "raid0"
  }

  expect_failures = [var.instance_store_policy]
}

run "instance_store_policy_raid1_rejected" {
  command = plan

  variables {
    instance_store_policy = "RAID1"
  }

  expect_failures = [var.instance_store_policy]
}

run "instance_store_policy_empty_string_rejected" {
  command = plan

  variables {
    instance_store_policy = ""
  }

  expect_failures = [var.instance_store_policy]
}

# --------------------------------------------------------------------------------------------------
# Cross-attribute: instanceStorePolicy and blockDeviceMappings are independent. A caller striping
# local NVMe for ephemeral storage still chooses their own root volume size.
# --------------------------------------------------------------------------------------------------

run "instance_store_policy_and_boot_volume_size_are_independent" {
  command = plan

  variables {
    instance_store_policy = "RAID0"
    boot_volume_size      = "200Gi"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.instanceStorePolicy == "RAID0"
    error_message = "instanceStorePolicy stopped rendering once boot_volume_size was also set"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings[0].ebs.volumeSize == "200Gi"
    error_message = "the root volume size stopped rendering once instance_store_policy was also set"
  }
}

# --------------------------------------------------------------------------------------------------
# tags -- single good, multi good
# --------------------------------------------------------------------------------------------------

run "tags_single_key_merges_over_the_discovery_tag" {
  command = plan

  variables {
    tags = { Team = "infra" }
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.tags == {
      "karpenter.sh/discovery" = "example-cluster"
      "Team"                   = "infra"
    }
    error_message = "a caller tag no longer merges alongside the module's discovery tag"
  }
}

run "tags_multiple_keys_all_render" {
  command = plan

  variables {
    tags = { Team = "infra", Environment = "production", "chalk.ai/managed-by" = "terraform" }
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.tags) == 4
    error_message = "three caller tags plus the discovery tag no longer render as four tags"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.tags["chalk.ai/managed-by"] == "terraform"
    error_message = "a prefixed tag key no longer renders"
  }
}

# Caller tags are merged last and therefore win, which is the conventional Terraform idiom.
run "a_caller_tag_can_override_the_default_discovery_tag" {
  command = plan

  variables {
    tags = { "karpenter.sh/discovery" = "some-other-value" }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.tags["karpenter.sh/discovery"] == "some-other-value"
    error_message = "a caller-supplied karpenter.sh/discovery tag no longer overrides the module default"
  }
}

# An empty tags map still renders the discovery tag, so spec.tags is never an empty mapping.
run "empty_tags_input_still_renders_the_discovery_tag" {
  command = plan

  variables {
    tags = {}
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.tags) == 1
    error_message = "an empty tags input no longer leaves exactly the discovery tag"
  }
}

# Values with YAML-significant characters must survive. Every interpolation goes through
# jsonencode(), so this is a regression test for that choice.
run "tag_values_with_yaml_significant_characters_survive" {
  command = plan

  variables {
    tags = { Note = "a: b #c \"quoted\" 'single' | > -" }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.tags["Note"] == "a: b #c \"quoted\" 'single' | > -"
    error_message = "a tag value containing YAML-significant characters no longer round-trips; the template is not escaping interpolations"
  }
}

# --------------------------------------------------------------------------------------------------
# tags -- single bad, multi bad, mixed. The key rule and the value rule are separate validations, so
# each run below trips exactly one.
# --------------------------------------------------------------------------------------------------

run "over_long_tag_key_rejected" {
  command = plan

  variables {
    tags = { (join("", [for i in range(129) : "k"])) = "v" }
  }

  expect_failures = [var.tags]
}

run "over_long_tag_value_rejected" {
  command = plan

  variables {
    tags = { Note = join("", [for i in range(257) : "v"]) }
  }

  expect_failures = [var.tags]
}

run "all_tag_keys_over_long_rejected" {
  command = plan

  variables {
    tags = {
      (join("", [for i in range(129) : "k"])) = "v"
      (join("", [for i in range(129) : "l"])) = "v"
      (join("", [for i in range(129) : "m"])) = "v"
    }
  }

  expect_failures = [var.tags]
}

# Mixed: valid keys plus one over-long one. A map has no element order, so the fill character is
# chosen to sort after the valid keys -- map iteration is lexical, and uppercase sorts first.
run "valid_tag_keys_plus_one_over_long_key_rejected" {
  command = plan

  variables {
    tags = {
      Team                                    = "infra"
      Environment                             = "production"
      (join("", [for i in range(129) : "z"])) = "v"
    }
  }

  expect_failures = [var.tags]
}

run "valid_tag_values_plus_one_over_long_value_rejected" {
  command = plan

  variables {
    tags = {
      Team = "infra"
      zzzz = join("", [for i in range(257) : "v"])
    }
  }

  expect_failures = [var.tags]
}

# --------------------------------------------------------------------------------------------------
# manifest_path. Null renders the template bundled with the module; a caller with an exotic node
# class points this at their own file and keeps the module's validation and output contract.
# --------------------------------------------------------------------------------------------------

run "manifest_path_null_uses_the_bundled_template" {
  command = plan

  variables {
    manifest_path = null
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).kind == "EC2NodeClass"
    error_message = "the bundled template is no longer rendered when manifest_path is null"
  }
}

# `path.module` is not in scope in a test file's variables block, so these paths are relative to the
# process working directory -- which is this module's directory, where `tofu test` is run.
run "manifest_path_pointing_at_the_bundled_template_explicitly_accepted" {
  command = plan

  variables {
    manifest_path = "templates/ec2nodeclass.yaml.tftpl"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).kind == "EC2NodeClass"
    error_message = "an explicit manifest_path to the bundled template was rejected"
  }
}

# Proves the override is actually HONOURED rather than silently falling back to the bundled
# template. The substituted file is the captured fixture, which contains no template directives and
# pins three subnet ids of its own -- so rendering three terms while the caller passed one can only
# happen if var.manifest_path won.
run "manifest_path_substituting_another_file_is_honoured" {
  command = plan

  variables {
    manifest_path         = "tests/fixtures/nodeclass-al2023.yaml"
    subnet_selector_terms = [{ id = "subnet-xxxxx" }]
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.subnetSelectorTerms) == 3
    error_message = "a substituted manifest_path was ignored and the bundled template rendered instead"
  }
}

# Checked with fileexists() in a validation block so the error names the variable, rather than being
# left to templatefile() to fail with a bare filesystem message.
run "manifest_path_that_does_not_exist_rejected" {
  command = plan

  variables {
    manifest_path = "./does-not-exist.tftpl"
  }

  expect_failures = [var.manifest_path]
}
