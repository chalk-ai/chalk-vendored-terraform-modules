# Characterization against a real object.
#
# tests/fixtures/nodeclass-al2023.yaml is an EC2NodeClass captured from a live customer cluster and
# anonymised: every identifier is a placeholder, and the server-populated metadata (uid,
# resourceVersion, creationTimestamp, hashes, last-applied-configuration) and the whole status block
# are stripped, since none of it is authored input.
#
# This suite replays the fixture's authored values as module inputs and requires the rendered
# manifest to match it structurally. It is what stops the module drifting away from the shape that
# is already running in production.
#
# The fixture path is relative to the process working directory -- this module's directory, where
# `tofu test` is run. `path.module` is not in scope inside a test file.

mock_provider "kubectl" {}

variables {
  # Every one of these is read straight off the fixture.
  name                  = "al2023"
  cluster_name          = "example-cluster"
  node_role_name        = "example-cluster-Managed-Node-Role"
  ami_alias             = "al2023@latest"
  boot_volume_size      = "50Gi"
  subnet_selector_terms = [{ id = "subnet-xxxxx" }, { id = "subnet-yyyyy" }, { id = "subnet-zzzzz" }]
}

# --------------------------------------------------------------------------------------------------
# Whole-object equality. Compared through yamldecode on both sides: the fixture carries comments and
# a different key order, and templatefile output is whitespace- and key-order-sensitive, so a string
# comparison would fail on cosmetics while proving nothing.
# --------------------------------------------------------------------------------------------------

run "rendered_manifest_matches_the_captured_node_class" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest) == yamldecode(file("tests/fixtures/nodeclass-al2023.yaml"))
    error_message = "the rendered EC2NodeClass no longer matches the captured customer object; a field was added, removed or changed"
  }
}

# The equality above must be able to fail. Changing one authored value has to break it, otherwise it
# is proving nothing.
run "whole_object_equality_is_sensitive_to_a_single_changed_field" {
  command = plan

  variables {
    boot_volume_size = "200Gi"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest) != yamldecode(file("tests/fixtures/nodeclass-al2023.yaml"))
    error_message = "changing boot_volume_size did not change the rendered manifest, so the whole-object comparison is vacuous"
  }
}

# --------------------------------------------------------------------------------------------------
# Field-by-field, so a failure names the field rather than only the object. Each condition compares
# the render against the fixture rather than against a literal, so the fixture stays the single
# source of truth.
# --------------------------------------------------------------------------------------------------

run "fixture_fields_match_individually" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).apiVersion == yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).apiVersion
    error_message = "apiVersion diverged from the captured object"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).kind == yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).kind
    error_message = "kind diverged from the captured object"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).metadata == yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).metadata
    error_message = "metadata diverged from the captured object; the module is emitting labels, annotations or a namespace the real object does not carry"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.amiSelectorTerms == yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).spec.amiSelectorTerms
    error_message = "amiSelectorTerms diverged from the captured object"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.role == yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).spec.role
    error_message = "role diverged from the captured object"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).spec.subnetSelectorTerms
    error_message = "subnetSelectorTerms diverged from the captured object"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.securityGroupSelectorTerms == yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).spec.securityGroupSelectorTerms
    error_message = "securityGroupSelectorTerms diverged from the captured object, including their order -- terms are ORed, so order is cosmetic to Karpenter but contractual to this test"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.tags == yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).spec.tags
    error_message = "spec.tags diverged from the captured object; with no caller tags the render must be exactly the discovery tag"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.metadataOptions == yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).spec.metadataOptions
    error_message = "metadataOptions diverged from the captured object"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.blockDeviceMappings == yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).spec.blockDeviceMappings
    error_message = "blockDeviceMappings diverged from the captured object"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.userData == yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).spec.userData
    error_message = "userData diverged from the captured object"
  }
}

# --------------------------------------------------------------------------------------------------
# The captured object's absences are part of the contract. It carries no amiFamily -- the alias
# implies it -- and no instanceStorePolicy or kubelet block, so neither may the render.
# --------------------------------------------------------------------------------------------------

run "the_render_has_exactly_the_captured_objects_spec_keys" {
  command = plan

  assert {
    condition     = keys(yamldecode(output.rendered_manifest).spec) == keys(yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).spec)
    error_message = "the rendered spec has a different key set from the captured object; the module is emitting or dropping a field"
  }
  # An assert condition must reference something from the configuration, so both sides are checked
  # in one expression rather than the fixture alone.
  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.amiFamily) && !can(yamldecode(file("tests/fixtures/nodeclass-al2023.yaml")).spec.amiFamily)
    error_message = "amiFamily appeared on the render or on the fixture; an amiSelectorTerms alias implies amiFamily and the two are mutually exclusive"
  }
}
