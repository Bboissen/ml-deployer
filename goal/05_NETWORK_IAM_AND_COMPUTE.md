# Goal 05 — Network, IAM, and disposable training node

```text
/goal Implement the GCP network, access, runtime identity, direct disposable training-node root, and the provider-neutral contracts later used by a recoverable target-size-1 Spot runner in project example-project. Do not apply until code-only validation and explicit authorization pass.

Network root:
- custom-mode VPC, not the default network;
- one us-central1 subnet, for example 10.91.0.0/24;
- Private Google Access enabled;
- no Cloud NAT in V0;
- no load balancer;
- no Cloud Router;
- no VPN;
- no DNS zone;
- ingress deny by absence except IAP SSH;
- IAP SSH source only 35.235.240.0/20, tcp:22, targeted to the training VM service account or network tag;
- no 0.0.0.0/0 SSH rule;
- no Ray ports;
- egress uses normal default behavior and is documented.

Administrative access:
- OS Login enabled project-wide or instance-wide;
- block project-wide SSH keys;
- administrator receives only the roles needed for IAP tunnel and OS Login;
- use `gcloud compute ssh --tunnel-through-iap` explicitly;
- no static external IP.

Runtime service account:
- `training-runtime` account;
- read Bronze and Silver;
- create artifacts;
- write logs/metrics if needed;
- no project Editor;
- no service-account User on unrelated identities;
- no IAM mutation;
- no state-bucket access;
- no service-account key.

Direct Standard compute root requirements:
- exactly one `google_compute_instance`;
- Ubuntu 24.04 LTS or another reviewed current LTS image;
- Shielded VM secure boot, vTPM, and integrity monitoring where compatible;
- OS Login and block-project-ssh-keys metadata;
- deletion protection false because VM is disposable;
- boot disk auto-delete true;
- optional workspace disk auto-delete true;
- cloud-platform OAuth scope with IAM enforcing actual access;
- labels: project, environment, role, run_id, profile, owner, expires_at, managed_by;
- `max_run_duration` mandatory;
- `instance_termination_action = "DELETE"` mandatory;
- startup script idempotent and non-secret;
- shutdown script best-effort artifact sync, but the workload itself must sync artifacts before success;
- serial-port and journal logs available for bootstrap debugging;
- no secrets in metadata or cloud-init.

External IPv4 ruling:
- smoke profiles may use an ephemeral external IPv4 only for outbound package installation;
- no public inbound rule exists, so SSH still uses IAP;
- the address is released on automatic VM deletion;
- profile and plan must expose the cost implication;
- high-security no-external-IP profiles are deferred until a prebuilt image or another economical egress design exists.

Startup contract:
1. Create `/opt/spotify-ml` and `/mnt/spotify-ml`.
2. Write bootstrap status to `/var/lib/spotify-ml/bootstrap-status.json` atomically.
3. Install minimal OS packages.
4. Install a locked Python environment without embedding credentials.
5. Authenticate to GCS through the attached service account.
6. Run an infrastructure smoke script.
7. Never download real data unless a snapshot ID is supplied.
8. Never start Ray unless `enable_ray=true`.

Machine profiles initially committed:
- smoke-free: e2-micro, STANDARD, 10 GB pd-standard, external IPv4 true, 45 minutes, Ray false.
- smoke-paid: e2-standard-2, STANDARD, 20 GB pd-balanced, external IPv4 true, 90 minutes, Ray false.
- dev-memory: e2-highmem-4, STANDARD, 50 GB pd-balanced, external IPv4 true, 120 minutes, Ray false.
- larger profiles remain disabled until Goal 09.

Plan-policy rejection rules:
- project or region mismatch;
- more than one VM;
- unapproved profile;
- GPU;
- local SSD;
- persistent non-auto-delete disk in the direct Standard root;
- missing max runtime;
- termination action not DELETE;
- public SSH;
- static IPv4;
- service-account key;
- metadata containing likely credentials;
- unexpected API, database, GKE, NAT, load balancer, or reserved-address resources.

Code-only validation:
- init and validate both roots;
- plan network and smoke-free compute;
- policy-check JSON plan;
- unit-test startup template rendering;
- scan rendered metadata for secrets;
- test that automatic deletion fields are present.

Stop condition:
No apply until the free-tier smoke authorization is separately issued.

Spot-runner boundary for Goal 09A:
- the Spot implementation belongs in a separate `tofu/gcp/spot-runner/` root;
- use one instance template and one zonal managed instance group with target size exactly 1;
- provisioning model is SPOT and VM termination action remains DELETE;
- boot disk auto-deletes;
- one separately managed zonal workspace disk is declared stateful and preserved across instance recreation;
- the workspace disk is not a persistent platform resource: it is labeled by run ID, has an expiry, and is explicitly deleted at terminal teardown;
- no autoscaling, no second worker, no load balancer, and no distributed model training;
- startup mounts the workspace disk by stable device/UUID, verifies the run manifest, reuses a valid staged dataset cache, and resumes the latest compatible checkpoint;
- shutdown handling receives only best-effort time and may flush logs or an already-written checkpoint, but periodic checkpointing is the primary recovery mechanism;
- serial logs and recovery events must distinguish PREEMPTED, BOOTSTRAP_FAILED, CHECKPOINT_INCOMPATIBLE, CAPACITY_WAIT, COMPLETED, FAILED, CANCELLED, and EXPIRED;
- max recovery attempts and a total recovery deadline prevent an endless recreate loop;
- plan policy rejects any Spot runner without terminal disk deletion and an orphan-disk audit path.
```
