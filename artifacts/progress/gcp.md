# GCP migration progress

## Owner stop — 2026-08-01

- The owner stopped GCP integration in favor of a new AWS integration workstream.
- No further GCP mutation, fixture, compute, or dataset work is authorized by this goal state.
- The artifact lifecycle correction plan `c47d937d3e04e2bab4b99238f8837e371c2f00e91822a15af3c6b87976909dcc` was applied under consumed authorization `046ed95f-e8ee-4ff9-922a-8a823612832e`: 0 additions, 1 in-place change, 0 destroys. Live verification confirmed exact lifecycle prefixes `artifacts/tmp/` and `artifacts/runs/unaccepted/`.
- The first `gcloud storage cp` artifact attempt failed before object creation because the intentionally create-only training identity cannot perform the destination metadata read used by that CLI path. A native JSON API create-only uploader and tests were added, but its live execution was cancelled when the owner stopped GCP work. Artifact fixture behavior is therefore `UNTESTABLE`, not passed.
- Goal 04 is partially accepted: infrastructure, IAM, Bronze/Silver fixtures, negative authorization checks, anonymous denial, immutable overwrite denial, soft-delete restore, and inventory passed. Artifact creation and final no-drift acceptance were not completed.
- Live persistent resources remain and can incur storage/operation charges: the three GCS buckets, two service accounts, their IAM bindings, four Bronze live objects totaling 1,206 bytes, and three Silver objects totaling 882 bytes. Artifact inventory was empty at the stop point. No GCP compute was created.

## 2026-07-31

- Started Goals 00–06 on `feat/gcp-single-node-foundation`.
- Preserved the existing DigitalOcean and Ray implementation.
- Added the code-only GCP scaffold, diagnostics, policy/authorization utilities, OpenTofu roots, tests, and operator documentation.
- No `gcloud` mutation, OpenTofu apply, destroy, bucket operation, IAM mutation, or VM creation was run.
- Goal 06 remains a human-authorized live phase after Goals 01, 03, 04, and 05 produce accepted evidence.

## Local evidence

- `make lint-shell`: pass.
- `make python-check`: pass.
- `make dryrun`: pass; existing DO behavior preserved.
- `make gcp-fmt`: pass.
- `make gcp-validate`: pass for bootstrap, storage, network, and training-node with Google provider 7.42.0.
- `make gcp-test`: ShellCheck, Ruff, and 28 pytest tests pass.
- Bootstrap offline plan: 9 add, 0 change, 0 destroy; plan policy accepted it.
- Secret-pattern scan: pass.
- `make gcp-doctor`: pass; all required local tools are available.
- `make gcp-account-check`: pass on 2026-07-31; exact project, ACTIVE lifecycle, billing, region, zone, bootstrap permissions, required APIs, ADC, and synchronized clock are accepted.
- Storage remote-backend planning now passes against accepted state bootstrap. Network and compute remain later phase gates.
- Goal 06: not run. No live authorization or prerequisite evidence exists yet.

## Live acceptance evidence

