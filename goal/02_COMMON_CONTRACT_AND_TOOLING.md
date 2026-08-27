# Goal 02: Common contract and tooling

Status: **Accepted**.

## Accepted boundary

- One closed runner request binds provider, deployment, digest-pinned OCI
  image, immutable run spec, capacity profile, and maximum runtime.
- One deployment owns one deterministic runner backend and disposable state.
- The workload writes an untrusted local receipt handoff; only a distinct
  provider control identity conditionally publishes the final receipt.
- Providers share schemas, semantic validators, guest behavior, conformance
  fixtures, output meaning, and lifecycle gates—not resource modules or IAM.
- Standard capacity is supported. Provider SKU mappings are implementation
  details, and current CLI quota/capacity decides what may launch.

## Executable acceptance

`make check` is the routine offline gate. The schemas and validators under
`shared/contracts`, `scripts`, and `tests` are authoritative. Any contract
change must keep valid AWS/GCP/Azure fixtures aligned and preserve negative
tests for secrets, mutable tags, unbounded runtime, backend binding, deadline,
receipt authority, and runner-only destruction.
