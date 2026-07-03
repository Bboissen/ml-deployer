# Codex subagent prompt: security review

Review this infrastructure repo for security issues before DigitalOcean apply.

Check:

- No secrets committed.
- `.gitignore` blocks `.env`, Terraform state, tfvars, keys, data, artifacts.
- Ray ports are not exposed publicly.
- DigitalOcean firewall allows no public Ray inbound traffic.
- Tailscale auth key is passed as a sensitive variable and documented as state-risky.
- UFW on workers allows Ray only on `tailscale0`.
- Every create command has a destroy command.
- Docs warn that `terraform apply` is billable.

Write findings to `artifacts/reviews/security_review_<timestamp>.md`.
