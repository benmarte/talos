#!/usr/bin/env bash
# Regression tests for pipeline-agent.sh (headless role runner for
# non-Claude-Code harnesses) and install.sh --harness codex.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

AGENT="$HOME/.talos/scripts/pipeline-agent.sh"
export RUNNER_LOG="$SANDBOX/runner.log"

# ── Default runner is claude, with global-config isolation ───────────────────
: > "$RUNNER_LOG"
out="$(bash "$AGENT" validator "Issue #7 is assigned to you.")"
assert_eq "claude-stub-ok" "$out" "default runner is claude"
log="$(cat "$RUNNER_LOG")"
assert_contains "$log" "CLAUDE ARGS: [-p] [--setting-sources] [project]" \
  "claude runner isolates from user-global settings"
assert_contains "$log" "You are the **Validator**" "role definition body included in prompt"
assert_contains "$log" "Issue #7 is assigned to you." "task prompt appended"
assert_not_contains "$log" "model: opus" "YAML frontmatter stripped from role file"

# ── Codex runner via config ──────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "codex", "runner_args": ["--full-auto"]}}
EOF
: > "$RUNNER_LOG"
out="$(bash "$AGENT" developer "Implement the spec for issue #7.")"
assert_eq "codex-stub-ok" "$out" "agents.runner=codex uses codex CLI"
log="$(cat "$RUNNER_LOG")"
assert_contains "$log" "CODEX ARGS: [exec] [--full-auto]" "codex exec with runner_args"
assert_contains "$log" "You are the **Developer**" "developer role body included"

# ── Stdin task prompt (heredoc form used by the playbook) ────────────────────
: > "$RUNNER_LOG"
out="$(bash "$AGENT" qa - <<'PROMPT'
Verify PR #9 against the acceptance criteria.
PROMPT
)"
assert_eq "codex-stub-ok" "$out" "stdin task prompt accepted"
assert_contains "$(cat "$RUNNER_LOG")" "Verify PR #9 against the acceptance criteria." \
  "stdin prompt reaches the runner"

# ── Gemini runner via config ─────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "gemini"}}
EOF
: > "$RUNNER_LOG"
out="$(bash "$AGENT" reviewer "Review PR #9.")"
assert_eq "gemini-stub-ok" "$out" "agents.runner=gemini uses gemini CLI"
assert_contains "$(cat "$RUNNER_LOG")" "GEMINI ARGS: [-p]" "gemini invoked with -p prompt"

# ── Antigravity runner via config ────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "antigravity"}}
EOF
: > "$RUNNER_LOG"
out="$(bash "$AGENT" reviewer "Review PR #9 with antigravity.")"
assert_eq "agy-stub-ok" "$out" "agents.runner=antigravity uses agy CLI"
log="$(cat "$RUNNER_LOG")"
assert_contains "$log" "AGY ARGS: [-p]" "antigravity invoked with -p prompt"
assert_contains "$log" "Review PR #9 with antigravity." "antigravity runner receives task prompt"

# ── pi runner via config ─────────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "pi", "runner_args": ["--no-skills"]}}
EOF
: > "$RUNNER_LOG"
out="$(bash "$AGENT" validator "Validate issue #7.")"
assert_eq "pi-stub-ok" "$out" "agents.runner=pi uses pi CLI"
log="$(cat "$RUNNER_LOG")"
assert_contains "$log" "PI ARGS: [-p] [--no-skills]" "pi invoked with -p prompt + runner_args"
assert_contains "$log" "Validate issue #7." "pi runner receives task prompt"
rm talos.pipeline.json

# ── Custom runner: prompt on stdin ───────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "custom", "runner_cmd": "wc -l | tr -d ' '"}}
EOF
out="$(bash "$AGENT" validator "line one")"
[ "$out" -gt 10 ] 2>/dev/null \
  && pass "custom runner receives full prompt on stdin" \
  || fail "custom runner receives full prompt on stdin" "got: $out"

cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "custom"}}
EOF
if bash "$AGENT" validator "x" >/dev/null 2>&1; then
  fail "custom runner without runner_cmd exits non-zero"
else
  pass "custom runner without runner_cmd exits non-zero"
fi

# ── Error paths ───────────────────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "no-such-runner"}}
EOF
if bash "$AGENT" validator "x" >/dev/null 2>&1; then
  fail "unknown runner exits non-zero"
else
  pass "unknown runner exits non-zero"
fi
rm talos.pipeline.json

if bash "$AGENT" no-such-role "x" >/dev/null 2>&1; then
  fail "missing role definition exits non-zero"
else
  pass "missing role definition exits non-zero"
fi

out="$(bash "$AGENT" 2>&1)"; rc=$?
assert_eq "2" "$rc" "missing args exits 2"

# ── install.sh --harness codex ────────────────────────────────────────────────
assert_file_exists "$HOME/.talos/scripts/pipeline-agent.sh" \
  "pipeline-agent.sh installed by --global into ~/.talos/scripts/"

out="$(bash "$TALOS_ROOT/install.sh" "$SANDBOX" --harness codex)"
assert_file_exists "AGENTS.md" "--harness codex writes AGENTS.md"
agents_md="$(cat AGENTS.md)"
assert_contains "$agents_md" "<!-- talos:begin -->" "AGENTS.md section is marker-fenced"
assert_contains "$agents_md" "pipeline-agent.sh" "AGENTS.md explains the subagent replacement"

