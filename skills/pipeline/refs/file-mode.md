# File mode and chat mode (`VCS_PROVIDER = file`)

Read when `talos.sh env` prints `ref=file-mode`. No PRs, no QA/reviewer/security/docs, no board (the file IS the board), no `state --summary`, no Step 1 or Step 3e. Steps 0, 2 and 5 still apply.

**Chat mode (no issues yet).** If the user describes work conversationally, extract the tasks, write `plan.md` with one `- [ ] Task` item per task, set config to file mode (`{"vcs": {"provider": "file", "file": {"source": {"path": "plan.md"}}}}` in `talos.pipeline.json`) and proceed as below.

**Issue list** = the unchecked items in `FILE_SOURCE_PATH`: `bash scripts/pipeline-vcs.sh list-issues` returns `[{"id": "1", "title": "..."}, ...]`. For each:

1. Validator: `view-issue <id> --since-stage` (body, latest stage comment, newer human comments, `earlier_comments` count). CONFIRMED: comment and continue; else comment the reason and skip.
2. Developer: branch, implement, verify, commit and push, comment the branch name.
3. The review stages are skipped. Close: `close-issue <id> --body-file -`, then the `issue-closed` notify.

Board calls are skipped; the checkbox IS the state.
