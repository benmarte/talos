CI is the authoritative full run. Never run the full suite: targeted tests only
(`--for <path> --strict`) through `pipeline-verify.sh` (it exports the identity
itself; never export TALOS_ISSUE_NUMBER / TALOS_WORKTREE_PATH by hand). With
Talos's own `tests/run-tests.sh` add `--budget-s <budget-s>` (agents/qa.md step 2):
exit 6 means the selection was over budget and not run, which is reported, not a
block. Step 1: