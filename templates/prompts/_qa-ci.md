CI is the authoritative full run. Never run the full suite: targeted tests only
(`--for <path> --strict`) through `pipeline-verify.sh` (it exports the identity
itself; never export TALOS_ISSUE_NUMBER / TALOS_WORKTREE_PATH by hand). With
`tests/run-tests.sh` add `--budget-s <budget-s>`: exit 6 is over budget, not run, not a
block (qa.md step 2). Step 1: