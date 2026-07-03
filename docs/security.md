# Security hardening

## Core rules

1. Ray traffic must stay on Tailscale.
2. DigitalOcean public firewalls must not expose Ray ports.
3. SSH over public IP is optional and must be restricted to `admin_public_cidr`.
4. Use ephemeral/pre-authorized Tailscale auth keys for workers.
5. Do not commit Terraform state, `.env`, or `terraform.tfvars`.
6. Destroy cloud workers immediately after the run.

## Tailscale auth key

Create an auth key with:

- reusable: yes, for multiple workers
- ephemeral: yes, for disposable nodes
- pre-authorized: yes, to avoid browser login
- tag: `tag:ray-worker` if your tailnet policy uses tags

Terraform state can contain rendered cloud-init data and therefore can contain the auth key. Keep state local, ignored, and short-lived. Rotate the key after cloud runs if possible.

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

Then check the dashboard for remaining Droplets, Volumes, Reserved IPs, Snapshots, and Spaces buckets.
