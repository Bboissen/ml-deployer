# Scripts

`./workspace` at the repository root is the operator entry point; everything
under `aws/` is called through it or shipped to the instance.

- `aws/workstation-setup.sh`, `aws/workstation-ui.sh` — Bash bootstrap of the
  hash-pinned tools; works before Python exists.
- `aws/workspace-guide.sh`, `aws/workspace-guide.py`, `aws/workspace_setup.py` —
  guided first use and the read-only companion page.
- `aws/workstation-auth.py` — native AWS and GitHub sign-in checks; never reads
  or prints credentials.
- `aws/workspace-doctor.py` — readiness report.
- `aws/workspace.py`, `aws/workspace-config.py`, `aws/workspace-deploy.py`,
  `aws/workspace-onboarding.py`, `aws/workspace-ingest.py`, `aws/workspace-e2e.py`,
  `aws/workspace_lifecycle.py`, `aws/workspace_target.py` — the controller:
  configuration, foundation, saved plans, authorization, ingestion, launch,
  verification and cleanup.
- `aws/clone-project.sh`, `aws/workspace-ssh.sh`, `aws/workspace-job.sh`,
  `aws/workspace-generic-job.py`, `aws/workspace-guest-observe.sh`,
  `aws/workspace_files.py`, `workspace/probe-toolbox.py` — run on the instance
  as the non-root `workspace` user.
- `aws/package-release.py`, `aws/install-release.sh`, `aws/workspace_release.py` —
  deterministic release archive and standalone installer.
- `workspace/validate.py` — offline validation of request, handoff and readiness
  records against `shared/workspace/schema.json`.
- `check-repository.sh` — static repository checks used by `make check`.

Scripts stay small infrastructure entry points; they never implement training,
scheduling, data transformation or result analysis.
