mock_provider "aws" {}

variables {
  table_name          = "existing-online-store"
  billing_mode        = "PROVISIONED"
  read_capacity       = 10
  write_capacity      = 500
  autoscaling_enabled = true
  autoscaling_read    = { max_capacity = 200, target_value = 70 }
  autoscaling_write   = { max_capacity = 2000, target_value = 70 }
}

run "default_names_are_unchanged" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.online_store_secret.name == "existing-online-store-online-store-secret"
    error_message = "Omitted secret_name must retain the existing naming convention."
  }
  assert {
    condition     = aws_appautoscaling_policy.table_read_policy[0].name == "DynamoDBReadCapacityUtilization:table/existing-online-store"
    error_message = "Omitted read_policy_name must retain the existing policy name."
  }
  assert {
    condition     = aws_appautoscaling_policy.table_write_policy[0].name == "DynamoDBWriteCapacityUtilization:table/existing-online-store"
    error_message = "Omitted write_policy_name must retain the existing policy name."
  }
  assert {
    condition     = aws_appautoscaling_target.table_read[0].min_capacity == 10 && aws_appautoscaling_target.table_write[0].min_capacity == 500
    error_message = "Scaling target minimums must continue to use read_capacity and write_capacity."
  }
}

run "existing_names_and_tags_can_be_preserved" {
  command = plan
  variables {
    secret_name       = "existing-connection-secret"
    read_policy_name  = "existing-read-policy"
    write_policy_name = "existing-write-policy"
    table_tags        = { ManagedBy = "terraform", Purpose = "online-store" }
    secret_tags       = { ManagedBy = "terraform" }
  }
  assert {
    condition     = aws_secretsmanager_secret.online_store_secret.name == "existing-connection-secret"
    error_message = "Importing an existing secret must not require a rename."
  }
  assert {
    condition     = aws_appautoscaling_policy.table_read_policy[0].name == "existing-read-policy" && aws_appautoscaling_policy.table_write_policy[0].name == "existing-write-policy"
    error_message = "Existing scaling policy names must be preserved when provided."
  }
  assert {
    condition     = aws_dynamodb_table.main.tags == tomap({ ManagedBy = "terraform", Purpose = "online-store" }) && aws_secretsmanager_secret.online_store_secret.tags == tomap({ ManagedBy = "terraform" })
    error_message = "Existing table and secret tags must be preserved when provided."
  }
  assert {
    condition     = aws_dynamodb_table.main.name == "existing-online-store" && aws_secretsmanager_secret_version.online_store_secret_version.secret_string == "dynamodb:///existing-online-store"
    error_message = "Custom metadata must not alter the table identity or connection URI."
  }
}
