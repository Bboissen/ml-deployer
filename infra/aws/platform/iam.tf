data "aws_partition" "current" {}

data "aws_iam_policy_document" "receipt_publisher_assume" {
  statement {
    sid     = "ReviewedControlPrincipalsOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.receipt_publisher_principal_arns
    }
  }
}

resource "aws_iam_role" "receipt_publisher" {
  name               = "${var.resource_prefix}-receipt-publisher"
  description        = "Distinct control-plane identity for conditional completion-receipt publication"
  assume_role_policy = data.aws_iam_policy_document.receipt_publisher_assume.json

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = alltrue([
        for arn in var.receipt_publisher_principal_arns :
        strcontains(arn, ":iam::${var.aws_account_id}:")
      ])
      error_message = "Receipt publisher trust principals must belong to the reviewed AWS account."
    }
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
    resources = ["arn:${data.aws_partition.current.partition}:scheduler:${var.aws_region}:${var.aws_account_id}:schedule/default/${substr(var.resource_prefix, 0, 16)}-*-stop"]
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
    sid    = "UseSystemsManagerControlChannels"
    effect = "Allow"
    actions = [
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
      "ssm:DescribeAssociation",
      "ssm:DescribeDocument",
      "ssm:GetDeployablePatchSnapshotForInstance",
      "ssm:GetDocument",
      "ssm:GetManifest",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:ListAssociations",
      "ssm:ListInstanceAssociations",
      "ssm:PutComplianceItems",
      "ssm:PutConfigurePackageResult",
      "ssm:PutInventory",
      "ssm:UpdateAssociationStatus",
      "ssm:UpdateInstanceAssociationStatus",
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
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
