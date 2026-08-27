# OCI conformance workflow

This workflow prepares one test-only ML image and proves its immutable manifest
across AWS, Google Cloud, and Azure. It does not authorize a registry push,
run-spec upload, runner apply, receipt publication, or runner destroy.

## What the smoke proves

The cloud-only workload exercises the pinned Python scientific stack, performs
deterministic statistical and ML calculations, round-trips Parquet through
PyArrow, DuckDB, and Polars, and writes three create-only result objects:

```text
conformance.parquet
summary.json
result-manifest.json
```

The manifest is uploaded last. Its SHA-256, the container exit code, bounded
bootstrap-log hash, and local execution-receipt hash are inputs to the trusted
provider control-plane completion receipt. Output existence by itself is never
success authority.

## Gated sequence

1. Review the conformance source, fully hashed dependency lock, base-image
   digest, run-spec bytes, target platform, and registry destinations.
2. Optionally build the image locally without running the workload:

   ```bash
   make oci-conformance-build
   ```

3. After exact publication authorization, perform one BuildKit build for
   `linux/amd64` with all three provider-local repository tags in the same
   invocation. Do not rebuild independently per provider. Capture BuildKit's
   metadata and canonical manifest digest.
4. Verify that ECR, Artifact Registry, and ACR each expose the exact manifest
   bytes:

   ```bash
   scripts/oci/verify-provider-digests.sh \
     sha256:EXPECTED \
     000000000000.dkr.ecr.us-east-1.amazonaws.com/demo/runner \
     REGION-docker.pkg.dev/PROJECT/REPOSITORY/runner \
     REGISTRY.azurecr.io/runner
   ```

5. Upload the exact bytes of `run-spec.example.json` to each provider-local
   content-addressed run-spec key. Record the S3 version ID, GCS generation, and
   Blob version ID. This is a separately authorized storage mutation.
6. Before the AWS runner plan, verify that the accepted receipt-publisher
   policy can read only `runs/*/results/result-manifest.json` in addition to
   the local receipt and bounded log. Any required persistent-policy update is
   a separate reviewed platform plan and apply.
7. Resolve the AWS runner AMI from the reviewed Amazon ECS-optimized Amazon
   Linux 2023 public SSM parameter and bind the returned x86-64 AMI ID in the
   saved plan. The image must provide Docker, AWS CLI and SSM Agent; the runner
   bootstrap starts Docker and SSM explicitly.
8. Prepare and review one disposable-runner saved plan per provider, using the
   provider-local repository, common digest, provider-local run-spec URI and
   immutable object version.
9. Apply, observe, publish the trusted final receipt, and destroy one provider
   at a time under separate exact authorizations. Never treat one provider's
   acceptance as authorization for another.

## Cross-cloud pass conditions

- all registries return the same OCI manifest digest;
- all run-spec objects return identical bytes and SHA-256;
- each result manifest validates and names the same artifact hashes;
- each independently published final receipt binds the reviewed provider,
  request, platform contract, deadline, local receipt, log and result manifest;
- each disposable runner is destroyed while state, platform, data, results and
  audit evidence remain.

The image is intentionally `linux/amd64` because all currently mapped CPU
profiles are x86-64. Arm64 becomes a separate reviewed multi-platform contract;
it must not silently change the accepted manifest identity.
