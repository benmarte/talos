#!/usr/bin/env bash
# tests/test-llm-profiles.sh -- named LLM profiles and the subagent capability
# (#539, part of epic #558): agents.profile / agents.profiles.<name> /
# TALOS_PROFILE, the harness a run is orchestrated from (CLAUDECODE=1 or
# TALOS_HARNESS), profile modes (native | adapter | inline), first-usable-profile
# selection, and fallback entries that name a profile.
#
# Everything runs against the stub runners in tests/stubs/ and a copy of
# scripts/ whose pipeline-worktree.sh is a stub. No real runner, no network.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

INST="$SANDBOX/inst"
mkdir -p "$INST"
cp -R "$TALOS_ROOT/scripts" "$INST/scripts"
cp -R "$TALOS_ROOT/agents" "$INST/agents"
AGENT="$INST/scripts/pipeline-agent.sh"
CONFIG="$INST/scripts/pipeline-config.sh"
TALOS="$INST/scripts/talos.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$INST/scripts/pipeline-worktree.sh"
export RUNNER_LOG="$SANDBOX/runner.log"
export STUB_PROMPT_DIR="$SANDBOX/prompts"
mkdir -p "$STUB_PROMPT_DIR"
ERR="$SANDBOX/err.txt"
EVENTS="$SANDBOX/.git/talos/events.jsonl"
MODEL_OUT="$SANDBOX/custom-model.txt"
ROLES="validator pm developer qa reviewer security adversarial docs planner"

# A single-model custom runner for the "ollama" profile: records what it was
# told through the environment, optionally hangs, then exits like STUB_CUSTOM_EXIT.
CUSTOM="$SANDBOX/ollama-agent.sh"
cat > "$CUSTOM" <<'EOF'
#!/usr/bin/env bash
printf 'model=%s role=%s\n' "${TALOS_MODEL:-<unset>}" "${TALOS_ROLE:-}" >> "$MODEL_OUT"
cat >/dev/null
[ -z "${STUB_CUSTOM_SLEEP:-}" ] || sleep "$STUB_CUSTOM_SLEEP"
echo custom-ok
exit "${STUB_CUSTOM_EXIT:-0}"
EOF
chmod +x "$CUSTOM"
export MODEL_OUT

reset() {
  rm -rf "${SANDBOX:?}/.talos" "${SANDBOX:?}/.git/talos" "$STUB_PROMPT_DIR" talos.pipeline.json
  mkdir -p "$STUB_PROMPT_DIR"
  : > "$RUNNER_LOG"; : > "$MODEL_OUT"
  unset TALOS_PROFILE TALOS_HARNESS CLAUDECODE TALOS_ISSUE STUB_CLAUDE_EXIT STUB_CLAUDE_STDERR \
        STUB_CUSTOM_EXIT STUB_CUSTOM_SLEEP STUB_PI_EXIT STUB_CODEX_EXIT TALOS_STAGE_TIMEOUT_DIVISOR
}
set_cfg() { printf '%s\n' "$1" > talos.pipeline.json; }
runner_calls() { grep -c "^$1 ARGS" "$RUNNER_LOG"; }
nonzero() { [ "$1" -ne 0 ] && echo yes || echo no; }
event_field() {  # <event> <field> -> field of the last such event
  python3 -I - "$EVENTS" "$1" "$2" <<'PYEOF'
import json, sys
val = None
for line in open(sys.argv[1]):
    e = json.loads(line)
    if e.get("event") == sys.argv[2]:
        val = e.get(sys.argv[3])
print("<none>" if val is None else val)
PYEOF
}
# dump_get <key> [ENV=val...]: the value of one pair of `pipeline-config.sh --dump`.
dump_get() {
  local key="$1"; shift
  env ${1+"$@"} bash "$CONFIG" --dump 2>/dev/null | python3 -I -c '
import sys
parts = sys.stdin.buffer.read().split(b"\0")
want = sys.argv[1].encode()
for i in range(0, len(parts) - 1, 2):
    if parts[i] == want:
        sys.stdout.write(parts[i + 1].decode("utf-8", "replace"))
        break' "$key"
}
env_get() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
# The `role=` rows of --resolve-all (the profile header line is not one).
role_rows() { grep '^role='; }

# The example from the issue: Claude with a model per role, a local pi, an
# Ollama-style custom runner. `mode` is the declared subagent capability.
PROFILES="\"profile\": \"claude\", \"profiles\": {
  \"claude\": {\"mode\": \"native\", \"model\": \"sonnet\",
    \"roles\": {\"planner\": {\"model\": \"opus\"},
                \"security\": {\"model\": \"opus\", \"restamp_model\": \"opus\"},
                \"adversarial\": {\"model\": \"opus\", \"restamp_model\": \"opus\"}}},
  \"local\": {\"runner\": \"pi\", \"mode\": \"inline\", \"subagents\": false, \"model\": \"glm-5.3-flash\"},
  \"ollama\": {\"runner\": \"custom\", \"mode\": \"adapter\", \"subagents\": false,
    \"runner_cmd\": \"$CUSTOM\", \"model\": \"qwen3-coder:480b-cloud\", \"stage_timeout_s\": 60}}"
CFG_PROFILES="{\"agents\": {$PROFILES}}"
# Today's per-role Claude routing, written without profiles.
CFG_PLAIN='{"agents": {"model": "sonnet", "roles": {"planner": {"model": "opus"},
  "security": {"model": "opus", "restamp_model": "opus"},
  "adversarial": {"model": "opus", "restamp_model": "opus"}}}}'

