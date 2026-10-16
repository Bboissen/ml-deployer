# Short AWS project configuration

`configure` prepares a versioned project intent and a reviewable local operation.
It discovers the selected profile's account/session identity and the repository's
advertised branch/tag commit, generates stable names and storage/backend paths,
and inspects local dataset metadata. It never uploads data, executes project
commands, changes credentials, initializes state or provisions infrastructure.

Ordinary use never calls `configure` directly: `./workspace project.json`
prepares this operation as the first step of its review, and
`./workspace doctor project.json` validates the file beforehand.

## Project input

Use [project.example.json](../../infra/aws/project.example.json) and the closed
[project schema 1.0.0](../../shared/workspace/project.schema.json). The schema is
separate from the existing workspace request/handoff/readiness schema 2.0.0 and
the historical explicit controller configuration with `version: 1`.

| Field | Meaning |
| --- | --- |
| `provider` | `aws` |
| `profile` | Existing non-default temporary AWS profile; account/identity are discovered |
| `region` | `us-east-1` in the current reviewed CPU profile |
| `project`, `workspace` | Canonical friendly names; generated workspace ID is `project-workspace`, at most 48 characters |
| `dataset.source` | Local file/directory, S3 object/prefix or credential-free public HTTPS file declaration |
| `repository.url`, `repository.ref` | Credential-free GitHub HTTPS/SSH URL and branch, tag, explicit `refs/heads/…`/`refs/tags/…`, or full lowercase commit |
| `commands.setup`, `commands.run` | Nonempty argument arrays supplied by the external project; retained as intent, never executed during configuration |
| `outputs.paths` | Relative project paths without traversal or `.git` access |
| `resources.policy` | `ram-first`; current candidate remains the reviewed CPU profile, with quota/price/availability pending |
| `maximum_runtime_minutes` | 15–60 minutes; records the future absolute-expiry scope |
| `mode` | Omit for `job`: setup/run on every future Deploy, then owned-compute cleanup. `workspace` retains the workspace until explicit teardown or expiry |

Local paths are relative to the configuration file's directory, not the shell's
working directory. Spaces are supported. Missing/empty directories, symlinks,
special files and inaccessible subtrees fail before discovery. A zero-byte
regular file is valid metadata input. The scan is bounded to 100000 files/30 seconds and
records total bytes, count and a metadata fingerprint without reading file content.
This fingerprint is not a content checksum or immutable upload manifest.

S3 and HTTPS declarations are retained with unknown sizes at configuration time;
Deploy's ingestion stage reads and verifies them before any compute. Other schemes,
embedded credentials, signed query strings and fragments are rejected. Keep
credentials out of project commands and configuration; use owner-managed native
credential stores for assisted login.

## Prepare and inspect

Run from the repository root. The [workstation installer](aws-workstation-setup.md)
provides the locked controller runtime and selected operator tools:

```bash
./workspace guide ~/aws-workspace/demo/project.json --repo owner/name --dataset ./dataset
# Optional: edit any derived field; reruns keep your values.
./workspace ~/aws-workspace/demo/project.json configure
```

Guided setup derives every field except the repository and dataset; the
derivation rules are in the [quickstart](aws-deployer-quickstart.md#2-configure).

Default discovery makes only STS `GetCallerIdentity` and a bounded `git ls-remote`
request. The existing profile boundary rejects conflicting environment sources,
static cloud credentials, default-profile fallback and alternate endpoints.
Git prompts and hooks are disabled; SSH requires existing trusted host access.
This command creates no private-repository runtime credential. A full commit is
recorded as `pin-only`; exact fetch verification remains a deployment prerequisite.
An ambiguous branch/tag name requires its full ref instead of a silent choice.

The response gives `operation_directory`, a review document and unresolved
prerequisites. Substitute the returned directory to inspect the saved preparation:

```bash
./workspace ~/aws-workspace/demo/project.json status evidence/aws/operations/OPERATION_ID
```

Status is immediate and local. Changed inputs, changed artifacts or evidence
symlinks fail. A new `configure` creates a new operation; it preserves earlier
records and keeps names stable for the same account/region/project. State bucket
names use a bounded project prefix and deterministic suffix; workload bucket names
reuse the existing AWS storage preparation rule. These names propose new resources,
not ownership or adoption of resources already using a name.

## Offline observations and document layout

`configure --discovery PATH` uses explicitly supplied observations without AWS or
remote Git calls. This is useful for offline checks and is marked `supplied-offline`.
The discovery document has exactly this shape:

```json
{
  "schema_version": "1.0.0",
  "kind": "aws-project-discovery",
  "profile": "reviewed-temporary",
  "region": "us-east-1",
  "identity": {"Account": "111111111111", "Arn": "arn:aws:iam::111111111111:user/operator"},
  "repository": {
    "url": "https://github.com/owner/project.git",
    "ref": "main",
    "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "resolved_ref": "refs/heads/main",
    "verification": "advertised-ref"
  }
}
```

Profile, region, account/ARN and repository/ref must agree. Federated identities
are recorded exactly; they do not establish support for SSO terminal grants.
Supplied observations cannot authorize deployment or establish native acceptance.

Each operation is an immutable directory in `evidence/aws/operations/` containing
`project.json`, `discovery.json`, `deployment.json` and `operation.json`. The last
file is written after the others, binds their exact byte hashes and records the
source revision/diff hash, discovery origin, time and operation ID. Incomplete
preparation never becomes a complete registry entry. `deployment.json` versions
the resolved intent, field provenance, names, selected profile, repository pin,
dataset metadata, setup/run/output choices and retention/expiry policy.

Every preparation reports `deployment_authorized: false`; its `pending` list
names what the Deploy review resolves next (foundation ownership/lineage,
quota/offering/price discovery, runtime repository access, ingestion and generic
execution). Configuration alone never authorizes or launches anything.

Run `make aws-project-config-test` for meaningful offline configuration checks.
The tests also run in the AWS scaffold suite. See the
baseline and assumption inventory for migration scope.
