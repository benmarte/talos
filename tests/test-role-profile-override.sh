#!/usr/bin/env bash
# Tests for the harness-neutral role override (#367, part of #353):
# $PWD/.agents/talos/agents/<role>.md, read by the adapter (pipeline-agent.sh
# <role> -) and the pi inline path (pipeline-agent.sh --resolve-profile
# <role>) only. Precedence, one function for both:
#   $PWD/.claude/agents/<role>.md
#   $PWD/.agents/talos/agents/<role>.md
#   the install's agents/ (via _resolve_talos_dir)
#   the self-relative fallbacks
#
# Hermetic: make_sandbox gives a sandbox HOME and unsets TALOS_HOME and
# CLAUDE_CONFIG_DIR, the script runs from inside the fixture repo, and the
# "install" is a fake ~/.talos under the sandbox HOME, so a real ~/.talos or
# ~/.claude on the machine running this can never win a step. Every token sits
# in the profile BODY (the adapter strips frontmatter).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

AGENT="$TALOS_ROOT/scripts/pipeline-agent.sh"
export RUNNER_LOG="$SANDBOX/runner.log"
ERR="$SANDBOX/stderr"
# The paths the script prints come from its own $PWD / pwd, which bash
# canonicalises (TMPDIR with a trailing slash gives "T//talos-test.X" in
# $SANDBOX); expected values use the same spelling.
REPO="$(pwd)"
HP="$(cd "$HOME" && pwd)"
OUTSIDE="$SANDBOX/.outside"
mkdir -p "$OUTSIDE"

T_CLAUDE="TOKEN-CLAUDE-DIR-$$"
T_NEUTRAL="TOKEN-NEUTRAL-DIR-$$"
T_TALOS="TOKEN-DOT-TALOS-DIR-$$"
T_INSTALL="TOKEN-INSTALLED-$$"
T_LINK="TOKEN-SYMLINK-TARGET-$$"

# A fake global install: probe position 2 of _resolve_talos_dir.
mkdir -p "$HOME/.talos/scripts" "$HOME/.talos/agents"
: > "$HOME/.talos/scripts/pipeline-vcs.sh"

# put_profile <dir> <role> <token>: frontmatter plus a body carrying the token.
put_profile() {
  mkdir -p "$1"
  printf -- '---\nname: %s\ndescription: fixture\n---\nYou are the fixture. %s\n' "$2" "$3" > "$1/$2.md"
}
NEUTRAL_DIR="$REPO/.agents/talos/agents"
CLAUDE_DIR="$REPO/.claude/agents"
reset_repo() {
  rm -rf "${SANDBOX:?}/.agents" "${SANDBOX:?}/.claude" "${SANDBOX:?}/.talos" "${SANDBOX:?}"/talos.pipeline.*
  put_profile "$HOME/.talos/agents" developer "$T_INSTALL"
}
profile() { bash "$AGENT" --resolve-profile "$@" 2>"$ERR"; }

# ── --resolve-profile: usage and exit codes ──────────────────────────────────
reset_repo
bash "$AGENT" --resolve-profile >/dev/null 2>"$ERR"; rc=$?
assert_eq "2" "$rc" "--resolve-profile with no role exits 2"
assert_contains "$(cat "$ERR")" "Usage: pipeline-agent.sh --resolve-profile <role>" "usage names the verb"

out="$(profile nosuchrole)"; rc=$?
assert_eq "1" "$rc" "no profile anywhere exits 1"
assert_eq "" "$out" "no profile: stdout empty"
err="$(cat "$ERR")"
assert_contains "$err" "role definition not found: nosuchrole" "exit 1 says which role"
assert_contains "$err" "$REPO/.claude/agents/" "exit 1 names the .claude/agents location"
assert_contains "$err" "$REPO/.agents/talos/agents/" "exit 1 names the neutral location"
assert_contains "$err" "$HP/.talos/agents/" "exit 1 names the install location"

