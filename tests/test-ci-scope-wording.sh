#!/usr/bin/env bash
# test-ci-scope-wording.sh -- the QA prompt says what the required check means:
# `verify.ci_scope: changed` (PR CI runs only the tests a change selects, the
# merge queue runs the full suite) vs the default `full` (#1010). The queue
# branches always run the required check, even on a Markdown-only change.
# No GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
ERR="$SANDBOX/stderr"
OUT="$SANDBOX/stdout"
TREE="$SANDBOX/tree"
mkdir -p "$TREE"
cp -R "$TALOS_ROOT/scripts" "$TREE/scripts"
cp -R "$TALOS_ROOT/templates" "$TREE/templates"
# pr-is-draft answers "ready": the post-CI shape that carries the skip line.
printf '#!/usr/bin/env bash\n[ "${1:-}" = pr-is-draft ] || exit 0\nprintf "%%s" "${GATE_PRD_OUT:-}"\nexit "${GATE_PRD_RC:-2}"\n' > "$TREE/scripts/pipeline-vcs.sh"
TALOS="$TREE/scripts/talos.sh"
export GATE_PRD_RC=1 GATE_PRD_OUT=ready

WT="$SANDBOX/wt"
mkdir -p "$WT/tests"
: > "$WT/tests/run-tests.sh"

# render_qa: the rendered qa prompt on stdout.
render_qa() {
  local pf
  bash "$TALOS" prompt qa --issue 1010 --pr 9 --worktree "$WT" > "$OUT" 2> "$ERR"
  pf="$(sed -n 's/^prompt_file=//p' "$OUT")"
  if [ -n "$pf" ]; then cat "$pf"; rm -f "${pf:?}"; else cat "$OUT"; fi
}

# AC1: ci_scope changed says the CI run is change-based and the queue runs the full suite.
printf '%s' '{"verify": {"qa_mode": "ci", "ci_scope": "changed"}, "merge": {"required_checks": ["ci / test"]}}' > "$SANDBOX/talos.pipeline.json"
text="$(render_qa)"
line="$(printf '%s\n' "$text" | grep '^Targeted run skipped:')"
assert_contains "$line" "CI ran the tests this change selects" "AC1 the line says the CI run is change-based"
assert_contains "$line" "the merge queue runs the full suite" "AC1 the line says the merge queue runs the full suite"
assert_contains "$line" "no \`tests/run-tests.sh\` command" "AC1 the line still forbids every run-tests.sh form"
assert_not_contains "$text" "CI is the full run" "AC1 the prompt does not say CI is the full run"

# AC2: the default (full) keeps the prompt unchanged, as the golden pins it.
printf '%s' '{"verify": {"qa_mode": "ci"}, "merge": {"required_checks": ["ci / test"]}}' > "$SANDBOX/talos.pipeline.json"
line="$(render_qa | grep '^Targeted run skipped:')"
golden="$(grep '^Targeted run skipped:' "$TALOS_ROOT/tests/fixtures/talos-prompt/qa.golden")"
assert_eq "$golden" "$line" "AC2 the default line equals the golden line"
printf '%s' '{"verify": {"qa_mode": "ci", "ci_scope": "full"}, "merge": {"required_checks": ["ci / test"]}}' > "$SANDBOX/talos.pipeline.json"
line="$(render_qa | grep '^Targeted run skipped:')"
assert_eq "$golden" "$line" "AC2 an explicit full is the same line"

# AC3: the push trigger runs the test job on talos/queue/** whatever changed: no paths filter on push.
WF="$TALOS_ROOT/.github/workflows/tests.yml"
push_block="$(awk '/^on:/{f=1;next} f && /^  pull_request:/{exit} f' "$WF")"
assert_contains "$push_block" "talos/queue/**" "AC3 the push trigger names talos/queue/**"
assert_not_contains "$push_block" "paths-ignore:" "AC3 the push trigger has no paths-ignore"
assert_not_contains "$push_block" "paths:" "AC3 the push trigger has no paths filter"

# AC4: verify.ci_scope has a defaults row and a golden row; this repo sets it to changed.
defaults_row="$(awk -F'\t' '$1=="verify.ci_scope"' "$TALOS_ROOT/scripts/pipeline-defaults.sh")"
golden_row="$(awk -F'\t' '$1=="verify.ci_scope"' "$TALOS_ROOT/tests/fixtures/config-golden-defaults.tsv")"
assert_contains "$defaults_row" "full" "AC4 the defaults table has a verify.ci_scope row defaulting to full"
assert_contains "$golden_row" "full" "AC4 the golden table has a verify.ci_scope row"
repo_scope="$(cd "$TALOS_ROOT" && bash scripts/pipeline-config.sh verify.ci_scope 2>/dev/null)"
assert_eq "changed" "$repo_scope" "AC4 this repo's talos.pipeline.json sets verify.ci_scope to changed"

finish