# ═══ 1. TALOS_PROFILE switches every role to one runner and one model ════════
reset
set_cfg "$CFG_PROFILES"
out="$(TALOS_PROFILE=local bash "$AGENT" --resolve-all 2>"$ERR")"; rc=$?
assert_eq "0" "$rc" "TALOS_PROFILE=local: --resolve-all exits 0"
assert_contains "$(printf '%s\n' "$out" | head -n 1)" "profile=local profile_origin=env" "TALOS_PROFILE=local: the header names the active profile and its origin (env)"
assert_eq "9" "$(printf '%s\n' "$out" | role_rows | wc -l | tr -d ' ')" "TALOS_PROFILE=local: still one row per role"
for r in $ROLES; do
  row="$(printf '%s\n' "$out" | grep "^role=$r ")"
  assert_contains "$row" "model=glm-5.3-flash" "TALOS_PROFILE=local: $r runs the single model"
  assert_contains "$row" "runner=pi" "TALOS_PROFILE=local: $r runs on pi"
done
case "$out" in
  *opus* | *sonnet*) fail "TALOS_PROFILE=local: no Claude model id anywhere in the output" "$out" ;;
  *) pass "TALOS_PROFILE=local: no Claude model id anywhere in the output" ;;
esac
assert_eq "runner=pi runner_cmd= model=glm-5.3-flash effort=" "$(TALOS_PROFILE=local bash "$AGENT" --resolve security 2>/dev/null)" "TALOS_PROFILE=local: --resolve security shows pi and the single model"

# The profile's roles block REPLACES the base roles: no model id leaks from base.
set_cfg '{"agents": {"roles": {"security": {"model": "opus"}},
  "profile": "local", "profiles": {"local": {"runner": "pi", "model": "glm-5.3-flash", "roles": {}}}}}'
assert_contains "$(bash "$AGENT" --resolve-all 2>/dev/null | grep '^role=security ')" "model=glm-5.3-flash" "roles block: a profile roles block replaces the base roles (no opus leak)"
set_cfg '{"agents": {"roles": {"security": {"model": "opus"}},
  "profile": "local", "profiles": {"local": {"runner": "pi", "model": "glm-5.3-flash"}}}}'
assert_contains "$(bash "$AGENT" --resolve-all 2>/dev/null | grep '^role=security ')" "model=opus" "roles block: a profile with no roles key keeps the base roles"

# Without TALOS_PROFILE the config's agents.profile (claude) gives today's routing.
set_cfg "$CFG_PROFILES"
profiled_all="$(bash "$AGENT" --resolve-all 2>"$ERR")"
profiled="$(printf '%s\n' "$profiled_all" | role_rows)"
set_cfg "$CFG_PLAIN"
plain="$(bash "$AGENT" --resolve-all 2>/dev/null | role_rows)"
assert_eq "$plain" "$profiled" "TALOS_PROFILE unset: agents.profile=claude routes every role exactly like the same config without profiles"
assert_contains "$(printf '%s\n' "$profiled_all" | head -n 1)" "profile=claude profile_origin=config" "TALOS_PROFILE unset: the header names the profile and its origin (config)"

# Resolution order: env -> selected profile -> base agents.* -> table default.
set_cfg '{"agents": {"runner": "codex", "model": "base-model", "effort": "low",
  "profile": "p", "profiles": {"p": {"model": "profile-model"}}}}'
assert_eq "runner=codex runner_cmd= model=profile-model effort=low" "$(bash "$AGENT" --resolve developer 2>/dev/null)" "order: a profile key beats base, base fills what the profile leaves out"

# ═══ 2. No profile configured: behaviour is untouched ════════════════════════
reset
set_cfg "$CFG_PLAIN"
out="$(CLAUDECODE=1 bash "$AGENT" --resolve-all 2>"$ERR")"
assert_eq "9" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "no profiles: --resolve-all has exactly the nine role rows (no header line)"
assert_eq "0" "$(wc -c < "$ERR" | tr -d ' ')" "no profiles: nothing on stderr"
assert_eq "0" "$(CLAUDECODE=1 bash "$CONFIG" --dump 2>/dev/null | tr '\0' '\n' | grep -c '^sources.profile\|^sources.harness')" "no profiles: --dump carries no profile or harness keys, even inside Claude Code"
env_plain="$(CLAUDECODE=1 bash "$TALOS" env 2>/dev/null)"
assert_eq "0" "$(printf '%s\n' "$env_plain" | grep -c '^HARNESS\|^PROFILE\|^AGENTS_MODE')" "no profiles: talos.sh env prints no harness or profile lines, even inside Claude Code"

