variable "project_id" {
  description = "Google Cloud project that owns the persistent platform."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid 6-30 character Google Cloud project ID."
  }
}

variable "region" {
  description = "Google Cloud region for storage, registry, and network resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.region))
    error_message = "region must be a canonical Google Cloud region such as europe-west1."
  }
}

variable "state_bucket_name" {
  description = "Protected GCS backend bucket selected by the reviewed bootstrap decision."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a canonical GCS bucket name."
  }
}

variable "name_prefix" {
  description = "Short stable project name used in provider-owned physical names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,10}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-12 lower-case letters, digits, or internal hyphens."
  }
}

variable "unique_suffix" {
  description = "Reviewed non-secret uniqueness suffix for globally named buckets."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{4,8}$", var.unique_suffix))
    error_message = "unique_suffix must be 4-8 lower-case letters or digits."
  }
}

variable "subnet_cidr" {
  description = "Private IPv4 CIDR for disposable runners."
  type        = string
  default     = "10.32.0.0/24"

  validation {
    condition     = can(cidrnetmask(var.subnet_cidr))
    error_message = "subnet_cidr must be a valid IPv4 CIDR."
  }
}

variable "enable_iap_ssh" {
  description = "Whether reviewed operators may use IAP with OS Login; false keeps interactive access disabled."
  type        = bool
  default     = false
}

variable "interactive_operator_principals" {
  description = "Exact principals granted OS Login and IAP tunnel access when enable_iap_ssh is true."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for principal in var.interactive_operator_principals :
      can(regex("^(user|group|serviceAccount):[^[:space:]]+@[^[:space:]]+$", principal))
    ])
    error_message = "Interactive principals must be explicit user:, group:, or serviceAccount: members."
  }

  validation {
    condition     = !var.enable_iap_ssh || length(var.interactive_operator_principals) > 0
    error_message = "enable_iap_ssh requires at least one reviewed interactive operator principal."
  }
}

variable "labels" {
  description = "Additional non-secret platform labels."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for key, value in var.labels : can(regex("^[a-z][a-z0-9_-]{0,62}$", key)) && can(regex("^[a-z0-9_-]{0,63}$", value))])
    error_message = "labels must use conservative Google Cloud label syntax."
  }
}
