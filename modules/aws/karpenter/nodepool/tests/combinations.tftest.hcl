# Rules that span two or more attributes, and are therefore invisible to the single-property
# matrices in the other test files. Each such rule gets its own run here.
#
# The requirements-plus-labels cap is the one rule that cannot live in a `validation` block at all: a
# validation may only reference its own variable, and this rule spans two. It is a `precondition` on
# kubectl_manifest.this, so it is that resource -- not a variable -- that expect_failures names.

mock_provider "kubectl" {}

variables {
  name              = "example-pool"
  ec2nodeclass_name = "al2023"
}

# --------------------------------------------------------------------------------------------------
# Operator arity is a per-ELEMENT rule pairing operator with values, not a per-field rule.
# --------------------------------------------------------------------------------------------------

run "exists_with_non_empty_values_rejected" {
  command = plan

  variables {
    requirements = [{ key = "karpenter.k8s.aws/instance-family", operator = "Exists", values = ["c7a"] }]
  }

  expect_failures = [var.requirements]
}

run "gt_with_two_values_rejected" {
  command = plan

  variables {
    requirements = [{ key = "karpenter.k8s.aws/instance-cpu", operator = "Gt", values = ["3", "4"] }]
  }

  expect_failures = [var.requirements]
}

# --------------------------------------------------------------------------------------------------
# minValues pairs with the length of the values list it selects from.
# --------------------------------------------------------------------------------------------------

run "min_values_three_with_two_values_rejected" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "In", values = ["x", "y"], minValues = 3 }]
  }

  expect_failures = [var.requirements]
}

run "min_values_three_with_three_values_accepted" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "In", values = ["x", "y", "z"], minValues = 3 }]
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.requirements[0].minValues == 3
    error_message = "minValues equal to the values length is the boundary and must be accepted"
  }
}

# --------------------------------------------------------------------------------------------------
# A budget's schedule and duration are meaningful only as a pair.
# --------------------------------------------------------------------------------------------------

run "budget_schedule_without_duration_rejected" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", schedule = "0 9 * * mon-fri" }] }
  }

  expect_failures = [var.disruption]
}

run "budget_duration_without_schedule_rejected" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", duration = "8h" }] }
  }

  expect_failures = [var.disruption]
}

run "budget_schedule_with_duration_accepted" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", schedule = "0 9 * * mon-fri", duration = "8h" }] }
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.disruption.budgets == [
      { nodes = "10%", schedule = "0 9 * * mon-fri", duration = "8h" }
    ]
    error_message = "a budget with both schedule and duration no longer renders both"
  }
}

# --------------------------------------------------------------------------------------------------
# Labels propagate onto every NodeClaim as requirements and count toward the SAME MaxItems=100 cap as
# spec.requirements. 60 + 40 is the boundary; 60 + 41 is over it, even though neither input alone is.
#
# BOTH runs opt out of chalk_managed, not just the accepted one. The stamped label takes one of the
# same 100 slots, so with the toggle on the boundary moves to 60 + 39 -- and a pair measured under
# different settings would not be a boundary pair at all: 60 + 41 would still be rejected, but for a
# count the caller did not write. The moved boundary is covered in chalk_managed.tftest.hcl.
# --------------------------------------------------------------------------------------------------

run "sixty_requirements_plus_forty_labels_accepted" {
  command = plan

  variables {
    requirements  = [for i in range(60) : { key = "k${i}", operator = "Exists" }]
    labels        = { for i in range(40) : "label-${i}" => "v" }
    chalk_managed = false
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.spec.requirements) == 60
    error_message = "60 requirements alongside 40 labels is exactly the combined cap and must be accepted"
  }
  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.metadata.labels) == 40
    error_message = "40 labels alongside 60 requirements is exactly the combined cap and must be accepted"
  }
}

run "sixty_requirements_plus_forty_one_labels_rejected" {
  command = plan

  variables {
    requirements  = [for i in range(60) : { key = "k${i}", operator = "Exists" }]
    labels        = { for i in range(41) : "label-${i}" => "v" }
    chalk_managed = false
  }

  expect_failures = [kubectl_manifest.this]
}

# --------------------------------------------------------------------------------------------------
# A literal node class name against each setting of lookup_ec2nodeclass.
# --------------------------------------------------------------------------------------------------

run "literal_name_with_lookup_enabled_reads_the_node_class" {
  command = plan

  variables {
    ec2nodeclass_name   = "al2023"
    lookup_ec2nodeclass = true
  }

  assert {
    condition     = length(data.kubectl_manifest.ec2nodeclass) == 1
    error_message = "a literal node class name with lookup enabled no longer produces a plan-time read"
  }
}

run "literal_name_with_lookup_disabled_reads_nothing" {
  command = plan

  variables {
    ec2nodeclass_name   = "al2023"
    lookup_ec2nodeclass = false
  }

  assert {
    condition     = length(data.kubectl_manifest.ec2nodeclass) == 0
    error_message = "a literal node class name with lookup disabled still produces a read"
  }
}
