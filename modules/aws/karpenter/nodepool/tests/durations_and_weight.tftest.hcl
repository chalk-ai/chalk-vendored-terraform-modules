# expire_after, termination_grace_period and weight.
#
# The two duration inputs look interchangeable and are not: expire_after accepts the literal Never,
# termination_grace_period does not. That asymmetry is in the CRD patterns and is pinned below.
#
# These are scalars, so "multi" means a run per representative value across the domain with the
# boundaries included, and there is no mixed good/bad case to write.

mock_provider "kubectl" {}

variables {
  name              = "example-pool"
  ec2nodeclass_name = "al2023"
}

# --------------------------------------------------------------------------------------------------
# expire_after
# --------------------------------------------------------------------------------------------------

run "expire_after_single_good" {
  command = plan

  variables {
    expire_after = "720h"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.expireAfter == "720h"
    error_message = "expireAfter no longer renders, or no longer renders as a string"
  }
}

run "expire_after_multi_good_one_hour" {
  command = plan

  variables {
    expire_after = "1h"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.expireAfter == "1h"
    error_message = "a short expireAfter no longer renders"
  }
}

run "expire_after_multi_good_never" {
  command = plan

  variables {
    expire_after = "Never"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.expireAfter == "Never"
    error_message = "the literal Never is valid for expireAfter and no longer renders"
  }
}

run "expire_after_multi_good_compound" {
  command = plan

  variables {
    expire_after = "720h0m0s"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.expireAfter == "720h0m0s"
    error_message = "the compound form Karpenter itself writes back no longer renders"
  }
}

run "expire_after_single_bad_no_unit" {
  command = plan

  variables {
    expire_after = "720"
  }

  expect_failures = [var.expire_after]
}

run "expire_after_multi_bad_word" {
  command = plan

  variables {
    expire_after = "soon"
  }

  expect_failures = [var.expire_after]
}

run "expire_after_multi_bad_days_unit" {
  command = plan

  variables {
    expire_after = "30d"
  }

  expect_failures = [var.expire_after]
}

run "expire_after_multi_bad_embedded_space" {
  command = plan

  variables {
    expire_after = "720 h"
  }

  expect_failures = [var.expire_after]
}

# --------------------------------------------------------------------------------------------------
# termination_grace_period -- same shape as expire_after MINUS the Never alternative
# --------------------------------------------------------------------------------------------------

run "termination_grace_period_single_good" {
  command = plan

  variables {
    termination_grace_period = "30m"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.terminationGracePeriod == "30m"
    error_message = "terminationGracePeriod no longer renders"
  }
}

run "termination_grace_period_multi_good_seconds" {
  command = plan

  variables {
    termination_grace_period = "1s"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.terminationGracePeriod == "1s"
    error_message = "a seconds terminationGracePeriod no longer renders"
  }
}

run "termination_grace_period_multi_good_hours" {
  command = plan

  variables {
    termination_grace_period = "2h"
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.template.spec.terminationGracePeriod == "2h"
    error_message = "an hours terminationGracePeriod no longer renders"
  }
}

run "termination_grace_period_multi_good_null_is_omitted" {
  command = plan

  variables {
    termination_grace_period = null
  }

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.template.spec.terminationGracePeriod)
    error_message = "terminationGracePeriod is emitted when the caller left it null; it has no Karpenter default and must stay absent"
  }
}

# Never is accepted by expire_after and rejected here. This is the one asymmetry between the two
# CRD patterns, and it is the mistake a caller who set both will make.
run "termination_grace_period_single_bad_never" {
  command = plan

  variables {
    termination_grace_period = "Never"
  }

  expect_failures = [var.termination_grace_period]
}

run "termination_grace_period_single_bad_no_unit" {
  command = plan

  variables {
    termination_grace_period = "30"
  }

  expect_failures = [var.termination_grace_period]
}

run "termination_grace_period_multi_bad_word" {
  command = plan

  variables {
    termination_grace_period = "forever"
  }

  expect_failures = [var.termination_grace_period]
}

run "termination_grace_period_multi_bad_days_unit" {
  command = plan

  variables {
    termination_grace_period = "1d"
  }

  expect_failures = [var.termination_grace_period]
}

# --------------------------------------------------------------------------------------------------
# weight -- bounded 1-100. Omitted means "treated as 0"; an explicit 0 is rejected.
# --------------------------------------------------------------------------------------------------

run "weight_single_good" {
  command = plan

  variables {
    weight = 10
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.weight == 10
    error_message = "weight no longer renders as an unquoted number"
  }
}

run "weight_boundary_one_accepted" {
  command = plan

  variables {
    weight = 1
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.weight == 1
    error_message = "1 is the documented minimum weight and must be accepted"
  }
}

run "weight_boundary_one_hundred_accepted" {
  command = plan

  variables {
    weight = 100
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.weight == 100
    error_message = "100 is the documented maximum weight and must be accepted"
  }
}

run "weight_null_is_omitted" {
  command = plan

  variables {
    weight = null
  }

  assert {
    condition     = !can(yamldecode(output.rendered_manifest).spec.weight)
    error_message = "weight is emitted when the caller left it null; omitting it is how a pool asks to be treated as weight 0"
  }
}

# An explicit 0 is NOT the same as omitting weight: omission is treated as 0, the value 0 is rejected.
run "weight_explicit_zero_rejected" {
  command = plan

  variables {
    weight = 0
  }

  expect_failures = [var.weight]
}

run "weight_boundary_one_hundred_and_one_rejected" {
  command = plan

  variables {
    weight = 101
  }

  expect_failures = [var.weight]
}

run "weight_negative_rejected" {
  command = plan

  variables {
    weight = -1
  }

  expect_failures = [var.weight]
}
