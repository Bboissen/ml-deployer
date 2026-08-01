# Runbook: AWS storage lifecycle

Goals 01-02 create no buckets. After Goal 03 code and a separate reviewed authorization exist, the intended order is:

1. plan the local-state bootstrap root;
2. authorize and create only the protected state bucket/deployer role;
3. migrate and prove S3 state locking with `use_lockfile=true`;
4. plan and separately authorize Bronze, Silver, and artifact buckets;
5. verify encryption, versioning/lifecycle, public-access blocks, IAM boundaries, and no drift.

There is intentionally no routine persistent-storage destroy target. Do not create any project bucket manually in the console.
