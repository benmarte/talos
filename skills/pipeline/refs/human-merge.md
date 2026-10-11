# Human-merge mode (`merge.auto = false`)

Read when `talos.sh env` prints `ref=human-merge`, or `gate merge` answers `handoff`, or `next` answers `wait reason=human-merge`, or the driver ends on `stop action=wait reason=human-merge`.

**After the driver** (`ORCHESTRATOR=code`). With `merge.auto` off `next` never answers `merge`, so the driver never ran the merge gate. Run it yourself, once per run:

1. `bash scripts/talos.sh state --summary`: `where=next: wait (human-merge) on PR #<PR> (#<N>)` names the PR and its issue. Any other `where=next:` line: no hand-off, relay only.
2. `bash scripts/talos.sh gate merge <PR> <N>`. First line `verdict=handoff`: the hand-off below. `verdict=wait` with `reason=awaiting-human-merge`: handed off on an earlier run, nothing to do. Any other answer: join its lines with spaces, put `stop ` in front (a `stop reason=<r>` stays as it is) and take that line's row in SKILL.md's end-state table. Never merge, never hand off without `verdict=handoff`.

Every gate still applied, and the verb set `pipeline:approved` (a repeat answers `wait`). Hand off to a human:

`bash scripts/talos.sh post-merge <PR> <N> --handoff [--details-file <file>]`: approved.md on the PR, then the relay, nothing else (a failed comment is `warn reason=comment-failed`: report it). STOP: do NOT close the issue or run the post-merge steps; the human's merge closes it, and `sweep`'s heal does the bookkeeping on a later run.

A PR waiting on a human merge after `pipeline:approved` is `in-flight` in the Step 5 table.
