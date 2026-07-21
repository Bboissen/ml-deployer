variable "do_token" {
  type      = string
  sensitive = true
}

variable "region" {
  type    = string
  default = "ams3"

  validation {
    condition     = var.region == "ams3"
    error_message = "region must be ams3 for the persistent storage and worker VPC contract."
  }
}

variable "vpc_uuid" {
  type        = string
  description = "UUID exported by the persistent storage root. A sentinel UUID is allowed only for code-only plan validation."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$", var.vpc_uuid))
    error_message = "vpc_uuid must be a syntactically valid UUID."
  }
}

variable "vpc_name" {
  type        = string
  description = "Non-secret VPC name recorded with plans and receipts for operator context."

  validation {
    condition     = length(trimspace(var.vpc_name)) > 0
    error_message = "vpc_name must not be empty."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "IPv4 CIDR exported by the persistent storage root; its second-to-last address is the VPC-local DNS resolver."

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && can(cidrhost(var.vpc_cidr, -2))
    error_message = "vpc_cidr must be a valid IPv4 CIDR with room for the VPC-local resolver."
  }
}

variable "allow_phase1_plan_sentinel" {
  type        = bool
  description = "Internal code-plan-only override for the exact Phase 1 VPC sentinel. Never enable for apply or live workers."
  default     = false
}

variable "image" {
  type    = string
  default = "ubuntu-24-04-x64"
}

variable "size" {
  type    = string
  default = "s-1vcpu-512mb-10gb"
}

variable "worker_count" {
  type    = number
  default = 1

  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 10
    error_message = "worker_count must be between 0 and 10 for the current account limit."
  }
}

variable "cluster_name" {
  type    = string
  default = "spotify-ray"
}

variable "ssh_key_name" {
  type        = string
  description = "Existing DigitalOcean SSH key name."
}

variable "admin_public_cidr" {
  type        = string
  description = "Admin public IP CIDR for emergency SSH, e.g. 1.2.3.4/32."
}

variable "tailscale_auth_key" {
  type      = string
  sensitive = true
}

variable "ray_head_tailscale_ip" {
  type        = string
  description = "Tailscale IPv4 of the home server running Ray head."
}

variable "ray_object_store_memory" {
  type    = number
  default = 80000000
}