# ═══ 3. An unknown profile fails closed with one reason line ═════════════════
reset
set_cfg "$CFG_PROFILES"
TALOS_PROFILE=nope bash "$AGENT" --resolve-all >"$SANDBOX/out.txt" 2>"$ERR"; rc=$?
assert_eq "yes" "$(nonzero "$rc")" "unknown TALOS_PROFILE: --resolve-all exits non-zero"
assert_eq "0" "$(wc -c < "$SANDBOX/out.txt" | tr -d ' ')" "unknown TALOS_PROFILE: nothing is resolved on stdout"
assert_eq "1" "$(grep -c 'reason=profile-unknown' "$ERR")" "unknown TALOS_PROFILE: exactly one reason line"
assert_contains "$(cat "$ERR")" "valid=claude,local,ollama" "unknown TALOS_PROFILE: the line names the valid profiles"
assert_contains "$(cat "$ERR")" "origin=env" "unknown TALOS_PROFILE: the line names where the name came from"
TALOS_PROFILE=nope bash "$CONFIG" agents.runner >/dev/null 2>"$ERR"; rc=$?
assert_eq "4" "$rc" "unknown TALOS_PROFILE: pipeline-config.sh KEY exits 4"
TALOS_PROFILE=nope bash "$CONFIG" --dump >/dev/null 2>"$ERR"; rc=$?
assert_eq "4" "$rc" "unknown TALOS_PROFILE: pipeline-config.sh --dump exits 4"
TALOS_PROFILE=nope bash "$TALOS" env >"$SANDBOX/out.txt" 2>"$ERR"; rc=$?
assert_eq "yes" "$(nonzero "$rc")" "unknown TALOS_PROFILE: talos.sh env stops"
assert_contains "$(cat "$SANDBOX/out.txt")" "stop reason=config-unreadable" "unknown TALOS_PROFILE: talos.sh env prints a stop line"
assert_contains "$(cat "$ERR")" "reason=profile-unknown" "unknown TALOS_PROFILE: talos.sh env relays the reason line"
set_cfg '{"agents": {"profile": "typo", "profiles": {"claude": {"model": "sonnet"}}}}'
bash "$CONFIG" --dump >/dev/null 2>"$ERR"; rc=$?
assert_eq "4" "$rc" "unknown agents.profile: --dump exits 4"
assert_contains "$(cat "$ERR")" "origin=config valid=claude" "unknown agents.profile: the line names the config origin and the valid profile"
rm -f talos.pipeline.json
TALOS_PROFILE=anything bash "$CONFIG" --dump >/dev/null 2>"$ERR"; rc=$?
assert_eq "4" "$rc" "TALOS_PROFILE with no config at all: fails closed too"
assert_contains "$(cat "$ERR")" "valid=none" "TALOS_PROFILE with no config at all: valid=none"
# A script that reads config through the cache never runs on the defaults of a failed load.
set_cfg "$CFG_PROFILES"
TALOS_PROFILE=nope bash "$AGENT" developer "task" >/dev/null 2>"$ERR"; rc=$?
assert_eq "yes" "$(nonzero "$rc")" "unknown TALOS_PROFILE: a stage run exits non-zero"
assert_eq "0" "$(wc -l < "$RUNNER_LOG" | tr -d ' ')" "unknown TALOS_PROFILE: no runner is started"

# ═══ 4. Harness x mode matrix ════════════════════════════════════════════════
reset
set_cfg '{"agents": {"profile": "claude", "profiles": {
  "claude": {"mode": "native", "model": "sonnet"},
  "adapt":  {"runner": "codex", "mode": "adapter", "model": "gpt-x"},
  "inl":    {"runner": "pi", "mode": "inline", "model": "glm"}}}}'
# Claude Code provides all three modes.
for p in claude adapt inl; do
  assert_eq "$p" "$(dump_get sources.profile CLAUDECODE=1 TALOS_PROFILE=$p)" "matrix: Claude Code provides profile $p"
done
# TALOS_HARNESS=pi: no native subagent tool; adapter and inline are fine.
assert_eq "adapt" "$(dump_get sources.profile TALOS_HARNESS=pi TALOS_PROFILE=adapt)" "matrix: pi provides adapter mode"
assert_eq "inl" "$(dump_get sources.profile TALOS_HARNESS=pi TALOS_PROFILE=inl)" "matrix: pi provides inline mode"
TALOS_HARNESS=pi TALOS_PROFILE=claude bash "$CONFIG" --dump >/dev/null 2>"$ERR"; rc=$?
assert_eq "4" "$rc" "matrix: pi cannot provide a native profile and nothing else is usable: fails closed"
assert_eq "1" "$(grep -c 'reason=profile-unusable' "$ERR")" "matrix: the failure is one reason line"
assert_contains "$(cat "$ERR")" "claude:mode-native-unsupported-by-pi" "matrix: the line says why the native profile was skipped"
# No harness at all: unknown, so no mode is refused.
assert_eq "claude" "$(dump_get sources.profile)" "matrix: with no harness detected a native profile is not refused"
assert_eq "unknown" "$(dump_get sources.harness)" "matrix: no harness is reported as unknown"
# TALOS_HARNESS wins over an inherited CLAUDECODE=1 (pi started inside Claude Code).
assert_eq "adapt" "$(dump_get sources.profile CLAUDECODE=1 TALOS_HARNESS=pi TALOS_PROFILE=adapt)" "matrix: TALOS_HARNESS wins over CLAUDECODE"
assert_eq "pi" "$(dump_get sources.harness CLAUDECODE=1 TALOS_HARNESS=pi TALOS_PROFILE=adapt)" "matrix: and is the reported harness"
TALOS_HARNESS=pi CLAUDECODE=1 TALOS_PROFILE=claude bash "$CONFIG" --dump >/dev/null 2>"$ERR"; rc=$?
assert_eq "4" "$rc" "matrix: an inherited CLAUDECODE=1 does not make a pi session native"
# A TALOS_HARNESS that is not a name is ignored with one line; detection still applies.
err="$(TALOS_HARNESS='Bad Name!' CLAUDECODE=1 bash "$CONFIG" --dump 2>&1 >/dev/null)"
assert_contains "$err" "TALOS_HARNESS is not a harness name" "matrix: an unusable TALOS_HARNESS is reported"
assert_eq "claude-code" "$(dump_get sources.harness TALOS_HARNESS='Bad Name!' CLAUDECODE=1 2>/dev/null)" "matrix: and ignored in favour of detection"
# A mode-less profile adapts to the harness instead of being refused.
set_cfg '{"agents": {"profile": "p", "profiles": {"p": {"model": "m"}}}}'
assert_eq "p" "$(dump_get sources.profile TALOS_HARNESS=pi)" "matrix: a profile with no mode is usable under pi"

