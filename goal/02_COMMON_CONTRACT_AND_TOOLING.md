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

## Accepted contract boundary

Goal 02 proves the portable lifecycle with a bounded single-node smoke
workload. It does not yet prove that the dummy image contains the complete
reviewed ML toolchain or that the final lifecycle works on all three providers.
[Goal 06](06_CROSS_CLOUD_ACCEPTANCE.md) closes that gap without adding
production Gold data, model code, large-scale training, or a production ML
service. The version-1 request, receipt, deadline, identity, and runner-only
destruction semantics remain the acceptance contract for that final dummy run.

The Goal 06 fixture binds its exact input without changing the accepted
version-1 schemas: the request binds a content-addressed run-spec object and
SHA-256; that run spec binds the synthetic Parquet object key, byte size,
SHA-256, schema, and logical results. Mutable names such as `latest` and broad
input-prefix discovery are rejected.
