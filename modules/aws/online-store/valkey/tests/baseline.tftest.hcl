# Characterization tests for the Valkey online-store module.
#
# These pin the module's behaviour as it shipped in v0.1.0 so that the valkey8 / valkey9 split can be
# proven faithful: the same suite must pass, unchanged, against all copies.
#
# `mock_provider "aws" {}` configures no provider, assumes no role and reads no state, so this suite
# runs with no AWS credentials and makes no cloud calls.

mock_provider "aws" {}

variables {
  cluster_id = "chalk-valkey-test"
  vpc_id     = "vpc-xxxxx"
  subnet_ids = ["subnet-xxxxx", "subnet-yyyyy"]
}

# --------------------------------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------------------------------

run "defaults_are_pinned" {
  command = plan

  assert {
    condition     = output.num_node_groups == 3
    error_message = "default num_node_groups changed"
  }
  assert {
    condition     = output.replicas_per_node_group == 1
    error_message = "default replicas_per_node_group changed"
  }
  assert {
    condition     = output.node_type == "cache.m5.large"
    error_message = "default node_type changed"
  }
  assert {
    condition     = output.engine_version == "8.0"
    error_message = "default engine_version changed"
  }
  assert {
    condition     = output.port == 6379
    error_message = "default port changed"
  }
  assert {
    condition     = output.engine == "valkey"
    error_message = "engine is no longer valkey"
  }
  assert {
    condition     = aws_elasticache_replication_group.valkey.parameter_group_name == "default.valkey8.cluster.on"
    error_message = "default parameter_group_name changed"
  }
  assert {
    condition     = aws_elasticache_replication_group.valkey.multi_az_enabled
    error_message = "multi_az_enabled no longer defaults to true"
  }
  assert {
    condition     = aws_elasticache_replication_group.valkey.transit_encryption_enabled
    error_message = "transit_encryption_enabled no longer defaults to true"
  }
  assert {
    condition     = aws_elasticache_replication_group.valkey.at_rest_encryption_enabled
    error_message = "at_rest_encryption_enabled no longer defaults to true"
  }
}

# --------------------------------------------------------------------------------------------------
# Derived naming. Chalk reads the secret name out of these, so they are contractual.
# --------------------------------------------------------------------------------------------------

run "names_derive_from_cluster_id" {
  command = plan

  assert {
    condition     = aws_elasticache_replication_group.valkey.replication_group_id == "chalk-valkey-test"
    error_message = "replication_group_id no longer tracks var.cluster_id"
  }
  assert {
    condition     = output.instance_id == "chalk-valkey-test"
    error_message = "instance_id no longer tracks var.cluster_id"
  }
  assert {
    condition     = output.subnet_group_id == "chalk-valkey-test-subnet"
    error_message = "subnet group name is no longer <cluster_id>-subnet"
  }
  assert {
    condition     = output.subnet_group_name == "chalk-valkey-test-subnet"
    error_message = "subnet group resource name is no longer <cluster_id>-subnet"
  }
  assert {
    condition     = output.security_group_name == "chalk-valkey-test-sg"
    error_message = "security group name is no longer <cluster_id>-sg"
  }
  assert {
    condition     = output.valkey_endpoint_redis_secret_name == "chalk-valkey-test-redis-uri"
    error_message = "secret name is no longer <cluster_id>-redis-uri"
  }
}

# --------------------------------------------------------------------------------------------------
# Connection-string scheme. The endpoint is unknown under `command = plan`, so these need `apply`
# (still fully mocked) plus an override pinning the configuration endpoint.
# --------------------------------------------------------------------------------------------------

run "transit_encryption_on_yields_rediss" {
  command = apply

  override_resource {
    target = aws_elasticache_replication_group.valkey
    values = {
      configuration_endpoint_address = "clustercfg.example.cache.amazonaws.com"
    }
  }

  assert {
    condition     = aws_secretsmanager_secret_version.valkey_endpoint_redis.secret_string == "rediss://clustercfg.example.cache.amazonaws.com:6379?clustered=true#insecure"
    error_message = "TLS-on connection string changed"
  }
}

run "transit_encryption_off_yields_redis" {
  command = apply

  variables {
    transit_encryption_enabled = false
  }

  override_resource {
    target = aws_elasticache_replication_group.valkey
    values = {
      configuration_endpoint_address = "clustercfg.example.cache.amazonaws.com"
    }
  }

  assert {
    condition     = aws_secretsmanager_secret_version.valkey_endpoint_redis.secret_string == "redis://clustercfg.example.cache.amazonaws.com:6379?clustered=true#insecure"
    error_message = "TLS-off connection string changed"
  }
}

# --------------------------------------------------------------------------------------------------
# Caller replay. Every known consumer's argument set must still plan cleanly.
# --------------------------------------------------------------------------------------------------

run "caller_replay_explicit_valkey9_args" {
  command = plan

  variables {
    cluster_id              = "chalk-valkey-explicit"
    engine_version          = "9.1"
    parameter_group_name    = "default.valkey9.cluster.on"
    node_type               = "cache.m7g.large"
    num_node_groups         = 2
    replicas_per_node_group = 1
    allowed_cidr_blocks     = ["10.0.0.0/16"]
  }

  assert {
    condition     = output.engine_version == "9.1"
    error_message = "explicit engine_version not honoured"
  }
  assert {
    condition     = output.num_node_groups == 2
    error_message = "explicit num_node_groups not honoured"
  }
  assert {
    condition     = output.node_type == "cache.m7g.large"
    error_message = "explicit node_type not honoured"
  }
}

run "caller_replay_minimal_args" {
  command = plan

  variables {
    cluster_id          = "chalk-valkey-minimal"
    vpc_id              = "vpc-xxxxx"
    subnet_ids          = ["subnet-xxxxx", "subnet-yyyyy"]
    allowed_cidr_blocks = ["10.0.0.0/16"]
  }

  assert {
    condition     = output.engine_version == "8.0"
    error_message = "minimal caller no longer gets the Valkey 8 default"
  }
  assert {
    condition     = output.valkey_endpoint_redis_secret_name == "chalk-valkey-minimal-redis-uri"
    error_message = "minimal caller secret name changed"
  }
}

# --------------------------------------------------------------------------------------------------
# Input validation
# --------------------------------------------------------------------------------------------------

run "single_subnet_is_rejected" {
  command = plan

  variables {
    subnet_ids = ["subnet-xxxxx"]
  }

  expect_failures = [var.subnet_ids]
}
