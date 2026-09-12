#!/usr/bin/env bash
# Regression tests for per-role runner override (#167, S1): a role can be
# pointed at a different backend from the pipeline default via
# agents.roles.<role>.runner / agents.roles.<role>.runner_cmd, resolved
# role-first (role value wins, else the global agents.runner / .runner_cmd).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

AGENT="$HOME/.talos/scripts/pipeline-agent.sh"
export RUNNER_LOG="$SANDBOX/runner.log"
ERRFILE="$SANDBOX/agent.stderr"

# ═══════════════════════════════════════════════════════════════════════════
# --resolve: shared resolution helper
# ═══════════════════════════════════════════════════════════════════════════

# No config at all: every role falls back to claude / empty runner_cmd / empty model.
out="$(bash "$AGENT" --resolve developer 2>"$ERRFILE")"; rc=$?
assert_eq_ctx "0" "$rc" "--resolve exits 0 with no config" "$(cat "$ERRFILE")"
assert_eq "runner=claude runner_cmd= model= effort=" "$out" \
  "--resolve developer with no config falls back to claude/empty/empty"

# Role override wins over global for both runner and runner_cmd.
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "codex", "runner_cmd": "global-cmd",
  "roles": {"qa": {"runner": "custom", "runner_cmd": "role-cmd"}}}}
EOF
out="$(bash "$AGENT" --resolve qa 2>"$ERRFILE")"; rc=$?
assert_eq_ctx "0" "$rc" "--resolve qa exits 0 (role override present)" "$(cat "$ERRFILE")"
assert_eq "runner=custom runner_cmd=role-cmd model= effort=" "$out" \
  "--resolve qa: role runner+runner_cmd override win over global"

# Absent role key falls back to the global runner/runner_cmd.
out="$(bash "$AGENT" --resolve developer 2>"$ERRFILE")"; rc=$?
assert_eq_ctx "0" "$rc" "--resolve developer exits 0 (no role override)" "$(cat "$ERRFILE")"
assert_eq "runner=codex runner_cmd=global-cmd model= effort=" "$out" \
  "--resolve developer: no role override, falls back to global runner+runner_cmd"

# runner_cmd falls back independently of runner: a role can override just
# one of the two (role runner set, role runner_cmd absent -> global runner_cmd).
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "codex", "runner_cmd": "global-cmd",
  "roles": {"security": {"runner": "custom"}}}}
EOF
out="$(bash "$AGENT" --resolve security 2>"$ERRFILE")"; rc=$?
assert_eq_ctx "0" "$rc" "--resolve security exits 0" "$(cat "$ERRFILE")"
assert_eq "runner=custom runner_cmd=global-cmd model= effort=" "$out" \
  "--resolve security: role runner override, runner_cmd falls back to global"

# Model resolution (role-first, same precedence as the native path) is part
# of the shared --resolve output.
cat > talos.pipeline.json <<'EOF'
{"agents": {"model": "haiku-global", "roles": {"reviewer": {"model": "opus-role"}}}}
EOF
out="$(bash "$AGENT" --resolve reviewer 2>"$ERRFILE")"; rc=$?
assert_eq "runner=claude runner_cmd= model=opus-role effort=" "$out" \
  "--resolve reviewer: role model wins over global model"
out="$(bash "$AGENT" --resolve docs 2>"$ERRFILE")"; rc=$?
assert_eq "runner=claude runner_cmd= model=haiku-global effort=" "$out" \
  "--resolve docs: no role model, falls back to global model"

# ═══════════════════════════════════════════════════════════════════════════
# Effort resolution (#271): role-first, same precedence shape as model.
# ═══════════════════════════════════════════════════════════════════════════

# No agents.effort anywhere -> empty (already covered by the no-config case
# above, since --resolve developer with no config asserts effort= too).

# Role effort wins over global effort.
cat > talos.pipeline.json <<'EOF'
{"agents": {"effort": "medium", "roles": {"developer": {"effort": "low"}}}}
EOF
out="$(bash "$AGENT" --resolve developer 2>"$ERRFILE")"; rc=$?
assert_eq_ctx "0" "$rc" "--resolve developer exits 0 (role effort override)" "$(cat "$ERRFILE")"
assert_eq "runner=claude runner_cmd= model= effort=low" "$out" \
  "--resolve developer: role effort wins over global effort"

