#!/usr/bin/env bash
# test-pipeline-verify.sh — regression tests for scripts/pipeline-verify.sh
# (#186): makes TALOS_ISSUE_NUMBER/TALOS_WORKTREE_PATH mechanical on the
# native (Claude Code) subagent path, instead of instruction-based exports.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

VERIFY_SH="$TALOS_ROOT/scripts/pipeline-verify.sh"
assert_file_exists "$VERIFY_SH" "pipeline-verify.sh exists"

# A tiny "verify script" that asserts $TALOS_ISSUE_NUMBER equals an expected
# value — the Prove-It fixture every case below runs through.
CHECK="$SANDBOX/check-issue.sh"
cat > "$CHECK" <<'EOF'
#!/usr/bin/env bash
if [ "${TALOS_ISSUE_NUMBER:-}" = "$EXPECTED_ISSUE" ]; then
  echo "OK: TALOS_ISSUE_NUMBER=$TALOS_ISSUE_NUMBER WT=$TALOS_WORKTREE_PATH"
  exit 0
else
  echo "MISMATCH: expected $EXPECTED_ISSUE got '${TALOS_ISSUE_NUMBER:-}'" >&2
  exit 1
fi
EOF
chmod +x "$CHECK"

# ── RED reproduction: running the check script bare (no wrapper) fails ─────
export EXPECTED_ISSUE="186"
out_bare="$(bash "$CHECK" 2>&1)"; rc_bare=$?
assert_eq "1" "$rc_bare" "check script run bare (no wrapper) fails"
assert_contains "$out_bare" "MISMATCH" "check script run bare reports a mismatch"

# ── GREEN: args form — the wrapper's --issue/--worktree exports and passes ─
WT_DIR="$SANDBOX/wt-args"
mkdir -p "$WT_DIR"
out_args="$(bash "$VERIFY_SH" --issue 186 --worktree "$WT_DIR" -- bash "$CHECK" 2>"$SANDBOX/args.err")"
rc_args=$?
assert_eq "0" "$rc_args" "args form: wrapper exit code is the wrapped command's"
assert_contains "$out_args" "OK: TALOS_ISSUE_NUMBER=186" "args form: TALOS_ISSUE_NUMBER=186 reaches the command"
assert_contains "$out_args" "WT=$WT_DIR" "args form: TALOS_WORKTREE_PATH reaches the command"

# ── GREEN: .talos/env form — resolves identity with zero flags ─────────────
ENV_WT="$SANDBOX/wt-env"
mkdir -p "$ENV_WT/.talos"
{
  printf 'export TALOS_ISSUE_NUMBER=186\n'
  printf 'export TALOS_WORKTREE_PATH=%s\n' "$ENV_WT"
} > "$ENV_WT/.talos/env"
out_env="$(cd "$ENV_WT" && bash "$VERIFY_SH" -- bash "$CHECK" 2>"$SANDBOX/env.err")"
rc_env=$?
assert_eq "0" "$rc_env" ".talos/env form: wrapper exit code is the wrapped command's"
assert_contains "$out_env" "OK: TALOS_ISSUE_NUMBER=186" ".talos/env form: TALOS_ISSUE_NUMBER=186 resolved with zero flags"
assert_contains "$out_env" "WT=$ENV_WT" ".talos/env form: TALOS_WORKTREE_PATH resolved with zero flags"

# ── GREEN: ambient-environment form (adapter path) — flags/.talos/env absent
NO_ENV_WT="$SANDBOX/wt-ambient"
mkdir -p "$NO_ENV_WT"
out_ambient="$(cd "$NO_ENV_WT" && TALOS_ISSUE_NUMBER=186 TALOS_WORKTREE_PATH="$NO_ENV_WT" bash "$VERIFY_SH" -- bash "$CHECK" 2>"$SANDBOX/ambient.err")"
rc_ambient=$?
assert_eq "0" "$rc_ambient" "ambient-env form: wrapper exit code is the wrapped command's"
assert_contains "$out_ambient" "OK: TALOS_ISSUE_NUMBER=186" "ambient-env form: falls back to the calling environment"

