# Contributing

This repository owns AWS ML workspace infrastructure: a Bash bootstrap, a Python
controller and OpenTofu roots. External ML repositories own their code,
dependencies, datasets and results. [AGENTS.md](AGENTS.md) holds the working
rules that apply to every change, human or automated; [SECURITY.md](SECURITY.md)
lists the protections every change must keep.

## License

The repository is released under the [MIT License](LICENSE). Contributions are
accepted under the same terms.

## Development setup

```sh
git clone https://github.com/Bboissen/ml-deployer.git
cd ml-deployer
make workspace-test-setup   # locked Python 3.13 test environment under .tools/
make check                  # repository, workspace, AWS and formatting checks
```

`make check` runs offline with mocked providers. Each AWS suite runs in a
disposable source snapshot and writes a cleanup receipt under ignored
`evidence/aws/test-receipts/`. Backend-disabled `tofu init` may download the
pinned providers. Passing checks are not native acceptance; see the
[native acceptance scope](docs/operations/aws-native-acceptance.md).

Keep `README.md`, the [first-use guide](docs/aws-setup-guide.html), the
[quickstart](docs/operations/aws-deployer-quickstart.md) and `./workspace --help`
consistent when a command changes.

## Branches, commits and pull requests

- One task per branch and pull request: `feat/`, `fix/`, `refactor/` or `docs/`.
  Never commit on `main`.
- Stage explicit paths; run `git status --short`, `git diff --stat` and
  `git diff --cached --stat` before committing.
- Open a draft pull request early and keep it updated with tested commits.
- Pull request bodies have three sections: Summary, Tests run, Risk / rollback notes.
- Merging requires the owner's authorization.

## Boundaries every change keeps

- No cloud keys, tokens or secrets in source, bootstrap, plans, state, logs or
  fixtures. Tests use obvious placeholders such as account `111111111111`.
- Pin OpenTofu, providers, tool archives and Python packages from official
  release metadata and commit the lockfiles.
- Keep the checks that protect the selected account, resource ownership,
  download integrity, scope-bound authorization, data integrity and
  provider-side expiry. No `--skip-checks` or `--unsafe` options.
- Tests stay offline and remove exactly the disposable resources they created.
  Never run global Docker or cache pruning.
- Cloud mutation, key registration, dataset upload, release publication and
  repository visibility changes each need the owner's explicit authorization.

## Releases

`shared/workspace/release.json` names the next release candidate.
`python3 -B scripts/aws/package-release.py OUTPUT_DIR` builds a deterministic
archive, its SHA-256 and a standalone `install.sh` from clean committed source;
the `release-package` CI job does the same on `workflow_dispatch`. Publishing a
GitHub release is a separate owner action after the native acceptance cases pass.
