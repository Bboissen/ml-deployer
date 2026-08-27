# Cross-cloud runner contract

This version `1.0.0` contract is the stable boundary between the ML repository and the AWS, Google Cloud and Azure implementations. Provider roots may map the contract to native resources but may not silently rename, weaken or reinterpret it.

## Validation authority

The committed JSON Schemas define closed structural shapes. Cross-field equality, profile lookup, canonical checksums and timestamp relationships are enforced by the matching executable validator in `scripts/`. Provider adapters must pass both layers; a generic Draft 2020-12 schema PASS alone is never contract acceptance. Final receipt acceptance adds a third layer of provider-authenticated publication metadata because a JSON payload cannot attest its own writer or object version.

## Normalized runner request

Each runner state accepts exactly one request matching [`../shared/contracts/runner-request.schema.json`](../shared/contracts/runner-request.schema.json).

| Field | Contract |
| --- | --- |
| `schema_version` | Exactly `1.0.0` |
| `deployment_id` | Lower-case alphanumeric/hyphen identifier, 3 to 48 characters, with alphanumeric ends |
| `provider` | `aws`, `gcp` or `azure` |
| `oci_repository` | Provider-local ECR, Artifact Registry or ACR repository without tag or digest |
| `oci_digest` | Canonical `sha256:<64 lowercase hex>` manifest digest |
| `run_spec_uri` | Provider-local immutable S3, Cloud Storage or Azure Blob URI |
| `run_spec_sha256` | SHA-256 of the opaque run-spec bytes |
| `run_spec_object_version` | Provider-native immutable object version or generation |
| `resource_profile` | `smoke`, `balanced` or `highmem` |
| `capacity_mode` | `standard`; `interruptible` is rejected in version 1 |
| `maximum_runtime_minutes` | Integer from 15 through 720 |

AWS, GCP and Azure fixtures carry different provider bindings but the same semantic request: deployment ID, image digest, run-spec checksum, profile, capacity mode and runtime. The provider implementation validates repository and URI agreement before planning.

The final image reference is always:

```text
<oci_repository>@<oci_digest>
```

A mutable tag is never accepted. Private copies are mirrored into ECR, Artifact Registry and ACR without changing the manifest digest. Runners authenticate to their local mirror using provider-native workload identity. Registry passwords are not request fields.

## Run-spec publishing

The ML publisher writes identical opaque bytes to each provider's results storage using:

```text
run-specs/<deployment_id>/<run_spec_sha256>.json
```

The publisher records the resulting native object version. The runner verifies both the object version and SHA-256 before container execution. Infrastructure validates the location and checksum but never parses model parameters, feature lists or experiment meaning.

## Forbidden input

The closed request schema rejects all unknown fields, including:

- registry passwords, cloud keys, SAS tokens, client secrets or other credentials;
- mutable OCI tags or inline image references;
- arbitrary shell, bootstrap or command fragments;
- model parameters, feature lists, years, families or trial schedules;
- multiple deployments or a deployment map;
- a request to disable or exceed the maximum-runtime safeguard;
- interruptible capacity until checkpoint recovery is separately accepted.

## One deployment per state

Every runner state contains exactly one deployment. Its backend key is deterministic from provider, non-secret account scope, region and deployment ID:

```text
<provider>/<account-scope>/<region>/runner/<deployment_id>.tfstate
```

The operator records a deployment-index entry matching [`../shared/contracts/deployment-index.schema.json`](../shared/contracts/deployment-index.schema.json). Before plan, observe or destroy, the adapter verifies the provider, account, region, deployment ID, request checksum and accepted platform-contract checksum. Runner destruction never uses bootstrap or platform state.

`request_sha256` is deterministic: validate the closed request, serialize it as the single UTF-8 line emitted by `jq -cS .`, remove the trailing line feed and hash those exact bytes with SHA-256. [`../scripts/hash-runner-request.sh`](../scripts/hash-runner-request.sh) is the normative Goal 02 implementation. The three provider-local bindings have separate full-request hashes because their provider, repository, URI and object-version fields differ even when their semantic workload projection is equivalent.

Provider deadline deletion can leave stale OpenTofu state. Observation and post-deadline reconciliation must report that condition explicitly; they do not silently recreate a runner. Destroyed state and receipts remain discoverable for audit.

Every runner plan exposes an absolute UTC provider deadline and a provider-specific latest-apply boundary. Applying after that boundary is rejected rather than allowing a stale daily shutdown schedule or an unexpectedly shortened safety window.

At execution, `deadline - started_at` must be positive and no greater than `maximum_runtime_minutes`. A successful `finished_at` cannot be later than the provider deadline. Failure and interruption evidence may finish later only while the bounded termination fallback completes.

## Runtime behavior

The runner must:

1. record the deployment ID, provider, exact image digest, run-spec URI/checksum/version, resolved shape and absolute UTC deadline;
2. authenticate through provider-native workload identity;
3. verify the digest-pinned image reference and run-spec checksum;
4. expose only the documented typed environment to the container;
5. execute the container exactly once;
6. retain bounded logs and result checksums;
7. write a local execution receipt matching [`../shared/contracts/local-execution-receipt.schema.json`](../shared/contracts/local-execution-receipt.schema.json) atomically in a private host path that is not mounted into the container;
8. shut down whether execution succeeds, fails or times out;
9. remain subject to an independent provider-side deadline.

The portable guest core is [`../shared/bootstrap/guest-runner.sh`](../shared/bootstrap/guest-runner.sh). Provider wrappers on the runner own image login, run-spec download/checksum verification, bounded-log handling and shutdown integration. They pass typed values and static commands; they may not inject shell fragments into the portable core. They do not possess receipt-publisher authority. A separate provider control-plane publisher enriches the private local outcome with provider facts and conditionally creates the final receipt. A local execution receipt alone is not cloud success evidence.

When a successful workload publishes results, it creates
`result-manifest.json` last. The manifest follows
[`../shared/contracts/result-manifest.schema.json`](../shared/contracts/result-manifest.schema.json),
uses sorted unique safe paths, and binds every preceding result object by byte
length, media type and SHA-256. The executable validator is normative for the
ordering, path and aggregate-size semantics that JSON Schema cannot fully bind.

## Container environment

The final environment names are:

```text
ML_DEPLOYMENT_ID
ML_RUN_SPEC_URI
ML_RUN_SPEC_SHA256
ML_RUN_SPEC_OBJECT_VERSION
ML_DATA_URI
ML_RESULTS_URI
ML_CLOUD_PROVIDER
ML_MAX_RUNTIME_MINUTES
ML_OCI_DIGEST
```

Azure runners additionally expose `ML_WORKLOAD_IDENTITY_CLIENT_ID`, a validated
non-secret UUID that lets the Azure SDK select the exact attached user-assigned
managed identity. AWS and GCP reject that variable. No token, key, secret or
provider credential is passed to the container.

No explicit cloud credential is passed. Provider SDKs inside the container discover temporary credentials from the native workload identity.

## Completion receipt

The atomic final object `control/receipts/<deployment_id>/completion.v1.json` matches [`../shared/contracts/completion-receipt.schema.json`](../shared/contracts/completion-receipt.schema.json). This prefix is not inside `ML_RESULTS_URI` and is not writable by the workload identity.

It records:

- deployment, provider, account scope, region and deterministic runner backend key;
- accepted request and platform-contract SHA-256 bindings;
- provider runner, workload identity and distinct receipt-publisher identity;
- final receipt URI and conditional-create mode;
- immutable control-evidence URI/checksum for provider lifecycle facts;
- SHA-256 of the private local execution receipt when guest execution reached atomic publication;
- exact OCI repository/digest and run-spec URI/checksum/version;
- requested profile, resolved provider shape and capacity mode;
- maximum runtime, start, finish and provider deadline timestamps;
- terminal status and container exit code;
- results URI, bounded-log checksum and a result-manifest checksum when results reached a canonical manifest.

The provider implementation must prove all of the following before accepting success:

- the workload identity has no write or assume access to the receipt-control namespace or publisher identity;
- provider-authenticated metadata identifies the expected control-plane publisher, proves conditional creation and supplies the provider-assigned object version outside the immutable payload;
- the payload validates, its provider/account/region/backend key match the deployment index, and its request and platform-contract hashes match the reviewed runner state;
- `terminal` is `true`, `status` is `succeeded` and `container_exit_code` is `0`.

The JSON payload cannot self-attest its writer or contain the version that the provider assigns only after creation; schema validation without provider metadata is insufficient. Logs, result objects, VM shutdown, a workload-written lookalike or a nonterminal receipt never imply success. `container_exit_code` is `-1` only for `bootstrap_failed`, when no container or local guest receipt exists; that status is bound instead to the immutable control-evidence object and bounded log. `interrupted` may or may not include a local-receipt or result-manifest checksum depending on where interruption occurred. A timeout is recorded as `timed_out` with code `124` and requires a local-receipt checksum.

## Common outputs

Every runner root exposes equivalent outputs:

| Output | Meaning |
| --- | --- |
| `deployment_id` | Accepted deployment identifier |
| `provider` | `aws`, `gcp` or `azure` |
| `runner_id` | Provider resource identifier |
| `workload_identity` | Non-secret identity name or resource ID |
| `resolved_profile` | Requested profile and actual provider SKU |
| `deadline` | Provider-enforced termination time |
| `data_uri` | Provider-local generic data location |
| `results_uri` | Deployment-specific result prefix |
| `receipt_uri` | Expected terminal receipt location |
| `request_sha256` | Canonical normalized request checksum |
| `platform_contract_sha256` | Accepted persistent-platform interface checksum |
| `management_hint` | Safe provider-native observation command |

Provider, account, project, subscription, region, backend configuration, IAM and machine SKU remain infrastructure implementation details. They are not ML parameters.
