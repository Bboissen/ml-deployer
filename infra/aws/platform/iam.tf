data "aws_partition" "current" {}

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
  name                 = "${var.resource_prefix}-tofu-deployer"
  description          = "Least-privilege OpenTofu deployer for disposable Demo AWS runners"
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

data "aws_iam_policy_document" "receipt_publisher_assume" {
  statement {
    sid     = "ReviewedControlPrincipalsOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.deployer.arn]
    }
  }
}

resource "aws_iam_role" "receipt_publisher" {
  name               = "${var.resource_prefix}-receipt-publisher"
  description        = "Distinct control-plane identity for conditional completion-receipt publication"
  assume_role_policy = data.aws_iam_policy_document.receipt_publisher_assume.json

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "receipt_publisher" {
  statement {
    sid       = "ReadRunnerLifecycleFacts"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadRunnerDeadlineSchedule"
    effect    = "Allow"
    actions   = ["scheduler:GetSchedule"]
    resources = ["arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}:${var.aws_account_id}:schedule/default/${substr(var.resource_prefix, 0, 12)}-run-*-stop"]
  }

  statement {
    sid     = "ReadResultsBucketLocation"
    effect  = "Allow"
    actions = ["s3:GetBucketLocation"]
    resources = [
      aws_s3_bucket.workload["results"].arn,
    ]
  }

  statement {
    sid    = "ReadBoundedRunnerEvidence"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = [
      "${aws_s3_bucket.workload["results"].arn}/runs/*/control-input/execution-receipt.local.json",
      "${aws_s3_bucket.workload["results"].arn}/runs/*/logs/bootstrap.log",
      "${aws_s3_bucket.workload["results"].arn}/runs/*/results/result-manifest.json",
    ]
  }

  statement {
    sid     = "ConditionallyCreateControlEvidenceAndReceipts"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.workload["results"].arn}/control/evidence/*",
      "${aws_s3_bucket.workload["results"].arn}/control/receipts/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:if-none-match"
      values   = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "receipt_publisher" {
  name   = "${var.resource_prefix}-conditional-receipt-create"
  role   = aws_iam_role.receipt_publisher.id
  policy = data.aws_iam_policy_document.receipt_publisher.json
}

data "aws_iam_policy_document" "runtime_boundary" {
  statement {
    sid       = "ListGenericData"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.workload["data"].arn]
  }

  statement {
    sid    = "ReadGenericDataObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${aws_s3_bucket.workload["data"].arn}/*"]
  }

  statement {
    sid       = "ReadResultsBucketMetadata"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [aws_s3_bucket.workload["results"].arn]
  }

  statement {
    sid    = "ReadRunSpecifications"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${aws_s3_bucket.workload["results"].arn}/run-specs/*"]
  }

  statement {
    sid     = "WriteOwnLogsAndResults"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.workload["results"].arn}/runs/$${aws:PrincipalTag/deployment_id}/logs/*",
      "${aws_s3_bucket.workload["results"].arn}/runs/$${aws:PrincipalTag/deployment_id}/results/*",
    ]
  }

  statement {
    sid       = "ConditionallyCreateOwnLocalReceiptHandoff"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.workload["results"].arn}/runs/$${aws:PrincipalTag/deployment_id}/control-input/execution-receipt.local.json"]

    condition {
      test     = "StringEquals"
      variable = "s3:if-none-match"
      values   = ["*"]
    }
  }

  statement {
    sid       = "GetECRAuthorizationToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PullCanonicalImageFromProviderLocalECR"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.runner.arn]
  }

  statement {
    sid       = "UseSystemsManagerControlChannels"
    effect    = "Allow"
    actions   = local.session_manager_actions
    resources = ["*"]
  }

  statement {
    sid       = "DenyParameterStoreReads"
    effect    = "Deny"
    actions   = ["ssm:GetParameter*", "ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    sid     = "DenyStateStorage"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      var.state_bucket_arn,
      "${var.state_bucket_arn}/*",
    ]
  }

  statement {
    sid     = "DenyReceiptControlNamespace"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      "${aws_s3_bucket.workload["results"].arn}/control/*",
    ]
  }

  statement {
    sid       = "DenyReceiptPublisherAssumption"
    effect    = "Deny"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.receipt_publisher.arn]
  }
}

resource "aws_iam_policy" "runtime_boundary" {
  name        = "${var.resource_prefix}-runtime-boundary"
  description = "Maximum permissions for one tagged disposable runner role"
  policy      = data.aws_iam_policy_document.runtime_boundary.json

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "scheduler_boundary" {
  statement {
    sid       = "TerminateTaggedDemoRunner"
    effect    = "Allow"
    actions   = ["ec2:TerminateInstances"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Project"
      values   = [var.project_name]
    }
  }
}

resource "aws_iam_policy" "scheduler_boundary" {
  name        = "${var.resource_prefix}-scheduler-boundary"
  description = "Maximum permissions for one provider-side runner termination role"
  policy      = data.aws_iam_policy_document.scheduler_boundary.json

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "deployer" {
  dynamic "statement" {
    for_each = local.workspace_guards
    content {
      sid       = "ManageReviewedNamedOperatorWorkspaceGrant"
      effect    = "Allow"
      actions   = ["iam:PutUserPolicy", "iam:DeleteUserPolicy", "iam:GetUserPolicy", "iam:ListUserTags"]
      resources = ["arn:aws:iam::${var.aws_account_id}:user/sposhfi-admin"]
    }
  }
  dynamic "statement" {
    for_each = local.workspace_guards
    content {
      sid       = "ManageReviewedNonRootTerminalDocuments"
      effect    = "Allow"
      actions   = ["ssm:CreateDocument", "ssm:DeleteDocument", "ssm:UpdateDocument", "ssm:UpdateDocumentDefaultVersion", "ssm:GetDocument", "ssm:DescribeDocument", "ssm:DescribeDocumentPermission", "ssm:ListTagsForResource", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource"]
      resources = ["arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:document/${substr(var.resource_prefix, 0, 12)}-run-ws-*-terminal"]
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
    sid       = "LaunchTaggedRunner"
    effect    = var.workspace_guard == null ? "Allow" : "Deny"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${var.aws_account_id}:instance/*"]

    dynamic "condition" {
      for_each = var.workspace_guard == null ? [var.project_name] : []
      content {
        test     = "StringEquals"
        variable = "aws:RequestTag/Project"
        values   = [condition.value]
      }
    }
  }

  statement {
    sid     = "UseReviewedRunnerLaunchDependencies"
    effect  = "Allow"
    actions = ["ec2:RunInstances"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}::image/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${var.aws_account_id}:network-interface/*",
      aws_security_group.runner.arn,
      aws_subnet.runner.arn,
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${var.aws_account_id}:volume/*",
    ]
  }

  statement {
    sid    = "ManageTaggedRunnerLifecycle"
    effect = "Allow"
    actions = [
      "ec2:ModifyInstanceAttribute",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Project"
      values   = [var.project_name]
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
      "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:role/${substr(var.resource_prefix, 0, 12)}-run-*",
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
      "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:role/${substr(var.resource_prefix, 0, 12)}-run-*",
    ]

    condition {
      test     = "ArnEquals"
      variable = "iam:PermissionsBoundary"
      values = concat([
        aws_iam_policy.runtime_boundary.arn,
        aws_iam_policy.scheduler_boundary.arn,
      ], [for boundary in aws_iam_policy.project_workspace_boundary : boundary.arn], [for boundary in aws_iam_policy.workspace_launch_boundary : boundary.arn])
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
      "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:instance-profile/${substr(var.resource_prefix, 0, 12)}-run-*",
    ]
  }

  statement {
    sid     = "PassOnlyRunnerRolesToNativeServices"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:role/${substr(var.resource_prefix, 0, 12)}-run-*",
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
      "arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}:${var.aws_account_id}:schedule/default/${substr(var.resource_prefix, 0, 12)}-run-*",
    ]
  }

  statement {
    sid       = "AssumeReceiptPublisherForControlPublication"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.receipt_publisher.arn]
  }
}

resource "aws_iam_role_policy" "deployer" {
  name   = "${var.resource_prefix}-disposable-runner-deployer"
  role   = aws_iam_role.deployer.id
  policy = data.aws_iam_policy_document.deployer.json
}
