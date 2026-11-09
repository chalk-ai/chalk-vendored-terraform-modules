mock_provider "aws" {}

variables {
  cluster_id = "existing-valkey"
  vpc_id     = "vpc-xxxxx"
  subnet_ids = ["subnet-xxxxx", "subnet-yyyyy"]
}

run "default_names_are_unchanged" {
  command = plan

  assert {
    condition     = aws_elasticache_subnet_group.valkey.name == "existing-valkey-subnet"
    error_message = "Omitted subnet_group_name must keep the default name."
  }
  assert {
    condition     = aws_security_group.valkey.name_prefix == "existing-valkey-sg-"
    error_message = "Omitted security_group_name must keep the generated prefix."
  }
  assert {
    condition     = aws_secretsmanager_secret.valkey_endpoint_redis.name == "existing-valkey-redis-uri"
    error_message = "Omitted secret_name must keep the default name."
  }
}

run "existing_names_can_be_preserved" {
  command = plan
  variables {
    subnet_group_name   = "legacy-subnets"
    security_group_name = "legacy-sg"
    secret_name         = "legacy-redis-secret"
  }

  assert {
    condition     = aws_elasticache_subnet_group.valkey.name == "legacy-subnets"
    error_message = "subnet_group_name must be honored."
  }
  assert {
    condition     = aws_security_group.valkey.name == "legacy-sg"
    error_message = "security_group_name must be used verbatim."
  }
  assert {
    condition     = aws_secretsmanager_secret.valkey_endpoint_redis.name == "legacy-redis-secret"
    error_message = "secret_name must be honored."
  }
}
