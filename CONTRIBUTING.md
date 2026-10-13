# Contributing

This repository owns cloud ML workspace infrastructure: a Bash bootstrap, a
Python controller and OpenTofu roots. External ML repositories own their code,
dependencies, datasets and results. Read [AGENTS.md](AGENTS.md) for the working
rules that apply to every change, human or automated.

## License status

The repository is private and has no tracked license yet. The owner decides the
license before any public release; no contribution implies one. Candidates under
review are Apache-2.0 (patent grant, common for infrastructure tooling) and MIT.
Do not add a `LICENSE` file or license headers without that decision.

## Development setup

```sh
git clone https://github.com/Bboissen/Ray_terraform.git
cd Ray_terraform
make workspace-test-setup                 # locked Python 3.13 validation environment under .tools/
uv pip install --python .tools/workspace-venv/bin/python --only-binary :all: \
  --require-hashes -r scripts/aws/controller-requirements.lock   # controller packages for the AWS suites
make check                                # repository, workspace, AWS, scaffold and formatting checks
```

`make check` runs offline: mocked providers, disposable source snapshots and an
exact cleanup receipt per suite under ignored `evidence/aws/test-receipts/`.
Backend-disabled `tofu init` may download pinned providers. Passing checks are
not native acceptance; see [native acceptance scope](docs/operations/aws-native-acceptance.md).

Developer acceptance matrices and historical milestone records live under
`docs/operations/` and `goal/`. The user-facing first-use path is the
[first-use guide](docs/aws-setup-guide.html) served by `make` and the
[quickstart](docs/operations/aws-deployer-quickstart.md); keep them, the README
and `./workspace --help` consistent when commands change.

## Branches, commits and pull requests

- One task per branch and pull request: `feat/`, `fix/`, `refactor/` or `docs/`.
  Never commit on `main`.
- Stage explicit paths. Before committing run `git status --short`,
  `git diff --stat` and `git diff --cached --stat`.
- Open a draft pull request early and keep it updated with tested commits.
- Pull request bodies have three sections: Summary, Tests run, Risk / rollback notes.
- Merging requires the owner's authorization.

## Boundaries that every change keeps

- No static cloud keys, tokens or secrets in source, bootstrap, plans, state,
  logs or test fixtures. Tests use obvious placeholders such as account
  `111111111111`.
- Pin OpenTofu, providers, tool archives and Python packages; commit lockfiles.
  Tool and package hashes come from official release metadata.
- Preserve checks that protect the selected account, resource ownership,
  download integrity, saved-plan authorization, data integrity and provider-side
  expiry. Do not add a `--skip-checks` or `--unsafe` option.
- Tests stay offline and remove exactly the disposable resources they created,
  including after failure. Never run global Docker or cache pruning.
- Cloud mutation, key registration, dataset upload, release publication and
  repository visibility changes each need the owner's explicit authorization.

## Releases

`shared/workspace/release.json` names the next release candidate.
`python3 -B scripts/aws/package-release.py OUTPUT_DIR` builds a deterministic
archive, its SHA-256 and a standalone `install.sh` from clean committed source;
the `release-package` CI job does the same on `workflow_dispatch`. Publishing a
GitHub release is a separate reviewed owner action that follows the native
acceptance cases.
