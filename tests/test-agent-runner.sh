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

# ERRFILE -- captures pipeline-agent.sh's stderr so assertion failures show
# the diagnostic instead of it being silently redirected away (#208, same
# pattern as tests/test-per-agent-env.sh from #210).
ERRFILE="$SANDBOX/agent.stderr"

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

# ── Custom runner: no EPIPE on a large prompt (#208) ──────────────────────────
# Root cause: the old implementation was `printf '%s' "$PROMPT" | sh -c
# "$RUNNER_CMD"`. A runner_cmd that exits without reading stdin (or simply
# wins the race on a loaded host) makes printf receive EPIPE; under
# `set -o pipefail` that turned into a spurious pipeline-agent.sh exit 1.
# RED on the old pipe implementation: a 200 KB prompt reliably overflows the
# pipe buffer, so `exit 0` (reads nothing) used to fail deterministically,
# not just under load.
#
# The prompt is passed via stdin (`developer -`), not as an argv element:
# Linux caps a single argv element at MAX_ARG_STRLEN (128 KB), so a ~209 KB
# prompt passed as `bash "$AGENT" developer "$BIG_PROMPT"` fails with "Argument
# list too long" on Linux CI even though it fits fine in a macOS argv.
BIG_PROMPT="$(head -c 204800 /dev/zero | tr '\0' 'x')"
BIG_PROMPT_FILE="$SANDBOX/big-prompt.txt"
printf '%s' "$BIG_PROMPT" > "$BIG_PROMPT_FILE"

cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "custom", "runner_cmd": "exit 0"}}
EOF
out="$(bash "$AGENT" developer - < "$BIG_PROMPT_FILE" 2>"$ERRFILE")"; rc=$?
assert_eq_ctx "0" "$rc" "runner_cmd 'exit 0' with 200 KB prompt exits 0 (no EPIPE)" "$(cat "$ERRFILE")"

# A runner that reads all of stdin must receive the prompt byte-for-byte.
EXPECT_FILE="$SANDBOX/expected-prompt.txt"
GOT_FILE="$SANDBOX/got-prompt.txt"
ROLE_BODY="$(awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; next} !fm' \
  "$HOME/.talos/agents/developer.md")"
printf '%s\n\n---\n\n%s' "$ROLE_BODY" "$BIG_PROMPT" > "$EXPECT_FILE"
cat > talos.pipeline.json <<EOF
{"agents": {"runner": "custom", "runner_cmd": "cat > $GOT_FILE"}}
EOF
out="$(bash "$AGENT" developer - < "$BIG_PROMPT_FILE" 2>"$ERRFILE")"; rc=$?
assert_eq_ctx "0" "$rc" "full-stdin runner exits 0" "$(cat "$ERRFILE")"
expect_bytes="$(wc -c < "$EXPECT_FILE" | tr -d ' ')"
got_bytes="$(wc -c < "$GOT_FILE" | tr -d ' ')"
assert_eq "$expect_bytes" "$got_bytes" "runner_cmd receives the prompt byte-for-byte (wc -c)"
if diff -q "$EXPECT_FILE" "$GOT_FILE" >/dev/null 2>&1; then
  pass "runner_cmd receives the prompt byte-for-byte (diff)"
else
  fail "runner_cmd receives the prompt byte-for-byte (diff)" "expected vs got prompt differ"
fi

# A runner's own exit code must propagate exactly.
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "custom", "runner_cmd": "exit 3"}}
EOF
bash "$AGENT" developer - < "$BIG_PROMPT_FILE" >/dev/null 2>"$ERRFILE"; rc=$?
assert_eq_ctx "3" "$rc" "runner_cmd exit code propagates exactly (exit 3)" "$(cat "$ERRFILE")"

