locals {
  physical_name_base  = "${var.name_prefix}-${var.project_id}-${var.unique_suffix}"
  data_bucket_name    = "${local.physical_name_base}-data"
  results_bucket_name = "${local.physical_name_base}-results"
  repository_id       = "${var.name_prefix}-runtime"

  common_labels = merge(var.labels, {
    managed_by = "opentofu"
    provider   = "gcp"
    project    = var.name_prefix
  })

  interactive_bindings = {
    for pair in setproduct(
      var.interactive_operator_principals,
      toset(["roles/compute.osLogin", "roles/iap.tunnelResourceAccessor"])
      ) : "${pair[0]}|${pair[1]}" => {
      member = pair[0]
      role   = pair[1]
    }
  }
}

resource "google_storage_bucket" "data" {
  name                        = local.data_bucket_name
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = merge(local.common_labels, { purpose = "data" })

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = length(toset([
        var.state_bucket_name,
        local.data_bucket_name,
        local.results_bucket_name,
      ])) == 3
      error_message = "State, data, and results must use three distinct GCS buckets."
    }
  }
}

resource "google_storage_bucket" "results" {
  name                        = local.results_bucket_name
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = merge(local.common_labels, { purpose = "results" })

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      age            = 7
      matches_prefix = ["tmp/", "runs/unaccepted/"]
      with_state     = "ANY"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_artifact_registry_repository" "runtime" {
  project       = var.project_id
  location      = var.region
  repository_id = local.repository_id
  description   = "Private digest-pinned OCI images for disposable ML runners"
  format        = "DOCKER"
  mode          = "STANDARD_REPOSITORY"
  labels        = merge(local.common_labels, { purpose = "runtime-images" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_network" "runner" {
  project                 = var.project_id
  name                    = "${var.name_prefix}-runner"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_subnetwork" "runner" {
  project                  = var.project_id
  name                     = "${var.name_prefix}-runner-${var.region}"
  region                   = var.region
  network                  = google_compute_network.runner.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
  stack_type               = "IPV4_ONLY"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_router" "runner" {
  project = var.project_id
  name    = "${var.name_prefix}-runner-${var.region}"
  region  = var.region
  network = google_compute_network.runner.id

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_router_nat" "runner" {
  project                             = var.project_id
  name                                = "${var.name_prefix}-runner-${var.region}"
  region                              = var.region
  router                              = google_compute_router.runner.name
  nat_ip_allocate_option              = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat  = "LIST_OF_SUBNETWORKS"
  enable_endpoint_independent_mapping = true

  subnetwork {
    name                    = google_compute_subnetwork.runner.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account" "receipt_publisher" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-receipt-pub"
  display_name = "Completion receipt control publisher"
  description  = "Keyless control-plane identity; never attached or exposed to a runner"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket_iam_member" "receipt_publisher_control_creator" {
  bucket = google_storage_bucket.results.name
  role   = "roles/storage.objectCreator"
  member = google_service_account.receipt_publisher.member

  condition {
    title       = "create_control_evidence_and_receipts"
    description = "Only the distinct publisher creates content-addressed evidence and terminal receipts."
    expression = join("", [
      "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.results.name}/objects/control/evidence/\") || ",
      "(resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.results.name}/objects/control/receipts/\") && ",
      "resource.name.endsWith(\"/completion.v1.json\"))",
    ])
  }
}

resource "google_storage_bucket_iam_member" "receipt_publisher_evidence_reader" {
  bucket = google_storage_bucket.results.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.receipt_publisher.member

  condition {
    title       = "read_runner_control_input"
    description = "Publisher reads only the bounded bootstrap log and local-receipt handoff for a known deployment."
    expression = join("", [
      "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.results.name}/objects/runs/\") && ",
      "(resource.name.endsWith(\"/logs/bootstrap.log\") || ",
      "resource.name.endsWith(\"/control-input/execution-receipt.local.json\"))",
    ])
  }
}

resource "google_project_iam_custom_role" "receipt_publisher_observer" {
  project     = var.project_id
  role_id     = "receiptPublisherObserver"
  title       = "Receipt publisher runner observer"
  description = "Read only runner metadata and bounded serial output for control evidence"
  permissions = [
    "compute.instances.get",
    "compute.instances.getSerialPortOutput",
  ]
  stage = "GA"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_project_iam_member" "receipt_publisher_observer" {
  project = var.project_id
  role    = google_project_iam_custom_role.receipt_publisher_observer.name
  member  = google_service_account.receipt_publisher.member

  condition {
    title       = "observe_disposable_runners_only"
    description = "Compute IAM cannot scope get or serial-output permissions by instance label; constrain to this project's reviewed region and reserved ml- runner namespace."
    expression = join("", [
      "resource.type == \"compute.googleapis.com/Instance\" && ",
      "resource.name.startsWith(\"projects/${var.project_id}/zones/${var.region}-\") && ",
      "resource.name.extract(\"/instances/{name}\").startsWith(\"ml-\")",
    ])
  }
}

resource "google_compute_firewall" "iap_ssh" {
  count = var.enable_iap_ssh ? 1 : 0

  project       = var.project_id
  name          = "${var.name_prefix}-iap-ssh"
  network       = google_compute_network.runner.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["ml-runner-iap"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_project_iam_member" "interactive" {
  for_each = var.enable_iap_ssh ? local.interactive_bindings : {}

  project = var.project_id
  role    = each.value.role
  member  = each.value.member
}
