#!/usr/bin/env bash
# test-qa-skip-rule-866.sh -- the QA `Targeted run skipped:` line and agents/qa.md
# step 2 forbid EVERY tests/run-tests.sh form (--changed, --for, a pattern, the full
# suite), not only --changed (#866). No GitHub write, no LLM call.
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
# pr-is-draft answers from GATE_PRD_*: ready for the skip shape.
printf '#!/usr/bin/env bash\n[ "${1:-}" = pr-is-draft ] || exit 0\nprintf "%%s" "${GATE_PRD_OUT:-}"\nexit "${GATE_PRD_RC:-2}"\n' > "$TREE/scripts/pipeline-vcs.sh"
TALOS="$TREE/scripts/talos.sh"

WT_HAS="$SANDBOX/wt-has"
mkdir -p "$WT_HAS/tests"
: > "$WT_HAS/tests/run-tests.sh"

printf '%s' '{"verify": {"qa_mode": "ci"}, "merge": {"required_checks": ["ci / test"]}}' > "$SANDBOX/talos.pipeline.json"
export GATE_PRD_RC=1 GATE_PRD_OUT=ready
bash "$TALOS" prompt qa --issue 866 --pr 9 --worktree "$WT_HAS" > "$OUT" 2> "$ERR"
pf="$(sed -n 's/^prompt_file=//p' "$OUT")"
if [ -n "$pf" ]; then text="$(cat "$pf")"; rm -f "${pf:?}"; else text="$(cat "$OUT")"; fi
line="$(printf '%s\n' "$text" | grep '^Targeted run skipped:')"

# AC1: the skip line forbids every run-tests.sh form and keeps the verdict wording.
assert_contains "$line" "no \`tests/run-tests.sh\` command" "AC1 the line says to run no tests/run-tests.sh command"
assert_contains "$line" "--changed" "AC1 the line names --changed"
assert_contains "$line" "--for" "AC1 the line names --for"
assert_contains "$line" "targeted run skipped: CI is the full run (merge.required_checks)" "AC1 the line keeps the verdict wording"

# AC2: agents/qa.md step 2 states the rule before the targeted command and the --for text.
step2="$(awk '/^2\. /{f=1} /^3\. /{f=0} f' "$TALOS_ROOT/agents/qa.md" | tr '\n' ' ' | tr -s ' ')"
rule_pos() { awk -v s="$step2" -v p="$1" 'BEGIN{print index(s, p)}'; }
skip_pos="$(rule_pos 'no `tests/run-tests.sh` command')"
chg_pos="$(rule_pos 'run-tests.sh --changed origin/')"
for_pos="$(rule_pos '--for <each path from pr-files>')"
if [ "$skip_pos" -gt 0 ]; then pass "AC2 step 2 states the skip rule (no run-tests.sh command)"
else fail "AC2 step 2 states the skip rule (no run-tests.sh command)" "not found"; fi
if [ "$skip_pos" -gt 0 ] && [ "$skip_pos" -lt "$chg_pos" ]; then pass "AC2 the rule comes before the --changed command"
else fail "AC2 the rule comes before the --changed command" "rule at $skip_pos, command at $chg_pos"; fi
if [ "$skip_pos" -gt 0 ] && [ "$skip_pos" -lt "$for_pos" ]; then pass "AC2 the rule comes before the --for text"
else fail "AC2 the rule comes before the --for text" "rule at $skip_pos, --for at $for_pos"; fi
rule="$(printf '%s' "$step2" | cut -c"$skip_pos"-"$((skip_pos + 160))")"
assert_contains "$rule" "--for" "AC2 the rule names --for as covered"

# AC3: the profile plus prompt stays within the budget qa ceiling, which is not raised.
budget_line="$(grep '^budget qa ' "$TALOS_ROOT/tests/test-stage-overhead.sh")"
ceiling="${budget_line#budget qa }"
size=$(( $(wc -c < "$TALOS_ROOT/agents/qa.md") + $(wc -c < "$TALOS_ROOT/templates/prompts/qa.md") ))
if [ "$size" -le "$ceiling" ]; then pass "AC3 qa profile + prompt is $size bytes (budget $ceiling)"
else fail "AC3 qa profile + prompt is $size bytes (budget $ceiling)" "over"; fi
assert_eq "12250" "$ceiling" "AC3 the budget qa ceiling is not raised"

finish