# Fallback profiles: the first usable profile in [profile, ...fallback] wins.
set_cfg '{"agents": {"profile": "claude", "fallback": ["inl", "adapt"], "profiles": {
  "claude": {"mode": "native", "model": "sonnet"},
  "adapt":  {"runner": "codex", "mode": "adapter", "model": "gpt-x"},
  "inl":    {"runner": "pi", "mode": "inline", "model": "glm"}}}}'
assert_eq "claude" "$(dump_get sources.profile CLAUDECODE=1)" "pick: a usable requested profile is kept"
assert_eq "config" "$(dump_get sources.profile_origin CLAUDECODE=1)" "pick: and keeps origin config"
assert_eq "inl" "$(dump_get sources.profile TALOS_HARNESS=pi)" "pick: under pi the first usable fallback profile is used"
assert_eq "fallback" "$(dump_get sources.profile_origin TALOS_HARNESS=pi)" "pick: a fallback pick reports origin fallback"
assert_eq "claude:mode-native-unsupported-by-pi" "$(dump_get sources.profile_skipped TALOS_HARNESS=pi)" "pick: the skipped profile carries one reason"
assert_eq "glm" "$(TALOS_HARNESS=pi bash "$CONFIG" agents.model 2>/dev/null)" "pick: the picked fallback profile's keys are the effective config"
assert_eq "pi" "$(TALOS_HARNESS=pi bash "$CONFIG" agents.runner 2>/dev/null)" "pick: and its runner"
# The runner CLI must be on PATH: a profile whose CLI is missing is skipped.
mkdir -p "$SANDBOX/bin-claude-only"
ln -s "$STUBS_DIR/claude" "$SANDBOX/bin-claude-only/claude"
NOPI="$SANDBOX/bin-claude-only:/usr/bin:/bin"
PATH="$NOPI" TALOS_HARNESS=pi bash "$CONFIG" --dump >/dev/null 2>"$ERR"; rc=$?
assert_eq "4" "$rc" "cli: pi and codex off PATH and the native profile unsupported: fails closed"
assert_contains "$(cat "$ERR")" "inl:runner-pi-not-on-path" "cli: the reason names the missing CLI"
assert_contains "$(cat "$ERR")" "adapt:runner-codex-not-on-path" "cli: every skipped profile is listed"
assert_eq "1" "$(grep -c 'reason=profile-unusable' "$ERR")" "cli: still one reason line"

# ═══ 5. talos.sh env reports the harness and the profiles ════════════════════
reset
set_cfg '{"agents": {"profile": "claude", "fallback": ["local"], "profiles": {
  "claude": {"mode": "native", "model": "sonnet"},
  "local":  {"runner": "pi", "mode": "inline", "model": "glm"},
  "gone":   {"runner": "gemini", "mode": "adapter", "model": "g"}}}}'
out="$(CLAUDECODE=1 bash "$TALOS" env 2>"$ERR")"
assert_eq "claude-code" "$(env_get "$out" HARNESS)" "env: CLAUDECODE=1 is reported as the harness claude-code"
assert_eq "detected" "$(env_get "$out" HARNESS_ORIGIN)" "env: and its origin is detected"
assert_eq "claude" "$(env_get "$out" PROFILE)" "env: the requested profile is active under Claude Code"
assert_eq "config" "$(env_get "$out" PROFILE_ORIGIN)" "env: its origin is config"
assert_eq "native" "$(env_get "$out" AGENTS_MODE)" "env: AGENTS_MODE is the profile's mode"
assert_eq "0" "$(printf '%s\n' "$out" | grep -c '^PROFILE_SKIPPED=')" "env: nothing skipped under Claude Code"
out="$(TALOS_HARNESS=pi bash "$TALOS" env 2>"$ERR")"
assert_eq "pi" "$(env_get "$out" HARNESS)" "env: TALOS_HARNESS=pi is reported as the harness"
assert_eq "env" "$(env_get "$out" HARNESS_ORIGIN)" "env: and its origin is env"
assert_eq "local" "$(env_get "$out" PROFILE)" "env: pi cannot run the native profile, so the fallback profile is active"
assert_eq "fallback" "$(env_get "$out" PROFILE_ORIGIN)" "env: and the origin says fallback"
assert_eq "inline" "$(env_get "$out" AGENTS_MODE)" "env: AGENTS_MODE is inline"
assert_eq "claude reason=mode-native-unsupported-by-pi" "$(env_get "$out" PROFILE_SKIPPED)" "env: the skipped profile has exactly one reason line"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^PROFILE_SKIPPED=')" "env: one PROFILE_SKIPPED line"
assert_contains "$(printf '%s\n' "$out" | grep '^PROFILE_INFO=local ')" "mode=inline runner=pi cli=present usable=yes" "env: the report says the runner CLI is installed"
assert_contains "$(printf '%s\n' "$out" | grep '^PROFILE_INFO=claude ')" "usable=no" "env: the native profile is reported unusable under pi"
assert_eq "pi" "$(env_get "$out" agent.developer.runner)" "env: the per-role runner follows the active profile"
assert_eq "glm" "$(env_get "$out" agent.developer.model)" "env: the per-role model follows the active profile"
out="$(PATH="$NOPI" CLAUDECODE=1 bash "$TALOS" env 2>/dev/null)"
assert_contains "$(printf '%s\n' "$out" | grep '^PROFILE_INFO=gone ')" "cli=missing usable=no" "env: a profile whose runner CLI is not installed is reported cli=missing"
assert_contains "$(printf '%s\n' "$out" | grep '^PROFILE_INFO=claude ')" "cli=present usable=yes" "env: and one whose CLI is installed cli=present"

