locals {
  profile_capacity = {
    smoke = {
      minimum_vcpu       = 2
      minimum_memory_mib = 8192
    }
    balanced = {
      minimum_vcpu       = 4
      minimum_memory_mib = 16384
    }
    highmem = {
      minimum_vcpu       = 4
      minimum_memory_mib = 32768
    }
  }

  runner_request   = var.runner_request
  platform_binding = var.platform_binding

  request_sha256           = sha256(jsonencode(local.runner_request))
  platform_binding_sha256  = sha256(jsonencode(local.platform_binding))
  latest_apply_at_utc      = timeadd(var.started_at_utc, "5m")
  runner_backend_key       = "gcp/${local.platform_binding.project_id}/${local.platform_binding.region}/runner/${var.runner_request.deployment_id}.tfstate"
  runner_name              = "ml-${var.runner_request.deployment_id}"
  absolute_delete_schedule = formatdate("mm hh DD MM *", var.deadline_utc)
  data_uri                 = "gs://${local.platform_binding.data_bucket_name}/"
  results_uri              = "gs://${local.platform_binding.results_bucket_name}/runs/${var.runner_request.deployment_id}/results/"
  receipt_uri              = "gs://${local.platform_binding.results_bucket_name}/control/receipts/${var.runner_request.deployment_id}/completion.v1.json"
  bootstrap_log_object     = "runs/${var.runner_request.deployment_id}/logs/bootstrap.log"
  local_receipt_object     = "runs/${var.runner_request.deployment_id}/control-input/execution-receipt.local.json"

  startup_script = templatefile("${path.module}/templates/startup.sh.tftpl", {
    deployment_id           = var.runner_request.deployment_id
    oci_repository          = var.runner_request.oci_repository
    oci_digest              = var.runner_request.oci_digest
    run_spec_uri            = var.runner_request.run_spec_uri
    run_spec_sha256         = var.runner_request.run_spec_sha256
    run_spec_object_version = var.runner_request.run_spec_object_version
    data_uri                = local.data_uri
    results_uri             = local.results_uri
    maximum_runtime_minutes = var.runner_request.maximum_runtime_minutes
    results_bucket_name     = local.platform_binding.results_bucket_name
    bootstrap_log_encoded   = replace(local.bootstrap_log_object, "/", "%2F")
    local_receipt_encoded   = replace(local.local_receipt_object, "/", "%2F")
    guest_runner_b64        = base64encode(file("${path.module}/../../../shared/bootstrap/guest-runner.sh"))
    deadline_marker_b64     = base64encode(file("${path.module}/../../../shared/bootstrap/deadline-marker.sh"))
  })

  common_labels = merge(var.labels, {
    managed_by = "opentofu"
    provider   = "gcp"
    deployment = var.runner_request.deployment_id
    disposable = "true"
  })
}

resource "google_service_account" "workload" {
  project      = local.platform_binding.project_id
  account_id   = "runner-${substr(sha256(var.runner_request.deployment_id), 0, 16)}"
  display_name = "Workload identity for ${var.runner_request.deployment_id}"
  description  = "Keyless runner-state identity unique to one disposable deployment"
}

resource "google_service_account_iam_member" "deployer_workload_user" {
  service_account_id = google_service_account.workload.name
  role               = "roles/iam.serviceAccountUser"
  member             = var.deployer_principal
}

resource "google_storage_bucket_iam_member" "data_reader" {
  bucket = local.platform_binding.data_bucket_name
  role   = "roles/storage.objectViewer"
  member = google_service_account.workload.member
}

resource "google_artifact_registry_repository_iam_member" "runtime_reader" {
  project    = local.platform_binding.project_id
  location   = local.platform_binding.region
  repository = local.platform_binding.artifact_repository_id
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.workload.member
}

resource "google_service_account" "deadline_deleter" {
  project      = local.platform_binding.project_id
  account_id   = "runner-del-${substr(sha256(var.runner_request.deployment_id), 0, 16)}"
  display_name = "Absolute deadline deleter for ${var.runner_request.deployment_id}"
  description  = "Keyless runner-state identity scoped to deletion of exactly one Compute Engine instance"
}

