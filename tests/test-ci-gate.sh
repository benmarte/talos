#!/usr/bin/env bash
# test-ci-gate.sh -- the developer waits for required CI, and the orchestrator
# gates QA on CI state (#355).
#
# Covers:
#   (a) skills/pipeline/SKILL.md Step 3d: the CI gate sits after the Draft guard
#       and before Spawn, is ci-mode only, routes rc 0/2 to QA, rc 1 plus
#       `pr-checks-required: failed:` to a developer re-dispatch counted as
#       `record-attempt <N> developer --pr`, and rc 1 without that line to QA
#   (b) the Step 3c developer prompt carries `Required checks:` and `CI wait
#       budget:`; local mode omits them; the draft block sends `none`
#   (c) agents/developer.md: the CI-wait step after step 9, the `none` skip,
#       the budget formula, the sleep-poll exception in step 3, both standing lines
#   (d) the exit-code/stderr contract the routing table depends on, against the
#       real `pr-checks-required` verb and a stubbed `gh`
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

SKILL="$TALOS_ROOT/skills/pipeline/SKILL.md"
DEV="$TALOS_ROOT/agents/developer.md"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── (a) Step 3d gate ─────────────────────────────────────────────────────────
STEP_3D="$(awk '/^### 3d\. QA/{f=1} /^### 3e\./{f=0} f' "$SKILL")"
GATE="$(printf '%s\n' "$STEP_3D" | awk '/^\*\*CI gate \(#355\)/{f=1} /^Spawn:$/{f=0} f')"
[ -n "$GATE" ] && pass "Step 3d carries a CI gate section" || fail "Step 3d carries a CI gate section"

line_of() { printf '%s\n' "$STEP_3D" | grep -n -m1 -F -- "$1" | cut -d: -f1; }
GUARD_END="$(printf '%s\n' "$STEP_3D" | grep -n -F '<!-- pr-draft:end -->' | head -1 | cut -d: -f1)"
GATE_AT="$(line_of '**CI gate (#355)')"
SPAWN_AT="$(line_of 'Spawn:')"
[ -n "$GUARD_END" ] && [ "$GUARD_END" -lt "$GATE_AT" ] && [ "$GATE_AT" -lt "$SPAWN_AT" ] \
  && pass "the gate follows the Draft guard and precedes Spawn" \
  || fail "the gate follows the Draft guard and precedes Spawn" "guard-end=$GUARD_END gate=$GATE_AT spawn=$SPAWN_AT"

assert_contains "$GATE" 'Only when `VERIFY_QA_MODE` is `ci`' "gate is ci-mode only (local unchanged)"
assert_contains "$GATE" 'never a Step 4 re-stamp' "gate skips a Step 4 re-stamp"
assert_contains "$GATE" 'out="$(bash scripts/pipeline-vcs.sh pr-checks-required <PR_NUMBER> 2>&1)"; rc=$?' \
  "gate captures output and exit code in one assignment"
assert_contains "$GATE" '| 0 or 2 | any | Spawn QA' "rc 0 and rc 2 route to QA"
assert_contains "$GATE" '| 1 | holds `pr-checks-required: failed:` | No QA: developer re-dispatch' \
  "rc 1 with the failed: line routes to a developer re-dispatch"
assert_contains "$GATE" '| 1 | no such line (unsupported provider, no checks) | Spawn QA as today' \
  "rc 1 without the failed: line routes to QA"
assert_contains "$GATE" 'record-attempt <N> developer --pr <PR_NUMBER>' "re-dispatch is recorded as a developer attempt"
assert_contains "$GATE" 'Run the Step 3 budget check ("Budget stop") first.' "re-dispatch runs the budget check first"
assert_contains "$GATE" 'clear `pipeline:blocked`' "re-dispatch clears pipeline:blocked"
assert_contains "$GATE" 'draft-pr` and `label-pr --remove qa:pass`' "draft mode reuses the QA/CI failure path"
assert_contains "$GATE" 'ready-pr' "draft mode ends the fix round with ready-pr"

