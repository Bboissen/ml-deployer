# Goal 09 — High-CPU and high-memory profiles

```text
/goal Add safe plan-only high-CPU and high-memory Compute Engine profiles based on measured workload needs. Do not apply a high-end profile until quota, availability, price, and a per-run authorization are documented.

Input evidence required:
- final Bronze and Silver snapshot sizes;
- object counts;
- staged disk footprint;
- Polars/DuckDB peak memory;
- model matrix memory;
- LightGBM/XGBoost/CatBoost peak RSS;
- training wall time;
- desired parallel fold/trial count.

Discovery commands must record:
- machine types available in the selected us-central1 zones;
- regional CPU quotas;
- machine-family-specific quotas;
- disk quotas;
- external IP quota;
- Spot availability where observable;
- current price capture from the official GCP calculator or Cloud Billing catalog;
- timestamp and currency of every price receipt.

Candidate profiles, subject to live discovery:
1. dev-memory
   - target around 4 vCPU / 32 GB
   - likely e2-highmem-4 or available equivalent
2. train-16x128
   - target around 16 vCPU / 128 GB
   - select an available N4/C4D high-memory type
3. train-32x256
   - target around 32 vCPU / 256 GB
   - select an available N4/C4D high-memory type
4. cpu-fast
   - compute-optimized profile chosen only after a measured CPU bottleneck
5. spot-recoverable variant
   - same approved CPU/RAM shape, provisioning_model=SPOT, checkpoint-capable workload only
   - execution through Goal 09A target-size-1 stateful MIG
   - auto-delete boot disk plus one preserved run-scoped workspace disk

Do not hard-code a machine type merely because documentation lists it. Confirm zone availability and quota.

Profile policy:
- one VM only;
- no GPU in this goal;
- max runtime mandatory;
- termination DELETE;
- Standard direct profiles use auto-delete boot and workspace disks;
- Spot-recoverable profiles use an auto-delete boot disk and one stateful workspace disk preserved only across VM recreation, then explicitly deleted at terminal teardown;
- no local SSD initially;
- pd-balanced, pd-ssd, or Hyperdisk Balanced selected only from measured staging, checkpoint, and restart requirements;
- disk sized from staged data plus workspace and 30% safety margin;
- external IPv4 explicit;
- allow_ray false until Goal 10;
- max estimated cost stored with timestamped price basis.

Cost receipt:
For every high-end run, create a receipt containing:
- project ID;
- profile;
- machine type;
- vCPU and RAM;
- provisioning model;
- disk type/size;
- workspace preservation mode and expected disk cost during recovery/capacity wait;
- external IPv4 assumption;
- region/zone;
- hourly estimate;
- maximum runtime;
- maximum estimated total;
- currency conversion source if needed;
- price timestamp;
- plan SHA;
- run purpose;
- operator approval.

Benchmark ladder:
1. Native small profile baseline.
2. dev-memory benchmark.
3. train-16x128 only if dev-memory is insufficient or too slow.
4. train-32x256 only if measured scaling justifies it.
5. Spot only after Goal 09A checkpoint, forced-replacement, cache reuse, bounded retry, and terminal disk-cleanup behavior is proven.

Benchmark outputs:
- startup time;
- dataset staging time;
- feature preparation time;
- model training time by library;
- peak memory;
- average CPU utilization;
- disk throughput;
- checkpoint serialization time and bytes;
- warm restart and cache verification time;
- duplicate compute after forced replacement;
- estimated cost per completed fold/trial;
- artifacts and teardown proof.

Decision rule:
Prefer the smallest profile that completes the workload reliably. More cores are not automatically better for tree boosting because memory bandwidth and diminishing parallel scaling can dominate.

Plan-only acceptance:
- all profiles validate;
- unavailable machine types fail early;
- quota insufficiency is reported, not auto-requested;
- cost receipt is mandatory;
- policy rejects profile escalation without authorization.

Live-run stop condition:
A high-end apply requires a fresh explicit authorization. Never chain it automatically from a small benchmark.

Additional Spot cost controls:
- authorization cost bound includes VM runtime, workspace-disk lifetime, checkpoint GCS storage/operations, and a worst-case capacity-wait window;
- the run has both a VM max runtime and an absolute recovery deadline measured from initial authorization;
- recovery attempts are capped;
- an expired run is scaled to zero/destroyed and its workspace disk is deleted unless a separate time-bounded debug retention is authorized;
- `gcp-audit` must identify detached run disks, target-size-1 MIGs with no active work, stale instance templates, and run artifacts without a terminal marker.
```
