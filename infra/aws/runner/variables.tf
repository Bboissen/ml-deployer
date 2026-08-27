variable "runner_request" {
  description = "Closed frozen Goal 02 request for exactly one AWS runner state. Field names match the common contract."
  type = object({
    schema_version          = string
    deployment_id           = string
    provider                = string
    oci_repository          = string
    oci_digest              = string
    run_spec_uri            = string
    run_spec_sha256         = string
    run_spec_object_version = string
    resource_profile        = string
    capacity_mode           = string
    maximum_runtime_minutes = number
  })

  validation {
    condition     = var.runner_request.schema_version == "1.0.0"
    error_message = "runner_request.schema_version must be 1.0.0."
  }

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{1,46}[a-z0-9])$", var.runner_request.deployment_id))
    error_message = "runner_request.deployment_id must be 3-48 lower-case letters, digits or internal hyphens."
  }

  validation {
    condition     = var.runner_request.provider == "aws"
    error_message = "runner_request.provider must be aws."
  }

  validation {
    condition     = length(var.runner_request.oci_repository) <= 255 && can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)+$", var.runner_request.oci_repository))
    error_message = "runner_request.oci_repository must be a provider-local ECR repository without a tag or digest."
  }

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.runner_request.oci_digest))
    error_message = "runner_request.oci_digest must be sha256 followed by 64 lower-case hexadecimal characters."
  }

  validation {
    condition     = length(var.runner_request.run_spec_uri) <= 2048 && can(regex("^s3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]/[^?#[:space:]]+$", var.runner_request.run_spec_uri))
    error_message = "runner_request.run_spec_uri must be a credential-free provider-local S3 URI."
  }

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.runner_request.run_spec_sha256))
    error_message = "runner_request.run_spec_sha256 must contain 64 lower-case hexadecimal characters."
  }

  validation {
    condition     = length(var.runner_request.run_spec_object_version) >= 1 && length(var.runner_request.run_spec_object_version) <= 512 && can(regex("^[^[:cntrl:][:space:]]+$", var.runner_request.run_spec_object_version))
    error_message = "runner_request.run_spec_object_version must be a bounded non-whitespace S3 version identifier."
  }

  validation {
    condition     = contains(["smoke", "balanced", "highmem"], var.runner_request.resource_profile)
    error_message = "runner_request.resource_profile must be smoke, balanced or highmem."
  }

  validation {
    condition     = var.runner_request.capacity_mode == "standard"
    error_message = "runner_request.capacity_mode must be standard until interruptible recovery is accepted."
  }

  validation {
    condition     = var.runner_request.maximum_runtime_minutes == floor(var.runner_request.maximum_runtime_minutes) && var.runner_request.maximum_runtime_minutes >= 15 && var.runner_request.maximum_runtime_minutes <= 720
    error_message = "runner_request.maximum_runtime_minutes must be an integer from 15 through 720."
  }
}

variable "platform_contract" {
  description = "Closed provider-specific binding emitted by the accepted AWS platform root."
  type        = any

  validation {
    condition = try(
      length(keys(var.platform_contract)) == 17 &&
      length(setsubtract(toset(keys(var.platform_contract)), toset([
        "schema_version",
        "provider",
        "aws_account_id",
        "aws_region",
        "state_bucket_name",
        "state_bucket_arn",
        "data_bucket_name",
        "data_bucket_arn",
        "results_bucket_name",
        "results_bucket_arn",
        "runner_subnet_id",
        "runner_security_group_id",
        "ecr_repository_url",
        "ecr_repository_arn",
        "runtime_permissions_boundary_arn",
        "scheduler_permissions_boundary_arn",
        "receipt_publisher_role_arn",
      ]))) == 0,
      false,
    )
    error_message = "platform_contract must contain exactly the 17 documented AWS binding fields."
  }

  validation {
    condition = try(
      var.platform_contract.schema_version == "1.0.0" &&
      var.platform_contract.provider == "aws",
      false,
    )
    error_message = "platform_contract must use schema 1.0.0 and provider aws."
  }
}

variable "aws_region" {
  description = "Reviewed AWS region for this deployment."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(?:-gov)?-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a conservative AWS region identifier."
  }
}

variable "aws_account_id" {
  description = "Expected AWS account ID; provider operations fail closed in any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must contain exactly 12 digits."
  }
}

variable "project_name" {
  description = "Short lower-case project identifier used in tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-32 lower-case letters, digits or internal hyphens."
  }
}

variable "resource_prefix" {
  description = "Reviewed lower-case prefix for deployment resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}$", var.resource_prefix))
    error_message = "resource_prefix must be 3-24 lower-case letters, digits or hyphens and start with a letter."
  }
}

variable "deployer_role_arn" {
  description = "Accepted persistent least-privilege role assumed for disposable runner operations."
  type        = string

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov):iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", var.deployer_role_arn))
    error_message = "deployer_role_arn must be an IAM role ARN."
  }
}

variable "ami_id" {
  description = "Reviewed x86-64 Amazon ECS-optimized Linux AMI with AWS CLI, Docker, SSM Agent and GNU coreutils installed."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must be an AMI identifier."
  }
}

variable "instance_type_by_profile" {
  description = "Reviewed AWS mapping for each common resource profile; live quota/capacity preflight remains mandatory."
  type        = map(string)
  default = {
    smoke    = "t3.large"
    balanced = "m7i.xlarge"
    highmem  = "r7i.xlarge"
  }

  validation {
    condition = (
      length(keys(var.instance_type_by_profile)) == 3 &&
      length(setsubtract(toset(keys(var.instance_type_by_profile)), toset(["smoke", "balanced", "highmem"]))) == 0 &&
      alltrue([for value in values(var.instance_type_by_profile) : can(regex("^[a-z0-9]+[a-z0-9.-]*$", value))])
    )
    error_message = "instance_type_by_profile must map exactly smoke, balanced and highmem to reviewed EC2 instance types."
  }
}