# ── (b) Step 3c developer prompt ─────────────────────────────────────────────
STEP_3C_PROMPT="$(awk '/^You are the Developer\. Implement/{f=1} f; /^Never fabricate a PR number/{if(f)exit}' "$SKILL")"
assert_contains "$STEP_3C_PROMPT" 'Required checks: <MERGE_REQUIRED_CHECKS' "developer prompt carries Required checks:"
assert_contains "$STEP_3C_PROMPT" 'CI wait budget: <VERIFY_CI_WAIT_S> seconds' "developer prompt carries CI wait budget:"
assert_contains "$(cat "$SKILL")" 'Under `VERIFY_QA_MODE` `local`, omit the `Required checks:` line and the `CI wait budget:` part.' \
  "local mode omits both developer prompt items"
assert_contains "$(cat "$SKILL")" 'Set `Required checks: none` (CI does not run until `ready-pr`)' \
  "the pr-draft block sends Required checks: none"

# ── (c) developer profile ────────────────────────────────────────────────────
DEV_TEXT="$(cat "$DEV")"
STEP_10="$(awk '/^10\. \*\*CI wait\*\*/{f=1; print; next} /^11\./{f=0} f' "$DEV")"
[ -n "$STEP_10" ] && pass "developer profile has the CI wait step 10" || fail "developer profile has the CI wait step 10"
assert_contains "$DEV_TEXT" '9. On success:' "step 9 is unchanged and precedes the CI wait"
assert_contains "$DEV_TEXT" '11. On failure:' "the failure step follows the CI wait"
assert_contains "$STEP_10" 'is present and not' "CI wait is skipped when Required checks: is none"
assert_contains "$STEP_10" 'pr-checks-required <PR>' "CI wait uses pr-checks-required"
assert_contains "$STEP_10" 'pipeline-verify.sh --issue <N>' "CI wait goes through pipeline-verify.sh"
assert_contains "$STEP_10" 'min(CI wait budget, Verify timeout/1000 - 30)' "CI wait budget is capped under the verify timeout"
assert_contains "$STEP_10" 'pr-checks-required: failed:' "only the failed: line triggers a fix"
assert_contains "$STEP_10" 'at most 2 rounds' "CI fix rounds are bounded"
assert_contains "$STEP_10" 'CI: green|red|pending on <head sha>' "final message carries the CI result"
assert_contains "$DEV_TEXT" 'The
   only exceptions are step 10: its one bounded CI wait, and one targeted
   re-run on a CI-fix commit.' "step 3 carries the sleep-poll and final-verify exception"
assert_contains "$DEV_TEXT" '`init.defaultBranch`' "standing line: fixtures must not depend on ambient git config"
assert_contains "$DEV_TEXT" 'Text over 128 KB reaches' "standing line: 128 KB text goes on stdin or in a file"

# ── (d) the contract the table depends on ────────────────────────────────────
gate_cmd="$(printf '%s\n' "$GATE" | sed -n '/^```bash$/,/^```$/p' | sed '1d;$d' | sed -e 's/<PR_NUMBER>/9/' -e "s#bash scripts/#bash $TALOS_ROOT/scripts/#")"
run_gate() { eval "$gate_cmd"; printf '%s|%s' "$rc" "$out"; }

cat > talos.pipeline.json <<'TALOS_k3QzJw9xVt2mA'
{"merge": {"required_checks": ["build", "test"]}}
TALOS_k3QzJw9xVt2mA

STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://x\ntest\tfail\t2m\thttps://x')"; export STUB_PR_CHECKS
res="$(run_gate)"
assert_eq "1" "${res%%|*}" "red required check: rc 1"
assert_contains "$res" 'pr-checks-required: failed: test' "red required check: out holds the failed: line"

STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://x\ntest\tpending\t0m\thttps://x')"; export STUB_PR_CHECKS
res="$(run_gate)"
assert_eq "2" "${res%%|*}" "pending required check: rc 2"
assert_not_contains "$res" 'pr-checks-required: failed:' "pending required check: no failed: line"

STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://x\ntest\tpass\t2m\thttps://x')"; export STUB_PR_CHECKS
res="$(run_gate)"
assert_eq "0" "${res%%|*}" "green required checks: rc 0"

rm -f talos.pipeline.json
res="$(run_gate)"
assert_eq "1" "${res%%|*}" "no checks configured: rc 1"
assert_not_contains "$res" 'pr-checks-required: failed:' "no checks configured: rc 1 without the failed: line (routes to QA)"

finish
