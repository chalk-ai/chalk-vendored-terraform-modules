# spec.disruption -- consolidationPolicy, consolidateAfter and budgets.
#
# The whole block is one variable, so every rejecting run below still names exactly one broken rule:
# the budget-duration runs pair schedule with duration so the schedule-and-duration rule cannot also
# fire, and the budget-nodes runs leave both unset for the same reason.

mock_provider "kubectl" {}

variables {
  name              = "example-pool"
  ec2nodeclass_name = "al2023"
}

# --------------------------------------------------------------------------------------------------
# consolidationPolicy
# --------------------------------------------------------------------------------------------------

run "consolidation_policy_single_good" {
  command = plan

  variables {
    disruption = { consolidationPolicy = "WhenEmptyOrUnderutilized" }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.disruption.consolidationPolicy == "WhenEmptyOrUnderutilized"
    error_message = "consolidationPolicy no longer renders"
  }
}

run "consolidation_policy_multi_good_when_empty" {
  command = plan

  variables {
    disruption = { consolidationPolicy = "WhenEmpty" }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.disruption.consolidationPolicy == "WhenEmpty"
    error_message = "WhenEmpty is a valid v1 consolidationPolicy and no longer renders"
  }
}

run "consolidation_policy_multi_good_balanced" {
  command = plan

  variables {
    disruption = { consolidationPolicy = "Balanced" }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.disruption.consolidationPolicy == "Balanced"
    error_message = "Balanced is a valid v1 consolidationPolicy and no longer renders"
  }
}

# WhenUnderutilized is the v1beta1 spelling. It is NOT valid in v1 and is the likeliest wrong value
# a caller migrating from v1beta1 will reach for.
run "consolidation_policy_single_bad_v1beta1_value" {
  command = plan

  variables {
    disruption = { consolidationPolicy = "WhenUnderutilized" }
  }

  expect_failures = [var.disruption]
}

run "consolidation_policy_single_bad_wrong_case" {
  command = plan

  variables {
    disruption = { consolidationPolicy = "whenempty" }
  }

  expect_failures = [var.disruption]
}

run "consolidation_policy_multi_bad_unknown_one" {
  command = plan

  variables {
    disruption = { consolidationPolicy = "Never" }
  }

  expect_failures = [var.disruption]
}

run "consolidation_policy_multi_bad_unknown_two" {
  command = plan

  variables {
    disruption = { consolidationPolicy = "WhenIdle" }
  }

  expect_failures = [var.disruption]
}

run "consolidation_policy_multi_bad_unknown_three" {
  command = plan

  variables {
    disruption = { consolidationPolicy = "Aggressive" }
  }

  expect_failures = [var.disruption]
}

# --------------------------------------------------------------------------------------------------
# consolidateAfter
# --------------------------------------------------------------------------------------------------

run "consolidate_after_single_good" {
  command = plan

  variables {
    disruption = { consolidateAfter = "0s" }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.disruption.consolidateAfter == "0s"
    error_message = "consolidateAfter 0s no longer renders, or no longer renders as a string"
  }
}

run "consolidate_after_multi_good_hours" {
  command = plan

  variables {
    disruption = { consolidateAfter = "1h" }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.disruption.consolidateAfter == "1h"
    error_message = "consolidateAfter 1h no longer renders"
  }
}

run "consolidate_after_multi_good_compound" {
  command = plan

  variables {
    disruption = { consolidateAfter = "1h30m" }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.disruption.consolidateAfter == "1h30m"
    error_message = "a compound consolidateAfter no longer renders"
  }
}

run "consolidate_after_multi_good_never" {
  command = plan

  variables {
    disruption = { consolidateAfter = "Never" }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.disruption.consolidateAfter == "Never"
    error_message = "the literal Never is valid for consolidateAfter and no longer renders"
  }
}

run "consolidate_after_single_bad_no_unit" {
  command = plan

  variables {
    disruption = { consolidateAfter = "0" }
  }

  expect_failures = [var.disruption]
}

