# Re-stamp dispatch

Read when the Step 3e re-stamp check or Step 4's `stale=` list names a role. A re-stamp is a delta-only re-review by a role that already approved this PR; the trigger and the `RESTAMP_FAIL` rules are in Step 3e.

- Same role and role profile as the full stage, never a different agent or prompt; spawned per the Spawning paragraph (usage form included).
- Prompt: `bash scripts/talos.sh prompt <role> --issue <N> --pr <PR_NUMBER> --shape restamp --restamp-file F`. `F` (a heredoc) holds the approved SHA and stale file list, the current head SHA, `diff-pr <PR_NUMBER> --stat` and the role's previous verdict comment URL. The verb sets the header `**Agent:** <role> (talos) — re-stamp` and the delta-only instruction.
- Model: `bash scripts/pipeline-config.sh agents.roles.<role>.restamp_model`, then `agents.restamp_model`, else the role's resolved model (project config over the user-level file; `pipeline-config.sh` resolves the first two links itself).
- Effort: the same chain with `restamp_effort`; advisory on the native path, `TALOS_EFFORT` on the adapter path.
- QA's re-stamp runs targeted tests only, never the full suite. A `RESTAMP_FAIL` is not merged against: it escalates to the role's full-stage re-dispatch on the next pass.
- Cost is separated through the `RESTAMP_PASS`/`RESTAMP_FAIL` verdict (`pipeline-events.sh cost`).
