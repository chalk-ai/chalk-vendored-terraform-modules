# spec.template.spec.requirements -- the full single / multi / mixed matrix for every rule.
#
# Each mixed case puts the invalid element LAST. A validation written as var.requirements[0].operator
# passes every single-element and every all-valid run below; only a trailing bad element forces the
# alltrue([for r in ...]) form.
#
# One violation per run: expect_failures proves that the listed object was rejected, not which of its
# validation blocks fired, so each rejecting run is built to break exactly one rule.

mock_provider "kubectl" {}

variables {
  name              = "example-pool"
  ec2nodeclass_name = "al2023"
}

# --------------------------------------------------------------------------------------------------
# operator enum -- eight values. Gte and Lte ARE valid in v1.
# --------------------------------------------------------------------------------------------------

run "operator_single_good" {
  command = plan

  variables {
    requirements = [{ key = "karpenter.k8s.aws/instance-family", operator = "In", values = ["c7a"] }]
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.requirements[0].operator == "In"
    error_message = "a single In requirement no longer renders"
  }
  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.requirements[0].values == ["c7a"]
    error_message = "a single In requirement's values no longer render"
  }
}

run "operator_multi_good_all_eight" {
  command = plan

  variables {
    requirements = [
      { key = "a", operator = "In", values = ["x"] },
      { key = "b", operator = "NotIn", values = ["y"] },
      { key = "c", operator = "Exists" },
      { key = "d", operator = "DoesNotExist" },
      { key = "karpenter.k8s.aws/instance-cpu", operator = "Gt", values = ["3"] },
      { key = "karpenter.k8s.aws/instance-cpu", operator = "Lt", values = ["64"] },
      { key = "karpenter.k8s.aws/instance-memory", operator = "Gte", values = ["0"] },
      { key = "karpenter.k8s.aws/instance-memory", operator = "Lte", values = ["131072"] },
    ]
  }

  assert {
    condition = [
      for r in yamldecode(output.rendered_manifest).spec.template.spec.requirements : r.operator
    ] == ["In", "NotIn", "Exists", "DoesNotExist", "Gt", "Lt", "Gte", "Lte"]
    error_message = "one of the eight v1 operators no longer round-trips; Gte and Lte in particular are valid"
  }
}

run "operator_single_bad_wrong_case" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "in", values = ["x"] }]
  }

  expect_failures = [var.requirements]
}

run "operator_single_bad_unknown" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "Contains", values = ["x"] }]
  }

  expect_failures = [var.requirements]
}

run "operator_multi_bad_three_unknown" {
  command = plan

  variables {
    requirements = [
      { key = "a", operator = "Contains", values = ["x"] },
      { key = "b", operator = "Matches", values = ["y"] },
      { key = "c", operator = "Like", values = ["z"] },
    ]
  }

  expect_failures = [var.requirements]
}

run "operator_mixed_bad_last" {
  command = plan

  variables {
    requirements = [
      { key = "a", operator = "In", values = ["x"] },
      { key = "b", operator = "NotIn", values = ["y"] },
      { key = "c", operator = "Contains", values = ["z"] },
    ]
  }

  expect_failures = [var.requirements]
}

# --------------------------------------------------------------------------------------------------
# In requires values
# --------------------------------------------------------------------------------------------------

run "in_single_good_with_values" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "In", values = ["c7a"] }]
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.requirements[0].values == ["c7a"]
    error_message = "In with values no longer renders"
  }
}

run "in_multi_good_three_with_values" {
  command = plan

  variables {
    requirements = [
      { key = "a", operator = "In", values = ["x"] },
      { key = "b", operator = "In", values = ["y", "z"] },
      { key = "c", operator = "In", values = ["w"] },
    ]
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.spec.requirements) == 3
    error_message = "three In requirements no longer all render"
  }
}

run "in_single_bad_empty_values" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "In", values = [] }]
  }

  expect_failures = [var.requirements]
}

run "in_multi_bad_all_empty_values" {
  command = plan

  variables {
    requirements = [
      { key = "a", operator = "In", values = [] },
      { key = "b", operator = "In", values = [] },
      { key = "c", operator = "In", values = [] },
    ]
  }

  expect_failures = [var.requirements]
}

run "in_mixed_bad_last" {
  command = plan

  variables {
    requirements = [
      { key = "a", operator = "In", values = ["x"] },
      { key = "b", operator = "In", values = ["y"] },
      { key = "c", operator = "In", values = [] },
    ]
  }

  expect_failures = [var.requirements]
}

# --------------------------------------------------------------------------------------------------
# Exists / DoesNotExist require EMPTY values
# --------------------------------------------------------------------------------------------------

run "exists_single_good_empty_values" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "Exists", values = [] }]
  }

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.template.spec.requirements[0].values)
    error_message = "an Exists requirement now renders an empty values key instead of omitting it"
  }
}

run "exists_multi_good_both_empty" {
  command = plan

  variables {
    requirements = [
      { key = "a", operator = "Exists", values = [] },
      { key = "b", operator = "DoesNotExist", values = [] },
    ]
  }

  assert {
    condition = [
      for r in yamldecode(output.rendered_manifest).spec.template.spec.requirements : r.operator
    ] == ["Exists", "DoesNotExist"]
    error_message = "Exists and DoesNotExist no longer both render with empty values"
  }
}

