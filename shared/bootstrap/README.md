# Portable guest runner

`guest-runner.sh` is the provider-neutral execution core for a disposable
runner. Provider bootstrapping is responsible for installing a Docker-compatible
container runtime, authenticating that runtime through the provider-native
workload identity, and creating a private local receipt directory before calling
this script.

The script does not authenticate to a cloud, upload objects, interpret the run
specification, evaluate shell text, or choose provider resources. A
provider-specific control-plane publisher consumes the completed local receipt
after the script returns. Its identity is separate from and unavailable to the
runner workload.

## Required environment

| Variable | Contract |
| --- | --- |
| `ML_DEPLOYMENT_ID` | Lower-case identifier, 3 to 48 characters |
| `ML_OCI_REPOSITORY` | Lower-case OCI registry and repository without a tag or digest |
| `ML_OCI_DIGEST` | `sha256:` followed by 64 lower-case hexadecimal characters |
| `ML_RUN_SPEC_URI` | Absolute object URI without credentials, query, fragment, whitespace or control characters |
| `ML_RUN_SPEC_SHA256` | SHA-256 of the opaque run-spec bytes |
| `ML_RUN_SPEC_OBJECT_VERSION` | Immutable provider-native object version or generation |
| `ML_DATA_URI` | Absolute object URI under the same URI restrictions |
| `ML_RESULTS_URI` | Absolute object URI under the same URI restrictions |
| `ML_CLOUD_PROVIDER` | `aws`, `gcp`, or `azure` |
| `ML_MAX_RUNTIME_MINUTES` | Integer from 15 through 720 |
| `ML_CONTAINER_RUNTIME_PATH` | Absolute executable path whose basename is `docker` or `podman` |
| `ML_RECEIPT_OUTPUT_DIRECTORY` | Existing, writable, non-symlink local directory |

The script accepts no positional arguments. It invokes the runtime exactly once
as an attached `run`, using
`ML_OCI_REPOSITORY@ML_OCI_DIGEST`. The image entrypoint is executed without an
injected command or shell fragment. The common `ML_*` run values are passed to
the container as environment variables; cloud credentials are not.

## Guest bound and receipt

GNU `timeout` is resolved only from `/usr/bin/timeout` or `/bin/timeout`; caller
`PATH` cannot select it. It bounds the attached runtime invocation to the
accepted maximum runtime and sends a terminating signal followed by a bounded
kill fallback. The static `deadline-marker.sh` wrapper records whether that
signal came from the deadline control, so a container that independently exits
with code `124` is not mislabeled as a timeout.
This guest control supplements rather than replaces the independent
provider-side deadline.

After the runtime exits, the script atomically publishes
`execution-receipt.local.json` in the output directory. The version-1 receipt records
the accepted identifiers, exact image, URIs, maximum runtime, UTC timestamps,
terminal status and exit code. Status is `succeeded` for exit code 0,
`timed_out` only when the deadline marker proves GNU `timeout` fired, and
`failed` otherwise. A timed-out execution is normalized to code `124`; an
independent container exit `124` remains `failed`. The script returns the
runtime code, or `124` for an enforced timeout, after publishing the receipt.

An existing local execution receipt is never overwritten. Receipt files are mode
`0600`; temporary files are created in the same directory and removed before
return. This local receipt matches
[`../contracts/local-execution-receipt.schema.json`](../contracts/local-execution-receipt.schema.json)
and is an input to a provider-specific control-plane publisher. The publisher
enriches it with the reviewed request and platform bindings, runner identity,
workload identity, resolved shape, provider deadline and result/log checksums.
It conditionally creates the final receipt in the reserved control namespace
using credentials unavailable to the runner. The local receipt is not evidence
that an object-store upload or trusted publication succeeded.
