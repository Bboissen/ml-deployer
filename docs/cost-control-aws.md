# AWS cost control

Budgets and anomaly alerts are notifications, not caps. No workload resource exists in Goals 01-02.

Later live runs require all of these controls:

- live price/quota/AZ evidence;
- allowlisted machine profile and exact saved plan;
- operator-selected maximum cost and runtime;
- exactly one direct instance or one Spot ASG fixed at size one;
- one-time EventBridge Scheduler deadline plus local fallback;
- encrypted bounded gp3 volumes and explicit public IPv4 cost;
- terminal artifact verification, compute teardown, and resource audit.

The plan-only candidates are deliberately not price assertions. `cpu-memory-plan` targets 16 vCPU/128 GiB and `gpu-single-plan` targets a small single-GPU experiment, but neither is authorized until current availability, quota, price, memory need, and expected benefit are recorded. GPU is not automatically faster or cheaper for tabular GBDT work.

Never buy a Savings Plan, Reserved Instance, Capacity Reservation, Dedicated Host, Marketplace AMI, or Support upgrade from this workflow.
