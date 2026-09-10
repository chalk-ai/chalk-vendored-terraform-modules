# The node role name is derived from the cluster name by Chalk convention, and is
# overridable for clusters whose managed node role was named some other way.

mock_provider "kubectl" {}

variables {
  cluster_name = "example-cluster"
  subnets      = ["subnet-xxxxx"]
}

run "role_defaults_to_the_chalk_convention" {
  command = plan

  assert {
    condition     = output.node_role_name == "example-cluster-Managed-Node-Role"
    error_message = "node_role_name must default to \"<cluster_name>-Managed-Node-Role\""
  }
  assert {
    condition     = yamldecode(nonsensitive(kubectl_manifest.al2023_node_class.yaml_body)).spec.role == "example-cluster-Managed-Node-Role"
    error_message = "the derived role name is not what actually lands in the EC2NodeClass"
  }
}

run "explicit_role_overrides_the_derived_one" {
  command = plan

  variables {
    node_role_name = "some-other-node-role"
  }

  assert {
    condition     = output.node_role_name == "some-other-node-role"
    error_message = "an explicit node_role_name must win over the derived default"
  }
  assert {
    condition = alltrue([
      for body in [
        nonsensitive(kubectl_manifest.al2023_node_class.yaml_body),
        nonsensitive(kubectl_manifest.al2023_lssd_node_class.yaml_body),
        nonsensitive(kubectl_manifest.gvisor_node_class[0].yaml_body),
      ] : yamldecode(body).spec.role == "some-other-node-role"
    ])
    error_message = "every EC2NodeClass must use the overridden role; a node class left on the derived name would launch nodes that cannot join the cluster"
  }
}
