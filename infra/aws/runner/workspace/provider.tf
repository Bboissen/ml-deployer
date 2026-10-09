provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
  assume_role {
    role_arn     = var.deployer_role_arn
    session_name = "workspace-${var.workspace_identity.request.workspace_id}"
  }
  dynamic "assume_role" {
    for_each = var.phase == "launch" ? [local.launch_role_arn] : []
    content {
      role_arn     = assume_role.value
      session_name = "lease-${var.lease.id}"
    }
  }
}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "runtime_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
