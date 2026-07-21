# Security hardening

## Core rules

1. Ray traffic must stay on Tailscale.
2. DigitalOcean public firewalls must not expose Ray ports.
3. SSH over public IP is optional and must be restricted to `admin_public_cidr`.
4. Use ephemeral/pre-authorized Tailscale auth keys for workers.
5. Do not commit Terraform state, `.env`, or `terraform.tfvars`.
6. Destroy cloud workers immediately after the run.
7. Keep persistent Spaces and VPC state separate from disposable worker state.
8. Issue storage identities by role and never render Spaces secrets into Terraform variables or cloud-init.

## Tailscale auth key

Create an auth key with:

- reusable: yes, for multiple workers
- ephemeral: yes, for disposable nodes
- pre-authorized: yes, to avoid browser login
- tag: `tag:ray-worker` if your tailnet policy uses tags

Terraform state can contain rendered cloud-init data and therefore can contain the auth key. Keep state local, ignored, and short-lived. Rotate the key after cloud runs if possible.

## Spaces and backend credentials

The storage provider reads `DIGITALOCEAN_TOKEN` plus `SPACES_ACCESS_KEY_ID` and `SPACES_SECRET_ACCESS_KEY` for the broad bootstrap identity. A later S3 backend reads a separate, state-bucket-scoped identity from `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Never map or reuse the broad provider key as the backend identity. Do not place any of these values in Terraform variables, backend files, command arguments, logs, outputs, plans, cloud-init, or committed files.

Bootstrap uses the temporary broad identity only until the separate state-bucket-scoped backend identity and Bronze-bucket-scoped identity are verified against their intended bucket operations. Revoking the broad bootstrap identity is a separate human-gated action. Bronze consumers receive presigned download plans rather than long-lived Spaces credentials. Silver and later data layers require a new reviewed phase.

All persistent resources use `force_destroy = false` where applicable and `lifecycle.prevent_destroy = true`. This is a guardrail, not deletion authority: `prevent_destroy` cannot protect a resource block after that block is removed from configuration. Persistent-resource decommission therefore follows the reviewed break-glass procedure in `docs/runbook-storage.md`.

## Suggested Tailscale ACL sketch

Adjust this to your tailnet naming. It is an example, not a drop-in policy.

```jsonc
{
  "tagOwners": {
    "tag:ray-worker": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["tag:ray-worker"],
      "dst": ["100.x.y.z:6379,10001,8265,10002-10100,11001-11005"]
    },
    {
      "action": "accept",
      "src": ["autogroup:admin"],
      "dst": ["tag:ray-worker:22"]
    }
  ]
}
```

## UFW on workers

Workers allow inbound Ray/SSH only on `tailscale0`. Public inbound is denied by UFW and DigitalOcean firewall except optional restricted SSH.

## DigitalOcean cleanup

Always run:

```bash
make do-down
```

Then check the dashboard for unexpected Droplets, Volumes, Reserved IPs, and Snapshots. The two approved Spaces buckets and named VPC are expected to remain and have their own human-gated lifecycle.
