# Human-merge mode (`merge.auto = false`)

Read when `talos.sh env` prints `ref=human-merge`, or `gate merge` answers `handoff`, or `next` answers `wait reason=human-merge`.

Every gate still applied, and the verb set `pipeline:approved` (a repeat answers `wait`). Hand off to a human:

`bash scripts/talos.sh post-merge <PR_NUMBER> <N> --handoff [--details-file <file>]`: approved.md on the PR, then the relay, nothing else (a failed comment is `warn reason=comment-failed`: report it). STOP: do NOT close the issue or run the post-merge steps; the human's merge closes it, and `sweep`'s heal does the bookkeeping on a later run.

A PR waiting on a human merge after `pipeline:approved` is `in-flight` in the Step 5 table.

With evidence on (`refs/evidence.md`), add its hand-off bullet through `--details-file`.
