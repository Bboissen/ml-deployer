# Workspace records (interface 2.0.0)

The controller and the instance exchange three closed JSON records defined in
[`shared/workspace/schema.json`](../shared/workspace/schema.json). Every record
carries `schema_version: "2.0.0"`, `provider: "aws"`, the 12-digit account scope,
the region and a 3–48-character workspace ID. Unknown fields, credentials,
model settings and publisher fields are rejected. A breaking change needs a new
major version; nothing is silently ignored.

| Kind | Producer and consumer | Content |
| --- | --- | --- |
| `request` | Controller → planner | CPU/memory/disk minimums, toolbox profile, named operators, 15–2880-minute maximum runtime, distinct `s3://` data/output prefixes and a state URI in a different bucket. Validation alone never touches the cloud. |
| `handoff` | Planner → controller and readiness collector | Exact request hash and scope, immutable image reference and bootstrap hash, instance ID, non-root user and project directory, instance-role selector, Session Manager terminal argv and absolute lifetime/guard facts. |
| `readiness` | Collector → controller | Request/handoff hashes, observed capacities and tool versions, timestamp and all nine check statuses with evidence paths under `evidence/aws/<workspace_id>/`. Failed or unverified checks cannot pass `--require-ready`. |

Canonical bytes are UTF-8 JSON with sorted keys, compact separators and one
trailing newline; SHA-256 covers that newline. Duplicate keys and nonfinite JSON
are rejected. Terminal argv is data and is never executed by shared code.

```bash
.tools/workspace-venv/bin/python scripts/workspace/validate.py request.json
.tools/workspace-venv/bin/python scripts/workspace/validate.py request.json \
  --handoff handoff.json --readiness readiness.json --require-ready
```

The [fixtures](../shared/workspace/fixtures/aws-request.json) are invented
specimens, not deployment inputs.

## Toolbox and readiness

The [toolbox profile](../shared/workspace/toolbox.json) is Linux x86_64 with
Python 3.13, venv, Git, uv, cc, make, the AWS CLI and boto3, pinned by the
immutable AMI and bootstrap hash in `infra/aws/runner/workspace/toolbox/`.
Project environments are writable by the non-root `workspace` user and separate
from the toolbox. Containers are optional; GPU, distributed execution and
notebook services are outside this profile.

`scripts/workspace/probe-toolbox.py aws PROJECT_DIRECTORY` reports local tool
and SDK versions, OS and architecture, capacity, venv and writable-directory
facts, and exits 2 when a local toolbox check fails. It leaves terminal,
identity, storage, denied-access and deadline checks unverified; the controller
collects those natively. The nine readiness checks are `toolbox`, `terminal`,
`identity`, `storage`, `state_denied`, `unrelated_denied`, `profile`,
`deadline` and `writable_project`. The deadline check must prove a
provider-side guard active at or before compute creation, with absolute expiry
within the maximum, including failed bootstrap and partial apply.

## Runtime contract v1

A generic job clones the pinned repository, then stages the dataset, then runs
`setup` (default `make setup`) and, in job mode, `run` (default `make train`).
Both commands run as the non-root `workspace` user with a cleared environment,
in the repository checkout, with exactly these variables:

| Variable | Value |
| --- | --- |
| `DATA_DIR` | `/workspaces/<workspace_id>/<run_id>/data`, outside the checkout. Every manifest object sits at its manifest `path`; files are `0444` and directories `0555`. |
| `OUTPUT_DIR` | `<checkout>/outputs`, created (or the committed directory reused) with mode `0700`. The default `outputs.paths` of `["outputs"]` persists it to `OUTPUT_URI/files/outputs/...`. |
| `RUN_ID`, `OUTPUT_URI` | The unique run ID and its versioned output prefix. |
| `AWS_REGION`, `AWS_DEFAULT_REGION` | The reviewed region; credentials come only from the instance role. |
| `DATA_MANIFEST_URI`, `DATA_MANIFEST_VERSION_ID`, `DATA_MANIFEST_SHA256` | The sealed manifest, for projects that want its provenance. |

The `data` stage reads the manifest by exact version, checks
`DATA_MANIFEST_SHA256`, its `dataset-manifest` schema, the job bucket, the
project data prefix, at most 100,000 objects and a `total_bytes` that equals
the object sum and fits the free disk. It then streams each object by key and
version ID, checking its size and SHA-256 before `setup` starts. Paths are
relative without empty, `.`, `..` or `.git` components. Staging counts against
the job timeout. A committed `outputs/` directory is reused; any failure,
including an `outputs` symlink or file, records `execution_error.stage` `data`
and skips setup. The
execution receipt reports `dataset_staged` and `dataset_staged_bytes`.

The root volume is fixed (30 GiB gp3, 25 GiB usable in every supported size).
The Deploy review refuses a dataset when its bytes, the declared
`outputs.maximum_bytes` and an 8 GiB checkout/environment reserve exceed the
usable disk; the scope prints this budget and adds no cost.

## Storage and the acceptance example

`data_uri` and `output_uri` are distinct prefixes ending in `/`; state lives in a
separate bucket that workload identities cannot read. Signed or query URIs,
userinfo, ports, percent-encoding, traversal and overlapping prefixes are
rejected. Uploads use instance-role credentials and S3 object version IDs.

New guided foundations use `datasets/` and `results/<workspace_id>/` in a
`<project>-storage-<account>-<region>` bucket, with a separate
`<project>-state-<account>-<region>` bucket. Dataset source names and UTC dates
make snapshots/runs navigable; manifests retain full checksums and immutable
versions. Existing foundations keep the legacy `projects/<project>/...`
prefixes and their original bucket names. The runner validates each exact
data/output pair and derives its permissions from that validated request;
mixed layouts, another workspace's output prefix and state access are refused.

The one exception to external ML ownership is the
[acceptance example](../shared/workspace/example/example.py): a fixture of
`value` then `1, 2, 3, 4`, fetched by exact version with a 128-byte bound,
computed with NumPy/pandas to count 4, sum 10 and mean 2.5, written as stable
JSON and read back by version for an exact-byte check. It never contacts a cloud
itself; offline tests simulate the transfers with local copies.
