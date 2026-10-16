variable "storage_layout" {
  description = "S3 naming and prefixes. Keep legacy for existing state; new guided foundations select readable-v1."
  type        = string
  default     = "legacy"
  validation {
    condition     = contains(["legacy", "readable-v1"], var.storage_layout)
    error_message = "Storage layout must be legacy or readable-v1; changing retained storage requires a reviewed migration."
  }
}

variable "ml_projects" {
  description = "Persistent ML project assignments. Keys and ml_project_name are identical canonical names; retain entries until a reviewed migration."
  type = map(object({
    ml_project_name = string
    storage_mode    = optional(string, "auto")
    assignment = optional(object({
      bucket_name      = string
      ownership        = string
      resource_address = string
      aws_account_id   = string
      aws_region       = string
      state_key        = string
      review_sha256    = string
      protections = object({
        versioning_enabled    = bool
        public_access_blocked = bool
        owner_enforced        = bool
        aes256_encryption     = bool
      })
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for slug, project in var.ml_projects :
      slug == project.ml_project_name && can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", slug)) &&
      contains(["auto", "create", "existing"], project.storage_mode) &&
      (project.storage_mode != "existing" || project.assignment != null) &&
      (project.storage_mode != "create" || try(project.assignment.ownership == "platform-managed" && project.assignment.resource_address == "aws_s3_bucket.project[\"${slug}\"]", project.assignment == null))
    ])
    error_message = "Use canonical 3-32 character ML project names, auto/create/existing, and an explicit assignment for existing; create cannot adopt another address."
  }

  validation {
    condition = alltrue([
      for slug, project in var.ml_projects : project.assignment == null ? true : (
        contains(["platform-managed", "external"], project.assignment.ownership) &&
        project.assignment.aws_account_id == var.aws_account_id && project.assignment.aws_region == var.aws_region &&
        can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", project.assignment.bucket_name)) &&
        can(regex("^[0-9a-f]{64}$", project.assignment.review_sha256)) &&
        (project.assignment.ownership == "external" ? project.assignment.resource_address == "" && project.assignment.state_key == "" : (
          project.assignment.state_key == "aws/${var.aws_account_id}/${var.aws_region}/platform/platform.tfstate" &&
          project.assignment.resource_address == "aws_s3_bucket.project[\"${slug}\"]"
        ))
      )
    ])
    error_message = "Assignments must bind reviewed same-account/region storage and ownership. External references have no managed address/state; platform assignments retain an exact existing address/state key."
  }
}

locals {
  project_prefixes = {
    for slug, project in var.ml_projects : slug => {
      data   = var.storage_layout == "readable-v1" ? "datasets/" : "projects/${slug}/data/"
      output = var.storage_layout == "readable-v1" ? "results/<workspace_id>/" : "projects/${slug}/workspaces/<workspace_id>/output/"
    }
  }
  project_bucket_names = {
    for slug, project in var.ml_projects : slug => (
      project.assignment == null ? (var.storage_layout == "readable-v1" ? "${slug}-storage-${var.aws_account_id}-${var.aws_region}" : "ml-${slug}-${substr(sha256("${var.aws_account_id}/${var.aws_region}/${slug}"), 0, 16)}") : project.assignment.bucket_name
    )
  }
  managed_projects = {
    for slug, project in var.ml_projects : slug => project
    if project.assignment == null || try(project.assignment.ownership == "platform-managed" && project.assignment.resource_address == "aws_s3_bucket.project[\"${slug}\"]", false)
  }
  referenced_projects = { for slug, project in var.ml_projects : slug => project if !contains(keys(local.managed_projects), slug) }
  project_storage = {
    for slug, project in var.ml_projects : slug => {
      ml_project_name          = slug
      aws_account_id           = var.aws_account_id
      aws_region               = var.aws_region
      storage_mode             = project.storage_mode
      inspection_sha256        = try(project.assignment.review_sha256, null)
      bucket_name              = local.project_bucket_names[slug]
      bucket_arn               = "arn:${data.aws_partition.current.partition}:s3:::${local.project_bucket_names[slug]}"
      ownership                = project.assignment == null ? "platform-managed" : project.assignment.ownership
      resource_address         = project.assignment == null ? "aws_s3_bucket.project[\"${slug}\"]" : project.assignment.resource_address
      state_key                = project.assignment == null ? "aws/${var.aws_account_id}/${var.aws_region}/platform/platform.tfstate" : project.assignment.state_key
      data_prefix              = local.project_prefixes[slug].data
      data_uri                 = "s3://${local.project_bucket_names[slug]}/${local.project_prefixes[slug].data}"
      output_prefix_template   = local.project_prefixes[slug].output
      permissions_boundary_arn = aws_iam_policy.project_workspace_boundary[slug].arn
      session_policy_arn       = aws_iam_policy.session_manager.arn
    }
  }
}

resource "aws_s3_bucket" "project" {
  for_each = local.managed_projects
  bucket   = local.project_bucket_names[each.key]

  force_destroy = false
  tags          = { MLProject = each.key }

  lifecycle {
    prevent_destroy = true
    precondition {
      condition = (
        length(distinct(values(local.project_bucket_names))) == length(local.project_bucket_names) &&
        local.project_bucket_names[each.key] != trimprefix(var.state_bucket_arn, "arn:${data.aws_partition.current.partition}:s3:::")
      )
      error_message = "New project storage must have unique ownership and must not rename/adopt historical or state buckets."
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "project" {
  for_each = aws_s3_bucket.project
  bucket   = each.value.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_public_access_block" "project" {
  for_each                = aws_s3_bucket.project
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "project" {
  for_each = aws_s3_bucket.project
  bucket   = each.value.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "project" {
  for_each = aws_s3_bucket.project
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "project" {
  for_each = aws_s3_bucket.project
  bucket   = each.value.id
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
  depends_on = [aws_s3_bucket_versioning.project]
}

resource "aws_s3_bucket_policy" "project" {
  for_each = aws_s3_bucket.project
  bucket   = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "s3:*",
      Resource  = [each.value.arn, "${each.value.arn}/*"],
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.project]
}

# The pinned AWS provider has no versioning/public-access-block data sources.
# Existing assignments require a target-bound metadata inspection receipt from
# workspace-storage.sh; refresh it during later native plan review. No adoption
# is inferred from a bucket name, and this offline record is not live access proof.
data "aws_s3_bucket" "assigned_project" {
  for_each = { for slug, project in var.ml_projects : slug => project if project.assignment != null }
  bucket   = local.project_bucket_names[each.key]
}

resource "terraform_data" "project_storage_checks" {
  for_each = var.ml_projects
  input    = local.project_bucket_names[each.key]
  lifecycle {
    precondition {
      condition = (
        local.project_storage[each.key].bucket_arn != var.state_bucket_arn &&
        length(distinct(values(local.project_bucket_names))) == length(local.project_bucket_names)
      )
      error_message = "Projects cannot reuse state storage or ambiguously share the same workload bucket."
    }
    precondition {
      condition = each.value.assignment == null ? true : (
        data.aws_s3_bucket.assigned_project[each.key].bucket_region == var.aws_region &&
        each.value.assignment.protections.versioning_enabled &&
        each.value.assignment.protections.public_access_blocked &&
        each.value.assignment.protections.owner_enforced &&
        each.value.assignment.protections.aes256_encryption
      )
      error_message = "Assigned storage must be readable in the reviewed region, versioned and have all four public-access blocks enabled."
    }

  }
}

output "project_storage" {
  description = "Provider-owned storage assignment metadata; not a workspace machine handoff or proof of effective access."
  value       = local.project_storage
  depends_on = [
    terraform_data.project_storage_checks, aws_s3_bucket_versioning.project,
    aws_s3_bucket_public_access_block.project, aws_s3_bucket_ownership_controls.project,
    aws_s3_bucket_server_side_encryption_configuration.project, aws_s3_bucket_policy.project,
  ]
}
