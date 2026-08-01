# GCP disaster recovery

State recovery uses GCS object versioning and soft delete. Preserve an encrypted backup of the bootstrap root's local state. For remote roots, stop writers, inventory state generations, copy the selected prior generation to a private recovery location, validate it offline, and restore only after peer review. Test locking with a disposable backend prefix, never the production prefixes.

Snapshot recovery accepts only a valid manifest and final commit marker. Verify every object's size and SHA-256 before republishing; use generation preconditions so recovery cannot overwrite an accepted snapshot.

If disposable compute survives a failed run, destroy only `tofu/gcp/training-node` and audit disks and addresses. Do not use a broad project destroy. Persistent resource deletion requires a break-glass plan, inventory, verified backups, billing-owner approval, and explicit removal of `prevent_destroy` in a reviewed commit.
