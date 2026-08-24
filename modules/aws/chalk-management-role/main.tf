data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  # id is the configured provider region in both AWS provider v5 and v6.
  region   = data.aws_region.current.id
  role_arn = "arn:${local.partition}:iam::${local.account_id}:role/${var.role_name}"

  common_tags = merge(
    var.tags,
    {
      "chalk.ai/managed-by" = "chalk"
      "chalk.ai/component"  = "management-role"
    },
  )

  deployment_actions = [
    "acm:*",
    "application-autoscaling:*",
    "autoscaling:*",
    "cloudwatch:*",
    "dax:*",
    "dynamodb:*",
    "ec2:*",
    "ecr:*",
    "eks:*",
    "elasticache:AddTagsToResource",
    "elasticache:CreateCacheSubnetGroup",
    "elasticache:CreateReplicationGroup",
    "elasticache:DeleteCacheSubnetGroup",
    "elasticache:DeleteReplicationGroup",
    "elasticache:DescribeCacheClusters",
    "elasticache:DescribeCacheSubnetGroups",
    "elasticache:DescribeReplicationGroups",
    "elasticache:ListTagsForResource",
    "elasticache:ModifyCacheSubnetGroup",
    "elasticache:ModifyReplicationGroup",
    "elasticache:RemoveTagsFromResource",
    "elasticloadbalancing:*",
    "glue:*",
    "iam:AddClientIDToOpenIDConnectProvider",
    "iam:AddRoleToInstanceProfile",
    "iam:AttachRolePolicy",
    "iam:CreateInstanceProfile",
    "iam:CreateOpenIDConnectProvider",
    "iam:CreatePolicy",
    "iam:CreatePolicyVersion",
    "iam:CreateRole",
    "iam:CreateServiceLinkedRole",
    "iam:DeleteInstanceProfile",
    "iam:DeleteOpenIDConnectProvider",
    "iam:DeletePolicy",
    "iam:DeleteRole",
    "iam:DeleteRolePolicy",
    "iam:DeleteServerCertificate",
    "iam:DeleteServiceLinkedRole",
    "iam:DetachRolePolicy",
    "iam:GetInstanceProfile",
    "iam:GetOpenIDConnectProvider",
    "iam:GetPolicy",
    "iam:GetPolicyVersion",
    "iam:GetRole",
    "iam:GetRolePolicy",
    "iam:GetServerCertificate",
    "iam:GetSSHPublicKey",
    "iam:ListAttachedRolePolicies",
    "iam:ListInstanceProfilesForRole",
    "iam:ListOpenIDConnectProviders",
    "iam:ListOpenIDConnectProviderTags",
    "iam:ListPolicies",
    "iam:ListPolicyTags",
    "iam:ListPolicyVersions",
    "iam:ListRoles",
    "iam:ListRolePolicies",
    "iam:ListRoleTags",
    "iam:ListSSHPublicKeys",
    "iam:PassRole",
    "iam:PutRolePolicy",
    "iam:RemoveClientIDFromOpenIDConnectProvider",
    "iam:RemoveRoleFromInstanceProfile",
    "iam:TagOpenIDConnectProvider",
    "iam:TagPolicy",
    "iam:TagRole",
    "iam:UntagOpenIDConnectProvider",
    "iam:UntagPolicy",
    "iam:UntagRole",
    "iam:UpdateAssumeRolePolicy",
    "iam:UpdateOpenIDConnectProviderThumbprint",
    "iam:UpdateRole",
    "iam:UpdateRoleDescription",
    "iam:UpdateServerCertificate",
    "iam:UploadServerCertificate",
    "iam:UploadSSHPublicKey",
    "kafka-cluster:*",
    "kafkaconnect:*",
    "kafka:*",
    "kms:*",
    "logs:*",
    "rds:*",
    "redshift-data:*",
    "redshift-serverless:*",
    "redshift:*",
    "route53:*",
    "s3:*",
    "secretsmanager:*",
    "sns:*",
    "sqs:*",
  ]

  restricted_tagged_actions = [
    "acm:*",
    "application-autoscaling:*",
    "cloudwatch:*",
    "dynamodb:*",
    "ec2:*",
    "ecr:*",
    "eks:*",
    "elasticache:*",
    "elasticloadbalancing:*",
    "glue:*",
    "iam:GetOpenIDConnectProvider",
    "iam:GetPolicy",
    "iam:GetPolicyVersion",
    "iam:GetRole",
    "iam:GetRolePolicy",
    "iam:ListAttachedRolePolicies",
    "iam:ListInstanceProfilesForRole",
    "iam:ListPolicyVersions",
    "iam:ListRolePolicies",
    "iam:PassRole",
    "kafka:*",
    "kms:*",
    "logs:*",
    "rds:*",
    "secretsmanager:*",
    "sqs:*",
  ]

  restricted_tagged_resources = [
    "arn:${local.partition}:acm:${local.region}:${local.account_id}:*",
    "arn:${local.partition}:application-autoscaling:${local.region}:${local.account_id}:*",
    "arn:${local.partition}:cloudwatch:${local.region}:${local.account_id}:*",
    "arn:${local.partition}:dynamodb:${local.region}:${local.account_id}:table/chalk*",
    "arn:${local.partition}:ec2:${local.region}:${local.account_id}:*",
    "arn:${local.partition}:ecr:${local.region}:${local.account_id}:repository/*",
    "arn:${local.partition}:eks:${local.region}:${local.account_id}:*",
    "arn:${local.partition}:elasticache:${local.region}:${local.account_id}:*:chalk*",
    "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:loadbalancer/*/k8s-*",
    "arn:${local.partition}:glue:${local.region}:${local.account_id}:*",
    "arn:${local.partition}:iam::${local.account_id}:oidc-provider/*",
    "arn:${local.partition}:iam::${local.account_id}:policy/*",
    "arn:${local.partition}:iam::${local.account_id}:role/*",
    "arn:${local.partition}:kafka:${local.region}:${local.account_id}:cluster/chalk*",
    "arn:${local.partition}:kms:${local.region}:${local.account_id}:*",
    "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*",
    "arn:${local.partition}:rds:${local.region}:${local.account_id}:*:chalk*",
    "arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:*",
    "arn:${local.partition}:sqs:${local.region}:${local.account_id}:chalk*",
  ]
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "ChalkAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = sort(tolist(var.trusted_principal_arns))
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.role_name
  description          = "Allows Chalk to deploy and manage resources in this AWS account."
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = var.max_session_duration
  permissions_boundary = var.permissions_boundary_arn
  tags                 = local.common_tags
}

