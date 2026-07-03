variable "do_token" {
  type      = string
  sensitive = true
}

variable "region" {
  type    = string
  default = "ams3"
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