resource "google_project_iam_custom_role" "deadline_deleter" {
  project     = local.platform_binding.project_id
  role_id     = "runnerDelete_${substr(sha256(var.runner_request.deployment_id), 0, 16)}"
  title       = "Delete runner ${var.runner_request.deployment_id}"
  description = "Runner-state role containing only compute.instances.delete for an exact-instance conditional grant"
  permissions = ["compute.instances.delete"]
  stage       = "GA"
}

resource "google_project_iam_member" "deadline_deleter" {
  project = local.platform_binding.project_id
  role    = google_project_iam_custom_role.deadline_deleter.name
  member  = google_service_account.deadline_deleter.member

  condition {
    title       = "delete_${replace(var.runner_request.deployment_id, "-", "_")}_only"
    description = "Absolute deadline identity can delete only this deployment's exact VM."
    expression = join("", [
      "resource.type == \"compute.googleapis.com/Instance\" && ",
      "resource.name == \"projects/${local.platform_binding.project_id}/zones/${var.zone}/instances/${local.runner_name}\"",
    ])
  }
}

resource "google_storage_bucket_iam_member" "run_spec_reader" {
  bucket = local.platform_binding.results_bucket_name
  role   = "roles/storage.objectViewer"
  member = google_service_account.workload.member

  condition {
    title       = "read_${replace(var.runner_request.deployment_id, "-", "_")}_run_spec"
    description = "This runner may fetch only its exact content-addressed run specification."
    expression  = "resource.name == \"projects/_/buckets/${local.platform_binding.results_bucket_name}/objects/run-specs/${var.runner_request.deployment_id}/${var.runner_request.run_spec_sha256}.json\""
  }
}

resource "google_storage_bucket_iam_member" "results_creator" {
  bucket = local.platform_binding.results_bucket_name
  role   = "roles/storage.objectCreator"
  member = google_service_account.workload.member

  condition {
    title       = "create_${replace(var.runner_request.deployment_id, "-", "_")}_outputs"
    description = "This runner may create result and log objects plus exactly one local-receipt handoff for its deployment."
    expression = join("", [
      "resource.name.startsWith(\"projects/_/buckets/${local.platform_binding.results_bucket_name}/objects/runs/${var.runner_request.deployment_id}/results/\") || ",
      "resource.name.startsWith(\"projects/_/buckets/${local.platform_binding.results_bucket_name}/objects/runs/${var.runner_request.deployment_id}/logs/\") || ",
      "resource.name == \"projects/_/buckets/${local.platform_binding.results_bucket_name}/objects/runs/${var.runner_request.deployment_id}/control-input/execution-receipt.local.json\"",
    ])
  }
}

