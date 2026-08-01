terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    google = { source = "hashicorp/google", version = ">= 6.0, < 8.0" }
  }
  backend "local" { path = ".bootstrap-state/terraform.tfstate" }
}
