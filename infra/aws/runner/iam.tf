data "aws_partition" "current" {}

locals {
  runner_name = "${substr(var.resource_prefix, 0, 12)}-run-${substr(var.runner_request.deployment_id, 0, 24)}-${substr(local.request_sha256, 0, 8)}"
}

data "aws_iam_policy_document" "runtime_assume" {
  statement {
    sid     = "EC2Only"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runtime" {
  name                 = "${local.runner_name}-run"
  description          = "Ephemeral workload identity for exactly one deployment"
  assume_role_policy   = data.aws_iam_policy_document.runtime_assume.json
  permissions_boundary = var.runtime_permissions_boundary_arn

  tags = {
    deployment_id = var.runner_request.deployment_id
  }
}

data "aws_iam_policy_document" "runtime" {
  statement {
    sid     = "ListAndReadGenericData"
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      var.data_bucket_arn,
    ]
  }

  statement {
    sid    = "ReadGenericDataObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${var.data_bucket_arn}/*"]
  }

  statement {
    sid     = "ReadExactRunSpec"
    effect  = "Allow"
    actions = ["s3:GetObjectVersion"]
    resources = [
      "${var.results_bucket_arn}/run-specs/${var.runner_request.deployment_id}/${var.runner_request.run_spec_sha256}.json",
    ]
  }

  statement {
    sid     = "WriteOwnLogsAndResultsOnly"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${var.results_bucket_arn}/runs/${var.runner_request.deployment_id}/logs/*",
      "${var.results_bucket_arn}/runs/${var.runner_request.deployment_id}/results/*",
    ]
  }

  statement {
    sid     = "ConditionallyCreateLocalReceiptHandoff"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${var.results_bucket_arn}/runs/${var.runner_request.deployment_id}/control-input/execution-receipt.local.json",
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:if-none-match"
      values   = ["*"]
    }
  }

  statement {
    sid    = "PullExactProviderLocalImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [var.ecr_repository_arn]
  }

  statement {
    sid       = "ObtainTemporaryECRToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid     = "ExplicitlyDenyPersistentStateAndReceiptControl"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      var.state_bucket_arn,
      "${var.state_bucket_arn}/*",
      "${var.results_bucket_arn}/control/*",
    ]
  }

  statement {
    sid       = "ExplicitlyDenyReceiptPublisherAssumption"
    effect    = "Deny"
    actions   = ["sts:AssumeRole"]
    resources = [var.receipt_publisher_role_arn]
  }
}

resource "aws_iam_role_policy" "runtime" {
  name   = "${local.runner_name}-workload"
  role   = aws_iam_role.runtime.id
  policy = data.aws_iam_policy_document.runtime.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.runtime.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:policy/${var.resource_prefix}-session-manager-minimal"
}

resource "aws_iam_instance_profile" "runtime" {
  name = "${local.runner_name}-run"
  role = aws_iam_role.runtime.name
  depends_on = [
    aws_iam_role_policy.runtime,
    aws_iam_role_policy_attachment.ssm,
  ]
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    sid     = "SchedulerOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name                 = "${local.runner_name}-stop"
  description          = "Independent provider-side absolute deadline for one EC2 runner"
  assume_role_policy   = data.aws_iam_policy_document.scheduler_assume.json
  permissions_boundary = var.scheduler_permissions_boundary_arn
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "TerminateOnlyThisRunner"
    effect    = "Allow"
    actions   = ["ec2:TerminateInstances"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${var.aws_account_id}:instance/${aws_instance.runner.id}"]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "${local.runner_name}-stop"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}
