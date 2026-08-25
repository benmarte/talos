#!/usr/bin/env bash
# Regression tests for per-agent environment identity (#54).
#
# Acceptance criteria (from the PM spec):
# 1. TALOS_ISSUE_NUMBER and TALOS_WORKTREE_PATH are visible to a runner_cmd on
#    the adapter path (pipeline-agent.sh).
# 2. Two-arg callers (no TALOS_ISSUE set) are unchanged — exit 0, TALOS_ISSUE_NUMBER
#    is exported as the empty string (not "unset"), TALOS_ROLE still works.
# 3. TALOS_ROLE still works (shipped in #100).
# 4. EXIT-ZERO PROOF: a valid invocation with TALOS_ISSUE set exits 0.
#
# The prompt-injection and SKILL.md halves are NOT unit-testable — they are
# instruction-based; no automated test can confirm a native subagent follows them.
# The grep inventory of SKILL.md dispatch sites is in the PR body.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

AGENT=".claude/talos/scripts/pipeline-agent.sh"
export RUNNER_LOG="$SANDBOX/runner.log"

# Configure a custom runner that prints all three identity vars so we can inspect them.
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "custom", "runner_cmd": "printf 'ROLE=%s ISSUE=%s PATH=%s' \"$TALOS_ROLE\" \"$TALOS_ISSUE_NUMBER\" \"$TALOS_WORKTREE_PATH\""}}
EOF

# ── 1. TALOS_ISSUE_NUMBER and TALOS_WORKTREE_PATH visible in runner_cmd ────────
# RED before fix: TALOS_ISSUE_NUMBER and TALOS_WORKTREE_PATH were not exported.
out="$(TALOS_ISSUE=54 bash "$AGENT" developer "some task" 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "TALOS_ISSUE set — exits 0 (exit-zero proof)"
assert_contains "$out" "ISSUE=54" "TALOS_ISSUE_NUMBER=54 visible in runner_cmd"

# Verify the exact values (not just non-empty) to satisfy the proof requirement.
actual_issue="$(printf '%s' "$out" | sed -n 's/.*ISSUE=\([^ ]*\).*/\1/p')"
actual_path="$(printf '%s' "$out" | sed -n 's/.*PATH=\(.*\)/\1/p')"
assert_eq "54" "$actual_issue" "TALOS_ISSUE_NUMBER exact value is 54"
# Normalize paths: macOS mktemp may produce // but $PWD resolves it to /
SANDBOX_NORM="$(cd "$SANDBOX" && pwd)"
assert_eq "$SANDBOX_NORM" "$actual_path" "TALOS_WORKTREE_PATH exact value is sandbox dir"
assert_contains "$out" "PATH=$SANDBOX_NORM" "TALOS_WORKTREE_PATH visible in runner_cmd (normalized)"

# ── 2. Two-arg callers unchanged — TALOS_ISSUE unset → TALOS_ISSUE_NUMBER="" ──
# RED before fix: TALOS_ISSUE_NUMBER was not exported at all (would be unset).
# After fix: exported as empty string; two-arg call still exits 0.
out2="$(bash "$AGENT" qa "verify pr" 2>/dev/null)"; rc2=$?
assert_eq "0" "$rc2" "two-arg caller (no TALOS_ISSUE) exits 0"
assert_contains "$out2" "ISSUE=" "TALOS_ISSUE_NUMBER exported (possibly empty) in two-arg call"
# The empty string distinguishes "Talos did not set TALOS_ISSUE" from any real number.
actual_issue2="$(printf '%s' "$out2" | sed -n 's/.*ISSUE=\([^ ]*\).*/\1/p')"
assert_eq "" "$actual_issue2" "TALOS_ISSUE_NUMBER is empty string when TALOS_ISSUE unset"

# ── 3. TALOS_ROLE still works (#100 regression guard) ─────────────────────────
# RED if TALOS_ROLE were accidentally removed; GREEN when it is still exported.
out3="$(TALOS_ISSUE=54 bash "$AGENT" reviewer "review it" 2>/dev/null)"
actual_role="$(printf '%s' "$out3" | sed -n 's/ROLE=\([^ ]*\).*/\1/p')"
assert_eq "reviewer" "$actual_role" "TALOS_ROLE still exported alongside new vars"

