# Batch: several reviewed jobs, one at a time

A batch runs several job-mode project files in order, one review for all of
them, from the same checkout used for [single deployments](aws-deploy-operation.md).
Each job is still an ordinary Deploy with its own scope hash, journal, cleanup
and S3 results folder. The batch adds one approval, waiting for a free machine
slot, bounded launch retries, a clean stop and a durable manifest.

```sh
./workspace batch a-project.json b-project.json c-project.json                    # review all jobs, confirm once
./workspace batch a-project.json b-project.json c-project.json --authorization "approve batch HASH"
./workspace batch status                                                          # latest batch manifest
```

Run long batches noninteractively so they survive the terminal, for example
`systemd-run --user --unit=ml-batch ./workspace batch ... --authorization "approve batch HASH"`.

## Review and approval

The review prepares each job's full deploy scope, exactly as `./workspace
PROJECT.json` would, then prints one line per job: machine, zone, hourly price,
lifetime, compute estimate, dataset size, its run command and its own scope
hash. The total compute estimate is information only; AWS billing stays
authoritative and the batch has no spending limit of its own. Typing `run`
approves the batch; without a terminal the review prints the batch hash, and a
later `--authorization` must contain it.

The batch scope pins, for every job: the ml-deployer commit, the project file
content, account, operator and backend, repository commit, dataset files and
hashes, disk, outputs, lifetime, mode, data location and the reviewed machine
size and zone, with the hourly price as a ceiling. Before each attempt the batch
prepares a fresh deploy scope with that size pinned and launches it only if
those fields match. Any difference, such as a new commit, a changed dataset or a
higher price, stops the batch for a new review. Nothing is resized or replaced
silently.

A batch only reuses what an earlier single Deploy created. Every job must have a
retained foundation and, for private repositories, a registered deploy key; any
foundation IAM migration or operator rebinding needs its own interactive Deploy
first. Workspace mode is not supported.

## Running

Jobs run in the given order. Before each attempt the batch:

1. stops if the AWS sign-in has expired;
2. waits while another controller holds the project lock or the account's
   standard On-Demand vCPU quota cannot fit the pinned size (no quota requests);
3. stops if another unsettled operation owns the workspace;
4. prepares and checks the fresh scope, then launches it with a per-job
   authorization quoting both the batch hash and the job's scope hash.

| Job result | Batch action |
| --- | --- |
| Success | Next job. |
| Job ran and failed, or setup failed or timed out | Mark failed; stop after `--max-failures` consecutive failures (default 2). |
| Failed before the job started (capacity, IAM propagation, lease timing) | Retry with a fresh scope after 5, 10, ... minutes, up to `--launch-attempts` (default 3), then mark skipped. |
| Cleanup unconfirmed | Run `resume` once; if still unconfirmed, stop. |
| Cancelled (`./workspace PROJECT.json cancel`) | Mark cancelled and stop; rerunning continues with the next job. |
| Controller stopped (Ctrl+C, `systemctl --user stop`) | Stop; the job reruns on continue. |

Rerun the same command with the same `--authorization` to continue after any
stop, including an expired sign-in or a restart. The batch rebuilds its state
from its journal: it reconciles an interrupted attempt with `resume` (never a
second launch), retries an attempt that was never authorized, and resets the
failure count. A completed batch returns its manifest without running anything.
Running the same files again needs a new review.

## Manifest and results

`./workspace batch status [BATCH_ID]` and the final output print the manifest,
also kept in `evidence/aws/batches/<id>/manifest.json`: per job its status,
attempts, operation, scope hash, job exit, compute estimate and S3 `output_uri`.
Results stay in S3 under each run's folder; downloading or renaming them belongs
to the ML repository. The batch journal (`evidence/aws/batches/<id>/journal/`)
adds one record per attempt and outcome, which a wake-up loop can watch.

## Limits

One job runs at a time; the scope records `max_parallel: 1`. Parallel machines
would need separate workspaces per job and a split project lock, and are left
for a later version. Scheduling, dependencies between jobs and choosing
experiments belong to orchestration tools, which can drive this command.
Offline tests cover review, ordering, retries, stops and restart recovery with
mocked deploys; they are not native acceptance.
