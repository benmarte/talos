#!/usr/bin/env bash
# Tests for `pipeline-agent.sh --resolve-all` (#336): one line per role showing
# the model, the re-stamp model and which config layer decided it, plus a
# warning for a role file that still carries a frontmatter `model:` line. Also
# pins that `--resolve <role>` output did not change.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

AGENT_SH="$TALOS_ROOT/scripts/pipeline-agent.sh"
USER_DIR="$HOME/.talos"
ERR="$SANDBOX/stderr"
ROLES="validator pm developer qa reviewer security adversarial docs planner"

reset_cfg() {
  rm -rf "$USER_DIR" "$SANDBOX"/talos.pipeline.* "$SANDBOX/.claude" "$HOME/.claude"
  unset PIPELINE_CONFIG TALOS_HOME CLAUDE_CONFIG_DIR
  mkdir -p "$USER_DIR"
}
user_json() { printf '%s' "$1" > "$USER_DIR/talos.pipeline.json"; }
proj_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }
all() { bash "$AGENT_SH" --resolve-all 2>"$ERR"; }
line_for() { printf '%s\n' "$1" | grep "^role=$2 " ; }

# ── AC9: one line per role, all nine, in a stable order ──────────────────────
reset_cfg
user_json '{"agents": {"model": "sonnet", "roles": {"security": {"model": "opus"}}}}'
proj_json '{"agents": {"roles": {"qa": {"model": "haiku", "restamp_model": "sonnet"}}}}'
out="$(all)"; rc=$?
assert_eq "0" "$rc" "AC9: --resolve-all exits 0"
assert_eq "9" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "AC9: exactly one line per role (nine)"
got_roles="$(printf '%s\n' "$out" | sed 's/^role=\([a-z]*\) .*/\1/' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "$ROLES" "$got_roles" "AC9: all nine roles listed in pipeline order"
assert_eq "role=qa model=haiku restamp_model=sonnet origin=project" "$(line_for "$out" qa)" "AC9: project role model + role re-stamp -> origin project"
assert_eq "role=security model=opus restamp_model=sonnet origin=global" "$(line_for "$out" security)" "AC9: user-level role model -> origin global"
assert_eq "role=docs model=sonnet restamp_model=sonnet origin=global" "$(line_for "$out" docs)" "AC9: role with no key falls to user-level agents.model -> origin global"

# project agents.model decides -> project
reset_cfg
user_json '{"agents": {"model": "sonnet"}}'
proj_json '{"agents": {"model": "haiku"}}'
assert_eq "role=pm model=haiku restamp_model=haiku origin=project" "$(line_for "$(all)" pm)" "AC9: project agents.model overrides the user-level one -> origin project"

# nothing configured anywhere -> session default
reset_cfg
rm -rf "$USER_DIR"
out="$(all)"
assert_eq "9" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "AC9: nine lines with no config at all"
assert_eq "role=developer model= restamp_model= origin=session default" "$(line_for "$out" developer)" "AC9: no model anywhere -> origin session default"

# re-stamp chain across layers: role -> global re-stamp -> agents.model
reset_cfg
user_json '{"agents": {"model": "sonnet", "restamp_model": "haiku"}}'
proj_json '{"agents": {"roles": {"docs": {"restamp_model": "opus"}}}}'
out="$(all)"
assert_eq "role=docs model=sonnet restamp_model=opus origin=global" "$(line_for "$out" docs)" "AC9: role re-stamp from the project layer"
assert_eq "role=qa model=sonnet restamp_model=haiku origin=global" "$(line_for "$out" qa)" "AC9: global re-stamp from the user-level layer"

# ── AC9: leftover frontmatter model: line is warned about ────────────────────
reset_cfg
user_json '{"agents": {"model": "sonnet"}}'
all >/dev/null
assert_eq "0" "$(wc -c < "$ERR" | tr -d ' ')" "AC9: no warning when no role file carries model:"
mkdir -p "$SANDBOX/.claude/agents" "$HOME/.claude/agents"
printf -- '---\nname: qa\nmodel: opus\ntools: Read\n---\nbody\n' > "$SANDBOX/.claude/agents/qa.md"
printf -- '---\nname: docs\nmodel: haiku\n---\nbody\n' > "$HOME/.claude/agents/docs.md"
printf -- '---\nname: pm\ntools: Read\n---\nA body line:\nmodel: opus\n' > "$SANDBOX/.claude/agents/pm.md"
all >/dev/null
err="$(cat "$ERR")"
assert_contains "$err" "/.claude/agents/qa.md still sets model:" "AC9: warns about a repo role file with model:"
assert_contains "$err" "$HOME/.claude/agents/docs.md" "AC9: warns about a ~/.claude role file with model:"
assert_not_contains "$err" "pm.md" "AC9: a model: line in the body (not frontmatter) is not flagged"
assert_eq "2" "$(printf '%s\n' "$err" | grep -c 'model:')" "AC9: one warning per offending file"
assert_eq "0" "$(printf '%s\n' "$(all)" | grep -c 'warn')" "AC9: warnings go to stderr, not stdout"
CLAUDE_CONFIG_DIR="$SANDBOX/cc" bash "$AGENT_SH" --resolve-all >/dev/null 2>"$ERR"
assert_not_contains "$(cat "$ERR")" "$HOME/.claude/agents/docs.md" "AC9: \$CLAUDE_CONFIG_DIR replaces ~/.claude when set"

# ── AC10: --resolve <role> output unchanged, byte for byte ───────────────────
reset_cfg
proj_json '{"agents": {"model": "opus", "effort": "high", "runner": "custom", "runner_cmd": "cat", "roles": {"qa": {"model": "haiku", "runner": "codex"}}}}'
assert_eq "runner=custom runner_cmd=cat model=opus effort=high" "$(bash "$AGENT_SH" --resolve developer 2>/dev/null)" "AC10: --resolve output format unchanged (global values)"
assert_eq "runner=codex runner_cmd=cat model=haiku effort=high" "$(bash "$AGENT_SH" --resolve qa 2>/dev/null)" "AC10: --resolve output format unchanged (role override)"
reset_cfg
rm -rf "$USER_DIR"
assert_eq "runner=claude runner_cmd= model= effort=" "$(bash "$AGENT_SH" --resolve qa 2>/dev/null)" "AC10: --resolve output unchanged with no config"
bash "$AGENT_SH" --resolve 2>/dev/null; assert_eq "2" "$?" "AC10: --resolve with no role still exits 2"

finish
