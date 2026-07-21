# Handoff: Phase 2 Ray, Spaces, and worker cache

## Scope and current gate

Continue only in `/home/user/docker/Ray_terraform` on branch `feat/persistent-dataset-storage`. Do not touch Demo or Scheduler. Do not create another Droplet without a new explicit human authorization. The last consumed cumulative conservative authorization is **$5.05**; a future single-worker attempt would require a newly reviewed authorization and updated cumulative accounting.

The last published infrastructure commit before this handoff work is `44231ae` (`fix: route worker DNS through the VPC`). The two untracked `.claude-tmp-codex-*.md` files predate this work and must remain untouched.

## Persistent DigitalOcean authority

- Region: `ams3`
- State bucket: `bbsn-ray-tfstate-ams3-cc6cac`
- Bronze bucket: `bbsn-demo-bronze-ams3-cc6cac`
- VPC: `demo-data-ams3`
- VPC UUID: `18b976c4-022d-43f4-a38c-7b1983182a6e`
- VPC CIDR: `10.110.16.0/20`
- VPC resolver: `10.110.31.254`
- Smoke prefix: `smoke/4daf3a9427bd5bcb36a07c0587c00ecc6af6a143e50594ea40842a5402017dce/`
- Pack: 16 Parquet objects, 536,903,904 object bytes, manifest SHA-256 `f24e3fd10cafe01b94eca2a39e931587cffa1bfac6fec56d7e33f7e8dd7ddfc1`

Credentials remain environment-only in ignored `.env`. Never put them in this file, Terraform arguments, logs, cloud-init, or committed files.

## Run `p2-ams3-20260722-05`

Terminal receipt: `artifacts/phase2/p2-ams3-20260722-05/controller-terminal.json`.

Proven live before the terminal failure:

1. One fresh isolated worker workspace and exactly one apply.
2. Bronze publication plus HEAD/list verification.
3. Fresh `/v2/sizes` check for `s-1vcpu-1gb`: 25 GiB disk, $0.00893/hour.
4. Independent 20-minute cleanup armed.
5. Worker discovery and secure presigned-plan transfer.
6. Cold 512 MiB cache materialization.
7. Signed plan deleted locally and remotely.
8. Warm-cache verification with no plan and an empty environment.
9. Exclusive VPC resolver, systemd-resolved stub, private-link `~.` ownership, no competing link resolver, and private route/source for every Spaces answer. This is proven because the network validator passed all those gates before reaching the Ray identity rejection.

The terminal failure was:

```text
ProtocolError: Ray node identity is absent or ambiguous
```

The collector required both `NodeName == hostname` and `NodeManagerAddress == tailscale_ip`. The live diagnostic proved that conjunction did not yield exactly one match, but no raw `ray.nodes()` receipt survived to show which field differed. Because the worker is explicitly started with `ray start --node-ip-address=<tailscale-ip>`, the code fix uses that configured address as authority: it matches exactly one alive node by the unique Tailscale `NodeManagerAddress`, requires a nonempty `NodeID`, records `NodeName` as evidence, and still forbids the DigitalOcean private IP as Ray identity. This correction remains pending live proof.

## Cleanup proof

- Droplet `586542651`, firewall, and Ray tag destroyed: `3 destroyed`.
- Worker OpenTofu state was empty.
- Smoke workspace was deleted; only `default` remained.
- DigitalOcean API returned `404` for Droplet `586542651`.
- Cleanup unit was disarmed and removed.
- Local Ray port `100.64.0.1:6379` was closed.

No worker resources from run `-05` remain. The two Spaces buckets, VPC, and smoke objects are intentionally persistent.

## Shared-host teardown incident and fix

The old `scripts/head/stop_head.sh` called `ray stop --force`. Ray 2.56.0 scans every host process and substring-matches `monitor.py`; it therefore sent SIGKILL to an unrelated Demo `scratchpad/monitor.py` process. That process was not restarted, and no further Demo action was taken.

The replacement lifecycle is repository-scoped:

- `make head-start` creates the exact transient user unit `spotify-ray-head.service`.
- The unit runs blocking Ray inside its own systemd control group.
- `make head-stop` validates the control group, working directory, exact start command, and `KillMode` before stopping only that unit.
- If the Ray port is open without the owned unit, stop refuses to act.
- `ray stop`, including the former `RAY_STOP_BEFORE_START` path, is forbidden under `scripts/head/`.

## Required offline validation

Run without starting Ray or contacting DigitalOcean:

```bash
make lint-shell
make head-lifecycle-check
make python-check
make storage-phase2-selftest
make dryrun
make do-validate
make do-plan DO_WORKER_COUNT=1
make storage-validate
git diff --check
```

Inspect the semantic outputs, not only exit codes:

- head lifecycle reports named unit, control-group kill, and no host-global `ray stop`;
- Phase 2 selftest accepts a Ray `NodeName` different from hostname when the unique Tailscale address and NodeID match;
- it rejects duplicate matches, empty NodeID, wrong Tailscale address, private-IP identity, public Spaces routes, and competing DNS.

Do not run `make head-start`, local VMs, SSH, Terraform apply, or another paid smoke during this offline gate.

## Next live gate, only after explicit approval

1. Start the head through `make head-start`; verify the exact unit/control group, Python 3.14.4, Ray 2.56.0, zero head CPUs, one alive head node, and zero workers.
2. Recheck live AMS3 size price and availability.
3. Create a new one-use authorization with prior conservative compute authorization of $0.05. If the hourly price remains below $0.01, the cumulative total becomes $5.06 under the existing $5.10 ceiling.
4. Run exactly one fresh smoke with no automatic retry.
5. Require a worker receipt with one alive node, unique Tailscale address, nonempty NodeID, exclusive VPC DNS, private Spaces routes, cold-cache receipt, and network-free warm-cache receipt.
6. Destroy and verify zero resources regardless of outcome, stop only `spotify-ray-head.service`, and stop for human review.
