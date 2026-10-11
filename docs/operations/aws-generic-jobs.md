# Generic project execution (M5)

Default job Deploy executes the declared setup and run argument arrays every
time as the non-root workspace user. The toolbox is the supported cpu-python-v1
profile. Dependencies belong to the external repository; failures report setup
errors rather than privileged package repair. Public GitHub HTTPS and reviewed
private SSH access both clone the exact commit with a cleared environment.
Private clone credentials are removed before setup runs.

Commands receive DATA_MANIFEST_URI, DATA_MANIFEST_VERSION_ID,
DATA_MANIFEST_SHA256, OUTPUT_URI and RUN_ID. The manifest describes exact native
input versions. Projects choose which bytes to read through their native SDK;
the controller does not silently copy an arbitrarily large dataset to the root
disk. Declared relative output files/trees are transferred automatically, with
bounded memory and exact versions/checksums. Logs retain at most 8 MiB. Missing
outputs, symlinks, changes during upload and transfer limits fail clearly.

Execution records infrastructure_ready, setup_exit, job_exit and
outputs_persisted independently. The controller verifies receipt scope and every
output version, then records cleanup_status separately and verifies retained
versions after compute deletion. No pre-known result hash, dependency-lock hash
or count/sum/mean is required for generic jobs. The old tiny acceptance route
keeps its fixture assertions and remains a compatibility interface.

Workspace mode executes setup only; the workspace remains available for connect
until explicit cancel or the unchanged absolute lease. Output persistence is
reported independently and does not claim checkpoint safety for interactive work.
The M6 operation API composes the full flow.

Offline checks run two different ordinary command styles, setup/job failures,
output-copy failure, timeout, bounded logs, unsafe output paths and fresh-run
isolation. Native ordinary-repository/private/public/timeout/output fault
acceptance remains pending. No compute was launched for this source change.
