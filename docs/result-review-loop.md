# Real-time result review loop

Ray Tune already reports trial metrics back to the Ray head when the trainable calls `tune.report(...)`.

This repo adds a file-based review loop:

```text
Ray trial -> tune.report -> LiveJsonlCallback -> artifacts/live/trial_events.jsonl
watch_results.py -> artifacts/live/latest_summary.md
Codex/subagent -> reads latest_summary.md -> writes artifacts/reviews/*.md
```

## Why file-based

It is simple, auditable, and tool-agnostic. Codex, a shell script, or a human can all read the same markdown summary.

## Optional subagent trigger

Set:

```bash
export CODEX_REVIEW_COMMAND="your-review-command"
```

Then run:

```bash
make watch
```

The watcher will create review task files in `artifacts/inbox/`. If `CODEX_REVIEW_COMMAND` is set, it calls the command with the report path.

## Review expectations

A result-review subagent should answer:

- What is the current best trial?
- Are metrics improving?
- Are failures systematic?
- Are workers underutilized?
- Should search space or feature set be narrowed?
- Is there any evidence of memory pressure or scheduling failure?
