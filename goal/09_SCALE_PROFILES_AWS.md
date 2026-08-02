# Goal 09 — AWS CPU, memory, and GPU profiles

```text
/goal Add safe plan-only EC2 profiles based on measured workload needs. Do not apply a high-end or GPU profile until quota, availability, price, architecture compatibility, and per-run authorization are documented.

Input evidence required:
- final Bronze and Silver snapshot sizes;
- object counts;
- staged EBS footprint;
- Polars/DuckDB peak memory;
- model matrix memory;
- LightGBM/XGBoost/CatBoost peak RSS;
- training wall time;
- desired parallel fold/trial count;
- CPU architecture compatibility;
- GPU acceleration benefit demonstrated on a representative sample before large GPU runs.

Discovery commands must record:
- instance types offered in candidate AZs;
- stable AZ IDs;
- On-Demand Standard, Memory, and G/VT quotas;
- Spot Standard and G/VT quotas;
- EBS quotas;
- public IPv4 quota;
- current On-Demand price from official AWS Pricing API or pricing pages;
- recent Spot price history and Spot placement score where available;
- timestamp and currency of every price receipt;
- AMI and driver compatibility for GPU profiles.

Candidate profiles, subject to live discovery:
1. dev-memory
   - target around 4-8 vCPU / 32-64 GiB
   - choose a current memory-optimized or flex type from measured need
2. train-16x128
   - target around 16 vCPU / 128 GiB
   - candidate R-family or compatible current-generation type
3. train-32x256
   - target around 32 vCPU / 256 GiB
   - candidate R-family or equivalent
4. cpu-fast
   - C-family only after CPU bottleneck measurement
5. graviton-value
   - Graviton profile only after complete arm64 dependency acceptance and benchmark
6. gpu-single
   - one GPU instance such as a discovered G5/G6/G6e size only after quota and GPU benchmark evidence
7. spot-recoverable variants
   - same approved CPU/RAM/GPU shape, Spot, checkpoint-capable only, single-AZ ASG fixed at one, preserved EBS workspace.

Do not hard-code an instance because marketing lists it. Confirm Region, AZ offering, quota, account-plan eligibility, architecture, and current price.

G6e ruling:
- G6e is not treated as a free-tier machine;
- it consumes promotional credits at normal pricing if the credit terms cover the usage;
- G/VT On-Demand quota commonly requires an explicit increase and may start at zero;
- request only the vCPU amount needed for the exact size under consideration;
- first GPU benchmark should use the smallest profile that can answer whether GPU acceleration is materially useful for this tabular workload;
- do not start with g6e.8xlarge merely because the console displays it.

Profile policy:
- one active instance only;
- no multi-GPU unless a separate architecture decision proves need;
- hard deadline schedule mandatory;
- local self-termination fallback mandatory;
- direct profiles use encrypted auto-delete root/workspace volumes;
- Spot profiles use encrypted auto-delete root plus one preserved run-scoped EBS workspace deleted at terminal state;
- no instance store initially;
- gp3 default; io2 only after measured checkpoint/staging requirements justify cost;
- disk sized from data, matrices, checkpoints, logs, temp space, and at least 30% safety margin;
- public IPv4 explicit;
- allow_ray false until Goal 10;
- max estimated cost stored with timestamped price basis.

Cost receipt for every high-end run:
- account ID;
- profile;
- instance type and architecture;
- vCPU, RAM, accelerator type/count/memory where applicable;
- purchase model;
- EBS type/size/IOPS/throughput;
- workspace preservation mode and expected EBS cost during capacity wait;
- public IPv4 assumption;
- Region/AZ/AZ ID;
- hourly On-Demand or recent Spot basis;
- maximum runtime;
- recovery deadline;
- maximum estimated total including EC2, EBS, IPv4, S3 requests/storage, EventBridge/CloudWatch/SSM optional costs;
- currency;
- price timestamp;
- plan SHA;
- run purpose;
- operator approval.

Benchmark ladder:
1. Native small profile baseline.
2. dev-memory benchmark.
3. train-16x128 only if smaller profile insufficient or too slow.
4. train-32x256 only if measured scaling justifies it.
5. smallest useful GPU benchmark.
6. larger GPU only if measured speedup and cost per completed experiment justify it.
7. Spot only after Goal 09A forced-replacement and cleanup acceptance.

Benchmark outputs:
- startup and SSM-ready time;
- dataset staging time;
- feature preparation time;
- model training time by library;
- peak RAM and GPU memory;
- average CPU/GPU utilization;
- EBS throughput and queue depth;
- checkpoint serialization and bytes;
- warm restart/cache verification;
- duplicate compute after replacement;
- estimated cost per completed fold/trial;
- artifact and teardown proof.

Decision rule:
Prefer the smallest profile that completes reliably. More cores or a GPU are not automatically better for GBDT workloads; memory bandwidth, CPU implementation, data conversion, GPU transfer, and diminishing parallel scaling can dominate.

Plan-only acceptance:
- all profiles validate;
- unavailable types fail early;
- quota insufficiency reported, never auto-requested by code;
- account-plan restriction reported;
- cost receipt mandatory;
- policy rejects escalation without authorization.

Live-run stop condition:
A high-end apply requires fresh explicit authorization. Never chain it automatically from a small benchmark.

Additional Spot cost controls:
- authorization includes VM runtime, EBS lifetime, S3 checkpoint operations, public IPv4 if any, and worst-case capacity-wait window;
- both per-instance runtime and absolute recovery deadline;
- capped attempts;
- expired run scales ASG to zero and deletes EBS unless separate debug retention approved;
- audit identifies detached run volumes, ASGs with no active work, stale launch templates, schedules, and run artifacts without terminal markers.
```
