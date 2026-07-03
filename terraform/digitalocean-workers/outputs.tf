output "worker_public_ips" {
  value = digitalocean_droplet.workers[*].ipv4_address
}

output "worker_names" {
  value = digitalocean_droplet.workers[*].name
}

output "worker_count" {
  value = length(digitalocean_droplet.workers)
}