variable "subnet_id" {
  description = "Accepted persistent platform runner subnet ID."
  type        = string

  validation {
    condition     = can(regex("^subnet-[0-9a-f]{8,17}$", var.subnet_id))
    error_message = "subnet_id must be an AWS subnet identifier."
  }
}

variable "security_group_id" {
  description = "Accepted persistent platform no-ingress security group ID."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]{8,17}$", var.security_group_id))
    error_message = "security_group_id must be an AWS security-group identifier."
  }
}

variable "associate_public_ipv4_address" {
  description = "Use public outbound connectivity in the accepted no-ingress platform subnet."
  type        = bool
  default     = true
}

variable "data_bucket_name" {
  description = "Accepted persistent generic data bucket name."
  type        = string

  validation {
    condition     = length(var.data_bucket_name) >= 3 && length(var.data_bucket_name) <= 63 && can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.data_bucket_name)) && !strcontains(var.data_bucket_name, "..")
    error_message = "data_bucket_name must be a conservative S3 bucket name."
  }
}

variable "data_bucket_arn" {
  description = "Accepted persistent generic data bucket ARN."
  type        = string

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov):s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.data_bucket_arn))
    error_message = "data_bucket_arn must be an S3 bucket ARN."
  }
}

variable "results_bucket_name" {
  description = "Accepted persistent results bucket name."
  type        = string

  validation {
    condition     = length(var.results_bucket_name) >= 3 && length(var.results_bucket_name) <= 63 && can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.results_bucket_name)) && !strcontains(var.results_bucket_name, "..")
    error_message = "results_bucket_name must be a conservative S3 bucket name."
  }
}

variable "results_bucket_arn" {
  description = "Accepted persistent results bucket ARN."
  type        = string

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov):s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.results_bucket_arn))
    error_message = "results_bucket_arn must be an S3 bucket ARN."
  }
}

variable "ecr_repository_arn" {
  description = "Accepted provider-local immutable ECR repository ARN."
  type        = string

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov):ecr:[a-z0-9-]+:[0-9]{12}:repository/[a-z0-9]+(?:[._/-][a-z0-9]+)*$", var.ecr_repository_arn))
    error_message = "ecr_repository_arn must be an ECR repository ARN."
  }
}

variable "state_bucket_arn" {
  description = "Accepted state bucket ARN explicitly denied to the runtime identity."
  type        = string

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov):s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_arn))
    error_message = "state_bucket_arn must be an S3 bucket ARN."
  }
}

variable "runtime_permissions_boundary_arn" {
  description = "Accepted persistent runtime maximum-permissions boundary ARN."
  type        = string

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov):iam::[0-9]{12}:policy/[A-Za-z0-9+=,.@_/-]+$", var.runtime_permissions_boundary_arn))
    error_message = "runtime_permissions_boundary_arn must be an IAM policy ARN."
  }
}

variable "scheduler_permissions_boundary_arn" {
  description = "Accepted persistent maximum-permissions boundary for provider-side deadline roles."
  type        = string

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov):iam::[0-9]{12}:policy/[A-Za-z0-9+=,.@_/-]+$", var.scheduler_permissions_boundary_arn))
    error_message = "scheduler_permissions_boundary_arn must be an IAM policy ARN."
  }
}

variable "receipt_publisher_role_arn" {
  description = "Accepted distinct control-plane publisher role explicitly unavailable to the runner."
  type        = string

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov):iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", var.receipt_publisher_role_arn))
    error_message = "receipt_publisher_role_arn must be an IAM role ARN."
  }
}

variable "account_scope" {
  description = "Non-secret account scope used in the deterministic backend key."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$", var.account_scope))
    error_message = "account_scope must be a bounded non-secret backend component."
  }
}

variable "backend_key" {
  description = "Reviewed per-deployment remote-state key."
  type        = string

  validation {
    condition     = can(regex("^aws/[0-9]{12}/[a-z0-9-]+/runner/[a-z0-9](?:[a-z0-9-]{1,46}[a-z0-9])\\.tfstate$", var.backend_key))
    error_message = "backend_key must be a deterministic AWS per-deployment runner state key."
  }
}

variable "backend_bucket_name" {
  description = "Expected accepted state bucket used by the externally supplied runner backend configuration."
  type        = string

  validation {
    condition     = length(var.backend_bucket_name) >= 3 && length(var.backend_bucket_name) <= 63 && can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.backend_bucket_name)) && !strcontains(var.backend_bucket_name, "..")
    error_message = "backend_bucket_name must be a conservative S3 bucket name."
  }
}

variable "started_at_utc" {
  description = "Reviewed planned start timestamp used to bound the absolute provider deadline."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.started_at_utc))
    error_message = "started_at_utc must be a whole-second UTC RFC3339 timestamp."
  }
}

variable "deadline_utc" {
  description = "Absolute provider-side stop deadline."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.deadline_utc))
    error_message = "deadline_utc must be a whole-second UTC RFC3339 timestamp."
  }
}

variable "root_volume_size_gib" {
  description = "Encrypted gp3 root volume size."
  type        = number
  default     = 40

  validation {
    condition     = var.root_volume_size_gib == floor(var.root_volume_size_gib) && var.root_volume_size_gib >= 20 && var.root_volume_size_gib <= 500
    error_message = "root_volume_size_gib must be an integer from 20 through 500."
  }
}

variable "tags" {
  description = "Additional non-secret ownership and cost-allocation tags."
  type        = map(string)
  default     = {}
}
