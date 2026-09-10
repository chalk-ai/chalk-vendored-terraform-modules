# var.subnets is the module's primary input. It is a plain list(string), rendered as one
# `{ id = <subnet> }` selector term per element, in order.
#
# Rejection of an empty list lives in tests/validation.tftest.hcl, because
# expect_failures needs a run block of its own.

mock_provider "kubectl" {}

variables {
  cluster_name = "example-cluster"
  subnets      = ["subnet-xxxxx"]
}

run "single_subnet" {
  command = plan

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.al2023_node_class.yaml_body)).spec.subnetSelectorTerms == [
      { id = "subnet-xxxxx" },
    ]
    error_message = "a single subnet must render as exactly one selector term"
  }
  assert {
    condition     = output.subnet_selector_terms == [{ id = "subnet-xxxxx" }]
    error_message = "the subnet_selector_terms output no longer mirrors what is rendered"
  }
}

run "multiple_subnets_preserve_input_order" {
  command = plan

  variables {
    subnets = ["subnet-xxxxx", "subnet-yyyyy", "subnet-zzzzz"]
  }

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.al2023_node_class.yaml_body)).spec.subnetSelectorTerms == [
      { id = "subnet-xxxxx" },
      { id = "subnet-yyyyy" },
      { id = "subnet-zzzzz" },
    ]
    error_message = "subnets must render one term each, in the order given -- Karpenter treats selector terms as an OR set, but a reordering here is still an unexplained diff on every existing cluster"
  }
}

run "all_three_node_classes_share_the_same_subnet_terms" {
  command = plan

  variables {
    subnets = ["subnet-xxxxx", "subnet-yyyyy"]
  }

  # A node class that can only reach a subset of the subnets is the failure mode this
  # guards: offline or gVisor capacity silently pinned to one AZ.
  assert {
    condition = (
      yamldecode(nonsensitive(kubectl_manifest.al2023_node_class.yaml_body)).spec.subnetSelectorTerms ==
      yamldecode(nonsensitive(kubectl_manifest.al2023_lssd_node_class.yaml_body)).spec.subnetSelectorTerms
    )
    error_message = "al2023 and al2023-offline-lssd no longer select the same subnets"
  }
  assert {
    condition = (
      yamldecode(nonsensitive(kubectl_manifest.al2023_node_class.yaml_body)).spec.subnetSelectorTerms ==
      yamldecode(nonsensitive(kubectl_manifest.gvisor_node_class[0].yaml_body)).spec.subnetSelectorTerms
    )
    error_message = "al2023 and gvisor no longer select the same subnets"
  }
  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.gvisor_node_class[0].yaml_body)).spec.subnetSelectorTerms == [
      { id = "subnet-xxxxx" },
      { id = "subnet-yyyyy" },
    ]
    error_message = "the shared subnet terms are not the ones that were passed in"
  }
}