# No role override -> falls back to the global effort.
out="$(bash "$AGENT" --resolve reviewer 2>"$ERRFILE")"; rc=$?
assert_eq "runner=claude runner_cmd= model= effort=medium" "$out" \
  "--resolve reviewer: no role effort, falls back to global effort"

# Neither level set -> empty (the runner's own default, unchanged behaviour).
cat > talos.pipeline.json <<'EOF'
{"agents": {"model": "haiku-global"}}
EOF
out="$(bash "$AGENT" --resolve developer 2>"$ERRFILE")"; rc=$?
assert_eq "runner=claude runner_cmd= model=haiku-global effort=" "$out" \
  "--resolve developer: no effort at either level resolves to empty"

# agents.restamp_effort (#271, same chain as agents.restamp_model, #258):
# resolved by pipeline-config.sh, not this script's role-first _resolve_effort
# -- exercised directly against pipeline-config.sh in tests/test-config.sh.
# Here, confirm --resolve's plain agents.effort output is unaffected by an
# unrelated restamp_effort override (the two chains are independent).
cat > talos.pipeline.json <<'EOF'
{"agents": {"effort": "high", "restamp_effort": "low", "roles": {"developer": {"restamp_effort": "max"}}}}
EOF
out="$(bash "$AGENT" --resolve developer 2>"$ERRFILE")"; rc=$?
assert_eq "runner=claude runner_cmd= model= effort=high" "$out" \
  "--resolve developer: plain effort output unaffected by a restamp_effort override"

rm -f talos.pipeline.json

# ═══════════════════════════════════════════════════════════════════════════
# TALOS_EFFORT is exported to runner_cmd (#271, mirrors TALOS_ROLE above)
# ═══════════════════════════════════════════════════════════════════════════

cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "custom", "runner_cmd": "printf '%s' \"$TALOS_EFFORT\"",
  "effort": "medium", "roles": {"qa": {"effort": "low"}}}}
EOF
out="$(bash "$AGENT" qa "Verify PR #9." 2>"$ERRFILE")"; rc=$?
assert_eq_ctx "0" "$rc" "TALOS_EFFORT test exits 0 (qa)" "$(cat "$ERRFILE")"
assert_eq "low" "$out" "TALOS_EFFORT=low visible in runner_cmd (role override)"

out="$(bash "$AGENT" reviewer "Review PR #9." 2>"$ERRFILE")"; rc=$?
assert_eq_ctx "0" "$rc" "TALOS_EFFORT test exits 0 (reviewer)" "$(cat "$ERRFILE")"
assert_eq "medium" "$out" "TALOS_EFFORT=medium visible in runner_cmd (global fallback)"

cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "custom", "runner_cmd": "printf 'EFFORT=[%s]' \"$TALOS_EFFORT\""}}
EOF
out="$(bash "$AGENT" docs "Update docs." 2>"$ERRFILE")"; rc=$?
assert_eq "EFFORT=[]" "$out" "TALOS_EFFORT is the empty string when unset at either level"

rm -f talos.pipeline.json

# --resolve with an invalid runner value errors clearly instead of printing
# a bogus resolution.
cat > talos.pipeline.json <<'EOF'
{"agents": {"roles": {"developer": {"runner": "not-a-runner"}}}}
EOF
if out="$(bash "$AGENT" --resolve developer 2>"$ERRFILE")"; then
  fail "--resolve rejects an unknown runner value" "got stdout: $out"
else
  pass "--resolve rejects an unknown runner value"
fi
assert_contains "$(cat "$ERRFILE")" "unknown agents.runner" \
  "--resolve unknown runner error names the bad value"
assert_contains "$(cat "$ERRFILE")" "developer" \
  "--resolve unknown runner error names the role"

# --resolve without a role argument is a usage error (exit 2).
out="$(bash "$AGENT" --resolve 2>"$ERRFILE")"; rc=$?
assert_eq "2" "$rc" "--resolve with no role exits 2"

rm -f talos.pipeline.json

# ═══════════════════════════════════════════════════════════════════════════
# Real dispatch: role override beats global; absent role falls back
# ═══════════════════════════════════════════════════════════════════════════

# Global runner is codex; qa has no override -> qa still goes through codex.
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "codex"}}
EOF
: > "$RUNNER_LOG"
out="$(bash "$AGENT" qa "Verify PR #9." 2>"$ERRFILE")"
assert_eq_ctx "codex-stub-ok" "$out" "qa with no role override uses the global runner (codex)" "$(cat "$ERRFILE")"
assert_contains "$(cat "$RUNNER_LOG")" "CODEX ARGS:" "qa dispatched to codex stub"

