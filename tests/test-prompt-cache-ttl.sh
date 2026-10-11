#!/usr/bin/env bash
# tests/test-prompt-cache-ttl.sh -- the 1-hour prompt cache for the two roles
# that wait on a test suite, developer and QA (#603).
#
#   AC1  agents/developer.md and agents/qa.md ask for it in their frontmatter
#        (experimental: / cacheTtl: 1h); the other seven agents do not
#   AC2  an install ships that frontmatter, and no runner's prompt carries it
#   AC3  the claude runner starts `claude` with CLAUDE_CODE_PROMPT_CACHE_TTL=1h
#        for those two roles, on both dispatch arms
#   AC4  only for them, only on the claude runner, and never over a value the
#        caller already set
#   AC5  install.sh --global names subagentPromptCacheTtl in one line when the
#        Claude adapter runs, and writes no setting
#   AC6  docs/reference.md has one section on prompt cache lifetime
#
# Everything runs against the stub CLIs in tests/stubs/ in a sandbox HOME: no
# real model CLI, no real Claude config.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
# The caller's own value must not answer for Talos (a stage of a real run has it).
unset CLAUDE_CODE_PROMPT_CACHE_TTL

ROLES="validator pm developer qa reviewer security adversarial docs planner"
TTL_ROLES="developer qa"

# frontmatter <file> -- the lines between the two `---` lines.
frontmatter() { awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {exit} fm' "$1"; }
# ttl_requests <file> -- how many times the frontmatter has an `experimental:`
# line directly followed by an indented `cacheTtl: 1h` line.
ttl_requests() {
  frontmatter "$1" | awk 'prev == "experimental:" && /^[ ]+cacheTtl: 1h$/ {n++} {prev = $0} END {print n + 0}'
}
# body_of <file> -- everything after the frontmatter.
body_of() { sed '1,/^---$/d' "$1"; }

# ═══ AC1: the shipped frontmatter ═══════════════════════════════════════════
for role in $ROLES; do
  f="$TALOS_ROOT/agents/$role.md"
  fm="$(frontmatter "$f")"
  case " $TTL_ROLES " in
    *" $role "*)
      assert_eq "1" "$(ttl_requests "$f")" "AC1 agents/$role.md has experimental: followed by an indented cacheTtl: 1h"
      rest="$(printf '%s\n' "$fm" | grep -v -e '^experimental:$' -e '^[ ]\{1,\}cacheTtl: 1h$')"
      ;;
    *)
      assert_not_contains "$fm" "experimental" "AC1 agents/$role.md has no experimental in its frontmatter"
      assert_not_contains "$fm" "cacheTtl" "AC1 agents/$role.md has no cacheTtl in its frontmatter"
      rest="$fm"
      ;;
  esac
  # Besides the cache request the frontmatter is the same three keys as before.
  assert_eq "name description tools" "$(printf '%s\n' "$rest" | awk -F: '{printf "%s%s", (NR > 1 ? " " : ""), $1}')" \
    "AC1 agents/$role.md keeps exactly name:, description: and tools:"
  assert_contains "$rest" "name: $role" "AC1 agents/$role.md keeps its name: line"
  if printf '%s\n' "$rest" | grep -Eq '^description: .+' && printf '%s\n' "$rest" | grep -Eq '^tools: .+'; then
    pass "AC1 agents/$role.md keeps a description: and a tools: value"
  else
    fail "AC1 agents/$role.md keeps a description: and a tools: value" "frontmatter: $rest"
  fi
done

# ═══ AC5 / AC2: the three installs ══════════════════════════════════════════
# install_out <install.sh args...> -- output in $OUT_TXT, exit code in $RC.
install_out() { OUT_TXT="$(bash "$TALOS_ROOT/install.sh" "$@" </dev/null 2>&1)"; RC=$?; }
ttl_lines() { printf '%s\n' "$OUT_TXT" | grep -c 'subagentPromptCacheTtl'; }
# json_with_ttl -- every *.json under the sandbox home that names a cache TTL setting.
json_with_ttl() { find "$HOME" -name '*.json' -exec grep -l 'CacheTtl' {} +; }

install_out --global --no-agent-skills --harness pi
assert_eq "0" "$RC" "AC5 install.sh --global --harness pi exits 0"
assert_eq "0" "$(ttl_lines)" "AC5 install.sh --global --harness pi prints no subagentPromptCacheTtl line"
assert_eq "" "$(json_with_ttl)" "AC5 after the pi install no *.json under the sandbox home contains CacheTtl"

install_out --global --no-agent-skills --harness claude
assert_eq "0" "$RC" "AC5 install.sh --global with the Claude adapter exits 0"
assert_eq "1" "$(ttl_lines)" "AC5 install.sh --global with the Claude adapter prints exactly one subagentPromptCacheTtl line"
ttl_line="$(printf '%s\n' "$OUT_TXT" | grep 'subagentPromptCacheTtl')"
assert_contains "$ttl_line" '"1h"' "AC5 that line contains \"1h\""
assert_contains "$ttl_line" "2.1.242" "AC5 that line contains 2.1.242"
assert_file_exists "$HOME/.claude/settings.json" "AC5 the Claude adapter did write a settings file (the check below reads it)"
assert_eq "" "$(json_with_ttl)" "AC5 after the Claude install no *.json under the sandbox home contains CacheTtl"

for role in $TTL_ROLES; do
  assert_eq "1" "$(ttl_requests "$HOME/.talos/agents/$role.md")" "AC2 the installed agents/$role.md under the Talos home carries cacheTtl: 1h"
done

install_out "$SANDBOX" --no-agent-skills --no-agents-md --harness claude
assert_eq "0" "$RC" "AC5 a per-repo install exits 0"
assert_eq "0" "$(ttl_lines)" "AC5 a per-repo install prints no subagentPromptCacheTtl line"
assert_eq "" "$(json_with_ttl)" "AC5 after the per-repo install no *.json under the sandbox home contains CacheTtl"

# ═══ Stage runs against the stub runners ════════════════════════════════════
use_stubs
AGENT="$HOME/.talos/scripts/pipeline-agent.sh"
ERR="$SANDBOX/agent.stderr"
export RUNNER_LOG="$SANDBOX/runner.log"
export STUB_PROMPT_DIR="$SANDBOX/prompts"
mkdir -p "$STUB_PROMPT_DIR"
# What a runner child saw: `set=<value>` or `unset`. The claude stub evals the
# hook; the custom runner script writes the same line and keeps its stdin.
export TTL_FILE="$SANDBOX/ttl.state"
export CUSTOM_STDIN="$SANDBOX/custom.stdin"
export STUB_CLAUDE_HOOK='printf "%s" "${CLAUDE_CODE_PROMPT_CACHE_TTL+set=}${CLAUDE_CODE_PROMPT_CACHE_TTL-unset}" > "$TTL_FILE"'
cat > "$SANDBOX/custom-runner.sh" <<'RUNNER'
cat > "$CUSTOM_STDIN"
printf '%s' "${CLAUDE_CODE_PROMPT_CACHE_TTL+set=}${CLAUDE_CODE_PROMPT_CACHE_TTL-unset}" > "$TTL_FILE"
RUNNER
CUSTOM_CFG="{\"agents\": {\"runner\": \"custom\", \"runner_cmd\": \"bash $SANDBOX/custom-runner.sh\"}}"

