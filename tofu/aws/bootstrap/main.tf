provider "aws" {
  region              = var.region
  profile             = var.profile
  allowed_account_ids = [var.account_id]

  dynamic "assume_role" {
    for_each = var.deployer_role_arn == "" ? [] : [var.deployer_role_arn]
    content {
      role_arn = assume_role.value
    }
  }

  default_tags {
    tags = {
      project     = "spotify-predictor"
      environment = "platform"
      managed_by  = "opentofu"
    }
  }
}

# Goal 02 scaffold only. Goal 03 adds the protected state bucket and deployer role.
