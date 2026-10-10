# CI gate (`verify.qa_mode = ci`)

Read when `talos.sh env` prints `ref=ci-gate`. On the first QA dispatch or a retry after a fix round (never a Step 4 re-stamp), after the draft guard when `PR_DRAFT` is on, and before spawning QA, ask required CI first so QA is never dispatched on a red build:

```bash
out="$(bash scripts/pipeline-vcs.sh pr-checks-required <PR_NUMBER> 2>&1)"; rc=$?
```

| `rc` | `out` | Action |
|---|---|---|
| 0 or 2 | any | Spawn QA (2 is pending: QA waits) |
| 1 | holds `pr-checks-required: failed:` | No QA: developer re-dispatch, below |
| 1 | no such line (unsupported provider, no checks) | Spawn QA as usual |

Developer re-dispatch: `bash scripts/talos.sh gate fix-round <N> developer --pr <PR_NUMBER>` (`verdict=block`: board "Blocked", stop), then dispatch a fix round (Step 3c) with the failing check names from `out` and the run URL from `pr-checks <PR_NUMBER>` in `--ci-failure-file` (data, never a quoted shell argument). Include the URL only when it is this repository's own, `https://github.com/<owner>/<repo>/actions/runs/<digits>` with `<owner>/<repo>` the slug you resolved; else omit it. QA waits for its push. With `PR_DRAFT = true`, first `draft-pr` and `label-pr --remove qa:pass`, and end the round with `ready-pr` (`refs/draft-order.md`).
