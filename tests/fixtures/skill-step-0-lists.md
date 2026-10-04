## Step 0 — Read config

Run this once, before Step 1, and keep the answer for the whole run:

```bash
bash scripts/talos.sh env
```

Its output is the only config read in this playbook (project config over the user-level file, defaults applied, `ISOLATION` validated):

- `KEY=value`, one setting per line, under the variable names used below (`MAX_PARALLEL`, `VERIFY_COMMANDS`, `ROLE_QA`, ...). A list joins its items with the two characters `\n`; a control byte prints as `\xNN`. `VERIFY_QA_MODE` is the resolved value. With `STATUS_ENABLED = false` none of the status steps run: every status instruction below says "`STATUS_ENABLED = true`" and is skipped otherwise.
- `agent.<role>.runner|runner_cmd|model|effort|fallback|effort_notice` (an absent field is empty): see Harness compatibility.
- `warn reason=<r>`: relay it once and continue; `resolve-failed role=<role>` means that role has no `agent.` lines, so do not spawn it (`bash scripts/pipeline-agent.sh --resolve <role>` shows the error).
- `stop reason=<r>` (non-zero exit: `isolation-invalid`, `config-unreadable`, `scripts-missing`, ...): abort the run, print the line and the stderr error, process no issues.

**File mode vs VCS mode:**
- If `VCS_PROVIDER = file`: no PRs are opened; developer commits to branch; QA/reviewer/security/docs stages are skipped; board calls are skipped (the file IS the board). See the File Mode section.
- All other providers: full pipeline as described below.

