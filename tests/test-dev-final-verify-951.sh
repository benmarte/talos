#!/usr/bin/env bash
# test-dev-final-verify-951.sh -- the developer's final verification when CI is the full run (#951).
#
# With merge.required_checks set, CI runs the full suite on the pushed head, so the
# developer brief tells the developer to run only the spec's `Tests:` files and the
# guard tests before the final push. This file pins, by criterion id:
#   AC1  required_checks set: the brief carries the one-line mode, the guard tests,
#        and neither the verify list nor the verify.dev_tests set
#   AC2  required_checks empty: the brief is today's, byte for byte
#   AC3  agents/developer.md, docs/reference.md and the CHANGELOG describe the rule
# Every test runs in a sandbox: no provider read, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TMPDIR="$SANDBOX/tmp"
export TALOS_RETRY_SLEEP_SCALE=0
mkdir -p "$TMPDIR"
unset TALOS_PROMPT_GUIDE_MAX_BYTES
ERR="$SANDBOX/stderr"
OUT="$SANDBOX/stdout"
GHOME="$SANDBOX/talos-home"
mkdir -p "$GHOME"
export TALOS_HOME="$GHOME"
OPEN='{''{'
CLOSE='}''}'
MARK="${OPEN}FINAL_VERIFY_LINE${CLOSE}"

git config user.email "test@talos.invalid"
git config user.name "talos-test"

# ── fixture: a checkout holding one guard test ───────────────────────────────
mkdir -p pkg
printf 'package a\nimport "path/filepath"\nfunc TestWalk() { filepath.WalkDir(".", nil) }\n' > pkg/walk_test.go
git add pkg
git commit -q -m "fixture"
git init -q --bare "$SANDBOX/origin.git"
git remote set-url origin "$SANDBOX/origin.git" 2>/dev/null || git remote add origin "$SANDBOX/origin.git"
git push -q origin HEAD:main 2>/dev/null
git fetch -q origin 2>/dev/null

