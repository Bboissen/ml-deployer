# One reviewed operator. Existing administrator permissions remain authoritative;
# this grant does not claim to reduce that administrator's AWS privileges.
resource "aws_iam_user_policy" "operator" {
  name = "${local.role_name}-terminal"
  user = "sposhfi-admin"
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    {
      Effect   = "Allow", Action = "ssm:StartSession",
      Resource = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*",
      Condition = { StringEquals = {
        "ssm:resourceTag/WorkspaceId" = local.id, "ssm:resourceTag/LeaseId" = var.lease.id,
        "ssm:resourceTag/GuardId"     = var.guard.guard_id
      }, Bool = { "ssm:SessionDocumentAccessCheck" = "true" } }
    },
    { Effect = "Allow", Action = ["ssm:StartSession", "ssm:GetDocument"], Resource = aws_ssm_document.terminal.arn },
    { Effect = "Allow", Action = ["ssm:ResumeSession", "ssm:TerminateSession"], Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:session/sposhfi-admin-*" },
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
  lifecycle {
    precondition {
      condition     = var.workspace_identity.request.operators == ["arn:aws:iam::${var.aws_account_id}:user/sposhfi-admin"]
      error_message = "This reviewed source profile grants only sposhfi-admin; additional operators require review."
    }
  }
}
