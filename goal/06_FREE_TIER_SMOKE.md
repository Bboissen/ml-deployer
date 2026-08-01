# Goal 06 — Cheapest live Compute Engine smoke

```text
/goal Run the first bounded live GCP compute smoke in project example-project using the `smoke-free` profile. This is infrastructure validation, not model training.

Preconditions:
- billing enabled;
- required APIs enabled;
- state backend accepted;
- storage fixture accepted;
- network and compute plans pass policy;
- machine type e2-micro available in us-central1-a;
- CPU quota sufficient;
- exact plan saved and reviewed;
- one-use authorization receipt issued;
- max authorized cost no more than the locally approved smoke cap;
- max runtime exactly 45 minutes or lower;
- automatic action DELETE.

Expected resources:
- custom VPC/subnet and IAP firewall if not already created;
- one e2-micro VM;
- one 10 GB pd-standard auto-delete boot disk;
- one ephemeral IPv4 only if the approved profile requires it;
- attached training-runtime service account;
- no other billable resource.

Smoke actions:
1. Apply the exact authorized plan.
2. Wait for bootstrap status and serial logs.
3. Connect through IAP.
4. Verify:
   - hostname and profile labels;
   - CPU, RAM, and disk size;
   - OS Login path;
   - no direct public SSH ingress;
   - attached service-account identity;
   - Bronze/Silver fixture read;
   - unauthorized Bronze/Silver write fails;
   - artifact write succeeds;
   - local disk write succeeds;
   - Python and basic tools launch.
5. Run a tiny Polars/DuckDB-only synthetic smoke if memory permits.
6. Write `artifacts/runs/<run_id>/metrics.json` and `COMPLETED.json`.
7. Invoke explicit compute teardown before the 45-minute limit.
8. Also prove the configured maximum runtime would delete the instance by inspecting the scheduling fields; a separate automatic-delete exercise may be done only if cost authorization allows it.

Post-run audit:
- no VM;
- no boot disk;
- no workspace disk;
- no static external IP;
- no snapshot;
- no image;
- no load balancer;
- no NAT;
- no GKE;
- persistent buckets remain;
- network remains only if intentionally persistent;
- artifact object exists;
- billing export or cost view shows expected bounded usage when data becomes available.

Failure handling:
- capture serial console and startup logs;
- upload non-secret diagnostics;
- destroy compute immediately;
- consumed authorization cannot be reused;
- generate a new plan and authorization for retry.

Acceptance gate:
Pass only if the VM reads GCS, writes an artifact, is reachable solely through IAP for administration, and leaves no disposable compute resources.

Stop condition:
Do not proceed directly to a larger VM. Review smoke evidence first.
```
