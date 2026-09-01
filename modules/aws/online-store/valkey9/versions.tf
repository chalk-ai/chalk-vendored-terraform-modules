terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # `durability` on aws_elasticache_replication_group shipped in AWS provider v6.51.0.
      version = ">= 6.51.0"
    }
  }
}