# ── Role names reach a path: validated first ─────────────────────────────────
reset_repo
put_profile "$OUTSIDE" secret "$T_LINK"
for bad in "../.outside/secret" "a/b" ".." "-x" "Developer" "1dev" "dev.md" "x y" "dev_1"; do
  out="$(profile "$bad")"; rc=$?
  assert_eq "2" "$rc" "role '$bad' is rejected with exit 2"
  assert_eq "" "$out" "role '$bad': nothing printed"
done
assert_contains "$(cat "$ERR")" "invalid role" "rejection says why"
# Digits and '-' after the first letter are valid role names ([a-z][a-z0-9-]*).
put_profile "$CLAUDE_DIR" dev2-b "TOKEN-DIGIT-ROLE-$$"
out="$(profile dev2-b)"; rc=$?
assert_eq "0" "$rc" "role 'dev2-b' (digit and dash) is accepted"
assert_eq "$CLAUDE_DIR/dev2-b.md" "$out" "role 'dev2-b' resolves to its profile"
: > "$RUNNER_LOG"
printf '{"agents": {"runner": "codex"}}\n' > talos.pipeline.json
bash "$AGENT" "../.outside/secret" "task" >/dev/null 2>"$ERR"; rc=$?
assert_eq "2" "$rc" "stage run with a traversal role exits 2"
assert_eq "" "$(cat "$RUNNER_LOG")" "stage run with a traversal role never reaches the runner"

# ── Only the neutral file: it wins over the install, on every adapter runner ─
reset_repo
put_profile "$NEUTRAL_DIR" developer "$T_NEUTRAL"
out="$(profile developer)"; rc=$?
assert_eq "$NEUTRAL_DIR/developer.md" "$out" "only neutral: --resolve-profile prints the neutral path"
assert_eq "0" "$rc" "only neutral: --resolve-profile exits 0"

printf '{"agents": {"runner": "codex"}}\n' > talos.pipeline.json
: > "$RUNNER_LOG"
bash "$AGENT" developer "task body" >/dev/null 2>"$ERR"
log="$(cat "$RUNNER_LOG")"
assert_contains "$log" "$T_NEUTRAL" "only neutral: the token reaches the codex stub"
assert_not_contains "$log" "$T_INSTALL" "only neutral: the installed profile does not"
assert_not_contains "$log" "name: developer" "only neutral: its frontmatter is stripped"

CUSTOM_OUT="$SANDBOX/custom.stdin"
printf '{"agents": {"runner": "custom", "runner_cmd": "cat > %s"}}\n' "$CUSTOM_OUT" > talos.pipeline.json
rm -f "$CUSTOM_OUT"
bash "$AGENT" developer "task body" >/dev/null 2>"$ERR"
assert_contains "$(cat "$CUSTOM_OUT" 2>/dev/null)" "$T_NEUTRAL" "only neutral: the token reaches runner_cmd stdin (custom)"

# ── Both files: .claude/agents wins ──────────────────────────────────────────
reset_repo
put_profile "$NEUTRAL_DIR" developer "$T_NEUTRAL"
put_profile "$CLAUDE_DIR" developer "$T_CLAUDE"
assert_eq "$CLAUDE_DIR/developer.md" "$(profile developer)" "both: --resolve-profile prints the .claude/agents path"
printf '{"agents": {"runner": "codex"}}\n' > talos.pipeline.json
: > "$RUNNER_LOG"
bash "$AGENT" developer "task body" >/dev/null 2>"$ERR"
log="$(cat "$RUNNER_LOG")"
assert_contains "$log" "$T_CLAUDE" "both: the .claude/agents token arrives"
assert_not_contains "$log" "$T_NEUTRAL" "both: the neutral token does not"
printf '{"agents": {"runner": "custom", "runner_cmd": "cat > %s"}}\n' "$CUSTOM_OUT" > talos.pipeline.json
rm -f "$CUSTOM_OUT"
bash "$AGENT" developer "task body" >/dev/null 2>"$ERR"
got="$(cat "$CUSTOM_OUT" 2>/dev/null)"
assert_contains "$got" "$T_CLAUDE" "both: custom runner gets the .claude/agents token"
assert_not_contains "$got" "$T_NEUTRAL" "both: custom runner does not get the neutral token"