# developer gets a role-specific override to claude -- wins over the global
# codex default even though nothing else in the pipeline is native here.
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "codex", "roles": {"developer": {"runner": "claude"}}}}
EOF
: > "$RUNNER_LOG"
out="$(bash "$AGENT" developer "Implement the spec." 2>"$ERRFILE")"
assert_eq_ctx "claude-stub-ok" "$out" "developer role override (claude) wins over global runner (codex)" "$(cat "$ERRFILE")"
assert_contains "$(cat "$RUNNER_LOG")" "CLAUDE ARGS:" "developer dispatched to claude stub, not codex"

# ═══════════════════════════════════════════════════════════════════════════
# Adapter path: role qa on a custom runner_cmd, role developer still global
# ═══════════════════════════════════════════════════════════════════════════

STUB_CMD_LOG="$SANDBOX/qa-adapter.log"
cat > talos.pipeline.json <<EOF
{"agents": {"runner": "claude",
  "roles": {"qa": {"runner": "custom", "runner_cmd": "cat > $STUB_CMD_LOG"}}}}
EOF

# qa: effective runner is custom -- the stub runner_cmd receives the full
# prompt (profile body + separator + task prompt) on stdin.
: > "$RUNNER_LOG"
out="$(bash "$AGENT" qa "Verify PR #9 against the acceptance criteria." 2>"$ERRFILE")"
rc=$?
assert_eq_ctx "0" "$rc" "qa custom-runner adapter exits 0" "$(cat "$ERRFILE")"
qa_prompt="$(cat "$STUB_CMD_LOG")"
assert_contains "$qa_prompt" "You are **QA**" "qa adapter runner_cmd received the qa role profile body"
assert_contains "$qa_prompt" "Verify PR #9 against the acceptance criteria." \
  "qa adapter runner_cmd received the task prompt"
assert_eq "" "$(cat "$RUNNER_LOG")" "qa custom-runner adapter never touched the claude stub"

# developer: no role override -- still resolves to the global runner (claude).
: > "$RUNNER_LOG"
: > "$STUB_CMD_LOG"
out="$(bash "$AGENT" developer "Implement the spec for issue #7." 2>"$ERRFILE")"
assert_eq_ctx "claude-stub-ok" "$out" "developer with no role override still resolves to the global runner (claude)" "$(cat "$ERRFILE")"
assert_contains "$(cat "$RUNNER_LOG")" "CLAUDE ARGS:" "developer dispatched to the claude stub"
assert_eq "" "$(cat "$STUB_CMD_LOG")" "developer never went through qa's custom runner_cmd"

# ═══════════════════════════════════════════════════════════════════════════
# talos:runner marker
# ═══════════════════════════════════════════════════════════════════════════

cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "codex", "roles": {"security": {"runner": "gemini"}}}}
EOF
: > "$RUNNER_LOG"
bash "$AGENT" security "Security review PR #9." >/dev/null 2>"$ERRFILE"
assert_contains "$(cat "$ERRFILE")" "talos:runner role=security runner=gemini" \
  "talos:runner marker emitted with the resolved (role-overridden) runner"

: > "$RUNNER_LOG"
bash "$AGENT" docs "Update docs for PR #9." >/dev/null 2>"$ERRFILE"
assert_contains "$(cat "$ERRFILE")" "talos:runner role=docs runner=codex" \
  "talos:runner marker emitted once per role with the resolved global fallback"

# ═══════════════════════════════════════════════════════════════════════════
# Invalid runner value -> clear error, real dispatch path (not just --resolve)
# ═══════════════════════════════════════════════════════════════════════════

cat > talos.pipeline.json <<'EOF'
{"agents": {"roles": {"reviewer": {"runner": "not-a-real-runner"}}}}
EOF
if bash "$AGENT" reviewer "Review PR #9." >/dev/null 2>"$ERRFILE"; then
  fail "invalid per-role runner value exits non-zero"
else
  pass "invalid per-role runner value exits non-zero"
fi
assert_contains "$(cat "$ERRFILE")" "unknown agents.runner" \
  "invalid per-role runner error names the bad value"
assert_contains "$(cat "$ERRFILE")" "not-a-real-runner" \
  "invalid per-role runner error quotes the offending value"

rm -f talos.pipeline.json

finish