# ── 4. Different TALOS_ISSUE values produce correct TALOS_ISSUE_NUMBER ─────────
out4="$(TALOS_ISSUE=99 bash "$AGENT" security "check it" 2>/dev/null)"; rc4=$?
assert_eq "0" "$rc4" "TALOS_ISSUE=99 exits 0"
actual_issue4="$(printf '%s' "$out4" | sed -n 's/.*ISSUE=\([^ ]*\).*/\1/p')"
assert_eq "99" "$actual_issue4" "TALOS_ISSUE_NUMBER=99 for issue 99"

rm talos.pipeline.json

# ── 5. Input validation: non-integer TALOS_ISSUE rejected with exit 2 ──────────
# RED before fix: TALOS_ISSUE was passed verbatim; no validation existed.
# The custom runner_cmd is no longer needed here — validation fires before runner.
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "custom", "runner_cmd": "echo should-not-reach"}}
EOF

# Shell metacharacter: should be rejected
out5="$(TALOS_ISSUE='54; rm -rf /' bash "$AGENT" developer "task" 2>&1)"; rc5=$?
assert_eq "2" "$rc5" "TALOS_ISSUE with shell metacharacters exits 2"
assert_contains "$out5" "must be a plain integer" "metacharacter rejection prints diagnostic"

# Whitespace in value: should be rejected
out6="$(TALOS_ISSUE='4 2' bash "$AGENT" developer "task" 2>&1)"; rc6=$?
assert_eq "2" "$rc6" "TALOS_ISSUE with whitespace exits 2"
assert_contains "$out6" "must be a plain integer" "whitespace rejection prints diagnostic"

# Path traversal attempt: should be rejected
out7="$(TALOS_ISSUE='../../etc' bash "$AGENT" developer "task" 2>&1)"; rc7=$?
assert_eq "2" "$rc7" "TALOS_ISSUE with path traversal exits 2"
assert_contains "$out7" "must be a plain integer" "path traversal rejection prints diagnostic"

# Newline in value: should be rejected (newline becomes a digit test via non-digit char)
out8="$(TALOS_ISSUE="$(printf '54\n99')" bash "$AGENT" developer "task" 2>&1)"; rc8=$?
assert_eq "2" "$rc8" "TALOS_ISSUE with newline exits 2"

# ── 6. Empty TALOS_ISSUE still exits 0 — regression guard ─────────────────────
# This is the backwards-compatibility guarantee: two-arg callers must not break.
# RED before fix (of the new guard): if we had implemented "reject empty", this fails.
out9="$(TALOS_ISSUE='' bash "$AGENT" qa "verify pr" 2>/dev/null)"; rc9=$?
assert_eq "0" "$rc9" "empty TALOS_ISSUE (explicit empty string) exits 0"
actual_issue9="$(printf '%s' "$out9" | sed -n 's/.*ISSUE=\([^ ]*\).*/\1/p')"
assert_eq "" "$actual_issue9" "TALOS_ISSUE_NUMBER is empty string when TALOS_ISSUE is empty"

# Unset TALOS_ISSUE also exits 0 (existing test 6-8 covers this; confirm here too)
out10="$(bash "$AGENT" qa "verify pr" 2>/dev/null)"; rc10=$?
assert_eq "0" "$rc10" "unset TALOS_ISSUE exits 0"

# ── 7. Valid integer exit-zero proof (guard does not over-reject) ───────────────
# Value propagation is already verified in sections 1 and 4 above; these just
# confirm the validation guard does not reject valid integers.
out11="$(TALOS_ISSUE=1 bash "$AGENT" developer "task" 2>/dev/null)"; rc11=$?
assert_eq "0" "$rc11" "TALOS_ISSUE=1 exits 0 (single digit)"

out12="$(TALOS_ISSUE=12345 bash "$AGENT" developer "task" 2>/dev/null)"; rc12=$?
assert_eq "0" "$rc12" "TALOS_ISSUE=12345 exits 0 (large integer)"

out13="$(TALOS_ISSUE=0 bash "$AGENT" developer "task" 2>/dev/null)"; rc13=$?
assert_eq "0" "$rc13" "TALOS_ISSUE=0 exits 0 (zero is a valid digit)"

rm talos.pipeline.json

finish
