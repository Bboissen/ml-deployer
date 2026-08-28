# OCI conformance workflow

The bounded conformance image tests the infrastructure runtime contract. It is
not production model code. It can run locally against provider-shaped storage;
cloud execution remains limited to separately reviewed provider runners.

## Sequence

1. Run `make dummy-image-check` and review the Dockerfile, base digest, package
   matrix, dependency lock, image-source manifest, expected-output policy,
   run-spec bytes, and synthetic input contract.
2. Import a local `linux/amd64` image without executing or pushing it:

   ```bash
   make dummy-image-build
   ```

3. Run the bounded image locally without network access or cloud credentials:

   ```bash
   make dummy-image-run-local
   ```

4. Under a separate publication authorization, build once and attach all three
   provider-local repository names to the same manifest. Do not rebuild per
   provider.
5. Verify registry manifest identity:

   ```bash
   scripts/oci/verify-provider-digests.sh \
     sha256:EXPECTED \
     AWS_ECR_REPOSITORY \
     GCP_ARTIFACT_REPOSITORY \
     AZURE_ACR_REPOSITORY
   ```

6. Under separate object-write authorization, upload the exact run-spec bytes
   to each content-addressed provider key and record S3 version, GCS generation,
   or Blob version plus SHA-256.
7. Verify the trusted publisher can read the exact canonical
   `runs/<deployment>/results/result-manifest.json`, bounded log, and local
   receipt handoff—but no arbitrary results—and can conditionally create only
   control evidence/final receipts.
8. Plan, authorize, apply, observe, publish and verify the trusted receipt,
   destroy, and verify runner absence for one provider at a time.

The workload writes Parquet, metrics, model, MLflow tracking, explanation,
checkpoint, recovery run-manifest, and report output, then creates
`result-manifest.json` last. Output presence is not success. Acceptance requires
the validated manifest, local receipt/log hashes, provider lifecycle facts, and
a conditionally created final receipt whose publisher and object version are
verified through provider APIs. Cross-cloud comparison consumes the actual
evidence bundle and every listed result artifact; a summary JSON alone is never
acceptance evidence.
