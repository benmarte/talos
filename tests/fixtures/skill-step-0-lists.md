## Step 0 — Read config

```bash
bash scripts/talos.sh env
```

Run once, keep the answer for the whole run. Its output replaces the Step 0 reads; only restamp keys are read later (project config over the user-level file, defaults applied, `ISOLATION` validated):

Run once. Restamp keys read later; project config over the user-level file. Lists join `\n`; backslash → `\\`, control → `\xNN`, bidi → `\uXXXX`, 8192-cut → `[truncated]`; with `STATUS_ENABLED = false` none of the status steps run (each says "`STATUS_ENABLED = true`").
- `agent.<role>.runner|runner_cmd|model|effort|fallback|effort_notice` (absent = empty): see Harness compatibility.
- `warn reason=<r>`: relay once, continue; `resolve-failed role=<role>`: do not spawn it.
- `stop reason=<r>` (non-zero exit): abort, print it, process no issues.

**File mode** (`VCS_PROVIDER = file`): no PRs, no QA/reviewer/security/docs, no board (the file IS the board).

