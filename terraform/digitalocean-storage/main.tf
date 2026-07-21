terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = ">= 2.0, < 3.0"
    }
  }
}

# The broad bootstrap/provider identity is read only from DIGITALOCEAN_TOKEN,
# SPACES_ACCESS_KEY_ID, and SPACES_SECRET_ACCESS_KEY.
provider "digitalocean" {}

resource "digitalocean_vpc" "demo" {
  name   = var.vpc_name
  region = var.region

  lifecycle {
    prevent_destroy = true
  }
}

resource "digitalocean_spaces_bucket" "state" {
  name          = var.state_bucket_name
  region        = var.region
  acl           = "private"
  force_destroy = false

  versioning {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = var.bronze_bucket_name != var.state_bucket_name
      error_message = "bronze_bucket_name must differ from state_bucket_name."
    }
  }
}

resource "digitalocean_spaces_bucket" "bronze" {
  name          = var.bronze_bucket_name
  region        = var.region
  acl           = "private"
  force_destroy = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id                                     = "expire-smoke-test-packs"
    prefix                                 = "smoke/"
    enabled                                = true
    abort_incomplete_multipart_upload_days = 7

    expiration {
      days = 7
    }

    noncurrent_version_expiration {
      days = 90
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "state_bucket_name" {
  value       = digitalocean_spaces_bucket.state.name
  description = "Private Spaces bucket holding infrastructure state."
}

output "state_bucket_endpoint" {
  value       = digitalocean_spaces_bucket.state.endpoint
  description = "Regional Spaces endpoint for the state bucket."
}

output "bronze_bucket_name" {
  value       = digitalocean_spaces_bucket.bronze.name
  description = "Private Spaces bucket holding Demo Bronze objects."
}

output "bronze_bucket_endpoint" {
  value       = digitalocean_spaces_bucket.bronze.endpoint
  description = "Regional Spaces endpoint for the Bronze bucket."
}

output "vpc_uuid" {
  value       = digitalocean_vpc.demo.id
  description = "Authoritative VPC UUID to pass explicitly to the worker root."
}

output "vpc_name" {
  value       = digitalocean_vpc.demo.name
  description = "Persistent VPC name."
}

output "vpc_region" {
  value       = digitalocean_vpc.demo.region
  description = "Persistent VPC region."
}

output "vpc_cidr" {
  value       = digitalocean_vpc.demo.ip_range
  description = "Authoritative VPC CIDR used by Phase 2 route receipts."
}
