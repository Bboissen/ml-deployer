provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = merge(var.tags, {
      Deployment = var.runner_request.deployment_id
      ManagedBy  = "opentofu"
      Project    = var.project_name
      Root       = "runner"
    })
  }
}
