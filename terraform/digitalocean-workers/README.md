# DigitalOcean worker Terraform

This module creates **workers only**. The Ray head is your home server on Tailscale.

## Plan

```bash
terraform init
terraform plan -var="worker_count=1"
```

## Apply

Billable:

```bash
terraform apply -var="worker_count=1"
```

## Destroy

```bash
terraform destroy
```

## Security notes

- Tailscale auth key is rendered into cloud-init and therefore may be stored in local Terraform state.
- Keep state local and ignored.
- Use short-lived ephemeral auth keys and rotate after use.
- No public Ray ports are opened by the DigitalOcean firewall.
