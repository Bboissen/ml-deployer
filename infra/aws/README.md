# AWS roots

The controller (`./workspace project.json`) plans and applies these roots with
saved plans bound to one reviewed authorization; nothing here is applied by
hand.

- `bootstrap/workspace`: protected S3 state bucket with local bootstrap state.
- `platform/workspace`: persistent workload bucket, no-ingress VPC/subnet,
  deployer role, project permissions boundaries, Session Manager policy and the
  Lambda/Scheduler expiry guard with its alarms.
- `platform`: the retained-platform root. Deploy uses it only for the reviewed
  IAM tightening of a foundation created by an earlier release; new installs
  never plan against it.
- `runner/workspace`: the guarded EC2 workspace, its instance role, SSM
  terminal/job documents, deadline schedule and the toolbox under `toolbox/`.

`project.example.json` is the short user configuration; `workspace-profiles.json`
pins the reviewed CPU sizes and region; `workspace-policy.json.tftpl` and
`workspace-git-policy.json.tftpl` render the runtime boundaries;
`targets.example.json` and `workspace.example.json` are the explicit advanced
configuration used by the lifecycle tests.

The instance uses IMDSv2 instance-role credentials bounded to the project's
prefixes, has no inbound rule and is reached only through Session Manager.
