variable "runner_request" {
  description = "Exactly one closed version-1 runner request using the frozen common field names."
  type        = any

  validation {
    condition = (
      can(keys(var.runner_request)) &&
      toset(keys(var.runner_request)) == toset([
        "schema_version",
        "deployment_id",
        "provider",
        "oci_repository",
        "oci_digest",
        "run_spec_uri",
        "run_spec_sha256",
        "run_spec_object_version",
        "resource_profile",
        "capacity_mode",
        "maximum_runtime_minutes",
      ])
    )
    error_message = "runner_request must contain exactly the frozen version-1 fields and no unknown input."
  }

  validation {
    condition = (
      try(var.runner_request.schema_version, null) == "1.0.0" &&
      try(var.runner_request.provider, null) == "gcp" &&
      can(regex("^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$", var.runner_request.deployment_id))
    )
    error_message = "runner_request must bind schema 1.0.0, provider gcp, and a valid deployment_id."
  }

  validation {
    condition = (
      can(regex("^[a-z0-9-]+-docker\\.pkg\\.dev/[a-z0-9-]+/[a-z0-9._/-]+$", var.runner_request.oci_repository)) &&
      !can(regex("[@:]", var.runner_request.oci_repository)) &&
      !can(regex("//|\\.\\.", var.runner_request.oci_repository)) &&
      can(regex("^sha256:[0-9a-f]{64}$", var.runner_request.oci_digest))
    )
    error_message = "runner_request must contain a tagless Artifact Registry repository and canonical OCI digest."
  }

  validation {
    condition = (
      can(regex("^gs://[a-z0-9][a-z0-9._-]*/run-specs/[a-z0-9-]+/[0-9a-f]{64}\\.json$", var.runner_request.run_spec_uri)) &&
      !can(regex("[?#@[:space:]]", var.runner_request.run_spec_uri)) &&
      can(regex("^[0-9a-f]{64}$", var.runner_request.run_spec_sha256)) &&
      can(regex("^[1-9][0-9]{0,20}$", var.runner_request.run_spec_object_version))
    )
    error_message = "runner_request must contain a content-addressed GCS run spec, checksum, and positive generation."
  }

  validation {
    condition = (
      contains(["smoke", "balanced", "highmem"], try(var.runner_request.resource_profile, null)) &&
      try(var.runner_request.capacity_mode, null) == "standard" &&
      can(tonumber(var.runner_request.maximum_runtime_minutes)) &&
      tonumber(var.runner_request.maximum_runtime_minutes) >= 15 &&
      tonumber(var.runner_request.maximum_runtime_minutes) <= 720 &&
      floor(tonumber(var.runner_request.maximum_runtime_minutes)) == tonumber(var.runner_request.maximum_runtime_minutes)
    )
    error_message = "runner_request profile, standard capacity mode, or integer runtime bound is invalid."
  }
}

variable "platform_binding" {
  description = "Exact closed provider-specific binding emitted by the accepted persistent platform state."
  type        = any

  validation {
    condition = (
      can(keys(var.platform_binding)) &&
      toset(keys(var.platform_binding)) == toset([
        "schema_version",
        "provider",
        "project_id",
        "region",
        "state_bucket_name",
        "data_bucket_name",
        "results_bucket_name",
        "artifact_repository_id",
        "artifact_repository_uri",
        "network_self_link",
        "subnetwork_self_link",
        "receipt_publisher_service_account_email",
        "workload_results_prefix",
        "reserved_control_prefix",
        "bootstrap_log_suffix",
        "local_receipt_handoff_suffix",
        "interactive_access_enabled",
      ])
    )
    error_message = "platform_binding must contain exactly the frozen GCP platform fields and no unknown input."
  }

  validation {
    condition = try(
      var.platform_binding.schema_version == "1.0.0" &&
      var.platform_binding.provider == "gcp" &&
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.platform_binding.project_id)) &&
      can(regex("^[a-z]+-[a-z]+[0-9]$", var.platform_binding.region)),
      false,
    )
    error_message = "platform_binding must bind schema 1.0.0, provider gcp, and canonical project/region values."
  }

  validation {
    condition = try(
      alltrue([
        for bucket_name in [
          var.platform_binding.state_bucket_name,
          var.platform_binding.data_bucket_name,
          var.platform_binding.results_bucket_name,
        ] : can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", bucket_name))
      ]) &&
      length(toset([
        var.platform_binding.state_bucket_name,
        var.platform_binding.data_bucket_name,
        var.platform_binding.results_bucket_name,
      ])) == 3,
      false,
    )
    error_message = "platform_binding must identify three distinct canonical state, data, and results buckets."
  }

  validation {
    condition = try(
      can(regex("^[a-z][a-z0-9-]{1,61}[a-z0-9]$", var.platform_binding.artifact_repository_id)) &&
      var.platform_binding.artifact_repository_uri == "${var.platform_binding.region}-docker.pkg.dev/${var.platform_binding.project_id}/${var.platform_binding.artifact_repository_id}" &&
      can(regex("^https://www.googleapis.com/compute/v1/projects/${var.platform_binding.project_id}/global/networks/[a-z][a-z0-9-]+$", var.platform_binding.network_self_link)) &&
      can(regex("^https://www.googleapis.com/compute/v1/projects/${var.platform_binding.project_id}/regions/${var.platform_binding.region}/subnetworks/[a-z][a-z0-9-]+$", var.platform_binding.subnetwork_self_link)),
      false,
    )
    error_message = "platform_binding registry, network, and subnetwork identifiers must be internally bound to its project and region."
  }

  validation {
    condition = try(
      var.platform_binding.receipt_publisher_service_account_email != "" &&
      endswith(var.platform_binding.receipt_publisher_service_account_email, "@${var.platform_binding.project_id}.iam.gserviceaccount.com") &&
      var.platform_binding.workload_results_prefix == "runs/" &&
      var.platform_binding.reserved_control_prefix == "control/" &&
      var.platform_binding.bootstrap_log_suffix == "/logs/bootstrap.log" &&
      var.platform_binding.local_receipt_handoff_suffix == "/control-input/execution-receipt.local.json" &&
      contains(["true", "false"], jsonencode(var.platform_binding.interactive_access_enabled)),
      false,
    )
    error_message = "platform_binding publisher, storage namespaces, or interactive-access flag is invalid."
  }
}

