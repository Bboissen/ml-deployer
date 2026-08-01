# Goal 11 — Security, recovery, cost, and final acceptance

```text
/goal Perform final GCP infrastructure acceptance for project example-project. Make no new billable resources unless an individual recovery exercise explicitly requires and receives authorization.

Security acceptance:
- enumerate project IAM and bucket IAM;
- prove no allUsers or allAuthenticatedUsers access;
- prove no service-account key exists for project-managed identities;
- prove trainer cannot access OpenTofu state;
- prove trainer cannot write Bronze/Silver;
- prove publisher cannot mutate infrastructure;
- prove IAP is the only inbound SSH path;
- prove no 0.0.0.0/0 or ::/0 ingress;
- prove no Ray ports;
- prove OS Login and block-project-ssh-keys;
- scan metadata, startup scripts, plans, state, logs, and artifacts for secrets;
- confirm public access prevention and UBLA on every bucket.

Cost acceptance:
- list all Compute Engine instances, managed instance groups, instance templates, per-instance configurations, disks, snapshots, images, addresses, load balancers, NAT gateways, routers, GKE clusters, databases, buckets, and logging sinks;
- compare inventory with the architecture allowlist;
- confirm no disposable compute, detached run-scoped workspace disk, stale target-size-1 MIG, or obsolete Spot template remains;
- calculate current persistent monthly estimate;
- verify budget alerts;
- verify every compute profile has maximum runtime and DELETE action;
- verify every Spot profile also has an absolute recovery deadline, capped attempts, stateful-disk terminal-delete policy, and orphan-disk audit;
- verify every live run has an authorization and teardown receipt;
- document that budget alerts are not a hard Compute/Storage cap.

State recovery exercise:
- identify current state object generation;
- list previous generations;
- copy a prior generation into a safe local recovery file;
- validate it without overwriting active state;
- document the exact break-glass restore procedure;
- do not delete current state or bucket.

Dataset recovery exercise:
- select disposable fixture object;
- delete through an authorized test identity if required;
- restore from soft delete/version history;
- re-run manifest verification;
- prove committed snapshot remains valid.

Compute disaster exercise:
- run a checkpoint-capable Spot smoke workload under a target-size-1 stateful MIG;
- produce and verify at least two local checkpoints and one GCS checkpoint backup;
- force managed-instance recreation;
- prove failure/preemption diagnostics upload;
- prove the original VM is gone and the replacement VM has a different instance ID;
- prove the same workspace disk is reattached;
- prove the immutable staged snapshot cache is validated and reused;
- prove the workload resumes from the highest compatible checkpoint or accepted job boundary;
- compare final output with an uninterrupted reference within documented tolerance;
- prove final artifacts upload;
- prove MIG, VM, boot disk, workspace disk, and temporary addresses are deleted at terminal completion;
- prove an incompatible checkpoint is rejected rather than silently resumed.

Documentation acceptance:
A first-time operator must be able to answer:
- which Google account and project are active;
- whether billing is enabled;
- where the credit and budget are visible;
- how to initialize and plan each root;
- which commands create billable resources;
- how to upload and identify an immutable dataset snapshot;
- how to launch the cheapest smoke;
- how to launch a larger approved server;
- how to launch, inspect, cancel, and recover a Spot run;
- how to distinguish local hot checkpoints, GCS backups, and final artifacts;
- how to connect through IAP;
- how to retrieve artifacts;
- how to destroy compute;
- which persistent resources should remain;
- how to audit unexpected cost;
- how to recover state and data.

Final verification commands:
- make gcp-doctor
- make gcp-account-check
- make gcp-fmt
- make gcp-validate
- make gcp-test
- make gcp-audit
- existing DigitalOcean validation targets
- git status --short --branch
- repository secret scan

Definition of done:
- persistent state, Bronze, Silver, and artifact storage are secure and documented;
- one direct disposable VM path has been proven end to end;
- one recoverable Spot path has survived forced VM replacement, resumed accepted work, and removed its stateful disk;
- native Polars/GBDT path works;
- larger profiles are safely gated;
- Ray Tune is optional and single-node;
- no unexpected billable resources remain;
- existing DigitalOcean functionality is intact;
- all live evidence and non-secret receipts are committed or archived according to repository policy.
```
