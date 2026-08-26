terraform {
  # Supply backend.local.example.hcl with an absolute protected path outside
  # the repository. Initializing this backend without that reviewed file is
  # forbidden by the operator workflow.
  backend "local" {}
}