run "consolidate_after_multi_bad_embedded_space" {
  command = plan

  variables {
    disruption = { consolidateAfter = "5 m" }
  }

  expect_failures = [var.disruption]
}

run "consolidate_after_multi_bad_word" {
  command = plan

  variables {
    disruption = { consolidateAfter = "forever" }
  }

  expect_failures = [var.disruption]
}

# --------------------------------------------------------------------------------------------------
# budgets[].nodes
# --------------------------------------------------------------------------------------------------

run "budget_nodes_single_good_percentage" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%" }] }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.disruption.budgets == [{ nodes = "10%" }]
    error_message = "a single percentage budget no longer renders, or no longer renders as a string"
  }
}

run "budget_nodes_multi_good_boundaries_and_absolute" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "0%" }, { nodes = "100%" }, { nodes = "5" }] }
  }

  assert {
    condition = [
      for b in yamldecode(output.rendered_manifest).spec.disruption.budgets : b.nodes
    ] == ["0%", "100%", "5"]
    error_message = "0%, the 100% boundary and an absolute node count must all be accepted"
  }
}

run "budget_nodes_single_bad_over_one_hundred_percent" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "101%" }] }
  }

  expect_failures = [var.disruption]
}

run "budget_nodes_single_bad_negative" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "-1" }] }
  }

  expect_failures = [var.disruption]
}

run "budget_nodes_single_bad_embedded_space" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10 %" }] }
  }

  expect_failures = [var.disruption]
}

run "budget_nodes_multi_bad_three_over_one_hundred_percent" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "101%" }, { nodes = "150%" }, { nodes = "999%" }] }
  }

  expect_failures = [var.disruption]
}

run "budget_nodes_mixed_bad_last" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%" }, { nodes = "101%" }] }
  }

  expect_failures = [var.disruption]
}

# --------------------------------------------------------------------------------------------------
# budgets[].schedule and budgets[].duration -- set together or not at all
# --------------------------------------------------------------------------------------------------

run "budget_schedule_and_duration_good_neither" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%" }] }
  }

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.disruption.budgets[0].schedule)
    error_message = "a budget with neither schedule nor duration now emits a schedule key"
  }
}

run "budget_schedule_and_duration_good_both" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "0", schedule = "@daily", duration = "10h" }] }
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.disruption.budgets == [
      { nodes = "0", schedule = "@daily", duration = "10h" }
    ]
    error_message = "a complete scheduled budget no longer renders"
  }
}

run "budget_schedule_and_duration_multi_good_two_complete" {
  command = plan

  variables {
    disruption = {
      budgets = [
        { nodes = "0", schedule = "0 9 * * mon-fri", duration = "8h" },
        { nodes = "100%", schedule = "0 21 * * mon-fri", duration = "10h" },
      ]
    }
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.disruption.budgets) == 2
    error_message = "two complete scheduled budgets no longer both render"
  }
}

run "budget_schedule_only_rejected" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", schedule = "@daily" }] }
  }

  expect_failures = [var.disruption]
}

run "budget_duration_only_rejected" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", duration = "10h" }] }
  }

  expect_failures = [var.disruption]
}

run "budget_schedule_and_duration_multi_bad_two_half_set" {
  command = plan

  variables {
    disruption = {
      budgets = [
        { nodes = "10%", schedule = "@daily" },
        { nodes = "10%", duration = "10h" },
      ]
    }
  }

  expect_failures = [var.disruption]
}

run "budget_schedule_and_duration_mixed_bad_last" {
  command = plan

  variables {
    disruption = {
      budgets = [
        { nodes = "10%", schedule = "@daily", duration = "10h" },
        { nodes = "10%", schedule = "@weekly" },
      ]
    }
  }

  expect_failures = [var.disruption]
}

# --------------------------------------------------------------------------------------------------
# budgets[].duration -- hours and minutes only. Seconds are accepted by consolidateAfter and
# expire_after but NOT here; every run below pairs a schedule so only the unit rule can fire.
# --------------------------------------------------------------------------------------------------