- Goal 01: pass. Project `example-project` is ACTIVE with billing enabled, required APIs enabled, ADC available, bootstrap authority present, synchronized clock, regional CPU quota 32 with usage 0, and in-use-address quota 4 with usage 1.
- Goal 03: pass. Authorized bootstrap plan `ac133ddde7c1d3ac034532fab096a240ff04ade28e1c2a38a13e6ec62248a00b` applied 9 additions, 0 changes, and 0 destroys under consumed authorization `e4ad8ba2-e19d-46a8-a3ee-9bafd573917a`.
- Goal 03 controls: state bucket is `US-CENTRAL1`/`STANDARD`, UBLA enabled, public-access prevention enforced, versioning enabled, seven-day soft delete enabled, required labels present, zero user-managed deployer keys, correct token-creator/object-admin bindings, and local bootstrap state modes 0700/0600.
- Goal 03 backend smoke: remote state write passed; concurrent plan was rejected with GCS precondition 412 while the apply lock was held; six state generations were observed; prior generation `1785526389515279` was downloaded, hashed, and validated offline as revision 1; the live restore was intentionally not executed; all visible objects under the disposable `gcp/backend-smoke` prefix were deleted.
- Goal 04 prior plan `fefc7db217b8045f0daa593a3b6fc94ddaa4ffeb28adf8763e67dd9ca2b19109` is superseded and must not be authorized or applied. Storage identity and immutable-upload controls changed after that plan. A fresh policy-accepted plan and SHA-256 are required.
- Goal 04 code-only implementation hardened: administrator impersonation for both keyless data identities, publisher read-after-create verification, CRC32C plus SHA-256 manifest binding, verified generation-zero uploads, final commit-marker validation, fixed storage IAM matrices, and fail-closed artifact lifecycle prefixes.
- Goal 04 fresh plan `afd42683f49720a8a47d5fda993769f355c79f5dfb18a51d4dc27509477f91a3` is policy-accepted with 14 additions, 0 changes, and 0 destroys. No authorization was issued and no apply or object mutation was run.
- Post-change checks: `make lint-shell`, `make python-check`, `make dryrun`, `make gcp-fmt`, `make gcp-validate`, and `make gcp-test` pass; the GCP suite now has 28 passing tests. Secret-pattern scan and ignored-runtime checks pass.
- Goal 04 live bucket controls and fixture behavior remain `UNTESTABLE` until the operator separately authorizes the exact fresh plan. Do not use the superseded plan or claim live acceptance from plan evidence.
- Goal 04 initial live apply: authorization `5b4d5d3c-9909-466b-8b85-30807536a4ea` was consumed for exact plan `afd42683f49720a8a47d5fda993769f355c79f5dfb18a51d4dc27509477f91a3`; apply completed 14 additions, 0 changes, and 0 destroys.
- Live bucket configuration passed for all three buckets: regional `US-CENTRAL1`, `STANDARD`, UBLA enabled, public-access prevention enforced, seven-day soft delete, required labels, Bronze versioning on, Silver/artifact versioning off, and artifact lifecycle limited to `tmp/` plus `runs/unaccepted/` after seven days.
- Live identity checks passed: zero user-managed keys on `data-publisher` and `training-runtime`, correct administrator token-creator bindings, publisher create/read on Bronze/Silver, trainer read on Bronze/Silver, and trainer create on artifacts.
- Goal 04 IAM verification is blocked: GCS default legacy convenience bindings still gave project Owners/Editors object-owner access and project Viewers object-reader access. This violates publisher-only Bronze/Silver writes, so no fixture objects were created.
- Code now removes the four default legacy roles from each bucket using narrowly allowlisted role-authoritative empty bindings. Remediation plan `91760289761e853e244e8abe81072e577a182ea4e1473d8d7a278ec58f3bf6a6` is policy-accepted with 12 additions, 0 changes, and 0 destroys; 29 tests pass. It requires a new exact human authorization before apply.
- Goal 04 IAM remediation: user-authorized receipt `0b820edd-f376-4099-a345-345369401416` was consumed for exact plan `91760289761e853e244e8abe81072e577a182ea4e1473d8d7a278ec58f3bf6a6`; apply completed 12 additions, 0 changes, and 0 destroys. Read-only verification through `tofu-deployer` shows no legacy convenience bindings remain.
- Goal 04 fixture snapshot `9f96f6879d55a9f3e76f4804707a474a6691de8fc29043ecbd9dcaa85d0b5051` was committed in Bronze and Silver. Publisher upload verified size, CRC32C, SHA-256 metadata, manifest, and final commit marker. Training-runtime downloads and local commit validation passed for both layers.
- Live negative checks passed: training-runtime create and delete were denied on both Bronze and Silver; an anonymous Bronze HTTP read returned 403; retrying the committed Bronze upload returned generation-precondition 412 and did not overwrite.
- Bronze soft-delete recovery passed on disposable generation `1785530498577302`: the live delete first made it noncurrent because Bronze versioning is enabled, exact-generation deletion moved it to soft delete, and exact-generation restore succeeded. The restored object has new live generation `1785531346255199`.
- Current inventory including Bronze versions: Bronze 4 live/noncurrent objects and 1,206 bytes; Silver 3 objects and 882 bytes; artifacts 0 objects and 0 bytes. At the illustrative USD 0.02/GB-month rate, stored-byte cost rounds to less than USD 0.000001/month before request charges and free-tier credit.
- Artifact fixture is blocked by a namespace mismatch found during verification: lifecycle prefixes were `tmp/` and `runs/unaccepted/`, but the required layout is under `artifacts/`. Code and policy now require `artifacts/tmp/` and `artifacts/runs/unaccepted/`. Fresh plan `c47d937d3e04e2bab4b99238f8837e371c2f00e91822a15af3c6b87976909dcc` is policy-accepted with 0 additions, 1 in-place change, and 0 destroys; it needs a new exact authorization before artifact write and final Goal 04 acceptance.
