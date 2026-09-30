locals {
  issuer_host_path = trimprefix(var.issuer_url, "https://")
  subject          = "env:${var.environment_id}"
}

resource "aws_iam_openid_connect_provider" "chalk" {
  url            = var.issuer_url
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

data "aws_iam_policy_document" "chalk_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.chalk.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host_path}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host_path}:sub"
      values   = [local.subject]
    }
  }
}

resource "aws_iam_role" "chalk" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.chalk_assume_role.json
  tags               = var.tags
}
