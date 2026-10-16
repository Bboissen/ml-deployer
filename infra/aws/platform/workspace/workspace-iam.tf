locals {
  session_manager_actions = [
    "ssm:UpdateInstanceInformation",
    "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
    "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
  ]
  workspace_storage_boundaries = {
    for slug, project in var.ml_projects : slug => templatefile("${path.module}/../../workspace-policy.json.tftpl", {
      bucket_arn         = "arn:${data.aws_partition.current.partition}:s3:::${local.project_bucket_names[slug]}"
      state_bucket_arn   = var.state_bucket_arn
      data_prefix        = local.project_storage[slug].data_prefix
      output_prefix      = replace(local.project_storage[slug].output_prefix_template, "<workspace_id>", "$${aws:PrincipalTag/workspace_id}")
      management_actions = local.session_manager_actions
      include_management = true
    })
  }
}

variable "workspace_git_secret_arns" {
  description = "Exact existing regional Git credential secret ARNs by project; no secret values or creation."
  type        = map(list(string))
  default     = {}
  validation {
    condition = alltrue([for slug, arns in var.workspace_git_secret_arns :
      contains(keys(var.ml_projects), slug) && length(arns) > 0 && length(arns) <= 10 &&
      length(distinct(arns)) == length(arns) && alltrue([for arn in arns :
        can(regex("^arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${slug}/workspaces/[a-z0-9-]+/git/[A-Za-z0-9_-]+-[A-Za-z0-9]{6}$", arn))
      ])
    ])
    error_message = "Git secrets must be exact existing ARNs in this account/region and project workspace namespace."
  }
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
  policy = contains(keys(var.workspace_git_secret_arns), each.key) ? templatefile("${path.module}/../../workspace-git-policy.json.tftpl", {
    storage_policy = local.workspace_storage_boundaries[each.key]
    secret_arns    = var.workspace_git_secret_arns[each.key]
  }) : local.workspace_storage_boundaries[each.key]
  lifecycle { prevent_destroy = true }
}