set_cfg() { printf '%s\n' "$1" > talos.pipeline.json; }
# stage <role> -- one stage run; the runner's argv in $RUNNER_LOG, stderr in $ERR.
stage() {
  rm -f "$TTL_FILE" "$CUSTOM_STDIN" "$STUB_PROMPT_DIR"/*.prompt
  : > "$RUNNER_LOG"
  bash "$AGENT" "$1" "the task text" >/dev/null 2>"$ERR"
}
# ttl_seen <role> -- run one stage and print what its runner child saw.
ttl_seen() {
  stage "$1"
  if [ -f "$TTL_FILE" ]; then cat "$TTL_FILE"; else printf 'runner-not-run'; fi
}

# ═══ AC2: no runner's prompt carries the frontmatter ════════════════════════
# check_prompt <role> <runner> <prompt-file>
check_prompt() {
  local _prompt="" _body
  [ ! -f "$3" ] || _prompt="$(cat "$3")"
  _body="$(body_of "$HOME/.talos/agents/$1.md")"
  assert_not_contains "$_prompt" "experimental:" "AC2 the $2 runner's $1 prompt has no experimental:"
  assert_not_contains "$_prompt" "cacheTtl" "AC2 the $2 runner's $1 prompt has no cacheTtl"
  case "$_prompt" in
    "$_body"*) [ -n "$_body" ] && pass "AC2 the $2 runner's $1 prompt still starts with the role body" \
                 || fail "AC2 the $2 runner's $1 prompt still starts with the role body" "empty role body" ;;
    *) fail "AC2 the $2 runner's $1 prompt still starts with the role body" "prompt starts: $(printf '%s' "$_prompt" | head -c 120)" ;;
  esac
}
for role in $TTL_ROLES; do
  set_cfg '{"agents": {"runner": "pi"}}'
  stage "$role"
  check_prompt "$role" pi "$STUB_PROMPT_DIR/pi.prompt"
  set_cfg "$CUSTOM_CFG"
  stage "$role"
  check_prompt "$role" custom "$CUSTOM_STDIN"
done

# ═══ AC3: the claude child of a developer or QA stage, both arms ════════════
for role in $TTL_ROLES; do
  rm -f talos.pipeline.json
  assert_eq "set=1h" "$(ttl_seen "$role")" "AC3 a $role stage with usage capture on starts claude with CLAUDE_CODE_PROMPT_CACHE_TTL=1h"
  assert_contains "$(cat "$RUNNER_LOG")" "[--output-format] [json]" "AC3 that $role run took the --output-format json arm"
  set_cfg '{"agents": {"capture_usage": false}}'
  assert_eq "set=1h" "$(ttl_seen "$role")" "AC3 a $role stage with agents.capture_usage false starts claude with CLAUDE_CODE_PROMPT_CACHE_TTL=1h"
  assert_not_contains "$(cat "$RUNNER_LOG")" "[--output-format]" "AC3 that $role run took the plain arm"
  assert_contains "$(cat "$RUNNER_LOG")" "CLAUDE ARGS: [-p] [--setting-sources] [project]" "AC3 the $role claude argv keeps its shape"
done

# ═══ AC4: only those two roles, only claude, never over the caller's value ══
rm -f talos.pipeline.json
seen=""
for role in $ROLES; do seen="$seen $role=$(ttl_seen "$role")"; done
assert_eq " validator=unset pm=unset developer=set=1h qa=set=1h reviewer=unset security=unset adversarial=unset docs=unset planner=unset" "$seen" \
  "AC4 on the claude runner only developer and qa get the variable; the other seven see it unset"
for role in $TTL_ROLES; do
  assert_eq "set=5m" "$(export CLAUDE_CODE_PROMPT_CACHE_TTL=5m; ttl_seen "$role")" "AC4 a caller value of 5m reaches claude unchanged for $role"
done
set_cfg "$CUSTOM_CFG"
assert_eq "unset" "$(ttl_seen developer)" "AC4 a developer stage on a custom runner sees the variable unset"
rm -f talos.pipeline.json

# ═══ AC6: the reference section ═════════════════════════════════════════════
DOC="$TALOS_ROOT/docs/reference.md"
assert_eq "1" "$(grep -c '^##* Prompt cache lifetime$' "$DOC")" "AC6 docs/reference.md has one section on prompt cache lifetime"
section="$(awk '/^##* Prompt cache lifetime$/ {on = 1; next} on && /^##* / {exit} on' "$DOC")"
for needle in cacheTtl subagentPromptCacheTtl promptCacheTtl CLAUDE_CODE_PROMPT_CACHE_TTL 2.1.248 2.1.242 "usage credits"; do
  assert_contains "$section" "$needle" "AC6 the prompt cache lifetime section names $needle"
done

finish
