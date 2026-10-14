# Local evidence

Only this README and `.gitignore` are tracked. Keep local state, backups, saved
plans, authorization ledgers, receipts and audit responses below this ignored
root. Use `aws/`, `gcp/`, `azure/`, `audits/`, `migrations/` and `foundation/`.
Each operation gets a fresh directory; preserve immutable review artifacts.
Tests own temporary directories under `.test-runtime/` and may remove only
those directories. Dependency downloads belong in ignored `.tools/`.

The original checkout holds the 7 October pivot audit and foundation preservation
record. An isolated worktree does not copy or share its evidence automatically.
Historical adapters may still enforce older external evidence paths; migrating
those paths is provider-owned work with a verified receipt, never a state move
inferred from a code change. Do not delete old evidence or rebuildable material
without its exact reviewed cleanup scope and verification receipt.