# ── prompt fixtures: a copied scripts dir, stubbed providers ─────────────────
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR" "$SANDBOX/templates/prompts"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cp -R "$TALOS_ROOT/templates/prompts/." "$SANDBOX/templates/prompts/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null
STUB_BODY='#!/usr/bin/env bash
printf "%s %s\n" "$(basename "$0" .sh)" "$*" >> "${STUB_DIR:?}/journal"
exit 0
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-mergebase.sh pipeline-draft-check.sh pipeline-status.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
# The tree as it was before the change: the template without the marker.
OLD="$SANDBOX/old"
mkdir -p "$OLD/scripts" "$OLD/templates/prompts"
cp "$GS"/* "$OLD/scripts/"
cp -R "$SANDBOX/templates/comments" "$OLD/templates/" 2>/dev/null
for t in "$SANDBOX"/templates/prompts/*; do
  grep -Fvx -- "$MARK" "$t" > "$OLD/templates/prompts/$(basename "$t")"
done
RUN="$GS/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
# cfg_with <extra verify keys> <extra top-level keys>
cfg_with() {
  printf '{"vcs": {"provider": "github"}, "base_branch": "main", "verify": {"timeout_ms": 600000, "ci_wait_s": 900, "commands": ["make verify-all"]%s}%s}' \
    "${1:-}" "${2:-}" > "$SANDBOX/talos.pipeline.json"
}
: > "$SANDBOX/no-prompt"
setpf() {
  PF="$(sed -n 's/^prompt_file=//p' "$OUT")"
  [ -n "$PF" ] && [ -f "$PF" ] || PF="$SANDBOX/no-prompt"
}
render() { bash "$RUN" prompt "$@" > "$OUT" 2> "$ERR" < /dev/null; RC=$?; setpf; }
render_old() {
  bash "$OLD/scripts/talos.sh" prompt "$@" > "$OUT" 2> "$ERR" < /dev/null; RC=$?; setpf
  if [ "$PF" != "$SANDBOX/no-prompt" ]; then
    sed "s|$(cd "$OLD/scripts" && pwd)|$(cd "$GS" && pwd)|g; s|$(cd "$OLD/templates" && pwd)|$(cd "$SANDBOX/templates" && pwd)|g" "$PF" > "$PF.n" && mv "$PF.n" "$PF"
  fi
}

# ── AC1: required_checks set ─────────────────────────────────────────────────
cfg_with ', "dev_tests": ["go test ./pkg/...", "bash scripts/check-guards.sh"]' ', "merge": {"required_checks": ["build"]}'
render developer --issue 9
assert_eq "0" "$RC" "AC1 the developer prompt renders (exit 0)"
P="$(cat "$PF")"
assert_eq "1" "$(grep -c '^Final verification: Tests: files only — CI is the full run (merge.required_checks)' "$PF")" "AC1 the brief carries the one-line mode"
assert_contains "$P" "Guard tests (discovered, run each by its file):
pkg/walk_test.go" "AC1 the guard tests are listed"
assert_contains "$P" "run neither the full \`verify\` list nor the \`verify.dev_tests\` set" "AC1 the line says to run neither the verify list nor verify.dev_tests"
assert_not_contains "$P" "make verify-all" "AC1 the verify list is not in the brief"
assert_not_contains "$P" "go test ./pkg/..." "AC1 the verify.dev_tests commands are not in the brief"
assert_not_contains "$P" "Developer verification set" "AC1 no Developer verification set block"
assert_eq "" "$(cat "$ERR")" "AC1 no stderr output"
# without dev_tests the mode and guards are the same
cfg_with "" ', "merge": {"required_checks": ["build"]}'
render developer --issue 9
P="$(cat "$PF")"
assert_contains "$P" "Final verification: Tests: files only" "AC1 the mode line does not need verify.dev_tests"
assert_contains "$P" "pkg/walk_test.go" "AC1 the guards are listed without verify.dev_tests"
assert_not_contains "$P" "make verify-all" "AC1 the verify list is not in the brief without verify.dev_tests"

# ── AC2: required_checks empty is today's brief ──────────────────────────────
for variant in "" ', "dev_tests": ["go test ./pkg/..."]'; do
  for rc in "" ', "merge": {"required_checks": []}'; do
    tag="[${variant:-no dev_tests}|${rc:-unset}]"
    cfg_with "$variant" "$rc"
    render_old developer --issue 9
    cp "$PF" "$SANDBOX/prompt.old"
    render developer --issue 9
    if cmp -s "$PF" "$SANDBOX/prompt.old"; then pass "AC2 $tag the brief is today's, byte for byte"
    else fail "AC2 $tag the brief is today's, byte for byte"; fi
    assert_not_contains "$(cat "$PF")" "Final verification:" "AC2 $tag no mode line"
  done
done
cfg_with ""
render developer --issue 9
assert_contains "$(cat "$PF")" "make verify-all" "AC2 the verify list is in the brief"

# ── AC3: template, names, docs ───────────────────────────────────────────────
assert_eq "1" "$(grep -Fxc -- "$MARK" "$TALOS_ROOT/templates/prompts/developer.md")" "AC3 developer.md carries the FINAL_VERIFY_LINE marker on its own line"
assert_eq "1" "$(sed -n '/^_TALOS_PROMPT_NAMES=/,/"$/p' "$TALOS_ROOT/scripts/talos.sh" | grep -c 'FINAL_VERIFY_LINE')" "AC3 _TALOS_PROMPT_NAMES allows FINAL_VERIFY_LINE"
assert_contains "$(cat "$TALOS_ROOT/agents/developer.md")" "Final verification:" "AC3 agents/developer.md names the Final verification line"
assert_contains "$(cat "$TALOS_ROOT/agents/developer.md")" "CI is the full run" "AC3 agents/developer.md says CI is the full run"
assert_contains "$(cat "$TALOS_ROOT/docs/reference.md")" "Final verification: Tests: files only" "AC3 docs/reference.md names the mode line"
assert_contains "$(grep '^| `verify.dev_tests` | none' "$TALOS_ROOT/docs/reference.md")" "merge.required_checks" "AC3 the verify.dev_tests row names merge.required_checks"
assert_contains "$(grep '^| `verify.qa_mode` | derived' "$TALOS_ROOT/docs/reference.md")" "developer" "AC3 the verify.qa_mode row names the developer"
assert_contains "$(grep '^| developer | LLM' "$TALOS_ROOT/docs/reference.md")" "Tests:" "AC3 the developer role row describes the rule"
assert_contains "$(sed -n '/^## \[Unreleased\]/,/^## \[/p' "$TALOS_ROOT/CHANGELOG.md" | sed -n 2p)" "Tests:" "AC3 the CHANGELOG top line names the rule"

finish
