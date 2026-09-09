# Baseline shape of the rendered NodePool, plus the `name` and `manifest_path` inputs.
#
# `mock_provider "kubectl" {}` configures no provider and makes no cluster calls, so this suite runs
# with no kubeconfig, no cluster and no AWS credentials.
#
# Every assertion goes through yamldecode. templatefile output is whitespace- and key-order-
# sensitive, so asserting on the raw string would make the suite fail on cosmetic edits.

mock_provider "kubectl" {}

variables {
  name              = "example-pool"
  ec2nodeclass_name = "al2023"
}

# --------------------------------------------------------------------------------------------------
# The minimal pool: everything the module always emits, and nothing else.
# --------------------------------------------------------------------------------------------------

run "minimal_pool_renders_a_v1_nodepool" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).apiVersion == "karpenter.sh/v1"
    error_message = "apiVersion is no longer karpenter.sh/v1"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).kind == "NodePool"
    error_message = "kind is no longer NodePool"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "example-pool"
    error_message = "metadata.name no longer tracks var.name"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.requirements == []
    error_message = "requirements is no longer emitted as an empty list when the caller supplies none"
  }
}

# --------------------------------------------------------------------------------------------------
# Karpenter defaults are the API server's to supply. Restating them writes server-side values into
# the caller's manifest and produces diff noise against clusters that never had them.
#
# chalk_managed is switched OFF here so this run keeps measuring exactly what it always measured: the
# absence of Karpenter's own defaults. The chalk.ai/managed-by label is not a Karpenter default -- it
# is a Chalk value the module writes on purpose -- but with the toggle on it renders
# spec.template.metadata, which is one of the seven things this run asserts is absent. Opting out
# keeps all seven assertions about Karpenter defaults rather than about the Chalk stamp; the stamp's
# own rendering is covered in chalk_managed.tftest.hcl.
# --------------------------------------------------------------------------------------------------

run "no_karpenter_defaults_are_emitted" {
  command = plan

  variables {
    chalk_managed = false
  }

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.disruption)
    error_message = "a disruption block is emitted when the caller set none"
  }
  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.template.spec.expireAfter)
    error_message = "expireAfter is emitted when the caller set none"
  }
  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.template.spec.terminationGracePeriod)
    error_message = "terminationGracePeriod is emitted when the caller set none"
  }
  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.weight)
    error_message = "weight is emitted when the caller set none"
  }
  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.limits)
    error_message = "limits is emitted when the caller set none"
  }
  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.template.metadata)
    error_message = "template.metadata is emitted when the caller set no labels"
  }
  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.template.spec.taints)
    error_message = "taints is emitted when the caller set none"
  }
}

# --------------------------------------------------------------------------------------------------
# The manifest submitted to the cluster is the manifest the tests assert on.
# --------------------------------------------------------------------------------------------------

run "resource_submits_the_rendered_manifest" {
  command = plan

  assert {
    condition     = kubectl_manifest.this.yaml_body == output.rendered_manifest
    error_message = "the resource no longer submits the manifest exposed by the rendered_manifest output"
  }
}

# --------------------------------------------------------------------------------------------------
# name -- single good / single bad / multi good / boundary
# --------------------------------------------------------------------------------------------------

run "name_single_good" {
  command = plan

  variables {
    name = "online-c7a"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "online-c7a"
    error_message = "a plain DNS-1123 label name no longer renders"
  }
}

run "name_multi_good_shortest" {
  command = plan

  variables {
    name = "a"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "a"
    error_message = "a one-character name no longer renders"
  }
}

run "name_multi_good_hyphenated" {
  command = plan

  variables {
    name = "a-b-c"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "a-b-c"
    error_message = "a hyphenated name no longer renders"
  }
}

run "name_boundary_63_characters_accepted" {
  command = plan

  variables {
    name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).metadata.name) == 63
    error_message = "a 63-character name no longer renders"
  }
}

run "name_empty_rejected" {
  command = plan

  variables {
    name = ""
  }

  expect_failures = [var.name]
}

run "name_uppercase_rejected" {
  command = plan

  variables {
    name = "Example-Pool"
  }

  expect_failures = [var.name]
}

run "name_leading_dash_rejected" {
  command = plan

  variables {
    name = "-x"
  }

  expect_failures = [var.name]
}

run "name_boundary_64_characters_rejected" {
  command = plan

  variables {
    name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  expect_failures = [var.name]
}

# --------------------------------------------------------------------------------------------------
# manifest_path -- the bundled default, and a path that does not exist
# --------------------------------------------------------------------------------------------------

run "manifest_path_defaults_to_the_bundled_template" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).kind == "NodePool"
    error_message = "the bundled template no longer renders when manifest_path is null"
  }
}

run "manifest_path_missing_file_rejected" {
  command = plan

  variables {
    manifest_path = "./does-not-exist.tftpl"
  }

  expect_failures = [var.manifest_path]
}
