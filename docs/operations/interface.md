# Common lifecycle command interface

This document freezes the provider-neutral behavior of the `doctor`, `plan`,
`observe` and `destroy` commands. Goal 02 defines only the interface and its
offline contract. AWS, Google Cloud and Azure adapters are implemented in later
provider goals and remain responsible for their own provider configuration,
identity, IAM, backend and lifecycle semantics.

The common interface must not hide provider resources behind a shared
OpenTofu module. It standardizes inputs, safety gates, machine-readable output
and operator expectations.

## Invocation contract

Every command accepts an explicit provider and provider configuration. Runner
commands also accept exactly one deployment identifier:

```text
<command> --provider aws|gcp|azure --config <identifier-only-config>
<command> --provider aws|gcp|azure --config <identifier-only-config> \
  --deployment-id <deployment-id>
```

Configuration files contain identifiers and contract inputs only. Credentials,
tokens, private keys, registry passwords, SAS tokens and arbitrary shell text
are forbidden. Authentication comes from the provider CLI or provider-native
temporary credentials.

Each runner state owns exactly one deployment. A provider adapter must reject a
runner configuration containing a collection, map or second deployment. This
keeps plan review, authorization, observation and destruction scoped to one
disposable runner. Parallel trials use independent runner states.

## Common JSON envelope

On every normal completion, including a failed readiness or policy check, the
command writes exactly one JSON document to standard output. Human diagnostics
may be written to standard error but must not be required to interpret the
result.

```json
{
  "schema_version": "1.0.0",
  "command": "doctor",
  "provider": "gcp",
  "status": "pass",
  "exit_code": 0,
  "generated_at_utc": "2026-08-26T00:00:00Z",
  "deployment_id": null,
  "scope": {
    "account_id": "non-secret-provider-identifier",
    "region": "provider-region",
    "root_kind": null
  },
  "checks": [
    {
      "id": "auth.identity",
      "status": "pass",
      "summary": "Expected non-secret account identifier is visible."
    }
  ],
  "artifacts": [],
  "warnings": [],
  "errors": []
}
```

Required envelope rules:

- `schema_version`, `command`, `provider`, `status`, `exit_code` and
  `generated_at_utc` are always present.
- `status` is `pass`, `fail` or `blocked` and agrees with `exit_code`. `pass`
  requires exit code `0`, an empty `errors` array, at least one check and every
  check at `pass`; every non-pass result has a non-zero exit code.
- `deployment_id` is present and non-null for runner plan, observe and destroy
  operations.
- `doctor` has a null deployment and root kind. Bootstrap/platform plans have a
  null deployment; runner plans and all observe/destroy results bind one
  deployment and the `runner` root.
- `scope` contains only non-secret account, project, subscription, region and
  root identifiers relevant to the command.
- Every check has a stable identifier, `pass`, `fail`, `blocked` or `unknown`
  status, a bounded summary and optional closed evidence. Evidence contains at
  most a bounded non-secret reference, a SHA-256 and a non-negative count; raw
  provider JSON, headers, environment maps and arbitrary nested values are
  invalid.
- `artifacts` lists immutable local review artifacts by path, byte size and
  SHA-256 digest. It never embeds plan content.
- Output never contains access tokens, environment dumps, state values,
  provider response headers containing credentials or unbounded logs.

## Exit codes

| Code | Meaning |
| ---: | --- |
| `0` | Command completed and all command-level gates passed |
| `1` | Internal or unclassified command failure |
| `2` | Invalid command arguments or contract input |
| `3` | Required tool or temporary authentication is unavailable or expired |
| `4` | Required visibility or declared permission is denied |
| `5` | Account, API, region, quota, state or storage prerequisite is not ready |
| `6` | Plan or operation rejected by repository safety policy |
| `7` | Provider API or required external service is unavailable |
| `8` | Saved-plan, digest, identity, configuration or authorization mismatch |
| `9` | An explicitly authorized provider operation failed |

An observed workload failure does not make a successful `observe` request exit
non-zero. The command returns exit `0` when observation itself succeeds and
records the runner or receipt outcome separately.

## `doctor`

