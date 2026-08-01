# GCP single-node architecture

The workstation plans infrastructure and stages initial immutable snapshots. Four separate roots own four lifecycles: local bootstrap state, persistent GCS data, persistent network, and disposable compute. Later roots use a native GCS backend and service-account impersonation.

Bronze is source truth, Silver contains accepted derived snapshots, and artifacts contain run outputs. The disposable VM stages selected Parquet objects to local disk and runs DuckDB, Polars, PyArrow, and native model libraries. Ray is disabled until the native path passes and is then single-node only.

Snapshots are immutable directories, not mutable bucket folders. A publisher uploads objects and `manifest.json` with generation precondition zero, verifies byte size, CRC32C, and the SHA-256 metadata, then creates `COMMITTED.json` last with the same precondition. Consumers accept only a commit whose snapshot ID and manifest digest match. Bronze has versioning; Silver defaults to no versioning; both retain soft-deleted objects for seven days. Artifact lifecycle rules cover only temporary and unaccepted prefixes.

The VM is exactly one instance in `us-central1-a`, with auto-delete disks and a maximum runtime. Administrative access is OS Login over IAP. The only ingress rule is TCP 22 from `35.235.240.0/20`; there are no Ray ports, load balancers, NAT gateways, or static addresses. A smoke profile may use an ephemeral external IPv4 solely for outbound bootstrap.
