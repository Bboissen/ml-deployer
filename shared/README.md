# Shared workspace contract

`workspace/schema.json` defines the request, handoff and readiness records the
controller exchanges with the instance; `workspace/project.schema.json` is the
short user configuration; `workspace/toolbox.json` pins the toolbox profile;
`workspace/release.json` names the release candidate. `workspace/example/` is
the deterministic NumPy/pandas acceptance example with its locked environment.

Nothing here contains provider configuration, production ML code or experiment
parameters.
