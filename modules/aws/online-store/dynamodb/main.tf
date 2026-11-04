// Configure a DynamoDB table for use as an Online Store
// NOTE: Multiple environments can use the same DynamoDB table

variable "table_name" {
  type    = string
  default = "chalk_online_store"
}

variable "secret_name" {
  description = "Existing or custom connection secret name. Defaults to <table_name>-online-store-secret when null."
  type        = string
  default     = null
}

variable "table_tags" {
  description = "Tags to apply to the DynamoDB table, including tags to preserve when importing an existing table."
  type        = map(string)
  default     = {}
}

variable "secret_tags" {
  description = "Tags to apply to the connection secret, including tags to preserve when importing an existing secret."
  type        = map(string)
  default     = {}
}

variable "billing_mode" {
  description = "Controls how you are billed for read/write throughput and how you manage capacity. The valid values are PROVISIONED or PAY_PER_REQUEST"
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "write_capacity" {
  description = "The number of write units for this table. If the billing_mode is PROVISIONED, this field should be greater than 0"
  type        = number
  default     = null
}

variable "read_capacity" {
  description = "The number of read units for this table. If the billing_mode is PROVISIONED, this field should be greater than 0"
  type        = number
  default     = null
}

variable "autoscaling_read" {
  description = "Autoscaling configuration for read capacity"
  type        = map(string)
  default = {
    min_capacity = 5
    max_capacity = 100
    target_value = 50
  }
}

variable "autoscaling_write" {
  description = "Autoscaling configuration for write capacity"
  type        = map(string)
  default = {
    min_capacity = 5
    max_capacity = 100
    target_value = 50
  }
}

variable "deletion_protection_enabled" {
  description = "Enables deletion protection for the table"
  type        = bool
  default     = false
}

resource "aws_dynamodb_table" "main" {
  name = var.table_name

  # Key schema
  hash_key  = "__id__"
  range_key = "__ns__"
  attribute {
    name = "__id__"
    type = "S"
  }
  attribute {
    name = "__ns__"
    type = "S"
  }

  ttl {
    enabled        = true
    attribute_name = "__exp__"
  }

  deletion_protection_enabled = var.deletion_protection_enabled
  table_class                 = "STANDARD"

  billing_mode   = var.billing_mode
  write_capacity = var.write_capacity
  read_capacity  = var.read_capacity

  tags = var.table_tags

  lifecycle {
    ignore_changes = [
      write_capacity,
      read_capacity,
    ]
  }
}

output "arn" {
  value = aws_dynamodb_table.main.arn
}
output "id" {
  value = aws_dynamodb_table.main.id
}
output "table_name" {
  value = aws_dynamodb_table.main.name
}

output "table_uri" {
  value = format("dynamodb:///%s", aws_dynamodb_table.main.name)
}

output "online_store_secret" {
  value = aws_secretsmanager_secret.online_store_secret.name
}

output "online_store_kind" {
  value = "DYNAMODB"
}

resource "aws_secretsmanager_secret" "online_store_secret" {
  name = coalesce(var.secret_name, "${var.table_name}-online-store-secret")
  tags = var.secret_tags
}

resource "aws_secretsmanager_secret_version" "online_store_secret_version" {
  secret_id     = aws_secretsmanager_secret.online_store_secret.id
  secret_string = format("dynamodb:///%s", aws_dynamodb_table.main.name)
}
