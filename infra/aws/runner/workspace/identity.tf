# AWS workspace runner configuration; preserves B identity addresses and envelope.
variable "workspace_identity" {
  description = "AWS workspace 2.0.0 request and exact project storage binding, validated by the provider launcher."
  type = object({
    ml_project_name          = string
    request                  = any
    bucket_name              = string
    permissions_boundary_arn = string
    session_policy_arn       = string
  })
  default = null

  validation {
    condition = var.workspace_identity == null ? true : try(
      can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.workspace_identity.ml_project_name)) &&
      var.workspace_identity.request.schema_version == "2.0.0" && var.workspace_identity.request.kind == "request" &&
      var.workspace_identity.request.provider == "aws" &&
      var.workspace_identity.request.account_scope == var.aws_account_id && var.workspace_identity.request.region == var.aws_region &&
      can(regex("^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$", var.workspace_identity.request.workspace_id)) &&
      startswith(var.workspace_identity.request.workspace_id, "${var.workspace_identity.ml_project_name}-") &&
      toset(keys(var.workspace_identity.request)) == toset([
        "schema_version", "kind", "provider", "account_scope", "region", "workspace_id",
        "toolbox_profile", "resources", "storage", "operators", "maximum_runtime_minutes",
      ]) &&
      toset(keys(var.workspace_identity.request.storage)) == toset(["data_uri", "output_uri", "state_uri"]) &&
      var.workspace_identity.request.toolbox_profile == "cpu-python-v1" &&
      toset(keys(var.workspace_identity.request.resources)) == toset(["cpus", "memory_mb", "disk_gb"]) &&
      alltrue([for key, minimum in { cpus = 1, memory_mb = 1024, disk_gb = 10 } :
        var.workspace_identity.request.resources[key] == floor(var.workspace_identity.request.resources[key]) && var.workspace_identity.request.resources[key] >= minimum
      ]) &&
      var.workspace_identity.request.maximum_runtime_minutes == floor(var.workspace_identity.request.maximum_runtime_minutes) &&
      var.workspace_identity.request.maximum_runtime_minutes >= 15 && var.workspace_identity.request.maximum_runtime_minutes <= 720 &&
      length(var.workspace_identity.request.operators) >= 1 && length(toset(var.workspace_identity.request.operators)) == length(var.workspace_identity.request.operators) &&
      alltrue([for operator in var.workspace_identity.request.operators : operator == tostring(operator) && length(operator) <= 2048 && can(regex("^[^[:cntrl:]]+$", operator))]) &&
      var.workspace_identity.request.storage.data_uri == "s3://${var.workspace_identity.bucket_name}/projects/${var.workspace_identity.ml_project_name}/data/" &&
      var.workspace_identity.request.storage.output_uri == "s3://${var.workspace_identity.bucket_name}/projects/${var.workspace_identity.ml_project_name}/workspaces/${var.workspace_identity.request.workspace_id}/output/" &&
      var.workspace_identity.request.storage.state_uri == "s3://${var.backend_bucket_name}/aws/${var.aws_account_id}/${var.aws_region}/runner/${var.workspace_identity.request.workspace_id}.tfstate" &&
      var.workspace_identity.bucket_name != var.backend_bucket_name &&
      can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.workspace_identity.bucket_name)) &&
      var.workspace_identity.permissions_boundary_arn == "arn:aws:iam::${var.aws_account_id}:policy/${var.resource_prefix}-ws-${var.workspace_identity.ml_project_name}-boundary" &&
      var.workspace_identity.session_policy_arn == "arn:aws:iam::${var.aws_account_id}:policy/${var.resource_prefix}-session-manager-minimal",
      false,
    )
    error_message = "Workspace identity must bind a closed AWS 2.0.0 request, exact project namespace, separate state and the project-specific boundary/minimal management policy. Validate the full request with the common validator first."
  }
}

locals {
  workspace_identities = var.workspace_identity == null ? {} : { (var.workspace_identity.request.workspace_id) = var.workspace_identity }
  workspace_role_names = {
    for id, identity in local.workspace_identities : id => "${substr(var.resource_prefix, 0, 12)}-run-ws-${substr(id, 0, 24)}-${substr(sha256("${var.aws_account_id}/${var.aws_region}/${identity.ml_project_name}/${id}"), 0, 10)}"
  }
  workspace_policy_documents = {
    for id, identity in local.workspace_identities : id => templatefile("${path.module}/../../workspace-policy.json.tftpl", {
      bucket_arn       = "arn:aws:s3:::${identity.bucket_name}"
      state_bucket_arn = var.state_bucket_arn
      data_prefix      = "projects/${identity.ml_project_name}/data/"
      output_prefix    = "projects/${identity.ml_project_name}/workspaces/${id}/output/"
      management_actions = [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
      ]
      include_management = false
    })
  }
}

resource "aws_iam_role" "workspace" {
  for_each             = local.workspace_identities
  name                 = local.workspace_role_names[each.key]
  assume_role_policy   = data.aws_iam_policy_document.runtime_assume.json
  permissions_boundary = each.value.permissions_boundary_arn
  tags = {
    MLProject    = each.value.ml_project_name
    workspace_id = each.key
  }
}

resource "aws_iam_role_policy" "workspace_storage" {
  for_each = local.workspace_identities
  name     = "workspace-storage"
  role     = aws_iam_role.workspace[each.key].id
  policy   = local.workspace_policy_documents[each.key]
}

resource "aws_iam_role_policy_attachment" "workspace_ssm" {
  for_each   = local.workspace_identities
  role       = aws_iam_role.workspace[each.key].name
  policy_arn = each.value.session_policy_arn
}

resource "aws_iam_instance_profile" "workspace" {
  for_each = local.workspace_identities
  name     = local.workspace_role_names[each.key]
  role     = aws_iam_role.workspace[each.key].name
  depends_on = [
    aws_iam_role_policy.workspace_storage,
    aws_iam_role_policy_attachment.workspace_ssm,
  ]
}

output "workspace_identity_preparation" {
  description = "Identity/profile references for later reviewed compute composition; no instance/readiness assertion."
  value = {
    for id, identity in local.workspace_identities : id => {
      role_arn                 = aws_iam_role.workspace[id].arn
      instance_profile_name    = aws_iam_instance_profile.workspace[id].name
      permissions_boundary_arn = identity.permissions_boundary_arn
      storage                  = identity.request.storage
      compute_enabled          = false
    }
  }
}
