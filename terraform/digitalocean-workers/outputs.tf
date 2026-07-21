output "worker_public_ips" {
  value = digitalocean_droplet.workers[*].ipv4_address
}

output "worker_names" {
  value = digitalocean_droplet.workers[*].name
}

output "worker_droplet_ids" {
  value       = digitalocean_droplet.workers[*].id
  description = "Droplet IDs cross-checked against the DigitalOcean API in Phase 2."
}

output "worker_private_ips" {
  value       = digitalocean_droplet.workers[*].ipv4_address_private
  description = "VPC addresses used only for identity and network evidence, never Ray identity."
}

output "worker_count" {
  value = length(digitalocean_droplet.workers)
}

output "selected_vpc_uuid" {
  value       = var.vpc_uuid
  description = "VPC UUID selected for every worker Droplet."
}

output "selected_vpc_name" {
  value       = var.vpc_name
  description = "Operator-facing name of the selected persistent VPC."
}
