# Conflicting PR (`pr-mergeable` exit 1) and the merge-base task

Read when `pr-mergeable <PR>` exits 1 (`CONFLICTING`) after the developer opened the PR, when `gate merge` answers `redispatch` with `merge-conflict`, or when the sibling sync answers `developer`. No QA runs on a conflicting PR: GitHub schedules no `pull_request` run for it, so QA would hang.

Mechanical path first:
1. `bash scripts/pipeline-vcs.sh conflict-files <PR>` (exit 2 = cannot determine: go to step 3).
2. Every path in `merge.union_paths` (default `CHANGELOG.md`): `bash scripts/pipeline-mergebase.sh <PR>`. Exit 0 = pushed: a one-line comment, `post_stage merge-base` via the verb's `--summary`, no `record-attempt`. Then `pr-mergeable` again.
3. Otherwise the orchestrator never moves HEAD here (hard rule 4): ALWAYS `bash scripts/talos.sh gate fix-round <N> developer --pr <PR>` and dispatch the developer merge-base task (worktree): branch, `git fetch origin && git merge origin/<BASE_BRANCH>` (a CHANGELOG conflict keeps BOTH entries, newest first), resolve, targeted verify, push. Then `pr-mergeable` again; at `MERGEABLE`/`UNKNOWN` continue to Step 3d. `verdict=block`: board "Blocked", stop.
