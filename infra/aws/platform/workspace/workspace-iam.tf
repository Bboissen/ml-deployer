locals {
  session_manager_actions = [
    "ssm:UpdateInstanceInformation",
    "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
    "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
  ]
}

resource "aws_iam_policy" "session_manager" {
  name        = "${var.resource_prefix}-session-manager-minimal"
  description = "Minimal Session Manager agent channels, without Parameter Store reads"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = local.session_manager_actions, Resource = "*" },
      { Effect = "Deny", Action = ["ssm:GetParameter*", "ssm:DescribeParameters"], Resource = "*" },
    ]
  })
  lifecycle { prevent_destroy = true }
}

resource "aws_iam_policy" "project_workspace_boundary" {
  for_each    = var.ml_projects
  name        = "${var.resource_prefix}-ws-${each.key}-boundary"
  description = "Project dataset reads and principal-tagged workspace output; no administration"
  policy = templatefile("${path.module}/../../workspace-policy.json.tftpl", {
    bucket_arn         = "arn:${data.aws_partition.current.partition}:s3:::${local.project_bucket_names[each.key]}"
    state_bucket_arn   = var.state_bucket_arn
    data_prefix        = "projects/${each.key}/data/"
    output_prefix      = "projects/${each.key}/workspaces/$${aws:PrincipalTag/workspace_id}/output/"
    management_actions = local.session_manager_actions
    include_management = true
  })
  lifecycle { prevent_destroy = true }
}
