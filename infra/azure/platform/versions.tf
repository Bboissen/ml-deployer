terraform {
  required_version = "= 1.12.3"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.0.1"
    }
  }
}
