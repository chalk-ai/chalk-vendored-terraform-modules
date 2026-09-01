# Engine defaults. This is the deliberate behaviour difference between valkey8 and valkey9, and the
# reason the module was split rather than edited in place: an ElastiCache engine upgrade is one-way.

mock_provider "aws" {}

variables {
  cluster_id = "chalk-valkey-test"
  vpc_id     = "vpc-xxxxx"
  subnet_ids = ["subnet-xxxxx", "subnet-yyyyy"]
}

run "defaults_to_valkey_9" {
  command = plan

  assert {
    condition     = output.engine_version == "9.0"
    error_message = "valkey9 must default to engine_version 9.0"
  }
  assert {
    condition     = aws_elasticache_replication_group.valkey.parameter_group_name == "default.valkey9.cluster.on"
    error_message = "valkey9 must default to the default.valkey9 parameter group family"
  }
}

run "an_older_engine_is_still_accepted_when_asked_for" {
  command = plan

  variables {
    engine_version       = "8.0"
    parameter_group_name = "default.valkey8.cluster.on"
  }

  assert {
    condition     = output.engine_version == "8.0"
    error_message = "valkey9 refuses an explicitly requested older engine"
  }
}

run "a_newer_minor_is_accepted" {
  command = plan

  variables {
    engine_version = "9.1"
  }

  assert {
    condition     = output.engine_version == "9.1"
    error_message = "valkey9 refuses a newer 9.x minor"
  }
}