run "budget_duration_multi_good_hours" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", schedule = "@daily", duration = "10h" }] }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.disruption.budgets[0].duration == "10h"
    error_message = "an hours-only budget duration no longer renders"
  }
}

run "budget_duration_multi_good_minutes" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", schedule = "@daily", duration = "30m" }] }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.disruption.budgets[0].duration == "30m"
    error_message = "a minutes-only budget duration no longer renders"
  }
}

run "budget_duration_multi_good_compound" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", schedule = "@daily", duration = "10h5m" }] }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.disruption.budgets[0].duration == "10h5m"
    error_message = "a compound hours-and-minutes budget duration no longer renders"
  }
}

run "budget_duration_single_bad_seconds" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", schedule = "@daily", duration = "30s" }] }
  }

  expect_failures = [var.disruption]
}

run "budget_duration_multi_bad_three_second_only" {
  command = plan

  variables {
    disruption = {
      budgets = [
        { nodes = "10%", schedule = "@daily", duration = "30s" },
        { nodes = "10%", schedule = "@daily", duration = "1s" },
        { nodes = "10%", schedule = "@daily", duration = "3600s" },
      ]
    }
  }

  expect_failures = [var.disruption]
}

run "budget_duration_mixed_bad_last" {
  command = plan

  variables {
    disruption = {
      budgets = [
        { nodes = "10%", schedule = "@daily", duration = "10h" },
        { nodes = "10%", schedule = "@daily", duration = "30s" },
      ]
    }
  }

  expect_failures = [var.disruption]
}

# --------------------------------------------------------------------------------------------------
# budgets[].reasons
# --------------------------------------------------------------------------------------------------

run "budget_reasons_single_good" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", reasons = ["Empty"] }] }
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.disruption.budgets[0].reasons == ["Empty"]
    error_message = "a single budget reason no longer renders"
  }
}

run "budget_reasons_multi_good_all_three" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", reasons = ["Underutilized", "Empty", "Drifted"] }] }
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.disruption.budgets[0].reasons == [
      "Underutilized", "Empty", "Drifted"
    ]
    error_message = "one of the three valid budget reasons no longer round-trips"
  }
}

run "budget_reasons_single_bad" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", reasons = ["Expired"] }] }
  }

  expect_failures = [var.disruption]
}

run "budget_reasons_multi_bad_three_unknown" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", reasons = ["Expired", "Interrupted", "Consolidated"] }] }
  }

  expect_failures = [var.disruption]
}

run "budget_reasons_mixed_bad_last" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%", reasons = ["Empty", "Drifted", "Expired"] }] }
  }

  expect_failures = [var.disruption]
}

# --------------------------------------------------------------------------------------------------
# budgets -- MaxItems = 50
# --------------------------------------------------------------------------------------------------

run "budget_cap_single_budget" {
  command = plan

  variables {
    disruption = { budgets = [{ nodes = "10%" }] }
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.disruption.budgets) == 1
    error_message = "a one-element budget list no longer renders"
  }
}

run "budget_cap_boundary_50_accepted" {
  command = plan

  variables {
    disruption = { budgets = [for i in range(50) : { nodes = "10%" }] }
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.disruption.budgets) == 50
    error_message = "exactly 50 budgets is the documented MaxItems and must be accepted"
  }
}

run "budget_cap_boundary_51_rejected" {
  command = plan

  variables {
    disruption = { budgets = [for i in range(51) : { nodes = "10%" }] }
  }

  expect_failures = [var.disruption]
}

run "budget_cap_multi_bad_60" {
  command = plan

  variables {
    disruption = { budgets = [for i in range(60) : { nodes = "10%" }] }
  }

  expect_failures = [var.disruption]
}

run "budget_cap_mixed_50_valid_plus_one_bad_nodes" {
  command = plan

  variables {
    disruption = {
      budgets = concat(
        [for i in range(50) : { nodes = "10%" }],
        [{ nodes = "101%" }],
      )
    }
  }

  expect_failures = [var.disruption]
}
