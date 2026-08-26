output "deployment_id" {
  value = var.runner_request.deployment_id
}

output "provider" {
  value = var.runner_request.provider
}

output "runner_id" {
  value = azurerm_linux_virtual_machine.runner.id
}

output "workload_identity" {
  value = azurerm_user_assigned_identity.runtime.id
}

output "resolved_profile" {
  value = {
    profile    = var.runner_request.resource_profile
    vm_size    = local.resolved_profile.vm_size
    vcpu       = local.resolved_profile.vcpu
    memory_mib = local.resolved_profile.memory_mib
  }
}

output "deadline" {
  value = var.deadline_utc
}

output "latest_apply_at_utc" {
  value = local.latest_apply_at_utc
}

output "data_uri" {
  value = var.data_uri
}

output "results_uri" {
  value = local.results_uri
}

output "receipt_uri" {
  value = local.receipt_uri
}

output "request_sha256" {
  value = local.request_sha256
}

output "platform_contract_sha256" {
  value = var.platform_contract_sha256
}

output "backend_key" {
  description = "Deterministic remote-state key bound to this one deployment."
  value       = var.backend_key
}

output "management_hint" {
  description = "Read-only provider-native VM observation command."
  value       = "az vm show --ids ${azurerm_linux_virtual_machine.runner.id} --query '{id:id,powerState:instanceView.statuses[-1].displayStatus}' --show-details --output json"
}