# ── Neither: the installed profile ───────────────────────────────────────────
reset_repo
assert_eq "$HP/.talos/agents/developer.md" "$(profile developer)" "neither: --resolve-profile prints the install path"
printf '{"agents": {"runner": "codex"}}\n' > talos.pipeline.json
: > "$RUNNER_LOG"
bash "$AGENT" developer "task body" >/dev/null 2>"$ERR"
assert_contains "$(cat "$RUNNER_LOG")" "$T_INSTALL" "neither: the installed profile body arrives"

# ── .talos/agents/<role>.md is not read ──────────────────────────────────────
reset_repo
put_profile "$SANDBOX/.talos/agents" developer "$T_TALOS"
assert_eq "$HP/.talos/agents/developer.md" "$(profile developer)" ".talos/agents is not a candidate"
: > "$RUNNER_LOG"
bash "$AGENT" developer "task body" >/dev/null 2>"$ERR"
assert_not_contains "$(cat "$RUNNER_LOG")" "$T_TALOS" ".talos/agents token never arrives"
assert_contains "$(cat "$RUNNER_LOG")" "$T_INSTALL" ".talos/agents present: the installed profile still arrives"

# ── A symlinked neutral file is never followed ───────────────────────────────
reset_repo
put_profile "$OUTSIDE" developer "$T_LINK"
mkdir -p "$NEUTRAL_DIR"
ln -s "$OUTSIDE/developer.md" "$NEUTRAL_DIR/developer.md"
assert_eq "$HP/.talos/agents/developer.md" "$(profile developer)" "symlinked neutral file is skipped"
: > "$RUNNER_LOG"
bash "$AGENT" developer "task body" >/dev/null 2>"$ERR"
assert_not_contains "$(cat "$RUNNER_LOG")" "$T_LINK" "symlinked neutral file: the target token never arrives"
# a symlinked directory on the way is skipped the same
reset_repo
put_profile "$OUTSIDE/agents-dir" developer "$T_LINK"
mkdir -p "$SANDBOX/.agents/talos"
ln -s "$OUTSIDE/agents-dir" "$SANDBOX/.agents/talos/agents"
assert_eq "$HP/.talos/agents/developer.md" "$(profile developer)" "symlinked agents directory is skipped"

# ── --resolve-all: stderr warnings, stdout untouched ─────────────────────────
reset_repo
put_profile "$HOME/.talos/agents" developer "$T_INSTALL"
bash "$AGENT" --resolve-all > "$SANDBOX/all.base" 2>"$ERR"
assert_eq "" "$(cat "$ERR")" "resolve-all: no neutral files, no stderr"

# both files for two roles -> one shadow line per role
reset_repo
for r in developer qa; do
  put_profile "$NEUTRAL_DIR" "$r" "$T_NEUTRAL"
  put_profile "$CLAUDE_DIR" "$r" "$T_CLAUDE"
done
bash "$AGENT" --resolve-all > "$SANDBOX/all.both" 2>"$ERR"
err="$(cat "$ERR")"
assert_eq "2" "$(printf '%s\n' "$err" | grep -c 'shadowed')" "both files: one shadow line per role (two roles, two lines)"
assert_contains "$err" "[warn] $NEUTRAL_DIR/developer.md is shadowed by $CLAUDE_DIR/developer.md" "both files: names the shadowed neutral path (developer)"
assert_contains "$err" "$NEUTRAL_DIR/qa.md is shadowed by" "both files: names the shadowed neutral path (qa)"
assert_not_contains "$err" "does not read" "both files: no native-path warning (the .claude/agents file exists)"
assert_eq "$(cat "$SANDBOX/all.base")" "$(cat "$SANDBOX/all.both")" "both files: --resolve-all stdout is unchanged"

