locals {
  persistent_buckets = {
    data    = var.data_bucket_name
    results = var.results_bucket_name
  }
}

resource "aws_s3_bucket" "workload" {
  for_each = local.persistent_buckets

  bucket        = each.value
  force_destroy = false

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = (
        var.data_bucket_name != var.results_bucket_name &&
        var.state_bucket_arn != "arn:${data.aws_partition.current.partition}:s3:::${var.data_bucket_name}" &&
        var.state_bucket_arn != "arn:${data.aws_partition.current.partition}:s3:::${var.results_bucket_name}"
      )
      error_message = "State, data and results storage must be three distinct S3 buckets."
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "workload" {
  for_each = aws_s3_bucket.workload

  bucket = each.value.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "workload" {
  for_each = aws_s3_bucket.workload

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "workload" {
  for_each = aws_s3_bucket.workload

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "workload" {
  for_each = aws_s3_bucket.workload

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

  }
}

resource "aws_s3_bucket_lifecycle_configuration" "workload" {
  for_each = aws_s3_bucket.workload

  bucket = each.value.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.workload]
}

data "aws_iam_policy_document" "data_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.workload["data"].arn,
      "${aws_s3_bucket.workload["data"].arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "data" {
  bucket = aws_s3_bucket.workload["data"].id
  policy = data.aws_iam_policy_document.data_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.workload]
}

data "aws_iam_policy_document" "results_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.workload["results"].arn,
      "${aws_s3_bucket.workload["results"].arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyControlWritesFromOtherPrincipals"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:AbortMultipartUpload",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.workload["results"].arn}/control/*"]

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.receipt_publisher.arn]
    }
  }

  statement {
    sid    = "DenyControlDeletion"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]
    resources = ["${aws_s3_bucket.workload["results"].arn}/control/*"]
  }

  statement {
    sid    = "DenyControlWritesWithoutConditionalCreate"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.workload["results"].arn}/control/*"]

    condition {
      test     = "Null"
      variable = "s3:if-none-match"
      values   = ["true"]
    }
  }

  statement {
    sid    = "DenyControlOverwrite"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.workload["results"].arn}/control/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:if-none-match"
      values   = ["*"]
    }
  }

  statement {
    sid    = "DenyLocalReceiptHandoffWithoutConditionalCreate"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.workload["results"].arn}/runs/*/control-input/execution-receipt.local.json"]

    condition {
      test     = "Null"
      variable = "s3:if-none-match"
      values   = ["true"]
    }
  }

  statement {
    sid    = "DenyLocalReceiptHandoffOverwrite"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.workload["results"].arn}/runs/*/control-input/execution-receipt.local.json"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:if-none-match"
      values   = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "results" {
  bucket = aws_s3_bucket.workload["results"].id
  policy = data.aws_iam_policy_document.results_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.workload]
}

resource "aws_ecr_repository" "runner" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  lifecycle {
    prevent_destroy = true
  }
}
