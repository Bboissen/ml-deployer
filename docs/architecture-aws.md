# AWS single-node native ML architecture

AWS is added beside DigitalOcean. It does not replace or extend the distributed Ray worker topology.

```text
operator workstation (AWS CLI aws login + OpenTofu)
  -> S3 state bucket                         persistent
  -> S3 Bronze/Silver/artifact buckets       persistent
  -> custom VPC + one subnet path            persistent
  -> one direct EC2 instance                 disposable CPU or GPU
       encrypted auto-delete root/workspace EBS
       SSM Session Manager; zero inbound rules
       Polars + DuckDB + native ML libraries
  -> or one single-AZ Spot ASG (size exactly 1)
       disposable root + preserved run-scoped EBS workspace
       explicit terminal deletion
```

S3 is the durable object and backup plane, not the active filesystem. A selected immutable snapshot is staged to local EBS. Polars and DuckDB scan projected Parquet data locally; model matrices are materialized only when needed.

CPU and GPU share the data/run contract but use separate AMI parameters. The GPU base DLAMI anticipates NVIDIA driver/CUDA compatibility; bootstrap verifies rather than silently replacing the driver. Ray remains disabled until native single-node workloads pass and may later run locally only.

Standard runs create one direct instance. Recoverable Spot runs use a separate root with an ASG fixed at min/max/desired one and a separately managed workspace volume in the same AZ. Persistent buckets/network never participate in routine compute teardown.
