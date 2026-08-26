resource "azurerm_resource_group" "runner" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_user_assigned_identity" "runtime" {
  name                = "${local.name_prefix}-runtime"
  resource_group_name = azurerm_resource_group.runner.name
  location            = azurerm_resource_group.runner.location
  tags                = merge(local.tags, { request-sha256 = local.request_sha256 })
}

resource "azurerm_network_interface" "runner" {
  name                = "${local.name_prefix}-nic"
  resource_group_name = azurerm_resource_group.runner.name
  location            = azurerm_resource_group.runner.location
  tags                = local.tags

  ip_configuration {
    name                          = "private"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "runner" {
  depends_on = [
    azurerm_role_assignment.runtime_data_reader,
    azurerm_role_assignment.runtime_deployment_writer,
    azurerm_role_assignment.runtime_registry_pull,
    azurerm_role_assignment.runtime_run_spec_reader,
  ]

  name                            = "${local.name_prefix}-vm"
  resource_group_name             = azurerm_resource_group.runner.name
  location                        = azurerm_resource_group.runner.location
  size                            = local.resolved_profile.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.runner.id]
  source_image_id                 = var.source_image_id
  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    guest_request_base64   = base64encode(jsonencode(local.guest_request))
    guest_runner_base64    = filebase64("${path.module}/../../../shared/bootstrap/guest-runner.sh")
    deadline_helper_base64 = filebase64("${path.module}/../../../shared/bootstrap/deadline-marker.sh")
    azure_wrapper_base64   = filebase64("${path.module}/azure-runner-wrapper.sh")
  }))
  encryption_at_host_enabled = true
  secure_boot_enabled        = true
  vtpm_enabled               = true
  tags                       = local.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.runtime.id]
  }

  os_disk {
    name                 = "${local.name_prefix}-os"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }

  boot_diagnostics {}

  lifecycle {
    precondition {
      condition     = var.runner_request.run_spec_uri == local.expected_run_spec
      error_message = "run_spec_uri must bind this deployment ID and run-spec SHA-256 in the results container."
    }

    precondition {
      condition     = var.backend_key == local.expected_backend_key && var.account_scope == lower(var.subscription_id)
      error_message = "backend_key and account_scope must bind the reviewed Azure subscription, region and deployment ID."
    }

    precondition {
      condition = (
        var.state_resource_group_name == local.state_resource_group_name &&
        var.state_storage_account_name == local.state_storage_account_name &&
        var.state_container_name == "tfstate" &&
        lower(var.state_storage_account_id) == lower(local.state_storage_account_id) &&
        lower(var.state_container_id) == lower(local.state_container_id) &&
        var.state_storage_account_name != local.storage_account_name &&
        lower(var.state_storage_account_id) != lower(local.storage_account_id)
      )
      error_message = "External backend storage must match the accepted bootstrap identity and remain separate from workload storage."
    }

    precondition {
      condition = (
        lower(var.subnet_id) == lower(local.expected_subnet_id) &&
        lower(var.receipt_publisher_identity_id) == lower(local.expected_receipt_publisher_identity_id)
      )
      error_message = "Subnet and receipt-publisher resource IDs must bind the accepted persistent platform."
    }

    precondition {
      condition = (
        lower(var.data_container_id) == lower(local.expected_data_container_id) &&
        lower(var.results_container_id) == lower(local.expected_results_container_id) &&
        lower(var.control_container_id) == lower(local.expected_control_container_id) &&
        var.data_uri == local.expected_data_uri &&
        var.results_container_uri == local.expected_results_container_uri &&
        var.control_container_uri == local.expected_control_container_uri
      )
      error_message = "Data, results and control container IDs and URIs must bind one accepted workload storage account."
    }

    precondition {
      condition = (
        lower(var.container_registry_id) == lower(local.expected_registry_id) &&
        var.container_registry_login_server == local.expected_registry_login_server &&
        startswith(var.runner_request.oci_repository, "${var.container_registry_login_server}/")
      )
      error_message = "The OCI repository must bind the accepted provider-local Azure Container Registry."
    }

    precondition {
      condition = (
        startswith(lower(var.results_blob_writer_role_definition_id), "/subscriptions/${lower(var.subscription_id)}/") &&
        strcontains(lower(var.results_blob_writer_role_definition_id), "/providers/microsoft.authorization/roledefinitions/") &&
        startswith(lower(var.source_image_id), "/subscriptions/${lower(var.subscription_id)}/")
      )
      error_message = "The custom writer role and immutable source image must bind the reviewed Azure subscription."
    }

    precondition {
      condition     = var.platform_contract_sha256 == sha256(jsonencode(local.platform_interface))
      error_message = "platform_contract_sha256 must match the exact accepted Azure platform interface."
    }

    precondition {
      condition     = timecmp(plantimestamp(), local.latest_apply_at_utc) <= 0
      error_message = "The plan was generated after the Azure latest-apply boundary."
    }

    precondition {
      condition     = timecmp(timestamp(), var.started_at_utc) >= 0 && timecmp(timestamp(), local.latest_apply_at_utc) <= 0
      error_message = "Apply must occur inside the reviewed five-minute window from started_at_utc through latest_apply_at_utc."
    }

    precondition {
      condition     = timecmp(var.deadline_utc, local.latest_apply_at_utc) > 0 && timecmp(var.deadline_utc, timeadd(var.started_at_utc, "${var.runner_request.maximum_runtime_minutes}m")) <= 0
      error_message = "deadline_utc must be after latest_apply_at_utc and no later than started_at_utc plus the accepted maximum runtime."
    }
  }
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "deadline" {
  virtual_machine_id    = azurerm_linux_virtual_machine.runner.id
  location              = azurerm_resource_group.runner.location
  enabled               = true
  daily_recurrence_time = local.shutdown_time_utc
  timezone              = "UTC"
  tags                  = local.tags

  notification_settings {
    enabled = false
  }
}
