# AGENTS.md

- don't spawn subagent when not asked
- don't use complex style reviewing for a simple HTML report
- don't resolve ambiguity yourself, ask me
- on a long running goal task, stop for my review at important milestone or to resolve ambiguity
- on a long running script, report only fail or success, create a monitoring progress script instead of continuous polling

## Git
- Keep diffs small, reviewable, and human-readable.
- If the task require broad changes, stop split commit per task
- Never commit directly to `main` or `master`, work in appropriate branch, use PR to properly merge on main
- Never use `git add .` or `git add -A`; stage files explicitly by path.
- If shell `git push` is blocked by the environment policy, push the branch through the GitHub API and then align the local branch ref to the remote API-created commit when the tree is identical.
- Before any commit, show:
  - `git status --short`
  - `git diff --stat`
  - `git diff --cached --stat`

## Branches and PRs

- One task = one branch = one PR.
- Do not create multiple PRs for one task unless I explicitly ask.
- Do not create parallel branches for the same task.
- Do not use "codex" as prefix for branch names, use industry convention for naming

## Commits

- Prefer one small logical commit.
- Use clear human-readable commit messages.
- Use conventional commits when appropriate:
  - `fix: ...`
  - `feat: ...`
  - `refactor: ...`
  - `test: ...`
  - `docs: ...`
  - `chore: ...`
- Avoid huge commits. If the diff is large, split it.

## Pull requests

- PR title must be clear and human-readable.
- PR body must include:
  - Summary
  - Tests run
  - Risk / rollback notes
