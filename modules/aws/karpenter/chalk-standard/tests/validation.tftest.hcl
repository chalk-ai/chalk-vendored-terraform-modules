# One violation per run block, so that each expect_failures identifies exactly one
# variable and cannot pass for the wrong reason.

mock_provider "kubectl" {}

variables {
  cluster_name = "example-cluster"
  subnets      = ["subnet-xxxxx"]
}

run "empty_subnets_are_rejected" {
  command = plan

  variables {
    subnets = []
  }

  expect_failures = [var.subnets]
}

run "empty_cluster_name_is_rejected" {
  command = plan

  variables {
    cluster_name = ""
  }

  expect_failures = [var.cluster_name]
}

run "whitespace_only_cluster_name_is_rejected" {
  command = plan

  variables {
    cluster_name = "   "
  }

  expect_failures = [var.cluster_name]
}

run "node_role_name_as_an_arn_is_rejected" {
  command = plan

  variables {
    node_role_name = "arn:aws:iam::123456789012:role/example-cluster-Managed-Node-Role"
  }

  expect_failures = [var.node_role_name]
}

run "blank_node_role_name_is_rejected" {
  command = plan

  variables {
    node_role_name = " "
  }

  expect_failures = [var.node_role_name]
}