# A profile name with upper case, - and _ is a fallback entry like any other.
set_cfg '{"agents": {"fallback": ["Big-Local_1"], "profiles": {"Big-Local_1": {"runner": "pi", "model": "m"}}}}'
assert_eq "Big-Local_1" "$(env_get "$(bash "$TALOS" env 2>/dev/null)" agent.developer.fallback)" "env: a profile name is shown in the per-role fallback chain"
assert_eq "runner=claude runner_cmd= model= effort= fallback=Big-Local_1" "$(bash "$AGENT" --resolve developer 2>/dev/null)" "resolve: fallback= lists a profile name"

# agents.subagents: auto resolves from the harness, not from agents.runner.
reset
set_cfg '{"agents": {"runner": "claude", "subagents": "auto"}}'
assert_eq "native" "$(env_get "$(TALOS_HARNESS=claude-code bash "$TALOS" env 2>/dev/null)" AGENTS_MODE)" "auto: Claude Code harness -> native"
assert_eq "adapter" "$(env_get "$(TALOS_HARNESS=pi bash "$TALOS" env 2>/dev/null)" AGENTS_MODE)" "auto: runner claude but a pi harness -> not native (adapter)"
set_cfg '{"agents": {"runner": "pi", "subagents": "auto"}}'
assert_eq "inline" "$(env_get "$(TALOS_HARNESS=pi bash "$TALOS" env 2>/dev/null)" AGENTS_MODE)" "auto: runner pi on a pi harness -> inline"
assert_eq "native" "$(env_get "$(TALOS_HARNESS=claude-code bash "$TALOS" env 2>/dev/null)" AGENTS_MODE)" "auto: the harness decides, not agents.runner (Claude Code + runner pi -> native)"
set_cfg '{"agents": {"runner": "claude", "subagents": false}}'
assert_eq "adapter" "$(env_get "$(TALOS_HARNESS=claude-code bash "$TALOS" env 2>/dev/null)" AGENTS_MODE)" "explicit subagents: false stays adapter"
set_cfg '{"agents": {"runner": "claude", "mode": "inline"}}'
assert_eq "inline" "$(env_get "$(TALOS_HARNESS=claude-code bash "$TALOS" env 2>/dev/null)" AGENTS_MODE)" "an explicit agents.mode wins over inference"
rm -f talos.pipeline.json
assert_eq "native" "$(env_get "$(TALOS_HARNESS=claude-code bash "$TALOS" env 2>/dev/null)" AGENTS_MODE)" "auto with no config at all: Claude Code harness -> native"
assert_eq "pi" "$(env_get "$(TALOS_HARNESS=pi bash "$TALOS" env 2>/dev/null)" HARNESS)" "env: TALOS_HARNESS alone (no config) is reported"

# ═══ 6. Config surface: keys, validators, --dump, --show ═════════════════════
reset
set_cfg "$CFG_PROFILES"
assert_eq "" "$(bash "$CONFIG" --dump 2>&1 >/dev/null)" "config: the example profiles warn about nothing"
assert_eq "" "$(bash "$CONFIG" agents.runner 2>&1 >/dev/null)" "config: a single-key lookup warns about nothing"
assert_eq "ollama" "$(dump_get sources.profile TALOS_PROFILE=ollama)" "dump: sources.profile is the active profile"
assert_eq "env" "$(dump_get sources.profile_origin TALOS_PROFILE=ollama)" "dump: sources.profile_origin is env"
assert_eq "ollama" "$(dump_get agents.profile TALOS_PROFILE=ollama)" "dump: agents.profile is the active profile"
assert_eq "custom" "$(dump_get agents.runner TALOS_PROFILE=ollama)" "dump: the profile's runner is the effective agents.runner"
assert_eq "adapter" "$(dump_get agents.mode TALOS_PROFILE=ollama)" "dump: the profile's mode is agents.mode"
assert_eq "60" "$(dump_get agents.stage_timeout_s TALOS_PROFILE=ollama)" "dump: the profile's stage_timeout_s is the effective one"
assert_eq "claude,local,ollama" "$(dump_get sources.profiles)" "dump: sources.profiles lists the configured profiles"
assert_eq "qwen3-coder:480b-cloud" "$(dump_get profile.ollama.model)" "dump: every profile's resolved keys are available as profile.<name>.<key>"
assert_eq "opus" "$(dump_get profile.claude.roles.security.model)" "dump: including its role overrides"
# show_row <key>: the one `--show` row of exactly that key.
show_row() { awk -F'\t' -v k="$1" '$1 == k' ; }
show_local="$(TALOS_PROFILE=local bash "$CONFIG" --show agents. 2>/dev/null)"
assert_eq "$(printf 'agents.profile\tlocal\tenv')" "$(printf '%s\n' "$show_local" | show_row agents.profile)" "show: agents.profile shows the active profile and the env layer"
assert_eq "$(printf 'agents.profile\tclaude\trepo')" "$(bash "$CONFIG" --show agents. 2>/dev/null | show_row agents.profile)" "show: agents.profile from the repo file is layer repo"
assert_eq "$(printf 'agents.runner\tpi\trepo')" "$(printf '%s\n' "$show_local" | show_row agents.runner)" "show: a key decided by a profile defined in the repo file is layer repo"

# agents.profile and agents.mode are table keys; TALOS_PROFILE is the env column.
. "$TALOS_ROOT/scripts/pipeline-defaults.sh"
assert_contains "$(_talos_defaults_keys)" "agents.profile" "table: agents.profile is a key"
assert_contains "$(_talos_defaults_keys)" "agents.mode" "table: agents.mode is a key"
assert_eq "TALOS_PROFILE" "$(_talos_scope_env_json | python3 -I -c 'import json,sys; print([e[2] for e in json.load(sys.stdin) if e[0]=="agents.profile"][0])')" "table: TALOS_PROFILE is the env column of agents.profile"

# Typos inside a profile warn; valid agents.* keys inside one do not.
set_cfg '{"agents": {"profiles": {"p": {"modle": "x", "model": "m", "roles": {"qa": {"effort": "low"}}}}}}'
err="$(bash "$CONFIG" --dump 2>&1 >/dev/null)"
assert_contains "$err" "unknown config key 'agents.profiles.p.modle'" "unknown-key: a typo inside a profile is reported"
assert_eq "1" "$(printf '%s\n' "$err" | grep -c 'unknown config key')" "unknown-key: only the typo is reported"
set_cfg '{"agents": {"profiles": {"p": {"profile": "q"}}}}'
assert_contains "$(bash "$CONFIG" --dump 2>&1 >/dev/null)" "agents.profiles.p.profile" "unknown-key: a profile cannot select a profile"
# An invalid mode is dropped with a warning; an invalid name is ignored with one.
set_cfg '{"agents": {"profile": "p", "profiles": {"p": {"mode": "swarm", "model": "m"}, "bad name!": {"model": "x"}}}}'
err="$(bash "$CONFIG" --dump 2>&1 >/dev/null)"
assert_contains "$err" "mode must be native, adapter or inline" "mode: an invalid mode warns"
assert_contains "$err" "profile name" "name: an invalid profile name warns"
assert_eq "" "$(bash "$CONFIG" agents.mode 2>/dev/null)" "mode: an invalid mode reads as unset"
# Layers: a user-level profile is selectable from the repo's agents.profile.
reset
mkdir -p "$SANDBOX/userhome"
printf '{"agents": {"profiles": {"home": {"runner": "pi", "model": "from-user"}}}}\n' > "$SANDBOX/userhome/talos.pipeline.json"
set_cfg '{"agents": {"profile": "home"}}'
assert_eq "from-user" "$(TALOS_HOME="$SANDBOX/userhome" bash "$CONFIG" agents.model 2>/dev/null)" "layers: a profile defined in the user-level file is selectable from the repo file"
assert_eq "$(printf 'agents.model\tfrom-user\tglobal')" "$(TALOS_HOME="$SANDBOX/userhome" bash "$CONFIG" --show agents. 2>/dev/null | show_row agents.model)" "layers: its keys are layer global in --show"

# ═══ 7. Fallback entries may name a profile ══════════════════════════════════
reset
set_cfg '{"agents": {"fallback": ["ollama"], "profiles": {"ollama": {"runner": "custom", "runner_cmd": "x", "model": "m"}}}}'
assert_eq "ollama" "$(bash "$CONFIG" agents.fallback 2>/dev/null)" "fallback: a profile name is a valid entry"
assert_eq "" "$(bash "$CONFIG" --dump 2>&1 >/dev/null)" "fallback: a profile-name entry warns about nothing"
set_cfg '{"agents": {"fallback": ["ollama", "codex"]}}'
assert_eq "D" "$(bash "$CONFIG" agents.fallback D 2>/dev/null)" "fallback: an unknown profile name is rejected (no such profile)"
assert_contains "$(bash "$CONFIG" agents.fallback D 2>&1 >/dev/null)" "or profile names" "fallback: the warning mentions profile names"
set_cfg '{"agents": {"fallback": ["codex", "gemini"]}}'
assert_eq "codex
gemini" "$(bash "$CONFIG" agents.fallback 2>/dev/null)" "fallback: bare runner names are accepted exactly as before"

# A fallback profile carries its model.
reset
export TALOS_ISSUE=5
set_cfg "{\"agents\": {\"runner\": \"claude\", \"model\": \"sonnet\", \"fallback\": [\"ollama\"], \"profiles\": {
  \"ollama\": {\"runner\": \"custom\", \"mode\": \"adapter\", \"runner_cmd\": \"$CUSTOM\", \"model\": \"qwen3-coder:480b-cloud\"}}}}"
