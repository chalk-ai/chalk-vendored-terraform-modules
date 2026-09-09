# The seam: ec2nodeclass_name, the v1 nodeClassRef triple it renders into, and lookup_ec2nodeclass.
#
# What is NOT tested here, deliberately: whether the data source read is deferred to apply. That is a
# dependency-graph property of the CALLER's configuration -- the read defers only when the block
# depends on a resource that is changing in the current plan, which happens when ec2nodeclass_name
# comes from the node class module's `name` output. mock_provider cannot construct that, so faking it
# would assert nothing. What is testable, and is tested, is that the data source is in the plan when
# lookup_ec2nodeclass is true and out of it when false. The literal-versus-module-reference
# distinction is documented in the README instead.

mock_provider "kubectl" {}

variables {
  name              = "example-pool"
  ec2nodeclass_name = "al2023"
}

# --------------------------------------------------------------------------------------------------
# nodeClassRef -- group and kind became strictly required in Karpenter v1.1.0, so the module renders
# the whole triple and a caller never hand-writes it.
# --------------------------------------------------------------------------------------------------

run "node_class_ref_renders_the_v1_triple" {
  command = plan

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef == {
      group = "karpenter.k8s.aws"
      kind  = "EC2NodeClass"
      name  = "al2023"
    }
    error_message = "nodeClassRef no longer renders the v1 group/kind/name triple"
  }
}

run "node_class_ref_never_carries_the_v1beta1_api_version_key" {
  command = plan

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef.apiVersion)
    error_message = "nodeClassRef emits apiVersion, which v1 replaced with group"
  }
}

# --------------------------------------------------------------------------------------------------
# ec2nodeclass_name
# --------------------------------------------------------------------------------------------------

run "ec2nodeclass_name_single_good" {
  command = plan

  variables {
    ec2nodeclass_name = "al2023"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef.name == "al2023"
    error_message = "a literal node class name no longer reaches nodeClassRef.name"
  }
}

run "ec2nodeclass_name_multi_good_shortest" {
  command = plan

  variables {
    ec2nodeclass_name = "a"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef.name == "a"
    error_message = "a one-character node class name no longer renders"
  }
}

run "ec2nodeclass_name_boundary_63_characters_accepted" {
  command = plan

  variables {
    ec2nodeclass_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef.name) == 63
    error_message = "a 63-character node class name no longer renders"
  }
}

run "ec2nodeclass_name_empty_rejected" {
  command = plan

  variables {
    ec2nodeclass_name = ""
  }

  expect_failures = [var.ec2nodeclass_name]
}

run "ec2nodeclass_name_uppercase_rejected" {
  command = plan

  variables {
    ec2nodeclass_name = "AL2023"
  }

  expect_failures = [var.ec2nodeclass_name]
}

run "ec2nodeclass_name_boundary_64_characters_rejected" {
  command = plan

  variables {
    ec2nodeclass_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  expect_failures = [var.ec2nodeclass_name]
}

# --------------------------------------------------------------------------------------------------
# lookup_ec2nodeclass
# --------------------------------------------------------------------------------------------------

run "lookup_true_puts_the_data_source_in_the_plan" {
  command = plan

  variables {
    lookup_ec2nodeclass = true
  }

  assert {
    condition     = length(data.kubectl_manifest.ec2nodeclass) == 1
    error_message = "lookup_ec2nodeclass = true no longer reads the EC2NodeClass, so a missing node class would surface at apply instead of at plan"
  }
  assert {
    condition     = data.kubectl_manifest.ec2nodeclass[0].api_version == "karpenter.k8s.aws/v1"
    error_message = "the node class lookup no longer reads the v1 API group"
  }
  assert {
    condition     = data.kubectl_manifest.ec2nodeclass[0].kind == "EC2NodeClass"
    error_message = "the node class lookup no longer reads kind EC2NodeClass"
  }
  assert {
    condition     = data.kubectl_manifest.ec2nodeclass[0].name == "al2023"
    error_message = "the node class lookup no longer reads the name the pool references"
  }
}

run "lookup_false_removes_the_data_source_from_the_plan" {
  command = plan

  variables {
    lookup_ec2nodeclass = false
  }

  assert {
    condition     = length(data.kubectl_manifest.ec2nodeclass) == 0
    error_message = "lookup_ec2nodeclass = false no longer opts out of the read, so a node class created elsewhere in the same root module would fail the plan"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.nodeClassRef.name == "al2023"
    error_message = "opting out of the lookup changed what the pool references"
  }
}

# Defaults OFF. `true` cannot work when the node class is created in the same run -- not even via
# the module-output reference -- because the read is not deferred. Proven against a real cluster
# 2026-09-09; see the comment on the data source in main.tf.
run "lookup_defaults_to_false" {
  command = plan

  assert {
    condition     = length(data.kubectl_manifest.ec2nodeclass) == 0
    error_message = "lookup_ec2nodeclass no longer defaults to false, which breaks the canonical two-module example on first plan"
  }
}