# Re-install must not duplicate the section; existing content must survive
echo "# My project notes" > AGENTS.md.orig
cat AGENTS.md >> AGENTS.md.orig && mv AGENTS.md.orig AGENTS.md
bash "$TALOS_ROOT/install.sh" "$SANDBOX" --harness codex >/dev/null
assert_eq "1" "$(grep -c 'talos:begin' AGENTS.md)" "codex re-install does not duplicate section"
assert_contains "$(cat AGENTS.md)" "# My project notes" "existing AGENTS.md content preserved"

# ── install.sh --harness antigravity ─────────────────────────────────────────
rm -f AGENTS.md
out="$(bash "$TALOS_ROOT/install.sh" "$SANDBOX" --harness antigravity)"
assert_file_exists "AGENTS.md" "--harness antigravity writes AGENTS.md"
agents_md="$(cat AGENTS.md)"
assert_contains "$agents_md" "<!-- talos:begin -->" "antigravity AGENTS.md section is marker-fenced"
assert_contains "$agents_md" "pipeline-agent.sh" "antigravity AGENTS.md explains subagent replacement"
assert_contains "$out" "NOTE: Antigravity reads AGENTS.md natively" "antigravity install prints native-reader note"

# Antigravity re-install must be idempotent
echo "# My antigravity notes" > AGENTS.md.orig
cat AGENTS.md >> AGENTS.md.orig && mv AGENTS.md.orig AGENTS.md
bash "$TALOS_ROOT/install.sh" "$SANDBOX" --harness antigravity >/dev/null
assert_eq "1" "$(grep -c 'talos:begin' AGENTS.md)" "antigravity re-install does not duplicate section"
assert_contains "$(cat AGENTS.md)" "# My antigravity notes" "existing AGENTS.md content preserved on antigravity re-install"

# Bad harness rejected
if bash "$TALOS_ROOT/install.sh" "$SANDBOX" --harness gemini >/dev/null 2>&1; then
  fail "unknown harness exits non-zero"
else
  pass "unknown harness exits non-zero"
fi

# ── TALOS_ROLE is exported to runner_cmd ──────────────────────────────────────
# Criterion (a): TALOS_ROLE is visible inside a custom runner_cmd for at least
# two different roles.  RED when the export is absent; GREEN after the fix.
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "custom", "runner_cmd": "printf '%s' \"$TALOS_ROLE\""}}
EOF

out="$(bash "$AGENT" developer "some task" 2>/dev/null)"; rc=$?
assert_eq "developer" "$out" "TALOS_ROLE=developer visible in runner_cmd"
assert_eq "0" "$rc" "TALOS_ROLE test exits 0 (developer)"

out="$(bash "$AGENT" reviewer "some task" 2>/dev/null)"; rc=$?
assert_eq "reviewer" "$out" "TALOS_ROLE=reviewer visible in runner_cmd"
assert_eq "0" "$rc" "TALOS_ROLE test exits 0 (reviewer)"

rm talos.pipeline.json

# ── Model resolution: all three levels ────────────────────────────────────────
# Criteria (b), (c), (d), (e), (f): test pipeline-config.sh directly because
# the resolution is in the config reader, not pipeline-agent.sh.

CONFIG_SH="$HOME/.talos/scripts/pipeline-config.sh"

# (b) Role-specific model wins over global
cat > talos.pipeline.json <<'EOF'
{"agents": {"model": "haiku-global", "roles": {"developer": {"model": "opus-role"}}}}
EOF

out="$(bash "$CONFIG_SH" agents.roles.developer.model 2>/dev/null)"; rc=$?
assert_eq "opus-role" "$out" "role-specific model wins over global"
assert_eq "0" "$rc" "role-specific model lookup exits 0"

# (c) Global model applies when role has no override
out="$(bash "$CONFIG_SH" agents.roles.reviewer.model 2>/dev/null)"; rc=$?
assert_eq "" "$out" "absent role entry returns empty (falls through to global)"
assert_eq "0" "$rc" "absent role entry exits 0"

out="$(bash "$CONFIG_SH" agents.model 2>/dev/null)"; rc=$?
assert_eq "haiku-global" "$out" "global model returned when role absent"
assert_eq "0" "$rc" "global model lookup exits 0"

rm talos.pipeline.json

# (d) No model at either level → empty (assert absence, not a default value)
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "claude"}}
EOF

out="$(bash "$CONFIG_SH" agents.roles.developer.model 2>/dev/null)"; rc=$?
assert_eq "" "$out" "no model at role level returns empty"
assert_eq "0" "$rc" "absent role model exits 0"

out="$(bash "$CONFIG_SH" agents.model 2>/dev/null)"; rc=$?
assert_eq "" "$out" "no model at global level returns empty"
assert_eq "0" "$rc" "absent global model exits 0"

# (e) Backwards compatibility: no roles: key → same empty results
# (already covered by the config above, which has no roles: key)

# (f) Exit-zero proof: valid config with both agents.model and role override exits 0
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "claude", "model": "haiku-global", "roles": {"reviewer": {"model": "opus-rev"}}}}
EOF

out="$(bash "$CONFIG_SH" agents.roles.reviewer.model 2>/dev/null)"; rc=$?
assert_eq "opus-rev" "$out" "role override resolved correctly in full config"
assert_eq "0" "$rc" "full config resolution exits 0 (exit-zero proof)"

# Unknown/misspelled role falls back rather than erroring
out="$(bash "$CONFIG_SH" agents.roles.no_such_role.model 2>/dev/null)"; rc=$?
assert_eq "" "$out" "unknown role name returns empty (no error)"
assert_eq "0" "$rc" "unknown role name exits 0"

rm talos.pipeline.json

finish
