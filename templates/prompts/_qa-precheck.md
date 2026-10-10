Pre-CI gate (pr.ready_gate): the PR is still a draft, so no CI has run and none starts
until you pass. Do not wait for CI and never call `pr-checks-required`. Run every
test through `pipeline-verify.sh` (it exports the identity itself; never export
TALOS_ISSUE_NUMBER / TALOS_WORKTREE_PATH by hand). Step 1: