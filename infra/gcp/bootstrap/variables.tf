variable "project_id" {
  description = "Google Cloud project that owns the state bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid 6-30 character Google Cloud project ID."
  }
}

variable "region" {
  description = "Google Cloud region used in the deterministic backend namespace."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.region))
    error_message = "region must be a canonical Google Cloud region such as europe-west1."
  }
}

variable "state_bucket_name" {
  description = "Globally unique private GCS bucket name reserved for OpenTofu state."
  type        = string

  validation {
    condition = (
      length(var.state_bucket_name) >= 3 &&
      length(var.state_bucket_name) <= 63 &&
      can(regex("^[a-z0-9][a-z0-9._-]*[a-z0-9]$", var.state_bucket_name)) &&
      !can(regex("\\.\\.", var.state_bucket_name))
    )
    error_message = "state_bucket_name must satisfy conservative GCS bucket naming rules."
  }
}

variable "state_bucket_mode" {
  description = "Explicit state bucket disposition: create a new bucket or inspect an adoption candidate."
  type        = string

  validation {
    condition     = contains(["create", "adopt_managed"], var.state_bucket_mode)
    error_message = "state_bucket_mode must be create or adopt_managed."
  }
}

variable "adoption_evidence_sha256" {
  description = "Reviewed inventory/state-lineage evidence digest required for adopt_managed preparation."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = (
      var.state_bucket_mode == "create" ||
      (var.adoption_evidence_sha256 != null && can(regex("^[0-9a-f]{64}$", var.adoption_evidence_sha256)))
    )
    error_message = "adopt_managed requires a lower-case SHA-256 evidence digest."
  }
}

variable "labels" {
  description = "Additional non-secret labels for a newly created state bucket."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for key, value in var.labels : can(regex("^[a-z][a-z0-9_-]{0,62}$", key)) && can(regex("^[a-z0-9_-]{0,63}$", value))])
    error_message = "labels must use conservative Google Cloud label syntax."
  }
}