data "aws_iam_policy_document" "deployment" {
  statement {
    sid       = "ChalkDeploymentPermissions"
    effect    = "Allow"
    actions   = local.deployment_actions
    resources = ["*"]
  }

  statement {
    sid    = "ChalkSimulateRolePermissions"
    effect = "Allow"
    actions = [
      "iam:GetContextKeysForPrincipalPolicy",
      "iam:SimulatePrincipalPolicy",
    ]
    resources = [local.role_arn]
  }
}

data "aws_iam_policy_document" "restricted" {
  statement {
    sid       = "ChalkManagedResources"
    effect    = "Allow"
    actions   = local.restricted_tagged_actions
    resources = local.restricted_tagged_resources

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/chalk.ai/managed-by"
      values   = ["chalk"]
    }
  }

  statement {
    sid    = "ChalkSimulateRolePermissions"
    effect = "Allow"
    actions = [
      "iam:GetContextKeysForPrincipalPolicy",
      "iam:SimulatePrincipalPolicy",
    ]
    resources = [local.role_arn]
  }

  statement {
    sid    = "ChalkUntaggedResources"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "kafka:DescribeConfiguration",
      "kafka:DescribeConfigurationRevision",
      "s3:*",
    ]
    resources = [
      "arn:${local.partition}:iam::aws:policy/*",
      "arn:${local.partition}:kafka:${local.region}:${local.account_id}:configuration/chalk*",
      "arn:${local.partition}:s3:::chalk-*",
      "arn:${local.partition}:s3:::chalk-*/*",
    ]
  }

  statement {
    sid    = "ChalkDescribeResources"
    effect = "Allow"
    actions = [
      "acm:Describe*",
      "dynamodb:Describe*",
      "dynamodb:ListTables*",
      "eks:Describe*",
      "elasticache:Describe*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/chalk.ai/managed-by"
      values   = ["chalk"]
    }
  }

  statement {
    sid    = "ChalkGlobalDescribe"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ecr:Describe*",
      "ecr:GetAuthorizationToken",
      "logs:DescribeLogGroups",
      "route53:Get*",
      "route53:List*",
    ]
    resources = ["*"]
  }

  # RDS Proxy and its default target group use AWS-generated IDs in their
  # ARNs, even when their configured names start with "chalk". Keep access to
  # those opaque ARNs limited to non-destructive proxy management and to
  # resources that carry Chalk's management tag.
  statement {
    sid    = "ChalkManagedRDSProxy"
    effect = "Allow"
    actions = [
      "rds:AddTagsToResource",
      "rds:DescribeDBProxies",
      "rds:DescribeDBProxyTargetGroups",
      "rds:DescribeDBProxyTargets",
      "rds:ListTagsForResource",
      "rds:ModifyDBProxy",
      "rds:ModifyDBProxyTargetGroup",
      "rds:RegisterDBProxyTargets",
    ]
    resources = [
      "arn:${local.partition}:rds:${local.region}:${local.account_id}:db-proxy:*",
      "arn:${local.partition}:rds:${local.region}:${local.account_id}:target-group:*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/chalk.ai/managed-by"
      values   = ["chalk"]
    }
  }

  statement {
    sid     = "ChalkRunInstances"
    effect  = "Allow"
    actions = ["ec2:RunInstances"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:network-interface/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:security-group/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:subnet/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:volume/*",
      "arn:${local.partition}:ec2:${local.region}::image/*",
      "arn:${local.partition}:ec2:${local.region}::snapshot/*",
    ]
  }

  statement {
    sid     = "ChalkTagOnCreate"
    effect  = "Allow"
    actions = ["ec2:CreateTags"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:network-interface/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:volume/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances"]
    }
  }
}

resource "aws_iam_policy" "this" {
  name        = "${var.role_name}-permissions"
  description = "Permissions for the Chalk management role."
  policy      = var.restricted_permissions ? data.aws_iam_policy_document.restricted.json : data.aws_iam_policy_document.deployment.json
  tags        = local.common_tags
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}
