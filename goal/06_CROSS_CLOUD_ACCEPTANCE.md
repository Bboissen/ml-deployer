# Goal 06: Cross-cloud acceptance

Status: **Not started**.

Run the same OCI manifest digest and byte-identical conformance run-spec bytes
on AWS, Google Cloud, and Azure, one complete experiment per provider.

For each provider, retain independently verified evidence for:

- account/project/subscription, region, quota, and resolved SKU;
- saved-plan digest and exact authorization;
- workload identity, backend key, and platform-contract hash;
- provider-side deadline and terminal container outcome;
- result-manifest, log, local receipt, control evidence, final receipt, and
  provider-authenticated publisher/object version;
- runner-only destruction and persistent storage retention.

Acceptance requires identical OCI manifest content, identical run-spec bytes,
equivalent container environment and receipt semantics, and isolated provider
state. It does not require identical resource graphs or persistent cross-cloud
networking.

Production Gold integration remains a later ML/infrastructure handoff.
