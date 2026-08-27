# OCI conformance workflow

The bounded conformance image tests the infrastructure runtime contract. It is
not production model code and runs only on reviewed cloud runners.

## Sequence

1. Run `make check` and review the Dockerfile, base digest, dependency lock,
   run-spec bytes, and provider adapters.
2. Optionally import a local `linux/amd64` image without executing or pushing it:

   ```bash
   make oci-conformance-build
   ```

3. Under a separate publication authorization, build once and attach all three
   provider-local repository names to the same manifest. Do not rebuild per
   provider.
4. Verify registry manifest identity:

   ```bash
   scripts/oci/verify-provider-digests.sh \
     sha256:EXPECTED \
     AWS_ECR_REPOSITORY \
     GCP_ARTIFACT_REPOSITORY \
     AZURE_ACR_REPOSITORY
   ```

5. Under separate object-write authorization, upload the exact run-spec bytes
   to each content-addressed provider key and record S3 version, GCS generation,
   or Blob version plus SHA-256.
6. Verify the trusted publisher can read the exact canonical
   `runs/<deployment>/results/result-manifest.json`, bounded log, and local
   receipt handoff—but no arbitrary results—and can conditionally create only
   control evidence/final receipts.
7. Plan, authorize, apply, observe, publish the trusted receipt, and destroy one
   provider runner at a time.

The workload writes Parquet and summary output, then creates
`result-manifest.json` last. Output presence is not success. Acceptance requires
the validated manifest, local receipt/log hashes, provider lifecycle facts, and
a conditionally created final receipt whose publisher and object version are
verified through provider APIs.
