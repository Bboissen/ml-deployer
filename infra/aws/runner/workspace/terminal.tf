# Exactly one account-native operator; user and role paths remain distinct.
locals {
  operator_arn  = one(var.workspace_identity.request.operators)
  operator_kind = strcontains(local.operator_arn, ":user/") ? "user" : "role"
  operator_name = element(reverse(split("/", local.operator_arn)), 0)
  operator_policy = jsonencode({ Version = "2012-10-17", Statement = [
    {
      Effect   = "Allow", Action = "ssm:StartSession",
      Resource = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*",
      Condition = { StringEquals = {
        "ssm:resourceTag/WorkspaceId" = local.id, "ssm:resourceTag/LeaseId" = var.lease.id,
        "ssm:resourceTag/GuardId"     = var.guard.guard_id
      }, Bool = { "ssm:SessionDocumentAccessCheck" = "true" } }
    },
    { Effect = "Allow", Action = ["ssm:StartSession", "ssm:GetDocument"], Resource = aws_ssm_document.terminal.arn },
    { Effect = "Allow", Action = ["ssmmessages:OpenDataChannel", "ssm:ResumeSession", "ssm:TerminateSession"], Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:session/$${aws:userid}-*" },
    { Effect = "Allow", Action = ["ssm:DescribeInstanceInformation", "ssm:GetCommandInvocation", "ec2:DescribeInstances"], Resource = "*" },
    { Effect = "Allow", Action = ["ssm:SendCommand", "ssm:GetDocument", "ssm:DescribeDocument"], Resource = aws_ssm_document.job.arn },
    {
      Effect   = "Allow", Action = "ssm:SendCommand",
      Resource = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*",
      Condition = { StringEquals = {
        "ssm:resourceTag/WorkspaceId" = local.id, "ssm:resourceTag/LeaseId" = var.lease.id,
        "ssm:resourceTag/GuardId"     = var.guard.guard_id
      } }
    }
  ] })
}
resource "aws_iam_user_policy" "operator" {
  provider = aws.operator
  count    = local.operator_kind == "user" ? 1 : 0
  name     = "${local.role_name}-terminal"
  user     = local.operator_name
  policy   = local.operator_policy
}
resource "aws_iam_role_policy" "operator" {
  provider = aws.operator
  count    = local.operator_kind == "role" ? 1 : 0
  name     = "${local.role_name}-terminal"
  role     = local.operator_name
  policy   = local.operator_policy
}
