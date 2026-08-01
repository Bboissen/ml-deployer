# GCP security policy

- Use user ADC for bootstrap and service-account impersonation afterward. Never create service-account keys or HMAC credentials.
- Keep state, plans, authorizations, tokens, data, models, and runtime audits out of Git.
- Enforce UBLA and public-access prevention on every bucket. No ACL resources or public IAM members are allowed.
- Remove the four default legacy bucket/object convenience grants for project Owners, Editors, and Viewers with role-authoritative empty bindings. This is required before accepting publisher-only Bronze/Silver writes.
- `tofu-deployer` controls infrastructure but is not a routine data identity. `data-publisher` creates and verifies immutable Bronze/Silver objects. `training-runtime` reads Bronze/Silver and creates artifacts. The administrator receives token-creator bindings on the two runtime identities; neither identity has a key file.
- Create every snapshot object and `COMMITTED.json` with generation precondition zero. Verify object size, CRC32C, and SHA-256 metadata before the final marker. Consumers ignore partial snapshots. Accepted objects are never overwritten.
- Use IAP plus OS Login; block project SSH keys. Never allow `0.0.0.0/0:22` or public Ray ports.
- Metadata and startup scripts contain no credentials. VM access to GCS comes from its attached identity.
- An authorization is mode 0600, expires, binds project/root/profile/exact plan SHA-256, and is consumed durably before apply. It is never reusable after success or failure.
- Persistent buckets and networks use `prevent_destroy`; compute teardown is scoped to the training-node root.
