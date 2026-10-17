variable "availability_zone" {
  type    = string
  default = "us-east-1a"
}
variable "aws_account_id" { type = string }
variable "aws_region" { type = string }
variable "resource_prefix" { type = string }
variable "project_name" { type = string }
variable "backend_bucket_name" { type = string }
variable "state_bucket_arn" { type = string }
variable "deployer_role_arn" { type = string }
variable "subnet_id" { type = string }
variable "security_group_id" { type = string }
variable "phase" {
  type    = string
  default = "prepare"
  validation {
    condition     = contains(["prepare", "launch", "retire"], var.phase)
    error_message = "Use separately planned prepare, launch or retire stages."
  }
}
variable "lease" {
  type = object({ id = string, starts_at = string, launch_before = string, expires_at = string })
  validation {
    condition = (can(regex("^[0-9a-f]{32}$", var.lease.id)) &&
      alltrue([for t in [var.lease.starts_at, var.lease.launch_before, var.lease.expires_at] : can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", t))])
    )
    error_message = "Lease uses a unique 32-hex ID and canonical absolute UTC timestamps."
  }
}
variable "guard" {
  description = "Exact platform guard contract; observations are separate and must be refreshed."
  type = object({
    guard_id                = string, function_arn = string, code_sha256 = string, invoker_role_arn = string,
    recurring_schedule_name = string, log_group = string, failure_queue_arn = string, alarm_names = list(string)
  })
}
variable "guard_observation" {
  description = "Truthful native guard readback; fixture assertions cannot authorize a real launch."
  type = object({
    observed_at        = string, heartbeat_at = string, guard_id = string, code_sha256 = string,
    recurrence_enabled = bool, deadline_enabled = bool, iam_verified = bool, alarms_ok = bool
  })
  default = null
}
variable "instance_type" {
  type    = string
  default = "r8i.2xlarge"
  validation {
    condition     = contains(keys(jsondecode(file("${path.module}/../../workspace-profiles.json")).profiles["cpu-python-v1"].supported_sizes), var.instance_type)
    error_message = "Select a discovered SKU from the supported cpu-python-v1 catalog."
  }
}
variable "ami_id" {
  type    = string
  default = "ami-03c3da4cfa8e8943a"
  validation {
    condition     = var.ami_id == "ami-03c3da4cfa8e8943a" && var.aws_region == "us-east-1"
    error_message = "Reviewed regional AMI is pinned to us-east-1; other image/region needs source review."
  }
}
variable "toolbox_zip_path" { type = string }
variable "toolbox_zip_sha256" { type = string }

locals {
  id              = var.workspace_identity.request.workspace_id
  role_name       = local.workspace_role_names[local.id]
  launch_role_arn = "arn:aws:iam::${var.aws_account_id}:role/${local.role_name}-launch"
  guard_tags = {
    ManagedBy   = "opentofu", Project = var.project_name, Root = "runner", GuardId = var.guard.guard_id,
    WorkspaceId = local.id, LeaseId = var.lease.id, ExpiresAt = var.lease.expires_at,
    LeaseStart  = var.lease.starts_at, LaunchBefore = var.lease.launch_before
  }
  terminate_at           = timeadd(var.lease.expires_at, "-5m")
  document_name_prefix   = can(regex("^(aws|amazon|amzn)", lower(local.role_name))) ? "ml-${local.role_name}" : local.role_name
  terminal_document_name = "${local.document_name_prefix}-terminal"
  deadline_name          = "${local.role_name}-deadline"
}

resource "terraform_data" "lease" {
  input = { lease = var.lease, request_sha256 = sha256("${jsonencode(var.workspace_identity.request)}\n") }
  lifecycle {
    precondition {
      condition = (var.workspace_identity != null && var.workspace_identity.request.resources.cpus <= jsondecode(file("${path.module}/../../workspace-profiles.json")).profiles["cpu-python-v1"].supported_sizes[var.instance_type].cpus &&
        var.workspace_identity.request.resources.memory_mb <= jsondecode(file("${path.module}/../../workspace-profiles.json")).profiles["cpu-python-v1"].supported_sizes[var.instance_type].memory_mb && var.workspace_identity.request.resources.disk_gb <= 25
      )
      error_message = "Request exceeds the selected supported SKU usable capacity."
    }
    precondition {
      condition = (timecmp(var.lease.expires_at, timeadd(var.lease.starts_at, "${var.workspace_identity.request.maximum_runtime_minutes}m")) <= 0 &&
        timecmp(var.lease.expires_at, timeadd(var.lease.starts_at, "15m")) >= 0 &&
        timecmp(var.lease.launch_before, var.lease.starts_at) > 0 &&
        timecmp(var.lease.launch_before, timeadd(var.lease.starts_at, "5m")) <= 0 &&
        timecmp(var.lease.launch_before, local.terminate_at) < 0
      )
      error_message = "Lease must bound launch to at most five minutes and absolute lifetime to the request."
    }
    precondition {
      condition = (var.guard.guard_id == substr(sha256("${var.aws_account_id}/${var.aws_region}/${var.resource_prefix}/workspace-v1"), 0, 32) &&
        startswith(var.guard.function_arn, "arn:aws:lambda:${var.aws_region}:${var.aws_account_id}:function:${var.resource_prefix}-workspace-watchdog:") &&
        can(regex(":[1-9][0-9]*$", var.guard.function_arn)) &&
        var.guard.invoker_role_arn == "arn:aws:iam::${var.aws_account_id}:role/${var.resource_prefix}-workspace-watchdog-invoke"
      )
      error_message = "Guard must bind this account/region/owner and immutable numeric function version."
    }
  }
}
