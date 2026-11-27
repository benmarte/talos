#!/usr/bin/env bash
# test-pm-no-suite-rerun-1090.sh -- the PM's spec-writing rules for tests that
# outlive the PR (#1090).
#
# What a PM stage reads is agents/pm.md (the role profile) plus the text of
# `talos.sh prompt pm`; the latter alone does not carry the profile. This feeds
# the rendered prompt through pipeline-agent.sh with a runner that keeps its
# stdin, so the assertions are on the joined text a run sends.
# No GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
GOT="$SANDBOX/pm-got.txt"
printf '{"vcs": {"provider": "github"}, "agents": {"runner": "custom", "runner_cmd": "cat > %s"}}' "$GOT" \
  > "$SANDBOX/talos.pipeline.json"

bash "$TALOS_ROOT/scripts/talos.sh" prompt pm --issue 1090 > "$SANDBOX/out" 2> "$SANDBOX/err"
assert_eq_ctx "0" "$?" "talos.sh prompt pm renders" "$(cat "$SANDBOX/out" "$SANDBOX/err")"
PF="$(sed -n 's/^prompt_file=//p' "$SANDBOX/out")"
[ -n "$PF" ] && [ -f "$PF" ] || { fail "talos.sh prompt pm names a prompt file"; finish; exit 1; }

bash "$TALOS_ROOT/scripts/pipeline-agent.sh" pm - < "$PF" > "$SANDBOX/agent.out" 2> "$SANDBOX/err"
assert_eq_ctx "0" "$?" "the pm stage runs on the stub runner" "$(cat "$SANDBOX/err")"
rm -f "${PF:?}"
[ -f "$GOT" ] || { fail "the stub runner received the pm prompt"; finish; exit 1; }
PROMPT="$(tr '\n' ' ' < "$GOT" | tr -s ' ')"

# Controls: both halves are in the captured text.
assert_contains "$PROMPT" 'You are the **Project Manager**. A validator has CONFIRMED' "control: the role profile is in the prompt"
assert_contains "$PROMPT" 'Issue #1090 has been CONFIRMED.' "control: the rendered task is in the prompt"

assert_contains "$PROMPT" "A criterion's test never runs other test files or the whole suite" \
  "AC1 the pm prompt says a criterion's test runs no other test file and not the suite"
assert_contains "$PROMPT" 'the `verify` list carries regression safety' \
  "AC1 the pm prompt says the verify list carries regression safety"

assert_contains "$PROMPT" 'files touched, `git diff`, or lint/format/type-check clean is `(prose: ...)`, never `(test)` or `(same)`' \
  "AC2 the pm prompt routes a git diff / files-touched criterion to (prose: ...)"

finish
