#!/usr/bin/env bash
# test-qa-no-runner-824.sh -- the QA prompt names the targeted run that applies to
# the repo (#824). Step 2's `run-tests.sh --changed` is Talos's own runner: a repo
# without tests/run-tests.sh gets a `Targeted run:` line naming qa-run's run
# instead, and the Talos repo's prompt is unchanged. No GitHub write, no LLM call.
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
  bash "$TALOS" prompt qa --issue 824 --pr 9 --worktree "$1" > "$OUT" 2> "$ERR"
  pf="$(sed -n 's/^prompt_file=//p' "$OUT")"
  if [ -n "$pf" ]; then cat "$pf"; rm -f "${pf:?}"; else cat "$OUT"; fi
}

WT_NONE="$SANDBOX/wt-none"
WT_HAS="$SANDBOX/wt-has"
mkdir -p "$WT_NONE" "$WT_HAS/tests"
: > "$WT_HAS/tests/run-tests.sh"

printf '{"verify": {"qa_mode": "ci"}, "merge": {"required_checks": ["ci / test"]}}' > "$SANDBOX/talos.pipeline.json"
export GATE_PRD_RC=1 GATE_PRD_OUT=ready
text="$(render_qa "$WT_NONE")"
assert_not_contains "$text" "run-tests.sh --changed" "AC1 no runner: no run-tests.sh --changed text"
assert_contains "$text" "Targeted run:" "AC1 no runner: a Targeted run: line"
line="$(printf '%s\n' "$text" | grep '^Targeted run:')"
assert_contains "$line" "qa-run" "AC1 no runner: the line names qa-run"
assert_contains "$line" "verify.targeted_commands" "AC1 no runner: the line names verify.targeted_commands"
assert_not_contains "$text" "{{" "AC1 no runner: no marker left over"

printf '{"verify": {"qa_mode": "ci"}, "merge": {"required_checks": ["ci / test"]}, "pr": {"draft": true, "ready_gate": "qa-local"}}' > "$SANDBOX/talos.pipeline.json"
export GATE_PRD_RC=0 GATE_PRD_OUT=draft
text="$(render_qa "$WT_NONE")"
assert_contains "$text" "Pre-CI gate" "AC2 the draft PR renders the pre-CI shape"
assert_contains "$text" "Targeted run:" "AC2 pre-CI shape: a Targeted run: line"
assert_eq "$line" "$(printf '%s\n' "$text" | grep '^Targeted run:')" "AC2 pre-CI shape: the same Targeted run: line"
assert_not_contains "$text" "{{" "AC2 pre-CI shape: no marker left over"

# AC3: with the runner present the line is dropped and nothing else changes.
cp -R "$TREE" "$SANDBOX/tree-old"
grep -v '^{{QA_TARGETED_LINE}}$' "$TREE/templates/prompts/qa.md" > "$SANDBOX/tree-old/templates/prompts/qa.md"
for shape in pre-ci ci; do
  if [ "$shape" = ci ]; then
    printf '{"verify": {"qa_mode": "ci"}, "merge": {"required_checks": ["ci / test"]}}' > "$SANDBOX/talos.pipeline.json"
    export GATE_PRD_RC=1 GATE_PRD_OUT=ready
  fi
  TALOS="$TREE/scripts/talos.sh"
  new="$(render_qa "$WT_HAS")"
  TALOS="$SANDBOX/tree-old/scripts/talos.sh"
  old="$(render_qa "$WT_HAS")"
  assert_not_contains "$new" "Targeted run:" "AC3 runner present ($shape): no Targeted run: line"
  # The two trees sit in sibling dirs, so compare past the dir name.
  assert_eq "$(printf '%s' "$old" | sed 's|/tree-old/|/tree/|g')" "$new" \
    "AC3 runner present ($shape): equals the prompt without the marker line"
done

# AC5: the qa-stage usage error of pipeline-verify.sh keeps its text and exit code.
rc=0
bash "$TALOS_ROOT/scripts/pipeline-verify.sh" --issue 824 --role qa > "$OUT" 2> "$ERR" || rc=$?
assert_eq "2" "$rc" "AC5 qa usage error keeps exit code 2"
assert_contains "$(cat "$ERR")" "pipeline-verify: the qa stage needs a command: pipeline-verify.sh ... -- bash tests/run-tests.sh --changed origin/<base> --strict (--all runs the full verify: list)" \
  "AC5 qa usage error keeps its text"

finish
