# The three identifier inputs: cluster_name, node_role_name and name.
#
# All three are scalars, so per the design there are no "mixed" cases to write -- that is stated
# here rather than faked with a contrived list.
#
# Boundary lengths are BUILT with `join`/`range` rather than typed out as literals, so a
# hand-miscounted string cannot make a boundary run pass or fail for the wrong reason.
#
# Each variable carries two disjoint validations -- a charset rule and a length rule -- so every
# negative run below trips exactly one of them. `expect_failures` proves rejection without matching
# on error_message, so overlapping rules would leave a passing run undiagnosable.

mock_provider "kubectl" {}

variables {
  cluster_name          = "example-cluster"
  node_role_name        = "example-cluster-Managed-Node-Role"
  subnet_selector_terms = [{ id = "subnet-xxxxx" }]
}

# --------------------------------------------------------------------------------------------------
# cluster_name -- single good, multi good
#
# It feeds three places at once: both securityGroupSelectorTerms and the default discovery tag. A
# wrong value therefore fails silently in three ways rather than one.
# --------------------------------------------------------------------------------------------------

run "cluster_name_representative_value" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.securityGroupSelectorTerms[0].tags["karpenter.sh/discovery"] == "example-cluster"
    error_message = "cluster_name no longer reaches the karpenter.sh/discovery security group selector term"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.securityGroupSelectorTerms[1].tags["aws:eks:cluster-name"] == "example-cluster"
    error_message = "cluster_name no longer reaches the aws:eks:cluster-name security group selector term"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.tags["karpenter.sh/discovery"] == "example-cluster"
    error_message = "cluster_name no longer reaches the default instance discovery tag"
  }
}

run "cluster_name_single_character_accepted" {
  command = plan

  variables {
    cluster_name = "a"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.tags["karpenter.sh/discovery"] == "a"
    error_message = "a one-character cluster_name was rejected or mangled"
  }
}

run "cluster_name_at_the_100_character_boundary_accepted" {
  command = plan

  variables {
    cluster_name = join("", [for i in range(100) : "a"])
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.tags["karpenter.sh/discovery"]) == 100
    error_message = "a cluster_name at the 100-character EKS boundary was rejected or truncated"
  }
}

run "cluster_name_with_underscores_accepted" {
  command = plan

  variables {
    cluster_name = "example_cluster-1"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.role == "example-cluster-Managed-Node-Role"
    error_message = "an underscore in cluster_name was rejected; EKS permits letters, digits, hyphens and underscores"
  }
}

# --------------------------------------------------------------------------------------------------
# cluster_name -- single bad
# --------------------------------------------------------------------------------------------------

run "empty_cluster_name_rejected" {
  command = plan

  variables {
    cluster_name = ""
  }

  expect_failures = [var.cluster_name]
}

run "cluster_name_with_a_leading_dash_rejected" {
  command = plan

  variables {
    cluster_name = "-leading-dash"
  }

  expect_failures = [var.cluster_name]
}

run "cluster_name_one_over_the_100_character_boundary_rejected" {
  command = plan

  variables {
    cluster_name = join("", [for i in range(101) : "a"])
  }

  expect_failures = [var.cluster_name]
}

# --------------------------------------------------------------------------------------------------
# node_role_name -- single good, multi good
# --------------------------------------------------------------------------------------------------

run "node_role_name_representative_value" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.role == "example-cluster-Managed-Node-Role"
    error_message = "node_role_name no longer reaches spec.role"
  }
}

run "node_role_name_single_character_accepted" {
  command = plan

  variables {
    node_role_name = "r"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.role == "r"
    error_message = "a one-character node_role_name was rejected"
  }
}

run "node_role_name_at_the_64_character_boundary_accepted" {
  command = plan

  variables {
    node_role_name = join("", [for i in range(64) : "r"])
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.role) == 64
    error_message = "a node_role_name at the 64-character IAM boundary was rejected or truncated"
  }
}

# IAM role names allow +=,.@- as well as word characters. A path-prefixed role is NOT accepted,
# because spec.role takes the bare name.
run "node_role_name_with_permitted_punctuation_accepted" {
  command = plan

  variables {
    node_role_name = "chalk.node-role_v2+eks@example"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.role == "chalk.node-role_v2+eks@example"
    error_message = "IAM-legal punctuation in node_role_name was rejected"
  }
}

# --------------------------------------------------------------------------------------------------
# node_role_name -- single bad
# --------------------------------------------------------------------------------------------------

run "empty_node_role_name_rejected" {
  command = plan

  variables {
    node_role_name = ""
  }

  expect_failures = [var.node_role_name]
}

# The single most likely mistake for this field. spec.role takes a NAME; an ARN makes Karpenter fail
# to resolve an instance profile, and nodes never launch.
run "node_role_arn_instead_of_name_rejected" {
  command = plan

  variables {
    node_role_name = "arn:aws:iam::123456789012:role/example-cluster-Managed-Node-Role"
  }

  expect_failures = [var.node_role_name]
}

run "node_role_name_one_over_the_64_character_boundary_rejected" {
  command = plan

  variables {
    node_role_name = join("", [for i in range(65) : "r"])
  }

  expect_failures = [var.node_role_name]
}

# --------------------------------------------------------------------------------------------------
# name -- single good, multi good
# --------------------------------------------------------------------------------------------------

run "name_representative_value" {
  command = plan

  variables {
    name = "al2023"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "al2023"
    error_message = "name no longer reaches metadata.name"
  }
}

run "name_single_character_accepted" {
  command = plan

  variables {
    name = "a"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "a"
    error_message = "a one-character name was rejected"
  }
}

run "name_with_interior_hyphens_accepted" {
  command = plan

  variables {
    name = "a-b-c"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).metadata.name == "a-b-c"
    error_message = "interior hyphens in name were rejected"
  }
}

run "name_at_the_63_character_boundary_accepted" {
  command = plan

  variables {
    name = join("", [for i in range(63) : "n"])
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).metadata.name) == 63
    error_message = "a name at the 63-character RFC 1123 label boundary was rejected or truncated"
  }
}

# --------------------------------------------------------------------------------------------------
# name -- single bad
# --------------------------------------------------------------------------------------------------

run "empty_name_rejected" {
  command = plan

  variables {
    name = ""
  }

  expect_failures = [var.name]
}

run "uppercase_name_rejected" {
  command = plan

  variables {
    name = "AL2023"
  }

  expect_failures = [var.name]
}

run "name_with_a_leading_dash_rejected" {
  command = plan

  variables {
    name = "-x"
  }

  expect_failures = [var.name]
}

run "name_with_a_trailing_dash_rejected" {
  command = plan

  variables {
    name = "x-"
  }

  expect_failures = [var.name]
}

run "name_one_over_the_63_character_boundary_rejected" {
  command = plan

  variables {
    name = join("", [for i in range(64) : "n"])
  }

  expect_failures = [var.name]
}
