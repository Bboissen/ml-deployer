# Cost safety

Credits are a payment source, not a resource or spending limit. Every provider implementation uses multiple independent controls.

## Required controls

1. **Quota preflight** refuses a shape that the live account cannot support.
2. **Plan policy** limits runner count, disk size, region and allowed resource profiles.
3. **Provider-side deadline** stops or deletes compute even when the guest workload hangs.
4. **Guest fallback** exits and shuts down after completion or failure.
5. **Budget alerts** notify on actual and forecast spend where supported.
6. **Explicit destroy** removes disposable compute and verifies persistent storage remains.

Budget alerts are not treated as immediate hard caps because billing data and evaluations are delayed.

## Capacity modes

`standard` is the default while consuming credits. It provides the simplest failure model for whole fixed trials.

`interruptible` is accepted only when:

- the ML image writes durable checkpoints to results storage;
- restart behavior is tested independently of this repository;
- partial output cannot be mistaken for a completed trial;
- the provider's credit terms cover the selected capacity mode;
- the run specification explicitly opts in.

The platform never silently falls back from standard to interruptible capacity or vice versa.

## Initial resource ceiling

Until live quotas are accepted, the portable ceiling is one `balanced` or `highmem` runner per provider. Raising concurrency is a reviewed configuration change based on current quota and credit evidence.
