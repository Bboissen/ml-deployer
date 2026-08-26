variable "aws_region" {
  description = "Reviewed AWS region for the persistent platform."
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
  description = "Short lower-case project identifier used in names and tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-32 lower-case letters, digits or internal hyphens."
  }
}

variable "resource_prefix" {
  description = "Reviewed lower-case prefix for AWS resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}$", var.resource_prefix))
    error_message = "resource_prefix must be 3-24 lower-case letters, digits or hyphens and start with a letter."
  }
}

variable "state_bucket_arn" {
  description = "Accepted bootstrap state bucket ARN denied to all runtime identities."
  type        = string

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov):s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_arn))
    error_message = "state_bucket_arn must be a private S3 bucket ARN."
  }
}

variable "data_bucket_name" {
  description = "Globally unique reviewed name for the initially empty generic data bucket."
  type        = string

  validation {
    condition     = length(var.data_bucket_name) >= 3 && length(var.data_bucket_name) <= 63 && can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.data_bucket_name)) && !strcontains(var.data_bucket_name, "..")
    error_message = "data_bucket_name must be a conservative S3 bucket name."
  }
}

variable "results_bucket_name" {
  description = "Globally unique reviewed name for run specifications, logs, results and controlled receipts."
  type        = string

  validation {
    condition     = length(var.results_bucket_name) >= 3 && length(var.results_bucket_name) <= 63 && can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.results_bucket_name)) && !strcontains(var.results_bucket_name, "..")
    error_message = "results_bucket_name must be a conservative S3 bucket name."
  }
}

variable "ecr_repository_name" {
  description = "Provider-local immutable ECR repository receiving the canonical OCI digest."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+(?:[._/-][a-z0-9]+)*$", var.ecr_repository_name))
    error_message = "ecr_repository_name must be a conservative lower-case ECR repository path."
  }
}

variable "availability_zone" {
  description = "Reviewed availability zone for the runner subnet."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(?:-gov)?-[a-z]+-[0-9]+[a-z]$", var.availability_zone))
    error_message = "availability_zone must be a conservative AWS availability-zone identifier."
  }
}

variable "vpc_cidr" {
  description = "Private IPv4 CIDR for the isolated runner VPC."
  type        = string
  default     = "10.80.0.0/20"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "runner_subnet_cidr" {
  description = "IPv4 CIDR for the no-ingress runner subnet."
  type        = string
  default     = "10.80.0.0/24"

  validation {
    condition     = can(cidrhost(var.runner_subnet_cidr, 0))
    error_message = "runner_subnet_cidr must be a valid IPv4 CIDR."
  }
}

variable "receipt_publisher_principal_arns" {
  description = "Reviewed temporary IAM principals allowed to assume the distinct control-plane receipt publisher."
  type        = list(string)

  validation {
    condition = (
      length(var.receipt_publisher_principal_arns) > 0 &&
      alltrue([
        for arn in var.receipt_publisher_principal_arns :
        can(regex("^arn:(aws|aws-us-gov):iam::[0-9]{12}:(?:role|user)/[A-Za-z0-9+=,.@_/-]+$", arn))
      ])
    )
    error_message = "receipt_publisher_principal_arns must contain reviewed IAM role or user ARNs."
  }
}

variable "tags" {
  description = "Additional non-secret ownership and cost-allocation tags."
  type        = map(string)
  default     = {}
}