`doctor` is read-only. It checks the provider CLI, temporary authentication,
the exact account/project/subscription and region, required APIs or resource
providers, quota visibility, relevant inventory visibility and the absence of
secret values in input files.

It may inspect state-storage and workload-storage metadata and IAM. It must not:

- log in, select an account or change local provider configuration;
- enable an API or resource provider;
- create a state lock or test object;
- change IAM, budgets, quotas or billing configuration;
- create, update, restart or delete a cloud resource;
- claim that read visibility proves create authority.

Backend write and lock behavior is proved later with a bounded, explicitly
authorized provider smoke. `doctor` reports that gate as pending until such
evidence exists.

## `plan`

`plan` selects exactly one provider root: `bootstrap`, `platform` or `runner`.
It may refresh and create a saved OpenTofu plan, but it never applies the plan.
The plan is written to a caller-approved path outside the repository workspace
with mode `0600`; it is never stored inside or committed to the repository.

The JSON envelope records:

- root kind, provider, account scope and configuration fingerprint;
- saved-plan path, size and SHA-256 digest;
- create, update, replace and destroy counts;
- persistent storage, IAM and billable-resource changes;
- every destruction or replacement address;
- the authenticated planning identity;
- whether policy accepted or rejected the plan.

A runner plan also records its absolute UTC provider deadline and a provider-specific `latest_apply_at_utc`. The executor rejects a stale plan whose latest-apply boundary has passed. This is mandatory for Azure, where the native shutdown schedule is a daily UTC time rather than a one-shot relative TTL, and remains useful evidence on every provider.

Policy rejects a plan that touches an unexpected provider or root, mixes
persistent platform resources with disposable runner state, contains more than
one runner deployment, destroys protected storage, or exceeds the reviewed
resource profile and cost ceiling.

A saved plan is immutable review evidence. Regeneration, configuration changes,
credential changes or provider-lock changes produce a new digest and invalidate
any prior authorization.

## Apply authorization boundary

Goal 02 does not define or execute a common apply command. A later
provider-specific executor may consume a saved plan only when the operator has
explicitly authorized all of the following exact values:

- provider and account/project/subscription;
- root kind and deployment identifier when applicable;
- saved-plan SHA-256 digest;
- planning identity and configuration fingerprint;
- summarized resource, IAM, billable and destructive changes.
- the absolute deadline and unexpired latest-apply boundary for a runner plan.

The executor must consume that exact saved plan without an implicit re-plan.
General approval to implement infrastructure is not authorization to apply.

## `observe`

`observe` is provider-native and read-only. For one deployment it reports:

- provider resource identifier and lifecycle state;
- requested profile and resolved provider shape;
- provider-side deadline and visible termination action;
- bounded boot and container status;
- completion-receipt presence and non-secret receipt summary;
- provider-authenticated receipt object version, create-only publication and expected control-plane publisher identity;
- results URI and a bounded log tail or log reference.

It never restarts, retries, repairs or replaces a runner. Missing evidence is
reported as `unknown` or `blocked`, not inferred from instance liveness. A
syntactically valid receipt is untrusted until its provider/account/region/backend,
request and platform hashes agree and provider metadata proves publication by
the distinct expected control identity.

## `destroy`

`destroy` is limited to one disposable runner state. It must never target a
bootstrap or platform root.

Before provider mutation, the command requires an already reviewed destroy
plan plus explicit authorization for that plan's exact SHA-256 digest and
scope. It fails closed if the plan includes state storage, data storage,
results storage, a persistent identity, an unexpected deployment or an
unreviewed replacement.

Execution consumes the authorized saved plan without re-planning. Its receipt
records the plan digest, authorization binding, provider identity, start and
finish timestamps, exit code and post-destroy read-only evidence that
persistent storage remains outside the runner state.

Historical-resource decommission, adoption and persistent-platform destruction
are separate workflows and are never routed through this command.

## Provider adapters

Later provider goals implement separate adapters for AWS, Google Cloud and
Azure. An adapter may extend the `checks` and evidence fields, but it may not
rename common inputs or outputs, weaken an exit condition, broaden an
authorization, accept multiple deployments per runner state or omit the common
JSON envelope.