resource "google_compute_instance" "runner" {
  depends_on = [
    google_service_account_iam_member.deployer_workload_user,
    google_storage_bucket_iam_member.data_reader,
    google_artifact_registry_repository_iam_member.runtime_reader,
    google_storage_bucket_iam_member.run_spec_reader,
    google_storage_bucket_iam_member.results_creator,
  ]

  project                   = local.platform_binding.project_id
  zone                      = var.zone
  name                      = local.runner_name
  machine_type              = var.machine_types[var.runner_request.resource_profile]
  deletion_protection       = false
  allow_stopping_for_update = false
  labels                    = local.common_labels

  boot_disk {
    auto_delete = true

    initialize_params {
      image = var.boot_image
      size  = var.boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    network    = local.platform_binding.network_self_link
    subnetwork = local.platform_binding.subnetwork_self_link

    access_config {
      network_tier = "STANDARD"
    }
  }

  service_account {
    email  = google_service_account.workload.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  tags = local.platform_binding.interactive_access_enabled ? ["ml-runner-iap"] : []

  metadata = {
    enable-oslogin           = local.platform_binding.interactive_access_enabled ? "TRUE" : "FALSE"
    block-project-ssh-keys   = "TRUE"
    ml-deployment-id         = var.runner_request.deployment_id
    ml-provider-deadline-utc = var.deadline_utc
    ml-request-sha256        = local.request_sha256
    ml-platform-binding-hash = local.platform_binding_sha256
  }

  metadata_startup_script = local.startup_script

  scheduling {
    automatic_restart           = false
    on_host_maintenance         = "TERMINATE"
    provisioning_model          = "STANDARD"
    instance_termination_action = "DELETE"

    max_run_duration {
      seconds = var.runner_request.maximum_runtime_minutes * 60
    }
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    precondition {
      condition     = terraform.workspace == var.runner_request.deployment_id
      error_message = "One deployment per state requires TF_WORKSPACE to equal deployment_id."
    }

    precondition {
      condition     = var.zone == "${local.platform_binding.region}-${element(split("-", var.zone), 2)}"
      error_message = "zone must belong to the reviewed region."
    }

    precondition {
      condition     = startswith(var.runner_request.oci_repository, "${local.platform_binding.artifact_repository_uri}/")
      error_message = "oci_repository must use the exact Artifact Registry repository in platform_binding."
    }

    precondition {
      condition     = var.runner_request.run_spec_uri == "gs://${local.platform_binding.results_bucket_name}/run-specs/${var.runner_request.deployment_id}/${var.runner_request.run_spec_sha256}.json"
      error_message = "run_spec_uri must bind the accepted results bucket, deployment ID, and run-spec checksum."
    }

    precondition {
      condition     = local.platform_binding_sha256 == var.platform_binding_sha256
      error_message = "platform_binding_sha256 does not match the exact consumed platform_binding object."
    }

    precondition {
      condition = length(toset([
        local.platform_binding.state_bucket_name,
        local.platform_binding.data_bucket_name,
        local.platform_binding.results_bucket_name,
      ])) == 3
      error_message = "State, data, and results must remain distinct storage boundaries."
    }

    precondition {
      condition = (
        timecmp(timestamp(), var.started_at_utc) >= 0 &&
        timecmp(local.latest_apply_at_utc, timestamp()) >= 0
      )
      error_message = "Runner creation is allowed only inside the reviewed earliest/latest apply window."
    }

    precondition {
      condition = (
        timecmp(var.deadline_utc, local.latest_apply_at_utc) > 0 &&
        timecmp(var.deadline_utc, timeadd(var.started_at_utc, "${var.runner_request.maximum_runtime_minutes}m")) <= 0
      )
      error_message = "deadline_utc must be after latest_apply_at_utc and no later than started_at_utc plus maximum runtime."
    }
  }
}

resource "google_cloud_scheduler_job" "absolute_delete" {
  depends_on = [
    google_compute_instance.runner,
    google_project_iam_member.deadline_deleter,
  ]

  project          = local.platform_binding.project_id
  region           = local.platform_binding.region
  name             = "delete-${var.runner_request.deployment_id}"
  description      = "Absolute DELETE safeguard for ${var.runner_request.deployment_id}; reconcile after terminal observation"
  schedule         = local.absolute_delete_schedule
  time_zone        = "Etc/UTC"
  attempt_deadline = "30s"

  http_target {
    http_method = "DELETE"
    uri         = "https://compute.googleapis.com/compute/v1/projects/${local.platform_binding.project_id}/zones/${var.zone}/instances/${local.runner_name}"

    oauth_token {
      service_account_email = google_service_account.deadline_deleter.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  retry_config {
    retry_count          = 3
    max_retry_duration   = "300s"
    min_backoff_duration = "10s"
    max_backoff_duration = "60s"
    max_doublings        = 3
  }

  lifecycle {
    precondition {
      condition = (
        timecmp(timestamp(), var.started_at_utc) >= 0 &&
        timecmp(local.latest_apply_at_utc, timestamp()) >= 0
      )
      error_message = "Do not create the recurring deletion schedule outside the reviewed apply window."
    }
  }
}
