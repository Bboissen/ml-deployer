data "aws_partition" "current" {}

locals {
  ssm_resource_prefix = can(regex("^(aws|amazon|amzn)", var.resource_prefix)) ? "ml-${substr(var.resource_prefix, 0, 12)}" : substr(var.resource_prefix, 0, 12)
}

data "aws_iam_policy_document" "deployer_assume" {
  statement {
    sid     = "ReviewedTemporaryPrincipalsOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.deployer_principal_arns
    }
  }
}

resource "aws_iam_role" "deployer" {
  name                 = "${var.resource_prefix}-workspace-deployer"
  description          = "Least-privilege OpenTofu deployer for guarded cloud workspaces"
  assume_role_policy   = data.aws_iam_policy_document.deployer_assume.json
  max_session_duration = 43200

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = alltrue([
        for arn in var.deployer_principal_arns :
        strcontains(arn, ":iam::${var.aws_account_id}:")
      ])
      error_message = "Deployer trust principals must belong to the reviewed AWS account."
    }
  }
}

data "aws_iam_policy_document" "deployer" {
  dynamic "statement" {
    for_each = local.workspace_guards
    content {
      sid       = "DenyReviewedOperatorPolicyMutation"
      effect    = "Deny"
      actions   = ["iam:*"]
      resources = var.deployer_principal_arns
    }
  }
  dynamic "statement" {
    for_each = local.workspace_guards
    content {
      sid     = "ManageReviewedNonRootTerminalDocuments"
      effect  = "Allow"
      actions = ["ssm:CreateDocument", "ssm:DeleteDocument", "ssm:UpdateDocument", "ssm:UpdateDocumentDefaultVersion", "ssm:GetDocument", "ssm:DescribeDocument", "ssm:DescribeDocumentPermission", "ssm:ListTagsForResource", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource"]
      resources = [
        "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:document/${local.ssm_resource_prefix}-run-ws-*-terminal",
        "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:document/${local.ssm_resource_prefix}-run-ws-*-job",
      ]
    }
  }
  statement {
    sid    = "ReadRunnerInfrastructure"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "iam:GetInstanceProfile",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "scheduler:GetSchedule",
      "scheduler:ListSchedules",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "UseRunnerRemoteState"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = [var.state_bucket_arn]
  }

  statement {
    sid    = "ReadWriteRunnerRemoteStateObjects"
    effect = "Allow"
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = [
      "${var.state_bucket_arn}/aws/${var.aws_account_id}/${var.aws_region}/runner/*",
    ]
  }

  statement {
    sid       = "DenyDirectComputeLaunch"
    effect    = "Deny"
    actions   = ["ec2:RunInstances", "ec2:StartInstances", "ec2:ModifyInstanceAttribute"]
    resources = ["*"]
  }

  statement {
    sid    = "ManageTaggedRunnerLifecycle"
    effect = "Allow"
    actions = [
      "ec2:TerminateInstances",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Project"
      values   = [var.project_name]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/GuardId"
      values   = [local.guard_id]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Root"
      values   = ["runner"]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/ManagedBy"
      values   = ["opentofu"]
    }
  }

  statement {
    sid       = "TagRunnerAtLaunch"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances"]
    }
  }

  statement {
    sid    = "ManageOnlyBoundedRunnerRoles"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:role/${substr(var.resource_prefix, 0, 12)}-run-ws-*",
    ]
  }

  dynamic "statement" {
    for_each = local.workspace_guards
    content {
      sid       = "AssumeOnlyPreparedWorkspaceLaunchRoles"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = ["arn:aws:iam::${var.aws_account_id}:role/${substr(var.resource_prefix, 0, 12)}-run-ws-*-launch"]
    }
  }

  dynamic "statement" {
    for_each = local.workspace_guards
    content {
      sid       = "PassPersistentWatchdogInvokerOnly"
      effect    = "Allow"
      actions   = ["iam:PassRole"]
      resources = [aws_iam_role.workspace_guard_invoker[statement.key].arn]
      condition {
        test     = "StringEquals"
        variable = "iam:PassedToService"
        values   = ["scheduler.amazonaws.com"]
      }
    }
  }

  statement {
    sid     = "RequireAcceptedRunnerBoundaries"
    effect  = "Allow"
    actions = ["iam:CreateRole"]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:role/${substr(var.resource_prefix, 0, 12)}-run-ws-*",
    ]

    condition {
      test     = "ArnEquals"
      variable = "iam:PermissionsBoundary"
      values = concat(
        [for slug in keys(var.ml_projects) : "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:policy/${var.resource_prefix}-ws-${slug}-boundary"],
        var.workspace_guard == null ? [] : ["arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:policy/${var.resource_prefix}-workspace-launch-boundary"],
      )
    }
  }

  statement {
    sid    = "ManageOnlyRunnerInstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:instance-profile/${substr(var.resource_prefix, 0, 12)}-run-ws-*",
    ]
  }

  statement {
    sid     = "PassOnlyRunnerRolesToNativeServices"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:role/${substr(var.resource_prefix, 0, 12)}-run-ws-*",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "ec2.amazonaws.com",
        "scheduler.amazonaws.com",
      ]
    }
  }

  statement {
    sid    = "ManageOnlyRunnerDeadlineSchedules"
    effect = "Allow"
    actions = [
      "scheduler:CreateSchedule",
      "scheduler:DeleteSchedule",
      "scheduler:TagResource",
      "scheduler:UntagResource",
      "scheduler:UpdateSchedule",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}:${var.aws_account_id}:schedule/default/${substr(var.resource_prefix, 0, 12)}-run-ws-*",
    ]
  }


}

resource "aws_iam_role_policy" "deployer" {
  name   = "${var.resource_prefix}-workspace-deployer"
  role   = aws_iam_role.deployer.id
  policy = data.aws_iam_policy_document.deployer.json
}
