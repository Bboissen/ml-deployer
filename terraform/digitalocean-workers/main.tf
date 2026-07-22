data "digitalocean_ssh_key" "main" {
  name = var.ssh_key_name
}

resource "digitalocean_tag" "ray" {
  count = var.worker_count > 0 ? 1 : 0

  name = var.cluster_name
}

resource "digitalocean_droplet" "workers" {
  count    = var.worker_count
  image    = var.image
  name     = format("%s-worker-%02d", var.cluster_name, count.index + 1)
  region   = var.region
  size     = var.size
  vpc_uuid = var.vpc_uuid
  ssh_keys = [data.digitalocean_ssh_key.main.id]
  tags     = var.worker_count > 0 ? [digitalocean_tag.ray[0].name] : []

  ipv6       = false
  monitoring = true

  lifecycle {
    precondition {
      condition = var.allow_phase1_plan_sentinel || (
        var.vpc_uuid != "00000000-0000-4000-8000-000000000000" &&
        var.vpc_name != "phase1-plan-sentinel" &&
        var.vpc_cidr != "10.255.240.0/20"
      )
      error_message = "Phase 1 sentinel VPC values are forbidden for apply and live workers."
    }
  }

  user_data = templatefile("${path.module}/../../cloud-init/do-worker.yaml.tftpl", {
    worker_hostname         = format("%s-worker-%02d", var.cluster_name, count.index + 1)
    tailscale_auth_key      = var.tailscale_auth_key
    ray_head_tailscale_ip   = var.ray_head_tailscale_ip
    ray_object_store_memory = var.ray_object_store_memory
    vpc_resolver_ip         = cidrhost(var.vpc_cidr, -2)
  })
}

resource "digitalocean_firewall" "workers" {
  count = var.worker_count > 0 ? 1 : 0

  name = "${var.cluster_name}-workers-fw"

  droplet_ids = digitalocean_droplet.workers[*].id

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = [var.admin_public_cidr]
  }

  # No public Ray ports. Ray communication happens over Tailscale.

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
