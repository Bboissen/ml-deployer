# Select TF_WORKSPACE=<deployment_id> so GCS stores the exact object
# gcp/example-project/europe-west1/runner/<deployment_id>.tfstate.
bucket = "ml-infra-example-project-gcp-state"
prefix = "gcp/example-project/europe-west1/runner"
