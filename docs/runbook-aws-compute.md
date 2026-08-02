# Runbook: AWS single-node compute

Goals 01-02 contain no EC2 resources and `make aws-up` fails closed.

The later direct lifecycle will be plan → policy check → exact one-use authorization → apply → SSM/runtime verification → artifact verification → compute-only destroy → audit. CPU and GPU profiles both run native Polars/DuckDB staging and ML smoke, but use their distinct AMI/driver policy.

The first live compute must be a currently discovered Free-Tier-eligible infrastructure smoke, not a training server. Larger CPU and GPU profiles remain plan-only until measured workload need, current price, quota, AZ availability, and maximum cost are approved.

Never launch through the EC2 Console, add SSH ingress, create a key pair, or leave a stopped instance/EBS volume for debugging without separate bounded authorization.