# only neutral + resolved runner claude -> native-path warning, one line per role
reset_repo
for r in developer qa; do put_profile "$NEUTRAL_DIR" "$r" "$T_NEUTRAL"; done
bash "$AGENT" --resolve-all > "$SANDBOX/all.only" 2>"$ERR"
err="$(cat "$ERR")"
assert_eq "2" "$(printf '%s\n' "$err" | grep -c 'native Claude path does not read it')" "only neutral, claude runner: one warning per role"
assert_contains "$err" "$NEUTRAL_DIR/developer.md" "only neutral, claude runner: names the neutral file"
assert_contains "$err" "$REPO/.claude/agents/developer.md" "only neutral, claude runner: names the .claude/agents path to use"
assert_not_contains "$err" "shadowed" "only neutral: no shadow line"
assert_eq "$(cat "$SANDBOX/all.base")" "$(cat "$SANDBOX/all.only")" "only neutral: --resolve-all stdout is unchanged"

# the same, for each condition that silences it
printf '{"agents": {"runner": "codex"}}\n' > talos.pipeline.json
bash "$AGENT" --resolve-all >/dev/null 2>"$ERR"
assert_not_contains "$(cat "$ERR")" "native Claude path" "only neutral, runner codex: no warning"
printf '{"agents": {"subagents": false}}\n' > talos.pipeline.json
bash "$AGENT" --resolve-all >/dev/null 2>"$ERR"
assert_not_contains "$(cat "$ERR")" "native Claude path" "only neutral, claude runner, agents.subagents false: no warning"
printf '{"agents": {"runner": "codex", "roles": {"qa": {"runner": "claude"}}}}\n' > talos.pipeline.json
bash "$AGENT" --resolve-all >/dev/null 2>"$ERR"
err="$(cat "$ERR")"
assert_eq "1" "$(printf '%s\n' "$err" | grep -c 'native Claude path does not read it')" "per-role runner claude over a codex default: one warning"
assert_contains "$err" "$NEUTRAL_DIR/qa.md" "per-role runner claude: the warning is for qa"

# the frontmatter model: scan still covers only the two Claude Code dirs
reset_repo
mkdir -p "$NEUTRAL_DIR"
printf -- '---\nname: developer\nmodel: opus\n---\nbody\n' > "$NEUTRAL_DIR/developer.md"
printf '{"agents": {"runner": "codex"}}\n' > talos.pipeline.json
bash "$AGENT" --resolve-all >/dev/null 2>"$ERR"
assert_not_contains "$(cat "$ERR")" "still sets model:" "a model: line in the neutral file is not warned about (the adapter strips frontmatter)"
printf -- '---\nname: developer\nmodel: opus\n---\nbody\n' > "$SANDBOX/dev.md"
mkdir -p "$CLAUDE_DIR" && cp "$SANDBOX/dev.md" "$CLAUDE_DIR/developer.md"
bash "$AGENT" --resolve-all >/dev/null 2>"$ERR"
assert_contains "$(cat "$ERR")" "$CLAUDE_DIR/developer.md still sets model:" "a model: line in .claude/agents is still warned about"

# ── The playbook states the real order ───────────────────────────────────────
SKILL="$(cat "$TALOS_ROOT/skills/pipeline/SKILL.md")"
inline_step="$(printf '%s\n' "$SKILL" | grep -F 'Find the role profile with')"
assert_contains "$inline_step" 'bash scripts/pipeline-agent.sh --resolve-profile <role>' "pi inline step 1 uses --resolve-profile"
adapter_line="$(printf '%s\n' "$SKILL" | grep -F 'The adapter finds the role definition itself')"
assert_contains "$adapter_line" '`$PWD/.claude/agents/<role>.md`, then `$PWD/.agents/talos/agents/<role>.md`' "adapter sentence states the order"
assert_contains "$SKILL" 'The neutral path (2) applies to the adapter and inline paths only.' "Subagent names section limits the neutral path to adapter and inline"
assert_contains "$(sed -n '1,60p' "$TALOS_ROOT/scripts/pipeline-agent.sh")" '.agents/talos/agents/<role>.md' "script header lists the neutral location"

finish