OUT="$(STUB_CLAUDE_EXIT=75 bash "$AGENT" developer "the task" 2>"$ERR")"; RC=$?
assert_eq "0" "$RC" "fallback profile: the stage ends on the profile runner's exit code"
assert_eq "custom-ok" "$OUT" "fallback profile: only the profile runner's stdout reaches the caller"
assert_eq "1" "$(runner_calls CLAUDE)" "fallback profile: the primary ran once"
assert_eq "model=qwen3-coder:480b-cloud role=developer" "$(cat "$MODEL_OUT")" "fallback profile: the runner is told the profile's model (TALOS_MODEL)"
assert_contains "$(cat "$ERR")" "talos:failover role=developer from=claude to=ollama reason=provider:exit75" "fallback profile: the switch names the profile"
assert_eq "custom" "$(event_field stage_complete runner)" "fallback profile: the stage event names the runner that ran"
assert_eq "qwen3-coder:480b-cloud" "$(event_field stage_complete model)" "fallback profile: the stage event records the profile's model"

# The profile's stage_timeout_s bounds its attempt.
reset
export TALOS_ISSUE=5
set_cfg "{\"agents\": {\"fallback\": [\"ollama\"], \"profiles\": {
  \"ollama\": {\"runner\": \"custom\", \"runner_cmd\": \"$CUSTOM\", \"model\": \"m\", \"stage_timeout_s\": 60}}}}"
OUT="$(STUB_CLAUDE_EXIT=75 STUB_CUSTOM_SLEEP=20 TALOS_STAGE_TIMEOUT_DIVISOR=30 bash "$AGENT" developer "the task" 2>"$ERR")"; RC=$?
assert_eq "124" "$RC" "fallback profile: the profile's stage_timeout_s kills a hung attempt (exit 124)"
assert_contains "$(cat "$ERR")" "pipeline-agent: reason=stage-timeout role=developer after_s=2" "fallback profile: the timeout line carries the profile's bound"
# A role override inside the profile beats the profile's model.
reset
export TALOS_ISSUE=5
set_cfg "{\"agents\": {\"fallback\": [\"ollama\"], \"profiles\": {
  \"ollama\": {\"runner\": \"custom\", \"runner_cmd\": \"$CUSTOM\", \"roles\": {\"developer\": {\"model\": \"dev-model\"}}, \"model\": \"base-m\"}}}}"
STUB_CLAUDE_EXIT=75 bash "$AGENT" developer "t" >/dev/null 2>&1
STUB_CLAUDE_EXIT=75 bash "$AGENT" qa "t" >/dev/null 2>&1
assert_eq "model=dev-model role=developer
model=base-m role=qa" "$(cat "$MODEL_OUT")" "fallback profile: a role override inside the profile beats its model"

# A fallback profile whose mode this harness cannot provide is skipped, not attempted.
reset
export TALOS_ISSUE=5
set_cfg "{\"agents\": {\"fallback\": [\"nat\", \"ollama\"], \"profiles\": {
  \"nat\": {\"runner\": \"codex\", \"mode\": \"native\", \"model\": \"x\"},
  \"ollama\": {\"runner\": \"custom\", \"runner_cmd\": \"$CUSTOM\", \"model\": \"m\"}}}}"
OUT="$(TALOS_HARNESS=pi STUB_CLAUDE_EXIT=75 bash "$AGENT" developer "t" 2>"$ERR")"; RC=$?
assert_eq "0" "$RC" "fallback skip: the chain continues past the unsupported profile"
assert_eq "0" "$(runner_calls CODEX)" "fallback skip: the unsupported profile's runner was never started"
assert_contains "$(cat "$ERR")" "from=nat to=ollama reason=mode-native-unsupported-by-pi" "fallback skip: one reason line names the profile and why"
assert_eq "model=m role=developer" "$(cat "$MODEL_OUT")" "fallback skip: the next profile ran"
reset
export TALOS_ISSUE=5
set_cfg "{\"agents\": {\"fallback\": [\"nat\"], \"profiles\": {
  \"nat\": {\"runner\": \"codex\", \"mode\": \"native\", \"model\": \"x\"}}}}"
OUT="$(CLAUDECODE=1 STUB_CLAUDE_EXIT=75 bash "$AGENT" developer "t" 2>"$ERR")"; RC=$?
assert_eq "1" "$(runner_calls CODEX)" "fallback skip: under Claude Code the same profile is attempted"

# Legacy runner-name fallback: unchanged, the runner's own default model.
reset
export TALOS_ISSUE=5
set_cfg '{"agents": {"model": "sonnet", "runner_args": ["--primary-only"], "fallback": ["codex"], "profiles": {"unused": {"model": "m"}}}}'
OUT="$(STUB_CLAUDE_EXIT=75 bash "$AGENT" developer "the task" 2>"$ERR")"; RC=$?
assert_eq "0" "$RC" "legacy fallback: a bare runner name still fails over"
assert_eq "codex-stub-ok" "$OUT" "legacy fallback: the runner ran"
assert_eq "1" "$(runner_calls CODEX)" "legacy fallback: codex ran once"
case "$(grep '^CODEX ARGS' "$RUNNER_LOG")" in
  *--primary-only*) fail "legacy fallback: runner_args are not forwarded" ;;
  *) pass "legacy fallback: runner_args are not forwarded" ;;
esac
assert_eq "<none>" "$(event_field stage_complete model)" "legacy fallback: the event model is null on a bare-runner fallback"
assert_contains "$(cat "$ERR")" "talos:failover role=developer from=claude to=codex reason=provider:exit75" "legacy fallback: the switch line is unchanged"

