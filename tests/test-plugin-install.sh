#!/usr/bin/env bash
# Regression tests for the marketplace-plugin install path (#35).
#
# A marketplace install copies the plugin into ~/.claude/plugins/cache/<mp>/<name>/<ver>/
# and exports CLAUDE_PLUGIN_ROOT to point at it. The target repo gets NOTHING except
# the config the user writes — no .claude/talos/, no .claude/agents/. Before 0.6.0
# that combination could not work: the role definitions were not shipped by the
# plugin at all, and every script path in the playbook resolved against the repo.
#
# These tests model that layout exactly: a plugin cache dir holding a copy of the
# Talos tree, and a target repo containing only talos.pipeline.yml.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

# ── Build a fake plugin cache, mirroring what a marketplace install produces ──
PLUGIN_ROOT="$SANDBOX/plugin-cache/talos/talos/0.6.0"
mkdir -p "$PLUGIN_ROOT"
for d in scripts agents templates skills; do
  cp -R "$TALOS_ROOT/$d" "$PLUGIN_ROOT/$d"
done
cp "$TALOS_ROOT/.claude-plugin/plugin.json" "$PLUGIN_ROOT/plugin.json" 2>/dev/null || true

# The repo the user runs /pipeline in: config only, nothing vendored.
REPO="$SANDBOX/bare-repo"
mkdir -p "$REPO"
cd "$REPO"
git init -q
git remote add origin git@github.com:acme/widget.git
# Config format: pipeline-config.sh parses YAML with PyYAML and falls back to
# json.load for everything else, so on a runner without PyYAML every YAML read
# silently returns the default. test-config.sh handles that by skipping its yaml
# cases; here the config is incidental — what is under test is WHERE it resolves
# from — so write the .json variant instead and keep full coverage on both
# platforms. Both names are in pipeline-config.sh's candidate list.
if python3 -c "import yaml" 2>/dev/null; then
  CFG_NAME="talos.pipeline.yml"
  cat > "$CFG_NAME" <<'EOF'
repo: acme/widget
base_branch: dev
vcs:
  provider: github
notifications:
  templates_dir: "templates/notifications"
agents:
  runner: custom
  runner_cmd: "cat"
EOF
else
  CFG_NAME="talos.pipeline.json"
  cat > "$CFG_NAME" <<'EOF'
{
  "repo": "acme/widget",
  "base_branch": "dev",
  "vcs": { "provider": "github" },
  "notifications": { "templates_dir": "templates/notifications" },
  "agents": { "runner": "custom", "runner_cmd": "cat" }
}
EOF
fi

assert_file_absent "$REPO/.claude/talos" "target repo has no vendored install"
assert_file_absent "$REPO/.claude/agents" "target repo has no repo-level agents"

# ── 1. The plugin must actually ship the role definitions ────────────────────
# Claude Code loads plugin agents from agents/ in the PLUGIN ROOT. Talos kept
# them in .claude/agents/, which is the plugin repo's own config and is not
# exported — so a marketplace install shipped /pipeline with none of the eight
# subagents it spawns.
for agent in validator pm developer qa reviewer security docs planner; do
  assert_file_exists "$PLUGIN_ROOT/agents/$agent.md" "plugin ships $agent role at agents/"
done

# Every role must be able to invoke skills (#37). Five of the eight had no Skill
# tool, so an installed skill pack — agent-skills, or Claude Code's own
# code-review/security-review — was unreachable from those stages no matter what
# the profile said. The dependency was never the problem; the tool grant was.
for agent in validator pm developer qa reviewer security docs planner; do
  tools_line="$(grep -E '^tools:' "$PLUGIN_ROOT/agents/$agent.md" || true)"
  case "$tools_line" in
    *Skill*) pass "$agent can invoke skills" ;;
    *)       fail "$agent can invoke skills" "tools: $tools_line" ;;
  esac
done

# Every role must actually direct the model to use skills, not merely tolerate
# them. As of 0.8.0 agent-skills is a hard dependency, so "if available" hedging
# would leave the guarantee unused.
# Bodies are hard-wrapped, so a phrase can straddle a newline — normalise
# whitespace before matching or these assertions fail on prose reflow alone.
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

