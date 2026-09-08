#!/usr/bin/env bash
# test-hooks-pre-dispatch.sh -- hooks.pre_dispatch (#181): a command run
# before each stage's prompt is built, whose stdout is prepended to the
# prompt under a "## Context" heading. Covers the adapter path
# (scripts/pipeline-agent.sh -> scripts/pipeline-hooks.sh) end to end:
#   (a) hook output lands at the top of the prompt the runner receives
#   (b) failing / slow (timeout) / empty hooks are no-ops -- prompt is
#       byte-identical to the no-hook case
#   (c) the hook receives the documented stdin JSON schema
#   (d) disabled by default (no hooks.pre_dispatch key at all)
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

AGENT="$HOME/.talos/scripts/pipeline-agent.sh"
RECEIVED="$SANDBOX/received-prompt.txt"

# ── (d) Disabled by default: no hooks.pre_dispatch key in config at all ──────
cat > talos.pipeline.json <<EOF
{"agents": {"runner": "custom", "runner_cmd": "cat > $RECEIVED"}}
EOF
: > "$RECEIVED"
out="$(TALOS_ISSUE=42 bash "$AGENT" developer "Implement the spec.")"
assert_eq "0" "$?" "no-hook run exits 0"
NOHOOK_PROMPT="$(cat "$RECEIVED")"
assert_not_contains "$NOHOOK_PROMPT" "## Context" \
  "disabled by default: no ## Context block when hooks.pre_dispatch is unset"

# ── (a) Adapter path: hook output at the top of the prompt ───────────────────
cat > talos.pipeline.json <<EOF
{"agents": {"runner": "custom", "runner_cmd": "cat > $RECEIVED"},
 "hooks": {"pre_dispatch": "cat > /dev/null; echo MARKER-9f3a", "timeout_s": 5}}
EOF
: > "$RECEIVED"
out="$(TALOS_ISSUE=42 bash "$AGENT" developer "Implement the spec.")"
assert_eq "0" "$?" "hooked run exits 0"
HOOKED_PROMPT="$(cat "$RECEIVED")"
case "$HOOKED_PROMPT" in
  "## Context"$'\n'"MARKER-9f3a"$'\n'"---"*)
    pass "received prompt starts with '## Context' + marker" ;;
  *)
    fail "received prompt starts with '## Context' + marker" \
      "got head: $(printf '%s' "$HOOKED_PROMPT" | head -c 200)" ;;
esac
assert_contains "$HOOKED_PROMPT" "You are the **Developer**" \
  "role body still present after the hook block"

# The hook block plus a blank-line separator is exactly what got prepended --
# strip it and the rest must be byte-identical to the no-hook prompt.
STRIPPED="$(printf '%s' "$HOOKED_PROMPT" | tail -n +4)"
assert_eq "$NOHOOK_PROMPT" "$STRIPPED" \
  "everything after the hook block is unchanged from the no-hook prompt"

# ── Watchdog reaps itself on the fast-success path (#181 review) ────────────
# A successful hook returns well within hooks.timeout_s. The watchdog runs
# `sleep "$timeout_s"` in the background to enforce that timeout; if the
# watchdog isn't reaped as a whole process group, that sleep is orphaned and
# keeps running for up to hooks.timeout_s after this call returns. Use a
# large, unique timeout_s value so the pgrep below can't match any other
# sleep started elsewhere in this test file.
cat > talos.pipeline.json <<EOF
{"agents": {"runner": "custom", "runner_cmd": "cat > $RECEIVED"},
 "hooks": {"pre_dispatch": "cat > /dev/null; echo fast-ok", "timeout_s": 20}}
EOF
: > "$RECEIVED"
out="$(TALOS_ISSUE=42 bash "$AGENT" developer "Implement the spec.")"; rc=$?
assert_eq "0" "$rc" "fast-success hook: pipeline-agent.sh still exits 0"
sleep 1
_leaked="$(pgrep -f 'sleep 20$' || true)"
assert_eq "" "$_leaked" \
  "fast-success hook: watchdog's own 'sleep 20' is reaped, not left running"

# ── (b) Failing hook -- no-op, byte-identical to no-hook ─────────────────────
cat > talos.pipeline.json <<EOF
{"agents": {"runner": "custom", "runner_cmd": "cat > $RECEIVED"},
 "hooks": {"pre_dispatch": "cat > /dev/null; echo should-not-appear; exit 1", "timeout_s": 5}}
