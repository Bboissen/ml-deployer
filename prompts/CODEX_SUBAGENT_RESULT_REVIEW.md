# Codex subagent prompt: review live Ray Tune results

You are reviewing live experiment output from a Ray Tune run.

Read:

- `artifacts/live/latest_summary.md`
- `artifacts/live/trial_events.jsonl`
- the active config file under `configs/`

Answer in `artifacts/reviews/review_<timestamp>.md`:

1. Best current trial and metric.
2. Whether search is improving, plateauing, or failing.
3. Any worker/resource symptoms: slow trials, failed trials, memory pressure, too little parallelism.
4. Whether to narrow, widen, or stop the search.
5. Concrete next config changes.
6. Any infra issues that must be fixed before scaling to DigitalOcean.

Do not modify infrastructure. Do not start or destroy workers. This is a read-only review.