for agent in validator pm developer qa reviewer security docs planner; do
  body="$(flat "$PLUGIN_ROOT/agents/$agent.md")"
  case "$body" in
    *"do not restate them"*) pass "$agent directs the model to use skills" ;;
    *) fail "$agent directs the model to use skills" "no mandatory skills clause" ;;
  esac
done

# ...but every profile must still carry a fallback. The dependency only applies
# to the PLUGIN install; a vendored install.sh copy does not pull agent-skills,
# so the skills may genuinely be absent and the mandate needs an exit.
#
# The fallback must NOT claim other harnesses lack skills. agent-skills ships
# .gemini/, .opencode/, .codex-plugin/ and an AGENTS.md naming Antigravity — it
# is not Claude-Code-only, and 0.8.0's wording said otherwise (#41).
for agent in validator pm developer qa reviewer security docs planner; do
  body="$(flat "$PLUGIN_ROOT/agents/$agent.md")"
  case "$body" in
    *"no skill mechanism"*) pass "$agent carries a skills fallback" ;;
    *) fail "$agent carries a skills fallback" "mandate with no fallback" ;;
  esac
  case "$body" in
    *"without skill support (Codex"*)
      fail "$agent does not claim other harnesses lack skills" "repeats the 0.8.0 error" ;;
    *) pass "$agent does not claim other harnesses lack skills" ;;
  esac
done

# The dependency must be declared, and the marketplace must catalogue it —
# otherwise `dependencies` resolves to nothing installable and enabling talos
# FAILS for anyone who does not already have agent-skills. The two halves are
# only correct together.
if python3 -c "
import json,sys
d=json.load(open('$TALOS_ROOT/.claude-plugin/plugin.json'))
deps=[x if isinstance(x,str) else x.get('name') for x in d.get('dependencies',[])]
sys.exit(0 if 'agent-skills' in deps else 1)
" 2>/dev/null; then
  pass "manifest declares agent-skills as a dependency"
else
  fail "manifest declares agent-skills as a dependency"
fi

if python3 -c "
import json,sys
m=json.load(open('$TALOS_ROOT/.claude-plugin/marketplace.json'))
e=[p for p in m['plugins'] if p['name']=='agent-skills']
assert e, 'agent-skills not catalogued'
src=e[0]['source']
assert src.get('source')=='github' and src.get('repo')=='addyosmani/agent-skills', src
" 2>/dev/null; then
  pass "marketplace catalogues agent-skills so the dependency can auto-install"
else
  fail "marketplace catalogues agent-skills so the dependency can auto-install"
fi

# The catalogue entry must point upstream, never at a vendored copy — Talos does
# not fork agent-skills, and a relative source would mean it had.
if grep -q '"repo": "addyosmani/agent-skills"' "$TALOS_ROOT/.claude-plugin/marketplace.json"; then
  pass "agent-skills is sourced upstream, not vendored"
else
  fail "agent-skills is sourced upstream, not vendored"
fi

# ── 2. Scripts resolve from the plugin root ──────────────────────────────────
# This is the resolution the SKILL.md instructs the orchestrator to perform.
resolved=""
for d in "${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/scripts" .claude/talos/scripts scripts; do
  [ -f "$d/pipeline-vcs.sh" ] && { resolved="$d"; break; }
done
assert_eq "$PLUGIN_ROOT/scripts" "$resolved" "script resolution lands on the plugin root"

# ── 3. pipeline-agent.sh finds the role via CLAUDE_PLUGIN_ROOT ───────────────
# The config sets runner: custom / runner_cmd: cat, so the composed prompt comes
# back on stdout and we can assert the role body was actually loaded rather than
# silently skipped.
out_agent="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash "$PLUGIN_ROOT/scripts/pipeline-agent.sh" validator "TASK: check issue 42" 2>&1)"
assert_contains "$out_agent" "TASK: check issue 42" "pipeline-agent composes the task prompt"
assert_not_contains "$out_agent" "role definition not found" \
  "pipeline-agent resolves the role from the plugin root"

