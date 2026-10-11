# Deployer audit

This source audit starts at `055454b` (`feat/aws-deployer-release`), the baseline
selected for the audit. Changes are isolated on `refactor/deployer-audit`; the
older dirty checkout, other worktrees and existing deployment evidence remain
owned by their original tasks.

## Scope and disposition

- Review the controller, installation/release path, shared validation, provider
  roots, guest execution, lifecycle safeguards and offline tests.
- Repair confirmed defects and consolidate equivalent code. Keep AWS, Google
  Cloud and Azure implementations separate, and preserve historical interfaces
  while workspace migration remains incomplete.
- Make the existing reviewed AWS deployment the primary launch path. Google
  Cloud and Azure workspace launch remains unsupported until its infrastructure
  and lifetime requirements are implemented and accepted.
- Preserve native state, buckets, identities, plans, authorizations and receipts.
  This audit changes source only; it does not provision, migrate, publish a
  release, upload datasets or decommission cloud resources.
- Tests use mocked providers and temporary task-owned paths. Delete disposable
  test payloads after each run and retain only small logs and cleanup receipts.

## Findings and repairs

| Area | Defect | Repair |
| --- | --- | --- |
| Operator IAM | Routine deployer could rewrite its trusted operator's IAM policies | Use the native operator provider for terminal grants; deny the deployer IAM actions against those principals |
| Interactive access | Operator lacked the Session Manager data-channel permission | Grant `ssmmessages:OpenDataChannel` only for its own sessions |
| Guest commands | A finished process could leave children running and modifying outputs | Terminate the owned process group before hashing/uploading outputs |
| File inputs | Opening a FIFO could block before regular-file validation | Open nonblocking, then validate the descriptor |
| Output receipts | Guest could emit metadata larger than the controller accepted | Share an 8 MiB limit and report oversized metadata as output failure |
| Source inventory | Byte counting repeatedly rescanned the accumulated inventory | Maintain a running total for linear accounting |
| Recovery | Completed operation resume/cancel could repeat cleanup and overwrite success | Return the verified completed result without replaying mutation |
| Authorization recovery | Interrupted onboarding could try to overwrite an immutable authorization | Reuse only the exact saved-plan, scope, review hash and approval binding |
| Cancellation | An uncertain stage could call its mutation recovery after cancellation | Check cancellation before initial and recovery callbacks |
| Git checkout | Fetching all default history could exhaust a bounded workspace | Initialize and shallow-fetch the exact reviewed commit |
| Release reinstall | Saved checksum marker did not establish installed source integrity | Compare installed source to the verified archive before executing setup |
| Test ownership | Cleanup deleted newly observed paths in shared evidence directories | Run each suite in its own disposable source snapshot and remove only that directory |
| Snapshot provenance | A clone without an index misrepresented tracked source as deleted | Restore the captured Git index before overlaying current source |
| macOS shell | Empty arrays failed under Bash 3.2 with `nounset` | Use compatible array checks and expansions |

The AWS Session Manager permission follows the official
[operator policy examples](https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-restrict-access-quickstart.html).

## Simplification

`./workspace project.json` is the primary review command. Adding
`--authorization 'Approved deployment scope'` launches the saved reviewed scope.
Pinned local tools install when needed; help runs without installation. The old
command path still works. A configuration and native authentication remain
necessary because account, cost, data and lifetime choices cannot be guessed.

The target and lifecycle engines are ordinary importable Python modules. The
controller and authentication code no longer split shell source and execute its
contents. Compatibility shell entrypoints only select the interpreter. The
repository check permits infrastructure Python by ownership directory instead
of maintaining a growing per-file exception list.

`make check` includes the complete AWS automation suite. Shared workspace and
provider scaffold tests use the same isolated test runner. Duplicate test calls
were removed from the AWS scaffold and CI.

## Validation and limits

Focused regressions exercise failed/cancelled recovery, surviving descendants,
FIFO rejection, large receipts, changed release source, concurrent test evidence,
interruption/timeout cleanup, source snapshots and launch argument handling.
All default-check components passed: repository checks, shared workspace tests,
AWS automation, AWS/GCP/Azure scaffolds and OpenTofu formatting. The preserved
historical contract, guest, OCI and dispatcher checks also passed. The lifecycle
suite includes 81 unit cases plus mocked OpenTofu plans and emitted IAM checks;
it covers IAM-only migration without requiring a Git secret. The PR records the
remaining focused suite counts and cleanup evidence.

No native cloud acceptance was run for this audit. Google Cloud and Azure
workspace launch remain unsupported; their historical roots and regression
contracts are preserved. The historical Azure daily shutdown schedule does not
establish the required absolute lifetime guarantee. Native generic AWS happy/fault
paths, interactive access with restricted real identities, clean macOS install
and provider-side deadline failure drills remain acceptance work.

Existing foundations need a reviewed IAM update before the tighter deployer
policy is effective. Existing state/resource addresses are preserved. The source
operator must already have authority to create/delete its own scoped terminal
grant; the deployer cannot grant itself that authority. Uncertain workspace-access
applies continue to stop for state reconciliation instead of replaying mutation.

Large test payloads and source snapshots are disposable; small ignored receipts
record exact deleted paths and before/after free space. Existing runtimes, source
worktrees, historical plans and actual deployment evidence remain untouched.
