# Cross-cloud runner contract

This contract is the stable boundary between the ML repository and the three provider implementations.

## Required inputs

| Input | Contract |
| --- | --- |
| `deployment_id` | Lower-case identifier, unique within a provider state, 3 to 48 characters |
| `oci_image` | Full OCI reference pinned as `repository@sha256:<64 lowercase hex characters>` |
| `run_spec_uri` | Provider-readable object URI; content is opaque to this repository |
| `resource_profile` | `smoke`, `balanced`, or `highmem` |
| `capacity_mode` | `standard` or `interruptible` |
| `maximum_runtime_minutes` | Positive bounded integer; provider-side enforcement is mandatory |

Provider, account, project, subscription, region and storage identifiers are infrastructure configuration, not ML run parameters.

## Forbidden inputs

- Registry passwords, cloud keys, SAS tokens or other secrets.
- Mutable OCI tags without a digest.
- Inline model parameters or feature lists.
- Shell fragments supplied as arbitrary user data.
- A request to disable the maximum-runtime safeguard.

## Runtime behavior

The runner must:

1. record the deployment identifier, image digest, run-spec URI, provider, resolved machine shape and deadline;
2. authenticate through its provider-native workload identity;
3. verify that the OCI reference is digest-pinned before pulling it;
4. make the run specification and provider-local storage URIs available to the container through documented environment variables;
5. execute the container once;
6. persist bounded logs, exit status and a completion receipt in result storage;
7. shut down whether the container succeeds or fails;
8. remain subject to an independent provider-side deadline if guest shutdown fails.

The runner must not contain model-specific retry or checkpoint logic. Interruptible recovery belongs to the ML image and run specification.

## Container environment

The final names will be frozen during Goal 02. The initial contract reserves:

```text
ML_DEPLOYMENT_ID
ML_RUN_SPEC_URI
ML_DATA_URI
ML_RESULTS_URI
ML_CLOUD_PROVIDER
ML_MAX_RUNTIME_MINUTES
```

No cloud credential is passed explicitly. Provider SDKs inside the container discover temporary credentials from the native workload identity.

## Common outputs

Every runner root must expose equivalent outputs:

| Output | Meaning |
| --- | --- |
| `deployment_id` | Accepted deployment identifier |
| `provider` | `aws`, `gcp`, or `azure` |
| `runner_id` | Provider resource identifier |
| `workload_identity` | Non-secret identity name or resource ID |
| `resolved_profile` | Requested profile and actual provider SKU |
| `deadline` | Provider-enforced termination time |
| `data_uri` | Provider-local generic data location |
| `results_uri` | Deployment-specific result prefix |
| `management_hint` | Safe provider-native observation command |

## Open decisions for Goal 02

- Canonical OCI registry and private-image authentication model.
- Exact run-spec object placement and publishing identity.
- Completion-receipt schema.
- Whether a provider runner root accepts one deployment or a map of independent deployments per state.

These decisions must be accepted before provider code is implemented.
