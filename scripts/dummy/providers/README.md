# Provider adapter boundary

The shared Makefile dispatches one operation to exactly one executable adapter:

```text
scripts/dummy/providers/aws.sh OPERATION
scripts/dummy/providers/gcp.sh OPERATION
scripts/dummy/providers/azure.sh OPERATION
```

This common milestone intentionally does not supply those adapters. Each later
provider task owns its adapter and its provider-specific OpenTofu roots. The
dispatcher validates common immutable hashes, saved plans, and exact JSON
authorization artifacts before it can invoke an adapter. A missing adapter is a
hard failure.

An adapter accepts exactly one of `preflight`, `publication-review`, `publish`,
`plan`, `apply`, `observe`, `receipt-publish`, `receipt-check`, `destroy-plan`,
`destroy`, or `post-destroy-check`. Goal 02 command-result version 1 is used
only where its command enum applies. Other operations emit their own exact,
hashed evidence and must not impersonate another command. `apply` and `destroy`
must consume the supplied saved plan; they must never plan implicitly.
