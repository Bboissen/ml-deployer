# OpenTofu roots

```text
infra/aws/
  bootstrap/workspace   explicit local-state bootstrap of the S3 state bucket
  platform/workspace    persistent platform: workload bucket, network, IAM boundaries, expiry guard
  platform              retained-platform root used only when Deploy must tighten the IAM of an existing foundation
  runner/workspace      disposable guarded toolbox instance, identity, terminal and job documents
```

Roots are flat (no modules), pin OpenTofu and the AWS provider, bind the
provider to the reviewed account and never contain state or saved plans.
`make scaffold-test` runs backend-disabled init/validate for each root. Passing
it authorizes no plan, apply, import, state change or destruction.
