#!/usr/bin/env bash
# tests/test-claude-hook-neutralise.sh -- a terminal wrapper's PermissionRequest
# hook must not stall a headless claude stage (#750).
#
#   AC1  a claude-runner stage of every role starts `claude` with
#        CMUX_CLAUDE_HOOKS_DISABLED=1 when the caller did not set it
#   AC2  a value the caller set (0, the empty string) reaches claude unchanged
#   AC3  the export is scoped to the claude child: not in the orchestrator's
#        environment afterwards, not seen by a custom runner
#
# Everything runs against the stub CLIs in tests/stubs/ in a sandbox HOME.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
# The caller's own value must not answer for Talos (a stage of a real run may have it).
unset CMUX_CLAUDE_HOOKS_DISABLED

ROLES="validator pm developer qa reviewer security adversarial docs planner"

# An install gives the stage runs the scripts and role profiles.
OUT_TXT="$(bash "$TALOS_ROOT/install.sh" --global --no-agent-skills --harness claude </dev/null 2>&1)" \
  || { fail "setup install.sh --global exits 0" "$OUT_TXT"; finish; exit 1; }

use_stubs
AGENT="$HOME/.talos/scripts/pipeline-agent.sh"
export RUNNER_LOG="$SANDBOX/runner.log"
export STUB_PROMPT_DIR="$SANDBOX/prompts"
mkdir -p "$STUB_PROMPT_DIR"
# What a runner child saw: `set=<value>` or `unset`. The claude stub evals the
# hook; the custom runner script writes the same line and keeps its stdin.
export HOOK_FILE="$SANDBOX/hook.state"
export CUSTOM_STDIN="$SANDBOX/custom.stdin"
export STUB_CLAUDE_HOOK='printf "%s" "${CMUX_CLAUDE_HOOKS_DISABLED+set=}${CMUX_CLAUDE_HOOKS_DISABLED-unset}" > "$HOOK_FILE"'
cat > "$SANDBOX/custom-runner.sh" <<'RUNNER'
cat > "$CUSTOM_STDIN"
printf '%s' "${CMUX_CLAUDE_HOOKS_DISABLED+set=}${CMUX_CLAUDE_HOOKS_DISABLED-unset}" > "$HOOK_FILE"
RUNNER
CUSTOM_CFG="{\"agents\": {\"runner\": \"custom\", \"runner_cmd\": \"bash $SANDBOX/custom-runner.sh\"}}"

# hook_seen <role> -- run one stage and print what its runner child saw.
hook_seen() {
  rm -f "$HOOK_FILE" "$CUSTOM_STDIN" "$STUB_PROMPT_DIR"/*.prompt
  : > "$RUNNER_LOG"
  bash "$AGENT" "$1" "the task text" >/dev/null 2>"$SANDBOX/agent.stderr"
  if [ -f "$HOOK_FILE" ]; then cat "$HOOK_FILE"; else printf 'runner-not-run'; fi
}

# ═══ AC1: every role, the caller did not set it ═════════════════════════════
rm -f talos.pipeline.json
for role in $ROLES; do
  assert_eq "set=1" "$(hook_seen "$role")" "AC1 a $role stage starts claude with CMUX_CLAUDE_HOOKS_DISABLED=1"
done

# ═══ AC2: the caller's value is kept ════════════════════════════════════════
assert_eq "set=0" "$(export CMUX_CLAUDE_HOOKS_DISABLED=0; hook_seen qa)" "AC2 a caller value of 0 reaches claude unchanged"
assert_eq "set=" "$(export CMUX_CLAUDE_HOOKS_DISABLED=; hook_seen developer)" "AC2 a caller value of the empty string reaches claude unchanged"
assert_eq "set=yes" "$(export CMUX_CLAUDE_HOOKS_DISABLED=yes; hook_seen reviewer)" "AC2 a caller value of yes reaches claude unchanged"

# ═══ AC3: scoped to the claude child ════════════════════════════════════════
hook_seen qa >/dev/null
assert_eq "unset" "${CMUX_CLAUDE_HOOKS_DISABLED-unset}" "AC3 the variable is not set in the test's own environment after a stage"
printf '%s\n' "$CUSTOM_CFG" > talos.pipeline.json
assert_eq "unset" "$(hook_seen developer)" "AC3 a developer stage on a custom runner sees the variable unset"
rm -f talos.pipeline.json

finish
