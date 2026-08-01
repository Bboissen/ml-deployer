# AWS disaster recovery

Persistent S3 state and data are independent of disposable compute. S3 state bucket versioning and native lockfile locking provide the recovery base; restoration is a reviewed operation, never an automatic rollback.

Direct instances are non-recoverable: selected checkpoints copy asynchronously to immutable S3 names, then the instance and its disks delete. Spot recovery is deferred to Goal 09A and will reuse exactly one encrypted, run-scoped EBS workspace in one AZ after validating run, volume, snapshot, and checkpoint identity.

Every terminal state must delete run-scoped instances/ASG, launch resources, deadline schedule, and workspace after required artifact verification. If automated cleanup fails, stop new runs, use the read-only audit to resolve exact resource IDs, and perform a separately reviewed compute-only cleanup. Persistent bucket deletion is a break-glass procedure outside routine commands.
