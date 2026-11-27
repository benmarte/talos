#!/usr/bin/env bash
# test-pipeline-agent-browser.sh -- qa.browser: a browser for the qa and
# developer stages (#1095). `claude -p --setting-sources project` loads no
# user-level MCP server, so Talos passes its own pinned config.
#   AC3 playwright + claude runner: --mcp-config <talos>/templates/mcp/playwright.json
#       and mcp__playwright for qa and developer; off (the default): neither
#   AC4 a repo .mcp.json defining playwright: no second server, tools still allowed
#   AC5 the shipped config pins an exact @playwright/mcp version
#   AC7 a role-level claude_allowed_tools rule reaches the QA dispatch argv
# Against the claude stub (argv recorded in $RUNNER_LOG).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs
install_talos

AGENT="$HOME/.talos/scripts/pipeline-agent.sh"
INSTALL="$(cd "$HOME/.talos" && pwd)"
MCP="$INSTALL/templates/mcp/playwright.json"
PROJ="$SANDBOX/proj"
mkdir -p "$PROJ" && cd "$PROJ" || exit 1
export RUNNER_LOG="$SANDBOX/runner.log"
set_cfg() { printf '%s\n' "$1" > talos.pipeline.json; }
run_role() {
  : > "$RUNNER_LOG"
  bash "$AGENT" "$1" "the task text" >/dev/null 2>"$SANDBOX/agent.err" </dev/null
  ARGV="$(grep '^[A-Z]* ARGS' "$RUNNER_LOG" | head -n 1)"
}
has() { assert_contains "$ARGV" "[$1]" "$2"; }
hasnt() { assert_not_contains "$ARGV" "[$1]" "$2"; }

ON='{"qa": {"browser": "playwright"}}'

# ── AC3 ──────────────────────────────────────────────────────────────────────
set_cfg "$ON"
for r in qa developer; do
  run_role "$r"
  assert_contains "$ARGV" "[--mcp-config] [$MCP] [--" "AC3 $r: --mcp-config names the shipped config, and a flag follows it"
  has "mcp__playwright" "AC3 $r: mcp__playwright is allowed"
done
assert_file_exists "$MCP" "AC3 install.sh --global ships the config"
for r in reviewer docs validator security pm; do
  run_role "$r"
  hasnt "--mcp-config" "AC3 $r: no MCP config"
  hasnt "mcp__playwright" "AC3 $r: no browser tools"
done
for cfg_json in '{}' '{"qa": {"browser": "off"}}' '{"qa": {"browser": "chrome"}}'; do
  set_cfg "$cfg_json"
  for r in qa developer; do
    run_role "$r"
    hasnt "--mcp-config" "AC3 $r $cfg_json: no MCP config"
    hasnt "mcp__playwright" "AC3 $r $cfg_json: no browser tools"
  done
done
set_cfg '{"qa": {"browser": "playwright"}, "agents": {"runner": "codex"}}'
run_role qa
assert_not_contains "$ARGV" "mcp" "AC3 another runner gets no MCP flag"
set_cfg '{"qa": {"browser": "playwright"}, "agents": {"runner_args": "--dangerously-skip-permissions"}}'
run_role qa
has "$MCP" "AC3 the browser is configured when runner_args owns the permissions"

# ── AC4 ──────────────────────────────────────────────────────────────────────
set_cfg "$ON"
printf '{"mcpServers": {"playwright": {"command": "npx", "args": ["my-server"]}}}\n' > .mcp.json
for r in qa developer; do
  run_role "$r"
  hasnt "--mcp-config" "AC4 $r: the repo's playwright server gets no second one"
  has "mcp__playwright" "AC4 $r: its tools are still allowed"
done
printf '{"mcpServers": {"other": {"command": "x"}}}\n' > .mcp.json
run_role qa
has "$MCP" "AC4 a .mcp.json without playwright still gets Talos's config"
printf 'not json\n' > .mcp.json
run_role qa
has "$MCP" "AC4 an unreadable .mcp.json counts as defining nothing"
rm -f .mcp.json

# ── AC5 ──────────────────────────────────────────────────────────────────────
pin="$(python3 -I -c '
import json, re, sys
args = json.load(open(sys.argv[1]))["mcpServers"]["playwright"]["args"]
pkgs = [a for a in args if a.startswith("@playwright/mcp")]
ok = len(pkgs) == 1 and re.fullmatch(r"@playwright/mcp@\d+\.\d+\.\d+", pkgs[0])
tail = " ".join(args[args.index(pkgs[0]) + 1:]) if pkgs else ""
print("exact" if ok else "not exact: %s" % pkgs)
print(tail)
' "$TALOS_ROOT/templates/mcp/playwright.json" 2>&1)"
assert_eq "exact" "$(printf '%s\n' "$pin" | head -n 1)" "AC5 one @playwright/mcp argument, pinned to an exact version"
for flag in "--headless" "--isolated" "--output-dir .talos/qa-shots"; do
  assert_contains "$(printf '%s\n' "$pin" | tail -n 1)" "$flag" "AC5 the server runs with $flag"
done

# ── AC7 ──────────────────────────────────────────────────────────────────────
ROLE_CFG='"agents": {"claude_allowed_tools": ["Bash(global-tool:*)"], "roles": {"qa": {"claude_allowed_tools": ["Bash(xcrun simctl:*)"]}}}'
set_cfg "{$ROLE_CFG}"
run_role qa
has "Bash(xcrun simctl:*)" "AC7 the QA role rule reaches the QA dispatch argv"
hasnt "Bash(global-tool:*)" "AC7 the role list replaces the global one"
set_cfg "{\"qa\": {\"browser\": \"playwright\"}, $ROLE_CFG}"
run_role qa
has "Bash(xcrun simctl:*)" "AC7 with the browser on, the role rule still reaches QA"
has "mcp__playwright" "AC7 a role list does not drop the browser rule"

finish
