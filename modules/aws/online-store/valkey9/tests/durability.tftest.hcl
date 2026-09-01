# Durability and snapshot-restore behaviour. valkey9 only.
#
# Two assertion shapes are needed because the two new arguments differ in the provider schema:
#
#   snapshot_name  Optional            -> the mock leaves it null, so it can be asserted directly,
#                                         and `override_resource` REFUSES it (non-computed).
#   durability     Optional + Computed -> the mock FABRICATES a value, so `output.durability == null`
#                                         fails even on correct code. Prove optionality with the
#                                         `durability_input` echo output, or pin it with an override.

mock_provider "aws" {}

variables {
  cluster_id = "chalk-valkey-test"
  vpc_id     = "vpc-xxxxx"
  subnet_ids = ["subnet-xxxxx", "subnet-yyyyy"]
}

# --------------------------------------------------------------------------------------------------
# Both arguments are optional and the module injects no default for either.
# --------------------------------------------------------------------------------------------------

run "omitted_both_stay_unset" {
  command = plan

  assert {
    condition     = output.snapshot_name == null
    error_message = "module set a snapshot_name when the caller supplied none"
  }
  assert {
    condition     = output.durability_input == null
    error_message = "module set a durability when the caller supplied none"
  }
}

run "omitted_durability_overridable" {
  command = plan

  override_resource {
    target = aws_elasticache_replication_group.valkey
    values = {
      durability = null
    }
  }

  assert {
    condition     = output.durability == null
    error_message = "durability is not null once the mock's fabricated value is overridden"
  }
}

# --------------------------------------------------------------------------------------------------
# A fully compliant durable configuration plans cleanly and passes both values through.
# --------------------------------------------------------------------------------------------------

run "compliant_durable_config_passes_through" {
  command = plan

  variables {
    node_type     = "cache.r7g.4xlarge"
    snapshot_name = "chalk-valkey-snapshot"
    durability    = "async"
  }

  assert {
    condition     = output.snapshot_name == "chalk-valkey-snapshot"
    error_message = "snapshot_name not wired onto the replication group"
  }
  assert {
    condition     = output.durability == "async"
    error_message = "durability not wired onto the replication group"
  }
  assert {
    condition     = output.durability_input == "async"
    error_message = "durability_input echo does not reflect the caller's value"
  }
}

run "sync_is_also_accepted" {
  command = plan

  variables {
    node_type  = "cache.r7g.4xlarge"
    durability = "sync"
  }

  assert {
    condition     = output.durability == "sync"
    error_message = "durability = sync rejected"
  }
}

# `disabled` and `default` are valid enum values but do NOT turn durability on, so they must not
# trigger the prerequisite preconditions -- here paired with the non-Graviton default node_type.
run "disabled_does_not_trigger_prerequisites" {
  command = plan

  variables {
    durability = "disabled"
  }

  assert {
    condition     = output.durability == "disabled"
    error_message = "durability = disabled rejected"
  }
}

# --------------------------------------------------------------------------------------------------
# Variable validation
# --------------------------------------------------------------------------------------------------

run "invalid_durability_rejected" {
  command = plan

  variables {
    durability = "eventually"
  }

  expect_failures = [var.durability]
}

# --------------------------------------------------------------------------------------------------
# Prerequisites. Each is enforced by a precondition on the replication group, so a violation fails at
# plan time rather than after AWS has been asked to build the cluster.
# --------------------------------------------------------------------------------------------------

run "durability_requires_valkey_9" {
  command = plan

  variables {
    node_type            = "cache.r7g.4xlarge"
    engine_version       = "8.0"
    parameter_group_name = "default.valkey8.cluster.on"
    durability           = "async"
  }

  expect_failures = [aws_elasticache_replication_group.valkey]
}

run "durability_requires_multi_az" {
  command = plan

  variables {
    node_type        = "cache.r7g.4xlarge"
    multi_az_enabled = false
    durability       = "async"
  }

  expect_failures = [aws_elasticache_replication_group.valkey]
}

run "durability_requires_a_replica" {
  command = plan

  variables {
    node_type               = "cache.r7g.4xlarge"
    replicas_per_node_group = 0
    durability              = "async"
  }

  expect_failures = [aws_elasticache_replication_group.valkey]
}

run "durability_requires_transit_encryption" {
  command = plan

  variables {
    node_type                  = "cache.r7g.4xlarge"
    transit_encryption_enabled = false
    durability                 = "async"
  }

  expect_failures = [aws_elasticache_replication_group.valkey]
}

run "durability_requires_a_graviton_node_family" {
  command = plan

  variables {
    node_type  = "cache.m5.large"
    durability = "async"
  }

  expect_failures = [aws_elasticache_replication_group.valkey]
}

# --------------------------------------------------------------------------------------------------
# Parameter-group / engine major agreement. Not gated on durability -- it is a footgun for every
# caller now that the engine default has moved to 9.
# --------------------------------------------------------------------------------------------------

run "default_parameter_group_major_must_match_engine" {
  command = plan

  variables {
    parameter_group_name = "default.valkey8.cluster.on"
  }

  expect_failures = [aws_elasticache_replication_group.valkey]
}

run "custom_parameter_group_skips_the_major_check" {
  command = plan

  variables {
    parameter_group_name = "chalk-valkey-tuned"
  }

  assert {
    condition     = aws_elasticache_replication_group.valkey.parameter_group_name == "chalk-valkey-tuned"
    error_message = "a custom parameter group name was rejected"
  }
}