# The prompt temp file/dir must be cleaned up afterward, pass or fail.
# Use a private TMPDIR for this one invocation (#215 QA) instead of a glob
# over the shared ${TMPDIR:-/tmp} namespace: that glob races against any
# other test (e.g. tests/test-per-agent-env.sh) creating/removing its own
# talos-prompt.* dirs concurrently under the parallel test runner.
_PRIVATE_TMPDIR="$SANDBOX/tmp"
mkdir -p "$_PRIVATE_TMPDIR"
TMPDIR="$_PRIVATE_TMPDIR" bash "$AGENT" developer - < "$BIG_PROMPT_FILE" >/dev/null 2>&1
_prompt_tmp_after="$(find "$_PRIVATE_TMPDIR" -mindepth 1 -maxdepth 1 -name 'talos-prompt.*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$_prompt_tmp_after" "prompt temp dir is removed after the runner exits"

cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "custom"}}
EOF
if bash "$AGENT" validator "x" >/dev/null 2>&1; then
  fail "custom runner without runner_cmd exits non-zero"
else
  pass "custom runner without runner_cmd exits non-zero"
fi

# ── mktemp -d failure fails closed, never falls back to a fixed path (#215) ──
# Regression for the PR #215 review finding: the old code did not check
# `mktemp -d`'s exit status, so a failure (e.g. an unwritable/nonexistent
# TMPDIR) left _PROMPT_DIR empty, _PROMPT_FILE became the literal path
# "/prompt", and the prompt (which may contain issue-thread text) was
# written there unconditionally on a root CI container -- with the EXIT
# trap's `rm -rf "$_PROMPT_DIR"` a no-op since _PROMPT_DIR was never set.
#
# A bare `TMPDIR=/nonexistent/dir` would also break pipeline-cfg-cache.sh's
# own `mktemp -d` (it shares TMPDIR), which silently falls back to
# cfg()-returns-default instead of erroring -- masking agents.runner=custom
# entirely and defeating this test before it reaches the code under test.
# Instead, shadow `mktemp` on PATH so only the prompt-dir call (matched by
# its "talos-prompt." template) fails; every other caller, including the
# config cache, still gets the real binary.
_REAL_MKTEMP="$(command -v mktemp)"
_FAKE_BIN="$SANDBOX/fakebin"
mkdir -p "$_FAKE_BIN"
cat > "$_FAKE_BIN/mktemp" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *talos-prompt.*) exit 1 ;;
  *) exec "$_REAL_MKTEMP" "\$@" ;;
esac
EOF
chmod +x "$_FAKE_BIN/mktemp"

cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "custom", "runner_cmd": "cat > /dev/null"}}
EOF
if PATH="$_FAKE_BIN:$PATH" bash "$AGENT" developer "sensitive issue text" >/dev/null 2>"$ERRFILE"; then
  fail "custom runner exits non-zero when mktemp -d fails" "stderr: $(cat "$ERRFILE")"
else
  pass "custom runner exits non-zero when mktemp -d fails"
fi
assert_contains "$(cat "$ERRFILE")" "custom runner" \
  "mktemp -d failure error names the custom adapter"
assert_contains "$(cat "$ERRFILE")" "temp directory" \
  "mktemp -d failure error mentions the temp directory failure"
if [ -w / ]; then
  _prompt_leak="$(find "$SANDBOX" -mindepth 1 -name 'prompt' 2>/dev/null | head -1)"
  assert_eq "" "$_prompt_leak" \
    "mktemp -d failure never writes the prompt anywhere under \$SANDBOX"
else
  assert_file_absent "/prompt" \
    "mktemp -d failure never falls back to writing the prompt at the fixed /prompt path"
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

out="$(bash "$AGENT" developer "some task" 2>"$ERRFILE")"; rc=$?
assert_eq "developer" "$out" "TALOS_ROLE=developer visible in runner_cmd"
assert_eq_ctx "0" "$rc" "TALOS_ROLE test exits 0 (developer)" "$(cat "$ERRFILE")"

out="$(bash "$AGENT" reviewer "some task" 2>"$ERRFILE")"; rc=$?
assert_eq "reviewer" "$out" "TALOS_ROLE=reviewer visible in runner_cmd"
assert_eq_ctx "0" "$rc" "TALOS_ROLE test exits 0 (reviewer)" "$(cat "$ERRFILE")"

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