# Without CLAUDE_PLUGIN_ROOT it must still work from the plugin layout itself
# (script at <plugin>/scripts/, agents at <plugin>/agents/) — harnesses that
# invoke the script directly do not always export the variable.
out_noenv="$(bash "$PLUGIN_ROOT/scripts/pipeline-agent.sh" validator "TASK: no env" 2>&1)"
assert_not_contains "$out_noenv" "role definition not found" \
  "pipeline-agent resolves the role from its own layout without the env var"

# A repo-level profile overrides the plugin's, so a project can replace one role
# without forking Talos. The orchestrator playbook makes the same choice for
# native subagents; these two must not diverge.
mkdir -p "$REPO/.claude/agents"
printf -- '---\nname: validator\n---\nREPO OVERRIDE MARKER\n' > "$REPO/.claude/agents/validator.md"
out_override="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash "$PLUGIN_ROOT/scripts/pipeline-agent.sh" validator "TASK: y" 2>&1)"
assert_contains "$out_override" "REPO OVERRIDE MARKER" \
  "repo-level role profile overrides the plugin's"

# ...and only for the role that was overridden.
out_other="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash "$PLUGIN_ROOT/scripts/pipeline-agent.sh" reviewer "TASK: z" 2>&1)"
assert_not_contains "$out_other" "REPO OVERRIDE MARKER" \
  "non-overridden roles still come from the plugin"
rm -rf "$REPO/.claude/agents"

# A genuinely missing role must still fail loudly, and name where it looked.
out_missing="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash "$PLUGIN_ROOT/scripts/pipeline-agent.sh" nosuchrole "TASK: x" 2>&1 || true)"
assert_contains "$out_missing" "role definition not found" "unknown role still fails loudly"
assert_contains "$out_missing" "CLAUDE_PLUGIN_ROOT" "failure names the plugin path it checked"

# ── 4. Notification templates resolve from the plugin root ───────────────────
# pipeline-notify.sh derives its template dir from the script's own location, so
# the plugin layout must land on <plugin>/templates/. Without this, every
# notification silently degrades to plain text.
export PIPELINE_DEBUG=1
out_notify="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash "$PLUGIN_ROOT/scripts/pipeline-notify.sh" validator "#42" "CONFIRMED: real bug" 42 2>&1)"
assert_not_contains "$out_notify" "template not found" "notify finds templates from the plugin root"

# ── 5. Config still comes from the REPO, never the plugin ────────────────────
# The plugin ships its own talos.pipeline.yml (Talos's own config). If config
# resolution ever followed the script location, every install would inherit
# Talos's settings instead of the user's.
got_repo="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash "$PLUGIN_ROOT/scripts/pipeline-config.sh" repo "none")"
assert_eq "acme/widget" "$got_repo" "config reads the target repo, not the plugin"

got_base="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash "$PLUGIN_ROOT/scripts/pipeline-config.sh" base_branch "none")"
assert_eq "dev" "$got_base" "config base_branch comes from the target repo"

# ── 6. The manifest must be valid and free of misleading fields ──────────────
# Two separate traps, both of which shipped in 0.5.0:
#   "scripts": "scripts/"  — not a recognized field. Claude Code ignores
#       unrecognized top-level fields, so it read like it wired the scripts up
#       and did precisely nothing.
#   "skills": ["skills/pipeline", ...] — `skills` names DIRECTORIES TO SCAN for
#       <name>/SKILL.md, not individual skill dirs. As written it failed schema
#       validation outright, and skills/ is the default scan path anyway.
if python3 -c "
import json,sys
d=json.load(open('$TALOS_ROOT/.claude-plugin/plugin.json'))
sys.exit(0 if 'scripts' not in d else 1)
" 2>/dev/null; then
  pass "plugin.json carries no no-op scripts field"
else
  fail "plugin.json carries no no-op scripts field"
fi

for s in pipeline pipeline-setup; do
  assert_file_exists "$TALOS_ROOT/skills/$s/SKILL.md" \
    "$s skill sits in the default skills/ scan path"
done

# NOTE: `claude plugin validate` is asserted in test-install.sh, not here —
# use_stubs puts tests/stubs/claude first on PATH, so running it in this file
# would validate against the stub and pass unconditionally.

finish
