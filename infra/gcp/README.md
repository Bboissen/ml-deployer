# Google Cloud roots

- `bootstrap`: create or inspect an adoption candidate for the versioned GCS
  state bucket; it never imports or moves state.
- `platform`: persistent data/results buckets, Artifact Registry, VPC/subnet,
  optional exact-principal IAP access, and unattached trusted publisher.
- `runner`: one Compute Engine VM, deployment/deadline service accounts and
  grants, ephemeral Standard-tier outbound address, native maximum duration,
  and independent Scheduler deletion.

There is no persistent Cloud Router or Cloud NAT. The subnet denies no traffic
by itself, but the project defines no general inbound firewall rule; the runner
has no SSH path unless the reviewed IAP option and exact principals are enabled.

The platform emits one closed hashed binding. The runner consumes and rehashes
it, binds the deterministic workspace/backend convention, and owns every
deployment-specific permission so destroy does not leave a shared runtime
identity with accumulated access.

Run the full backend-disabled provider test from the repository root:

```bash
bash tests/gcp/test-scaffold.sh
```

It performs locked `init -backend=false`, `validate`, semantic checks, and
fail-closed mutations. It does not prove current authentication, enabled APIs,
effective inherited IAM, quota/capacity, backend locking, or cloud acceptance.
