## Step 0 — Read config

```bash
bash scripts/talos.sh env
```

Run once, keep the answer for the whole run. Its output replaces the Step 0 reads; only restamp keys are read later (project config over the user-level file, defaults applied, `ISOLATION` validated):

Run once. Restamp keys read later; project config over the user-level file. Lists join `\n`; backslash → `\\`, control → `\xNN`, bidi → `\uXXXX`, 8192-cut → `[truncated]`.
- `agent.<role>.runner|runner_cmd|model|effort|fallback|effort_notice` (absent = empty): see Harness compatibility.
- `warn reason=<r>`: relay once, continue; `resolve-failed role=<role>`: do not spawn it.
- `stop reason=<r>` (non-zero exit): abort, print it, process no issues.

Then print where the run stands: `bash scripts/talos.sh state --summary` (read-only; at most three `where=` lines: in flight, waiting, next) and continue. A new session, or another LLM, resumes by starting this skill; there is nothing else to read. Skip it in File mode; on a `stop`, report it and continue.

**File mode** (`VCS_PROVIDER = file`): no PRs, no QA/reviewer/security/docs, no board (the file IS the board).

