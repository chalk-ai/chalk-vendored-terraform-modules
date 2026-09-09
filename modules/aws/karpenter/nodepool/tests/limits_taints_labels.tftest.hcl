# spec.limits, spec.template.spec.taints and spec.template.metadata.labels.
#
# limits is a MAP keyed by resource name, not a fixed cpu/memory/gpu triple: Karpenter accepts any
# resource name, and nvidia.com/gpu and nodes are as legal as cpu.
#
# Maps have no element order, so the "mixed" row for a map means "several keys, some invalid" rather
# than "invalid element last"; only the list inputs can place the bad element last.

mock_provider "kubectl" {}

variables {
  name              = "example-pool"
  ec2nodeclass_name = "al2023"
}

# --------------------------------------------------------------------------------------------------
# limits
# --------------------------------------------------------------------------------------------------

run "limits_single_good" {
  command = plan

  variables {
    limits = { cpu = "500" }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.limits == { cpu = "500" }
    error_message = "a single cpu limit no longer renders, or no longer renders as a string"
  }
}

run "limits_multi_good_arbitrary_resource_names" {
  command = plan

  variables {
    limits = {
      cpu              = "500"
      memory           = "5000Gi"
      "nvidia.com/gpu" = "2"
      nodes            = "10"
    }
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.limits == {
      cpu              = "500"
      memory           = "5000Gi"
      "nvidia.com/gpu" = "2"
      nodes            = "10"
    }
    error_message = "limits no longer accepts arbitrary resource names; it must not be a fixed cpu/memory/gpu triple"
  }
}

run "limits_decimal_si_suffix_stays_a_string" {
  command = plan

  variables {
    limits = { cpu = "1k" }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.limits.cpu == "1k"
    error_message = "the decimal-SI quantity 1k no longer survives rendering as a string"
  }
}

run "limits_single_bad_empty_quantity" {
  command = plan

  variables {
    limits = { cpu = "" }
  }

  expect_failures = [var.limits]
}

run "limits_single_bad_non_quantity" {
  command = plan

  variables {
    limits = { cpu = "abc" }
  }

  expect_failures = [var.limits]
}

run "limits_multi_bad_three_malformed" {
  command = plan

  variables {
    limits = { cpu = "abc", memory = "lots", nodes = "many" }
  }

  expect_failures = [var.limits]
}

run "limits_mixed_bad" {
  command = plan

  variables {
    limits = { cpu = "500", memory = "abc" }
  }

  expect_failures = [var.limits]
}

# --------------------------------------------------------------------------------------------------
# taints -- effect
# --------------------------------------------------------------------------------------------------

run "taints_effect_single_good" {
  command = plan

  variables {
    taints = [{ key = "chalk.ai/managed-by", value = "chalk", effect = "NoSchedule" }]
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.spec.taints == [
      { key = "chalk.ai/managed-by", effect = "NoSchedule", value = "chalk" }
    ]
    error_message = "a single taint no longer renders with key, effect and value"
  }
}

run "taints_value_is_optional" {
  command = plan

  variables {
    taints = [{ key = "k", effect = "NoSchedule" }]
  }

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.template.spec.taints[0].value)
    error_message = "an omitted taint value is emitted anyway"
  }
}

run "taints_effect_multi_good_all_three" {
  command = plan

  variables {
    taints = [
      { key = "a", effect = "NoSchedule" },
      { key = "b", effect = "PreferNoSchedule" },
      { key = "c", effect = "NoExecute" },
    ]
  }

  assert {
    condition = [
      for t in yamldecode(output.rendered_manifest).spec.template.spec.taints : t.effect
    ] == ["NoSchedule", "PreferNoSchedule", "NoExecute"]
    error_message = "one of the three Kubernetes taint effects no longer round-trips"
  }
}

run "taints_effect_single_bad_wrong_case" {
  command = plan

  variables {
    taints = [{ key = "a", effect = "noschedule" }]
  }

  expect_failures = [var.taints]
}

run "taints_effect_single_bad_unknown" {
  command = plan

  variables {
    taints = [{ key = "a", effect = "Evict" }]
  }

  expect_failures = [var.taints]
}

run "taints_effect_multi_bad_three_unknown" {
  command = plan

  variables {
    taints = [
      { key = "a", effect = "Evict" },
      { key = "b", effect = "Drain" },
      { key = "c", effect = "Reject" },
    ]
  }

  expect_failures = [var.taints]
}

run "taints_effect_mixed_bad_last" {
  command = plan

  variables {
    taints = [
      { key = "a", effect = "NoSchedule" },
      { key = "b", effect = "NoExecute" },
      { key = "c", effect = "Evict" },
    ]
  }

  expect_failures = [var.taints]
}

# --------------------------------------------------------------------------------------------------
# taints -- key
# --------------------------------------------------------------------------------------------------

run "taints_key_multi_good_three_distinct" {
  command = plan

  variables {
    taints = [
      { key = "chalk.ai/managed-by", effect = "NoSchedule" },
      { key = "chalk.ai/resource-group", effect = "NoSchedule" },
      { key = "dedicated", effect = "NoExecute" },
    ]
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.spec.taints) == 3
    error_message = "three distinct taint keys no longer all render"
  }
}

run "taints_key_single_bad_empty" {
  command = plan

  variables {
    taints = [{ key = "", effect = "NoSchedule" }]
  }

  expect_failures = [var.taints]
}

run "taints_key_multi_bad_three_empty" {
  command = plan

  variables {
    taints = [
      { key = "", effect = "NoSchedule" },
      { key = "", effect = "NoExecute" },
      { key = "", effect = "PreferNoSchedule" },
    ]
  }

  expect_failures = [var.taints]
}

run "taints_key_mixed_bad_last" {
  command = plan

  variables {
    taints = [
      { key = "a", effect = "NoSchedule" },
      { key = "b", effect = "NoSchedule" },
      { key = "", effect = "NoSchedule" },
    ]
  }

  expect_failures = [var.taints]
}

# --------------------------------------------------------------------------------------------------
# taints -- MaxItems = 50
# --------------------------------------------------------------------------------------------------

run "taints_cap_boundary_50_accepted" {
  command = plan

  variables {
    taints = [for i in range(50) : { key = "k${i}", effect = "NoSchedule" }]
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.spec.taints) == 50
    error_message = "exactly 50 taints is the documented MaxItems and must be accepted"
  }
}

run "taints_cap_boundary_51_rejected" {
  command = plan

  variables {
    taints = [for i in range(51) : { key = "k${i}", effect = "NoSchedule" }]
  }

  expect_failures = [var.taints]
}

run "taints_cap_multi_bad_75" {
  command = plan

  variables {
    taints = [for i in range(75) : { key = "k${i}", effect = "NoSchedule" }]
  }

  expect_failures = [var.taints]
}

run "taints_cap_mixed_50_valid_plus_one_bad_effect" {
  command = plan

  variables {
    taints = concat(
      [for i in range(50) : { key = "k${i}", effect = "NoSchedule" }],
      [{ key = "bad", effect = "Evict" }],
    )
  }

  expect_failures = [var.taints]
}

# --------------------------------------------------------------------------------------------------
# labels
# --------------------------------------------------------------------------------------------------

run "labels_single_good" {
  command = plan

  variables {
    labels = { "chalk.ai/managed-by" = "chalk" }
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.template.metadata.labels == {
      "chalk.ai/managed-by" = "chalk"
    }
    error_message = "a single prefixed label no longer renders"
  }
}

run "labels_multi_good_three_keys" {
  command = plan

  variables {
    labels = {
      "chalk.ai/managed-by"     = "chalk"
      "chalk.ai/resource-group" = "default"
      "team"                    = "infra"
    }
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.metadata.labels) == 3
    error_message = "three labels, prefixed and unprefixed, no longer all render"
  }
}

run "labels_boundary_63_character_value_accepted" {
  command = plan

  variables {
    labels = { "team" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.template.metadata.labels.team) == 63
    error_message = "a 63-character label value is the Kubernetes maximum and must be accepted"
  }
}

run "labels_single_bad_empty_key" {
  command = plan

  variables {
    labels = { "" = "chalk" }
  }

  expect_failures = [var.labels]
}

run "labels_single_bad_64_character_value" {
  command = plan

  variables {
    labels = { "team" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  }

  expect_failures = [var.labels]
}

run "labels_single_bad_malformed_prefix" {
  command = plan

  variables {
    labels = { "Chalk.AI/managed-by" = "chalk" }
  }

  expect_failures = [var.labels]
}

run "labels_multi_bad_three_malformed_keys" {
  command = plan

  variables {
    labels = {
      "Chalk.AI/managed-by" = "chalk"
      "a//b"                = "chalk"
      "-leading-dash"       = "chalk"
    }
  }

  expect_failures = [var.labels]
}

run "labels_mixed_bad" {
  command = plan

  variables {
    labels = {
      "chalk.ai/managed-by"     = "chalk"
      "chalk.ai/resource-group" = "default"
      "a//b"                    = "chalk"
    }
  }

  expect_failures = [var.labels]
}