variable "platform_binding_sha256" {
  description = "Accepted deterministic digest of the exact platform_binding object."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.platform_binding_sha256))
    error_message = "platform_binding_sha256 must be a lower-case SHA-256 digest."
  }
}

variable "deployer_principal" {
  description = "Exact temporary operator identity allowed to attach this deployment's workload service account."
  type        = string

  validation {
    condition     = can(regex("^(user|group|serviceAccount):[^[:space:]]+@[^[:space:]]+$", var.deployer_principal))
    error_message = "deployer_principal must be an explicit user:, group:, or serviceAccount: member."
  }
}

variable "zone" {
  description = "Reviewed Compute Engine zone inside region."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]-[a-z]$", var.zone))
    error_message = "zone must be a canonical Google Cloud zone."
  }
}

variable "boot_image" {
  description = "Reviewed immutable boot image self-link or image name; image families are forbidden."
  type        = string

  validation {
    condition = (
      can(regex("^projects/[a-z0-9-]+/global/images/[a-z0-9-]+$", var.boot_image)) &&
      !can(regex("/famil(y|ies)/", var.boot_image))
    )
    error_message = "boot_image must name an immutable projects/.../global/images/... image, not a family."
  }
}

variable "boot_disk_size_gb" {
  description = "Disposable runner boot disk size."
  type        = number
  default     = 30

  validation {
    condition     = var.boot_disk_size_gb >= 20 && var.boot_disk_size_gb <= 200 && floor(var.boot_disk_size_gb) == var.boot_disk_size_gb
    error_message = "boot_disk_size_gb must be a whole number from 20 through 200."
  }
}

variable "machine_types" {
  description = "Reviewed GCP machine mapping for the common capacity profiles."
  type        = map(string)
  default = {
    smoke    = "e2-standard-2"
    balanced = "e2-standard-4"
    highmem  = "e2-highmem-4"
  }

  validation {
    condition = (
      toset(keys(var.machine_types)) == toset(["smoke", "balanced", "highmem"]) &&
      alltrue([for machine_type in values(var.machine_types) : can(regex("^[a-z][a-z0-9-]+$", machine_type))])
    )
    error_message = "machine_types must map exactly smoke, balanced, and highmem to canonical GCP machine types."
  }
}

variable "started_at_utc" {
  description = "Reviewed earliest apply boundary for this deployment; the latest boundary is fixed at five minutes later."
  type        = string

  validation {
    condition = (
      can(formatdate("YYYY-MM-DD'T'hh:mm:ss'Z'", var.started_at_utc)) &&
      can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:00Z$", var.started_at_utc))
    )
    error_message = "started_at_utc must be a valid RFC 3339 UTC timestamp on an exact minute (:00Z)."
  }
}

variable "deadline_utc" {
  description = "Reviewed absolute UTC upper bound for this deployment."
  type        = string

  validation {
    condition = (
      can(formatdate("YYYY-MM-DD'T'hh:mm:ss'Z'", var.deadline_utc)) &&
      can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:00Z$", var.deadline_utc))
    )
    error_message = "deadline_utc must be a valid RFC 3339 UTC timestamp on an exact minute (:00Z)."
  }
}

variable "labels" {
  description = "Additional non-secret labels for the disposable runner."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for key, value in var.labels : can(regex("^[a-z][a-z0-9_-]{0,62}$", key)) && can(regex("^[a-z0-9_-]{0,63}$", value))])
    error_message = "labels must use conservative Google Cloud label syntax."
  }
}
