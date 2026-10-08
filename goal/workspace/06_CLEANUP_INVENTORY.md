# Exact cleanup inventory proposed for review

Cloud sizing follows the [global RAM-first quota-bounded default](../README.md#execution-rules).

Source: original checkout's ignored
`evidence/audits/20261007-pivot-audit/RECONCILED_AUDIT.txt` and its snapshots.
Inventory date: 7 October 2026; it is historical point-in-time evidence. This
milestone deletes nothing, moves no state, and changes no cloud resources. The
four dispositions below describe the next reviewed action, not a completed one.

## Source and local material

| Exact path/scope | Disposition | Owner / prerequisite / state implication |
| --- | --- | --- |
| `infra/{aws,gcp,azure}/{bootstrap,platform,runner}/` and all nine `.terraform.lock.hcl` files | Keep | Provider owners; keep root names, version pins, backend keys and resource lineage. Removing resource blocks is not cleanup approval. |
| `scripts/load-cloud-env.sh`, `scripts/hash-runner-request.sh`, `scripts/validate-*.sh`, `tests/contracts/`, `tests/bootstrap/` | Keep | Integration owner; historical batch validators remain until callers migrate. New workspace validators are separate. |
| `shared/contracts/{runner-request,completion-receipt,local-execution-receipt,deployment-index,command-result,result-manifest}.schema.json` and their fixture directories | Replace | Integration owner; workspace request/handoff/readiness replace the default product boundary. Preserve every old file and schema version until each provider's migration is reviewed. No workload completion/result format in workspace 2.0.0. |
| `shared/bootstrap/guest-runner.sh`, `shared/bootstrap/README.md` | Replace | Integration owner coordinates provider bootstraps; batch fire-and-exit behavior must not become interactive toolbox startup. Keep until historical provider paths migrate. |
| `scripts/dummy/`, `tests/dummy/`, `scripts/{aws,gcp}/*dummy*`, `scripts/gcp/task-b.sh`, provider `scripts/*/validate-scaffold.sh` | Replace | Provider owners replace their own dummy adapters and gates; integrator owns dispatch/tests. Preserve exact saved-plan authorization and useful IAM/absence checks. PR18/19-only GCP paths stay on those branches until selective integration. |
| `scripts/{aws,gcp}/dummy-receipt.sh`, `scripts/{aws,gcp}/prepare-dummy-receipt.sh`, `scripts/dummy/validate-result-evidence.sh` (PR18), `scripts/validate-result-manifest.sh` | Retire | Remove publisher/result grading only after provider migration; live publisher identities/grants have separate platform-state dispositions below. Keep historical receipts immutable. |
| `shared/conformance/oci-ml-smoke/` including Dockerfile, 23-package lock/matrix, image-source manifest, generated fixture, `conformance.py`, `generate-fixture.py`, `test_conformance.py`, run spec and expected output | Replace | Integrator; new `shared/workspace/example/` is the bounded acceptance. Keep old bytes/hashes for historical tools; no lock/hash refresh or image publication here. |
| `scripts/oci/`, `tests/conformance/`, Make `dummy-*` / `oci-conformance-build` targets | Retire | Integrator; available only as explicit historical interfaces until migrations. Local build/runtime defaults now use ignored evidence; do not start registries or build images during this milestone. |
| `goal/02_COMMON_CONTRACT_AND_TOOLING.md` through `goal/06_CROSS_CLOUD_ACCEPTANCE.md`, `docs/contract.md`, `docs/operations/{lifecycle,aws-dummy-lifecycle,aws-platform-acceptance,gcp-dummy-lifecycle}.md`, `docs/opentofu-architecture.html` | Replace | Integrator/provider document owners; mark historical now, rewrite or remove only with migrated replacements and link checks. GCP lifecycle doc exists on PR18/original checkout, not main. |
| `/home/user/docker/Ray_terraform/docs/ml-project/` (90 untracked files, ten Python files, SQL, pyproject and methodology) | Export | User selects external ML repository/destination. Copy exact tree, verify path/size/hash manifest and destination, then separately authorize source removal. No OpenTofu state ownership. |
| `/home/user/docker/Ray_terraform/Ray_terraform-audit-and-goals.zip`, untracked `docs/operations/aws-dummy-acceptance-status.html` | Keep | User-owned unique audit/status artifacts; no deletion/export destination assumed. |
| `/home/user/docker/Ray_terraform/evidence/` and `/home/user/evidence/Ray_terraform/` retained recovery/migration material | Keep | Infrastructure evidence owner; preserve state/backups/plans/ledgers/receipts/archives. Only layout docs tracked. Verify the migration receipt's final `migration.env` integrity separately; do not rewrite its old manifest. |
| `/home/user/docker/Ray_terraform/.dummy-runtime/` (111 audited files), `.tools/uv-cache/` (about 72 MB at audit) | Retire | Local acceptance owner; classify unique run/log/input/result evidence for export into `evidence/` first. Exact owned cache/build paths and a verified pruning receipt required. No broad recursive cleanup. |
| Container `demo-acceptance-registry-41e7c1b`, port 5002; bind `/home/user/evidence/Ray_terraform/aws/goal-06-live/20260828T-live-acceptance-07/phase-3-local-registry-data-01` | Retire | Local acceptance owner; separately authorize exact container stop/removal and mount disposition after preservation. Not an OpenTofu resource. |
| Container `demo-acceptance-registry-c5f5618`, port 5001; bind `/home/user/evidence/Ray_terraform/aws/goal-06-live/20260827T-live-acceptance-06/phase-5-image-build-01/local-registry-data` | Retire | Same; container removal does not authorize mount deletion. |
| Container `buildx_buildkit_demo-oci-c5f56180`, volume `buildx_buildkit_demo-oci-c5f56180_state` | Retire | Local acceptance owner; exact builder/container/volume authorization after checking ownership and unique outputs. No global Docker prune. |
| Other Docker containers/images including Spotify builder; old Ray/ML Git branches; other hosts/accounts | Keep | Ownership unclassified/outside this task. Multipass reported zero instances; no delete command follows from that result. |

## GCP resources and exact state scopes

Project: `example-project`, region `us-central1`.
Current state bucket: `ml-infra-example-project-gcp-state`.
All current object keys below start with
`gcp/example-project/us-central1/`.

| Exact resource/state scope | Disposition | Owner / implications |
| --- | --- | --- |
| Current state bucket and `platform.tfstate`, lineage `7c9d5a80-ee68-23f2-c5e1-d8316cf21340` | Keep | GCP bootstrap/platform owner; 11 managed instances in audit. Keep remote object versions and platform outputs. |
| `mlinfra-example-project-00000000-{data,results}`, network `mlinfra-runner`, platform subnet | Keep | GCP platform owner; candidate adoption with fresh evidence. Existing data contains synthetic content, so do not advertise an empty newly created bucket or delete its contents. |
| Platform Artifact Registry `runtime`, `receipt_publisher`, observer role/member, impersonation and control/evidence bucket grants at their existing platform addresses | Retire | GCP platform owner prepares a separate exact plan after workspace migration; retain buckets/network/state. No blanket platform destroy. |
| Job `delete-gcp-dummy-64cea4473e8`; identities `runner-555492ee40890cf0` / `runner-del-555492ee40890cf0` in this project, their deletion role/member and owned bucket/registry/actAs grants | Retire | GCP runner owner; exact `runner/gcp-dummy-64cea4473e8.tfstate`, lineage `ea3f760a-6e35-6b69-f09b-9de398e4b71c`, serial 4, generation `1787948445651505`. Audit: VM absent but 11 state instances. Refresh drift, review saved runner-only destroy plan, authorize separately, verify all owned remnants absent. |
| Job `delete-gcp-dummy-64cea4473e8-r4`; identities `runner-11730ebca87f22d0` / `runner-del-11730ebca87f22d0`, their deletion role/member and owned grants | Retire | Exact `runner/gcp-dummy-64cea4473e8-r4.tfstate`, lineage `0dc462d5-618e-482c-879e-54e96b2d4b48`, serial 4, generation `1787964235554134`. Same review; preserve successful local workload and unpublished receipt draft. |
| `runner/default.tfstate`, `runner/gcp-dummy-64cea4473e8-{r2,r3}.tfstate` and their versions | Keep | GCP evidence owner; audited empty states retain lineage. No deletion to conceal history. |
| Buckets `example-project-{artifacts,bronze,silver}`; `data-publisher@example-project.iam.gserviceaccount.com`, `training-runtime@example-project.iam.gserviceaccount.com`, their bindings | Retire | Separately decommissioned in historical ownership classification; contents unverified (403), not empty. Old bucket `example-project-tofu-state`, key `gcp/storage/default.tfstate`, lineage `9e41929f-4c64-deff-c83a-0008fe773ea8`, serial 5, generation `1785532022015507`, owns 26 instances. Verify/export content and exact addresses before any plan/authorization. `force_destroy=false` remains. |
| Old tofu-state bucket and legacy `gcp/storage/default.tfstate` | Keep | State/evidence owner; do not delete backend or move state as part of workload cleanup. |
| Default VPC, default compute service account, `tofu-deployer` | Keep | GCP account owner; default VPC adoption/retirement and inherited IAM require fresh exact scope. Do not assume default/shared resources belong to the obsolete demo. |

## AWS and Azure

| Scope | Disposition | Owner / implications |
| --- | --- | --- |
| AWS bootstrap/platform S3, network, ECR, publisher roles/grants and runner lineage | Keep | AWS owner; audit STS expired, current names/absence unverified. Use preserved Task A/B plans/outputs plus refreshed inventory to enumerate exact ARNs/state addresses before adoption or decommission. ECR/publisher are retirement candidates, not an approved deletion list. |
| AWS August runner receipt and post-destroy evidence | Keep | Evidence owner; preserve original contract/image provenance. It is not current workspace acceptance. |
| Azure bootstrap/platform/runner resource scopes | Keep | Azure owner; audited subscription inventory empty, permissions/quota unproven. No concrete deployed ACR/publisher/private-endpoint cleanup target established. Enumerate any newly found resources and state before changing them. |
| Azure proposed registry/control/publisher resources in `infra/azure/platform/{registry,identity}.tf` | Replace | Azure owner reviews source migration before provisioning; absent resources cannot be reported decommissioned. Keep storage/network ownership independent from access/deadline decisions. |

## Exact authorization packets still required

1. Local ML export: chosen destination, source manifest, verified destination
   receipt, then separately enumerated source removals.
2. Local acceptance services: only the three named containers and the named
   BuildKit volume above, with refreshed IDs/mounts and preservation decisions.
   Each bind directory needs its own deletion scope; no global prune.
3. GCP initial and r4 runner cleanup: separate immutable saved destroy plans,
   state generation/lineage, exact managed-resource allowlists, explicit excluded
   platform/buckets, authorization and authoritative post-destroy evidence.
4. GCP pre-pivot buckets/identities: content inventory/export (resolve 403 first),
   old-state addresses, retention decision and separate exact plan authorization.
5. AWS resource disposition: fresh login/inventory and exact state-to-resource
   mapping before a concrete cleanup plan can be offered.

None of these packets is created or authorized by this source-only milestone.
