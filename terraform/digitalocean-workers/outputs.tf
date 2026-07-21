output "worker_public_ips" {
  value = digitalocean_droplet.workers[*].ipv4_address
}

output "worker_names" {
  value = digitalocean_droplet.workers[*].name
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