# ── --issue/--worktree flags win over .talos/env when both are present ────
out_override="$(cd "$ENV_WT" && bash "$VERIFY_SH" --issue 999 --worktree "$SANDBOX/other" -- bash -c 'echo "ISSUE=$TALOS_ISSUE_NUMBER"')"
assert_contains "$out_override" "ISSUE=999" "explicit --issue overrides .talos/env"

# ── talos:verify identity line on stderr ────────────────────────────────────
assert_contains "$(cat "$SANDBOX/args.err")" "talos:verify issue=186 worktree=$WT_DIR" \
  "wrapper prints talos:verify issue=<N> worktree=<path> on stderr"

# ── No command after `--`: runs every configured verify: command in order,
# stopping at the first failure and propagating its exit code ──────────────
CFG_WT="$SANDBOX/wt-cfg"
mkdir -p "$CFG_WT"
LOG="$SANDBOX/verify-order.log"
: > "$LOG"
cat > "$CFG_WT/talos.pipeline.json" <<EOF
{"verify": ["echo one >> $LOG", "echo two >> $LOG && exit 7", "echo three >> $LOG"]}
EOF
out_cfg="$(cd "$CFG_WT" && bash "$VERIFY_SH" --issue 186 --worktree "$CFG_WT" 2>"$SANDBOX/cfg.err")"
rc_cfg=$?
assert_eq "7" "$rc_cfg" "no-command form: propagates the failing command's exit code"
log_contents="$(cat "$LOG")"
assert_contains "$log_contents" "one" "no-command form: first verify: command ran"
assert_contains "$log_contents" "two" "no-command form: second (failing) verify: command ran"
assert_not_contains "$log_contents" "three" "no-command form: stops at the first failure -- third command never ran"

# ── Full config verify: list passing end to end ─────────────────────────────
PASS_WT="$SANDBOX/wt-pass"
mkdir -p "$PASS_WT"
cat > "$PASS_WT/talos.pipeline.json" <<'EOF'
{"verify": ["echo one", "echo two"]}
EOF
out_pass="$(cd "$PASS_WT" && bash "$VERIFY_SH" --issue 186 --worktree "$PASS_WT")"
rc_pass=$?
assert_eq "0" "$rc_pass" "no-command form: exits 0 when every verify: command passes"
assert_contains "$out_pass" "one" "no-command form: runs the first verify: command"
assert_contains "$out_pass" "two" "no-command form: runs the second verify: command"

# ── No background children left running (foreground rule, #205) ───────────
# A unique marker (not a bare "pipeline-verify.sh" pgrep -- run-tests.sh runs
# test files in parallel, and a sibling test's own pipeline-verify.sh
# invocation would otherwise produce a false positive here) scopes the check
# to exactly this invocation.
_marker="talos-verify-test-$$-$RANDOM"
bash "$VERIFY_SH" --issue 186 --worktree "$WT_DIR" -- bash -c "sleep 0.2; : $_marker" >/dev/null 2>&1
sleep 1
if command -v pgrep >/dev/null 2>&1; then
  leftover="$(pgrep -f "$_marker" 2>/dev/null || true)"
  assert_eq "" "$leftover" "no lingering child process from this invocation after it returns"
else
  pass "no lingering child process from this invocation after it returns (pgrep unavailable, skipped)"
fi

# Static guard alongside the dynamic check: the wrapper's own source never
# backgrounds anything (no trailing bare "&", no nohup/disown).
verify_src="$(cat "$VERIFY_SH")"
assert_not_contains "$verify_src" "nohup" "pipeline-verify.sh source does not use nohup"
assert_not_contains "$verify_src" "disown" "pipeline-verify.sh source does not use disown"
if printf '%s\n' "$verify_src" | grep -E '[^&]& *$' >/dev/null; then
  fail "pipeline-verify.sh source never backgrounds a command (no trailing '&')" \
       "found a trailing '&' in the source"
else
  pass "pipeline-verify.sh source never backgrounds a command (no trailing '&')"
fi

finish