run "exists_single_bad_with_values" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "Exists", values = ["x"] }]
  }

  expect_failures = [var.requirements]
}

run "exists_multi_bad_both_with_values" {
  command = plan

  variables {
    requirements = [
      { key = "a", operator = "Exists", values = ["x"] },
      { key = "b", operator = "DoesNotExist", values = ["y"] },
    ]
  }

  expect_failures = [var.requirements]
}

run "exists_mixed_bad_last" {
  command = plan

  variables {
    requirements = [
      { key = "a", operator = "Exists", values = [] },
      { key = "b", operator = "DoesNotExist", values = ["y"] },
    ]
  }

  expect_failures = [var.requirements]
}

# --------------------------------------------------------------------------------------------------
# Gt / Lt / Gte / Lte -- exactly one value, a non-negative integer
# --------------------------------------------------------------------------------------------------

run "ordered_operator_single_good" {
  command = plan

  variables {
    requirements = [{ key = "karpenter.k8s.aws/instance-cpu", operator = "Gt", values = ["3"] }]
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.requirements[0].values == ["3"]
    error_message = "Gt with a single integer value no longer renders"
  }
}

run "ordered_operator_multi_good_all_four" {
  command = plan

  variables {
    requirements = [
      { key = "a", operator = "Gt", values = ["1"] },
      { key = "b", operator = "Lt", values = ["2"] },
      { key = "c", operator = "Gte", values = ["0"] },
      { key = "d", operator = "Lte", values = ["999"] },
    ]
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.spec.requirements) == 4
    error_message = "the four ordered operators no longer all render with one non-negative integer each"
  }
}

run "ordered_operator_single_bad_no_values" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "Gt", values = [] }]
  }

  expect_failures = [var.requirements]
}

run "ordered_operator_single_bad_two_values" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "Gt", values = ["3", "4"] }]
  }

  expect_failures = [var.requirements]
}

run "ordered_operator_single_bad_negative" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "Gt", values = ["-1"] }]
  }

  expect_failures = [var.requirements]
}

run "ordered_operator_single_bad_non_integer" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "Gt", values = ["x"] }]
  }

  expect_failures = [var.requirements]
}

run "ordered_operator_multi_bad_all_four_two_values" {
  command = plan

  variables {
    requirements = [
      { key = "a", operator = "Gt", values = ["1", "2"] },
      { key = "b", operator = "Lt", values = ["1", "2"] },
      { key = "c", operator = "Gte", values = ["1", "2"] },
      { key = "d", operator = "Lte", values = ["1", "2"] },
    ]
  }

  expect_failures = [var.requirements]
}

run "ordered_operator_mixed_bad_last" {
  command = plan

  variables {
    requirements = [
      { key = "a", operator = "Gt", values = ["3"] },
      { key = "b", operator = "Lte", values = ["3", "4"] },
    ]
  }

  expect_failures = [var.requirements]
}

# --------------------------------------------------------------------------------------------------
# minValues -- must not exceed the values it selects from, and is itself bounded 1-50
# --------------------------------------------------------------------------------------------------

run "min_values_single_good" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "In", values = ["x", "y", "z"], minValues = 2 }]
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.requirements[0].minValues == 2
    error_message = "minValues no longer renders as an unquoted number"
  }
}

run "min_values_omitted_is_not_emitted" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "In", values = ["x"] }]
  }

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.template.spec.requirements[0].minValues)
    error_message = "minValues is emitted when the caller set none"
  }
}

run "min_values_single_bad_zero" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "In", values = ["x"], minValues = 0 }]
  }

  expect_failures = [var.requirements]
}

run "min_values_single_bad_above_fifty" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "In", values = ["x"], minValues = 51 }]
  }

  expect_failures = [var.requirements]
}

# --------------------------------------------------------------------------------------------------
# MaxItems = 100 -- and the boundary either side of it
# --------------------------------------------------------------------------------------------------

run "cap_single_requirement" {
  command = plan

  variables {
    requirements = [{ key = "a", operator = "Exists" }]
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.spec.requirements) == 1
    error_message = "a one-element requirements list no longer renders"
  }
}

run "cap_boundary_100_accepted" {
  command = plan

  variables {
    requirements = [for i in range(100) : { key = "k${i}", operator = "Exists" }]
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.spec.requirements) == 100
    error_message = "exactly 100 requirements is the documented MaxItems and must be accepted"
  }
}

run "cap_boundary_101_rejected" {
  command = plan

  variables {
    requirements = [for i in range(101) : { key = "k${i}", operator = "Exists" }]
  }

  expect_failures = [var.requirements]
}

run "cap_multi_bad_150" {
  command = plan

  variables {
    requirements = [for i in range(150) : { key = "k${i}", operator = "Exists" }]
  }

  expect_failures = [var.requirements]
}

# 100 valid entries plus one malformed one: over the cap AND carrying a bad element. Both rules hang
# off var.requirements, so this is still a single rejected object.
run "cap_mixed_100_valid_plus_one_malformed" {
  command = plan

  variables {
    requirements = concat(
      [for i in range(100) : { key = "k${i}", operator = "Exists" }],
      [{ key = "bad", operator = "Contains", values = ["x"] }],
    )
  }

  expect_failures = [var.requirements]
}