EOF
: > "$RECEIVED"
ERRFILE="$SANDBOX/agent.stderr"
out="$(TALOS_ISSUE=42 bash "$AGENT" developer "Implement the spec." 2>"$ERRFILE")"; rc=$?
assert_eq_ctx "0" "$rc" "failing hook: pipeline-agent.sh still exits 0" "$(cat "$ERRFILE")"
assert_eq "$NOHOOK_PROMPT" "$(cat "$RECEIVED")" \
  "failing hook: prompt is byte-identical to the no-hook prompt"
assert_contains "$(cat "$ERRFILE")" "pipeline-hooks:" \
  "failing hook: one stderr note is printed"

# ── (b) Slow hook (exceeds hooks.timeout_s) -- no-op, byte-identical ─────────
cat > talos.pipeline.json <<EOF
{"agents": {"runner": "custom", "runner_cmd": "cat > $RECEIVED"},
 "hooks": {"pre_dispatch": "cat > /dev/null; sleep 3; echo too-late", "timeout_s": 1}}
EOF
: > "$RECEIVED"
: > "$ERRFILE"
_start=$(date +%s)
out="$(TALOS_ISSUE=42 bash "$AGENT" developer "Implement the spec." 2>"$ERRFILE")"; rc=$?
_elapsed=$(( $(date +%s) - _start ))
assert_eq_ctx "0" "$rc" "slow hook: pipeline-agent.sh still exits 0" "$(cat "$ERRFILE")"
assert_eq "$NOHOOK_PROMPT" "$(cat "$RECEIVED")" \
  "slow hook: prompt is byte-identical to the no-hook prompt"
if [ "$_elapsed" -le 3 ]; then
  pass "slow hook: killed at hooks.timeout_s (1s), not left to run its full 3s sleep"
else
  fail "slow hook: killed at hooks.timeout_s (1s), not left to run its full 3s sleep" \
    "elapsed: ${_elapsed}s"
fi

# ── (b) Empty hook -- no-op, byte-identical ───────────────────────────────────
cat > talos.pipeline.json <<EOF
{"agents": {"runner": "custom", "runner_cmd": "cat > $RECEIVED"},
 "hooks": {"pre_dispatch": "cat > /dev/null", "timeout_s": 5}}
EOF
: > "$RECEIVED"
out="$(TALOS_ISSUE=42 bash "$AGENT" developer "Implement the spec.")"; rc=$?
assert_eq "0" "$rc" "empty hook: pipeline-agent.sh still exits 0"
assert_eq "$NOHOOK_PROMPT" "$(cat "$RECEIVED")" \
  "empty hook: prompt is byte-identical to the no-hook prompt"

# ── (c) Stdin JSON schema ─────────────────────────────────────────────────────
STDIN_CAPTURE="$SANDBOX/hook-stdin.json"
cat > talos.pipeline.json <<EOF
{"agents": {"runner": "custom", "runner_cmd": "cat > $RECEIVED"},
 "hooks": {"pre_dispatch": "cat > $STDIN_CAPTURE; echo ok", "timeout_s": 5},
 "base_branch": "dev"}
EOF
: > "$RECEIVED"
TALOS_ISSUE=42 bash "$AGENT" developer "Implement the spec." >/dev/null

_json_check="$(python3 - "$STDIN_CAPTURE" <<'PYEOF'
import json
import sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

checks = [
    (data.get("role") == "developer", "role"),
    (data.get("issue") == 42, "issue"),
    ("base_branch" in data, "base_branch"),
    ("repo" in data, "repo"),
    ("worktree_path" in data, "worktree_path"),
    (isinstance(data.get("files_hint"), list), "files_hint"),
    ("pr" in data, "pr"),
]
missing = [label for ok, label in checks if not ok]
print("OK" if not missing else "MISSING:" + ",".join(missing))
PYEOF
)"
assert_eq "OK" "$_json_check" \
  "stdin JSON has role/issue/pr/repo/base_branch/worktree_path/files_hint fields"

# role/issue values are correct, not just present.
_role_issue="$(python3 -c "
import json
d = json.load(open('$STDIN_CAPTURE'))
print(d.get('role'), d.get('issue'))
")"
assert_eq "developer 42" "$_role_issue" "stdin JSON: role and issue have the expected values"

finish
