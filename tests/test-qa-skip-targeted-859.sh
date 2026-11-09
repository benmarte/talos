#!/usr/bin/env bash
# test-qa-skip-targeted-859.sh -- with merge.required_checks set, CI is the full
# run, so the QA prompt tells QA to skip step 2's targeted `run-tests.sh --changed`
# (#859). An empty list, a repo without the runner and the pre-CI gate shape keep
# their text. No GitHub write, no LLM call.
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
# pr-is-draft answers from GATE_PRD_*: draft for the pre-CI shape, ready otherwise.
printf '#!/usr/bin/env bash\n[ "${1:-}" = pr-is-draft ] || exit 0\nprintf "%%s" "${GATE_PRD_OUT:-}"\nexit "${GATE_PRD_RC:-2}"\n' > "$TREE/scripts/pipeline-vcs.sh"
TALOS="$TREE/scripts/talos.sh"

# render_qa <worktree>: the rendered qa prompt on stdout (the stop line on a stop).
render_qa() {
  local pf
  bash "$TALOS" prompt qa --issue 859 --pr 9 --worktree "$1" > "$OUT" 2> "$ERR"
  pf="$(sed -n 's/^prompt_file=//p' "$OUT")"
  if [ -n "$pf" ]; then cat "$pf"; rm -f "${pf:?}"; else cat "$OUT"; fi
}

WT_NONE="$SANDBOX/wt-none"
WT_HAS="$SANDBOX/wt-has"
mkdir -p "$WT_NONE" "$WT_HAS/tests"
: > "$WT_HAS/tests/run-tests.sh"

# The same tree with the marker line removed: what an empty line must equal.
cp -R "$TREE" "$SANDBOX/tree-old"
grep -v '^{{QA_TARGETED_LINE}}$' "$TREE/templates/prompts/qa.md" > "$SANDBOX/tree-old/templates/prompts/qa.md"

CFG_CI='{"verify": {"qa_mode": "ci"}, "merge": {"required_checks": ["ci / test"]}}'
CFG_PRECI='{"verify": {"qa_mode": "ci"}, "merge": {"required_checks": ["ci / test"]}, "pr": {"draft": true, "ready_gate": "qa-local"}}'

# AC1: required_checks set, runner present, ready PR: the skip line.
printf '%s' "$CFG_CI" > "$SANDBOX/talos.pipeline.json"
export GATE_PRD_RC=1 GATE_PRD_OUT=ready
text="$(render_qa "$WT_HAS")"
line="$(printf '%s\n' "$text" | grep '^Targeted run skipped:')"
assert_contains "$text" "Targeted run skipped:" "AC1 required_checks set: a Targeted run skipped: line"
assert_contains "$line" "run-tests.sh --changed" "AC1 the line names the step 2 run-tests.sh --changed command"
assert_contains "$line" "targeted run skipped: CI is the full run (merge.required_checks)" "AC1 the line gives the verdict wording"
assert_contains "$line" "qa-run" "AC1 the line names qa-run"
assert_not_contains "$text" "{{" "AC1 no marker left over"

# AC2: empty or absent required_checks: no line, the prompt equals the marker-less one.
for cfgjson in '{"verify": {"qa_mode": "local"}, "merge": {"required_checks": []}}' '{"verify": {"qa_mode": "local"}}'; do
  printf '%s' "$cfgjson" > "$SANDBOX/talos.pipeline.json"
  TALOS="$TREE/scripts/talos.sh"
  new="$(render_qa "$WT_HAS")"
  TALOS="$SANDBOX/tree-old/scripts/talos.sh"
  old="$(render_qa "$WT_HAS")"
  assert_not_contains "$new" "Targeted run" "AC2 empty required_checks: no Targeted run line"
  assert_eq "$(printf '%s' "$old" | sed 's|/tree-old/|/tree/|g')" "$new" \
    "AC2 empty required_checks: equals the prompt without the marker line"
done
TALOS="$TREE/scripts/talos.sh"
assert_contains "$(cat "$TALOS_ROOT/agents/qa.md")" "--budget-s <budget-s>" "AC2 agents/qa.md keeps the targeted command with --budget-s"

# AC3: the no-runner line wins whatever required_checks holds; the pre-CI shape never skips.
printf '%s' "$CFG_CI" > "$SANDBOX/talos.pipeline.json"
text="$(render_qa "$WT_NONE")"
assert_contains "$text" "Targeted run: this repo has no" "AC3 no runner, required_checks set: the #824 line"
assert_not_contains "$text" "Targeted run skipped:" "AC3 no runner: no skip line"

printf '%s' "$CFG_PRECI" > "$SANDBOX/talos.pipeline.json"
export GATE_PRD_RC=0 GATE_PRD_OUT=draft
text="$(render_qa "$WT_HAS")"
assert_contains "$text" "Pre-CI gate" "AC3 the draft PR renders the pre-CI shape"
assert_not_contains "$text" "Targeted run skipped:" "AC3 pre-CI shape: no skip line"

# AC4: the merge gate text is untouched in the skip shape.
printf '%s' "$CFG_CI" > "$SANDBOX/talos.pipeline.json"
export GATE_PRD_RC=1 GATE_PRD_OUT=ready
text="$(render_qa "$WT_HAS")"
assert_contains "$text" "Required checks: ci / test" "AC4 the required checks line stays"
assert_contains "$text" "CI wait budget:" "AC4 the CI wait budget line stays"
assert_contains "$(cat "$TALOS_ROOT/agents/qa.md")" "pr-checks-required <pr> --wait" "AC4 agents/qa.md keeps the pr-checks-required wait"

finish
