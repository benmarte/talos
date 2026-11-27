#!/usr/bin/env bash
# test-env-qa-keys.sh -- the QA keys in `talos.sh env`, and the required-checks
# coverage warning (#1095).
#   AC6 env prints QA_BROWSER= and QA_UNVERIFIABLE= (the effective values) and
#       warns on an invalid one
#   AC8 merge.required_checks + verify.ci_scope full + verify.ci_covers false:
#       env warns `required-checks-skip-verify`, the developer brief asks for the
#       full verify list once, and QA no longer calls CI the full run
# Sandboxed: no provider read, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TMPDIR="$SANDBOX/tmp"
export TALOS_RETRY_SLEEP_SCALE=0
mkdir -p "$TMPDIR"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
ERR="$SANDBOX/stderr"
OUT="$SANDBOX/stdout"

# ── fixture: a copied scripts dir, stubbed providers ─────────────────────────
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR" "$SANDBOX/templates/prompts" tests
cp "$TALOS_ROOT"/scripts/* "$GS/"
cp -R "$TALOS_ROOT/templates/prompts/." "$SANDBOX/templates/prompts/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null
STUB_BODY='#!/usr/bin/env bash
printf "%s %s\n" "$(basename "$0" .sh)" "$*" >> "${STUB_DIR:?}/journal"
exit 0
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-mergebase.sh pipeline-status.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
: > tests/run-tests.sh

cfg() { printf '%s' "$1" > "$PIPELINE_CONFIG"; }
# env reads no provider, so it runs from the real scripts dir (as test-talos-env.sh).
env_run() { OUTPUT="$(bash "$TALOS_ROOT/scripts/talos.sh" env 2>"$ERR")"; RC=$?; }
env_line() { printf '%s\n' "$OUTPUT" | grep -x -- "$1" || true; }
warns() { printf '%s\n' "$OUTPUT" | grep -c "^warn reason=$1" || true; }

# ── AC6 ──────────────────────────────────────────────────────────────────────
cfg '{}'
env_run
assert_eq "0" "$RC" "AC6 env exits 0"
assert_eq "QA_BROWSER=off" "$(env_line 'QA_BROWSER=.*')" "AC6 the default browser is off"
assert_eq "QA_UNVERIFIABLE=note" "$(env_line 'QA_UNVERIFIABLE=.*')" "AC6 the default for unverifiable is note"
assert_eq "0" "$(warns invalid-value)" "AC6 the defaults warn nothing"

cfg '{"qa": {"browser": "playwright", "unverifiable": "fail"}}'
env_run
assert_eq "QA_BROWSER=playwright" "$(env_line 'QA_BROWSER=.*')" "AC6 playwright is printed"
assert_eq "QA_UNVERIFIABLE=fail" "$(env_line 'QA_UNVERIFIABLE=.*')" "AC6 fail is printed"
assert_eq "0" "$(warns invalid-value)" "AC6 valid values warn nothing"

cfg '{"qa": {"browser": "chrome", "unverifiable": "ignore"}}'
env_run
assert_eq "0" "$RC" "AC6 invalid values do not stop the run"
assert_eq "QA_BROWSER=off" "$(env_line 'QA_BROWSER=.*')" "AC6 an invalid browser reads as off"
assert_eq "QA_UNVERIFIABLE=note" "$(env_line 'QA_UNVERIFIABLE=.*')" "AC6 an invalid unverifiable reads as note"
assert_eq "1" "$(warns 'invalid-value key=qa.browser$')" "AC6 qa.browser is warned about"
assert_eq "1" "$(warns 'invalid-value key=qa.unverifiable$')" "AC6 qa.unverifiable is warned about"
for reason in invalid-value required-checks-skip-verify; do
  assert_eq "1" "$(sed -n 's/^# env-reasons: //p' "$TALOS_ROOT/scripts/talos.sh" | head -n 1 | tr ' ' '\n' | grep -cx "$reason")" "AC6 $reason is in the env reason enum"
done

# ── AC8: env ─────────────────────────────────────────────────────────────────
req='"merge": {"required_checks": ["viewer-tests"]}'
cfg "{$req, \"verify\": {\"commands\": [\"make verify-all\"], \"ci_covers\": false}}"
env_run
assert_eq "1" "$(warns 'required-checks-skip-verify$')" "AC8 env warns when CI does not run every verify command"
for case_json in "{$req, \"verify\": {\"commands\": [\"make verify-all\"]}}" \
                 "{$req, \"verify\": {\"commands\": [\"make verify-all\"], \"ci_covers\": true}}" \
                 "{$req, \"verify\": {\"commands\": [\"make verify-all\"], \"ci_covers\": false, \"ci_scope\": \"changed\"}}" \
                 '{"verify": {"commands": ["make verify-all"], "ci_covers": false}}'; do
  cfg "$case_json"
  env_run
  assert_eq "0" "$(warns required-checks-skip-verify)" "AC8 no warning for $case_json"
done

# ── AC8: the developer brief and QA ──────────────────────────────────────────
render() {
  bash "$GS/talos.sh" prompt "$@" > "$OUT" 2> "$ERR" < /dev/null; RC=$?
  PF="$(sed -n 's/^prompt_file=//p' "$OUT")"
  if [ -n "$PF" ] && [ -f "$PF" ]; then P="$(cat "$PF")"; else P=""; fi
}
base='"vcs": {"provider": "github"}, "base_branch": "main"'
cfg "{$base, $req, \"verify\": {\"commands\": [\"make verify-all\"], \"dev_tests\": [\"make dev-only\"], \"ci_covers\": false}}"
render developer --issue 9
assert_eq "0" "$RC" "AC8 the developer prompt renders"
assert_contains "$P" "make verify-all" "AC8 the full verify list is in the developer brief"
assert_contains "$P" "Final verification: the full \`verify\` list, once, before the final commit" "AC8 the brief says to run it once"
assert_not_contains "$P" "CI is the full run" "AC8 the brief does not call CI the full run"
assert_not_contains "$P" "make dev-only" "AC8 the dev_tests set does not replace the full list"

render qa --issue 9 --pr 12
assert_eq "0" "$RC" "AC8 the QA prompt renders"
assert_not_contains "$P" "Targeted run skipped" "AC8 QA keeps its targeted run"

cfg "{$base, $req, \"verify\": {\"commands\": [\"make verify-all\"]}}"
render developer --issue 9
assert_contains "$P" "Final verification: Tests: files only" "AC8 with ci_covers unset the brief is today's"
assert_not_contains "$P" "make verify-all" "AC8 with ci_covers unset the verify list stays out"
render qa --issue 9 --pr 12
assert_contains "$P" "Targeted run skipped" "AC8 with ci_covers unset QA skips the targeted run as today"

finish