# A stage run under a profile uses that profile's runner.
reset
export TALOS_ISSUE=5
set_cfg "$CFG_PROFILES"
OUT="$(TALOS_PROFILE=local bash "$AGENT" developer "the task" 2>"$ERR")"; RC=$?
assert_eq "0" "$RC" "stage: a run under TALOS_PROFILE=local succeeds"
assert_eq "1" "$(runner_calls PI)" "stage: the profile's runner (pi) ran"
assert_eq "0" "$(runner_calls CLAUDE)" "stage: claude did not run"
assert_contains "$(cat "$ERR")" "talos:runner role=developer runner=pi" "stage: the runner marker shows pi"
assert_eq "glm-5.3-flash" "$(event_field stage_complete model)" "stage: the stage event records the profile's model"

# ═══ 8. A profile whose runner is marked down is passed over (#418 tracking) ═
PROV="$SANDBOX/.talos/providers.json"
# mark_down <runner> <seconds from now, negative = expired> <class:detail>
mark_down() {
  mkdir -p "$SANDBOX/.talos"
  python3 -I - "$PROV" "$1" "$2" "$3" <<'PYEOF'
import datetime, json, sys
path, runner, secs, reason = sys.argv[1:5]
fmt = "%Y-%m-%dT%H:%M:%SZ"
now = datetime.datetime.now(datetime.timezone.utc)
until = (now + datetime.timedelta(seconds=int(secs))).strftime(fmt)
try:
    data = json.load(open(path))
except Exception:
    data = {}
data[runner] = {"down_until": until, "reason": reason, "since": now.strftime(fmt)}
json.dump(data, open(path, "w"))
print(until)
PYEOF
}
reset
set_cfg '{"agents": {"profile": "claude", "fallback": ["local"], "profiles": {
  "claude": {"model": "sonnet"},
  "local":  {"runner": "pi", "mode": "inline", "model": "glm"}}}}'
assert_eq "claude" "$(dump_get sources.profile)" "down: nothing marked down -> the requested profile"
until_ts="$(mark_down claude 600 provider:quota)"
assert_eq "local" "$(dump_get sources.profile)" "down: the requested profile's runner is down and unexpired -> the fallback profile"
assert_eq "fallback" "$(dump_get sources.profile_origin)" "down: and the origin says fallback"
want_reason="provider-down until=$until_ts reason=provider:quota"
assert_eq "claude:$want_reason" "$(dump_get sources.profile_skipped)" "down: the skip carries one reason with the expiry and the recorded class:detail"
bash "$AGENT" --resolve-all >"$SANDBOX/out.txt" 2>"$ERR"
assert_contains "$(cat "$ERR")" "profile 'claude' skipped: $want_reason" "down: --resolve-all warns with the reason line"
assert_eq "pi" "$(bash "$CONFIG" agents.runner 2>/dev/null)" "down: the fallback profile's keys are the effective config"
out="$(bash "$TALOS" env 2>/dev/null)"
assert_eq "local" "$(env_get "$out" PROFILE)" "down: talos.sh env reports the fallback profile"
assert_eq "claude reason=$want_reason" "$(env_get "$out" PROFILE_SKIPPED)" "down: and the skipped profile with its reason"
# A down mark on a runner no candidate uses changes nothing.
reset
set_cfg '{"agents": {"profile": "claude", "fallback": ["local"], "profiles": {
  "claude": {"model": "sonnet"},
  "local":  {"runner": "pi", "mode": "inline", "model": "glm"}}}}'
mark_down codex 600 provider:429 >/dev/null
assert_eq "claude" "$(dump_get sources.profile)" "down: a different runner being down changes nothing"
# Expired: usable again.
mark_down claude -60 provider:quota >/dev/null
assert_eq "claude" "$(dump_get sources.profile)" "down: an expired mark is usable"
assert_eq "" "$(dump_get sources.profile_skipped)" "down: and nothing is skipped"
# Corrupt file: nothing down, with the existing reader's one warning.
printf '{not json' > "$PROV"
assert_eq "claude" "$(dump_get sources.profile)" "down: a corrupt providers.json reads as nothing down"
assert_eq "1" "$(bash "$CONFIG" --dump 2>&1 >/dev/null | grep -c 'unreadable or corrupt')" "down: with the existing warning, once"
# Every harness-usable candidate down: the first is used anyway, not a stop.
mark_down claude 600 provider:quota >/dev/null
mark_down pi 600 provider:429 >/dev/null
assert_eq "claude" "$(dump_get sources.profile)" "down: all usable candidates down -> the requested one is still used"
assert_eq "" "$(dump_get sources.profile_skipped)" "down: and it is not reported as skipped"
# A down fallback is skipped in favour of the next usable one.
reset
set_cfg '{"agents": {"profile": "claude", "fallback": ["local", "ollama"], "profiles": {
  "claude": {"model": "sonnet"},
  "local":  {"runner": "pi", "model": "glm"},
  "ollama": {"runner": "codex", "model": "q"}}}}'
mark_down claude 600 provider:quota >/dev/null
mark_down pi 600 provider:overloaded >/dev/null
assert_eq "ollama" "$(dump_get sources.profile)" "down: a down fallback is passed over for the next usable profile"
assert_eq "2" "$(dump_get sources.profile_skipped | awk 'END { print NR }')" "down: both passed-over profiles are listed"
# No profile configured and no harness: providers.json is never read.
reset
set_cfg "$CFG_PLAIN"
mark_down claude 600 provider:quota >/dev/null
assert_eq "" "$(bash "$CONFIG" --dump 2>&1 >/dev/null)" "down: a run without profiles ignores providers.json"

finish
