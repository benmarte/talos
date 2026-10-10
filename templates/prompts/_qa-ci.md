CI is the authoritative full run. Never run the full suite: targeted tests only
(`--for <path> --strict`) through `pipeline-verify.sh` (it exports the identity
itself; never export TALOS_ISSUE_NUMBER / TALOS_WORKTREE_PATH by hand). Step 1: