#!/usr/bin/env bash
# Tests for install.sh --harness as an open, comma-separated list (#365, part of
# #353) and for the Claude adapter running only when Claude is selected or
# detected. Every install runs under a sandbox HOME inside make_sandbox's
# directory with TALOS_HOME / CLAUDE_CONFIG_DIR unset (or pointed inside it) in
# the SAME command as the installer. Cases that need "no claude on PATH" use a
# stripped PATH of symlinks built in the sandbox, never the ambient PATH.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

INSTALL="$TALOS_ROOT/install.sh"
BASH_BIN="$(command -v bash)"
. "$TALOS_ROOT/scripts/pipeline-contract.sh"

# Every destructive line below is under a HOME created by newhome.
newhome() {
  HOME="$SANDBOX/home-$1"
  export HOME
  case "$HOME" in "$SANDBOX"/*) ;; *) echo "refusing: HOME=$HOME is not inside the sandbox" >&2; exit 1 ;; esac
  rm -rf "$HOME"
  mkdir -p "$HOME"
}

new_repo() {
  mkdir -p "$SANDBOX/$1"
  git -C "$SANDBOX/$1" init -q -b main
  printf '%s' "$SANDBOX/$1"
}

# ── stripped PATH: only the tools the installer and its children need ────────
BIN="$SANDBOX/bin"
mkdir -p "$BIN"
STRIP_OK=true
for tool in bash dirname basename mkdir cp chmod mktemp rm cat grep sed awk env git python3 \
            sort tr cut head tail wc date uname ls ln mv touch readlink find xargs \
            sleep expr diff cmp; do
  t="$(command -v "$tool" 2>/dev/null || true)"
  case "$t" in
    /*) ln -sf "$t" "$BIN/$tool" ;;
    *) case "$tool" in
         bash|dirname|basename|mkdir|cp|chmod|mktemp|rm|cat|grep|env) STRIP_OK=false ;;
       esac ;;
  esac
done
CLAUDE_BIN="$SANDBOX/claude-bin"      # a PATH dir holding only a stub claude
mkdir -p "$CLAUDE_BIN"
printf '#!/bin/sh\nexit 0\n' > "$CLAUDE_BIN/claude"
chmod +x "$CLAUDE_BIN/claude"
if [ "$STRIP_OK" = true ] && [ -z "$(PATH="$BIN" command -v claude 2>/dev/null || true)" ]; then
  CAN_STRIP=true
else
  CAN_STRIP=false
  echo "  -- skipped: cannot build a PATH without claude (stripped-PATH cases)"
fi

# inst <path> <args...> -- run the installer with a controlled PATH, no
# CLAUDE_CONFIG_DIR and no TALOS_HOME. Output in $OUT, status in $RC.
inst() {
  local p="$1"; shift
  OUT="$(env -u CLAUDE_CONFIG_DIR -u TALOS_HOME PATH="$p" "$BASH_BIN" "$INSTALL" "$@" 2>&1)"; RC=$?
}
inst_err() {
  local p="$1"; shift
  ERR="$(env -u CLAUDE_CONFIG_DIR -u TALOS_HOME PATH="$p" "$BASH_BIN" "$INSTALL" "$@" 2>&1 >/dev/null)"; RC=$?
}

assert_claude_tree() {  # $1=config dir $2=label -- cmp-equal to the sources
  local d="$1" label="$2" role name
  for role in validator pm developer qa reviewer security adversarial docs planner; do
    src="$TALOS_ROOT/agents/$role.md"; [ -f "$src" ] || src="$TALOS_ROOT/.claude/agents/$role.md"
    if cmp -s "$src" "$d/agents/$role.md"; then pass "$label: agents/$role.md is cmp-equal"
    else fail "$label: agents/$role.md is cmp-equal"; fi
  done
  # The commands come from the plugin (#335); the adapter's own skills are the
  # two legacy aliases, thin files carrying the alias marker.
  for name in pipeline pipeline-setup; do
    if grep -qxF '<!-- talos:alias -->' "$d/skills/$name/SKILL.md" 2>/dev/null; then pass "$label: skills/$name/SKILL.md is a legacy alias"
    else fail "$label: skills/$name/SKILL.md is a legacy alias"; fi
  done
}

# ── the harness list and the runner ids stay two lists, cross-checked ────────
known="$(sed -n 's/^KNOWN_HARNESSES="\(.*\)"$/\1/p' "$INSTALL")"
assert_eq "claude codex gemini antigravity pi cursor opencode generic" "$known" \
  "install.sh keeps the known harness list from the issue"
for entry in "${TALOS_RUNNERS[@]}"; do
  id="${entry%%|*}"
  [ "$id" = custom ] && continue
  case " $known " in
    *" $id "*) pass "runner $id is a known harness name" ;;
    *) fail "runner $id is a known harness name" ;;
  esac
done
runner_ids=" $(for e in "${TALOS_RUNNERS[@]}"; do printf '%s ' "${e%%|*}"; done)"
R="$(new_repo nextsteps-runners)"
newhome nextsteps
printed=""
for h in codex gemini antigravity pi cursor opencode generic made-up; do
  inst "$PATH" "$R" --no-agent-skills --no-agents-md --harness "$h"
  printed="$printed $(printf '%s\n' "$OUT" | grep -o 'agents\.runner: [a-z]*' | sed 's/agents\.runner: //')"
done
for v in $(printf '%s\n' $printed | sort -u); do
  case "$runner_ids" in
    *" $v "*) pass "runner value printed in Next steps ($v) is a TALOS_RUNNERS id" ;;
    *) fail "runner value printed in Next steps ($v) is a TALOS_RUNNERS id" ;;
  esac
done

# Reverse direction: every known harness is either a runner id or one of the
# named harnesses that have glue but no runner of their own, so a harness added
# to install.sh without a runner is a deliberate edit here.
for h in $known; do
  case "$runner_ids" in
    *" $h "*) pass "known harness $h is a TALOS_RUNNERS id" ;;
    *) case " cursor opencode generic " in
         *" $h "*) pass "known harness $h is a documented harness without a runner" ;;
         *) fail "known harness $h is a TALOS_RUNNERS id or a documented runner-less harness" ;;
       esac ;;
  esac
done

# ── header comment ───────────────────────────────────────────────────────────
inst_src="$(cat "$INSTALL")"
header="$(sed -n '1,/^set -euo/p' "$INSTALL")"
assert_contains "$header" "comma-separated list" "header describes the list"
assert_contains "$header" "install_claude_adapter" "header names the adapter function"
assert_contains "$header" "claude is on PATH" "header describes the PATH detection signal"
assert_contains "$header" "dangling symlink" "header states the dangling-symlink decision"
assert_contains "$header" "--harness claude forces" "header describes the override"

# ── all Claude writes live in install_claude_adapter ─────────────────────────
# install_claude_adapter and the two helpers only it calls are the writers. Any
# other non-comment line naming CLAUDE_DIR / CLAUDE_CONFIG_DIR must be an echo,
# an assignment or a test, never a command that writes. (A same-line grep for
# write verbs misses `dir="$CLAUDE_DIR/skills/x"` followed by `mkdir -p "$dir"`.)
strip_fns() {  # $1... = function names whose bodies are dropped
  awk -v names=" $* " '
    match($0, /^[a-z_]+\(\) \{/) { n = substr($0, 1, RLENGTH - 4); if (index(names, " " n " ")) skip = 1 }
    !skip { print }
    skip && /^\}/ { skip = 0 }
  ' "$INSTALL" | grep -v '^[[:space:]]*#'
}
outside="$(strip_fns install_claude_adapter install_claude_plugin handle_bare_skill)"
stray="$(printf '%s\n' "$outside" | grep -E 'CLAUDE_DIR|CLAUDE_CONFIG_DIR' \
  | grep -Ev '^[[:space:]]*(echo |CLAUDE_DIR=|CLAUDE_ADAPTER=|CLAUDE_WHY=|(el)?if \[ )' || true)"
assert_eq "" "$stray" "nothing outside the Claude adapter functions names CLAUDE_DIR except decisions and echoes"
helper_calls="$(strip_fns install_claude_adapter | grep -E '^[[:space:]]*(install_claude_plugin|handle_bare_skill)[[:space:]]' || true)"
assert_eq "" "$helper_calls" "install_claude_plugin and handle_bare_skill are called only from install_claude_adapter"
if grep -q '^install_claude_adapter() {' "$INSTALL"; then
  pass "install.sh defines install_claude_adapter"
else
  fail "install.sh defines install_claude_adapter"
fi

# ── --harness parsing ────────────────────────────────────────────────────────
newhome parse
for list in codex "codex,pi" "claude,codex,gemini" generic "cursor,opencode"; do
  inst "$PATH" --global --no-agent-skills --harness "$list"
  assert_eq "0" "$RC" "--harness $list exits 0"
  assert_not_contains "$OUT" "unknown harness" "--harness $list: known names are not flagged unknown"
done
inst "$PATH" --global --no-agent-skills --harness "mytool"
assert_eq "0" "$RC" "unknown name mytool exits 0"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c "unknown harness 'mytool'")" "unknown name is named on exactly one line"
assert_contains "$OUT" "agents.runner: custom" "unknown-name line points at agents.runner: custom"
assert_contains "$OUT" "agents.runner_cmd" "unknown-name line points at agents.runner_cmd"
inst "$PATH" --global --no-agent-skills --harness=codex
assert_eq "0" "$RC" "--harness=codex form exits 0"
for bad in "" "codex,,pi" ",codex" "codex," "a b" "Claude" "co_dex" "codex;ls"; do
  inst_err "$PATH" --global --no-agent-skills --harness "$bad"
  assert_eq "1" "$RC" "--harness '$bad' exits 1"
  assert_contains "$ERR" "error:" "--harness '$bad' prints an error on stderr"
done
inst_err "$PATH" --global --no-agent-skills --harness
assert_eq "1" "$RC" "a trailing --harness with no value exits 1"
inst_err "$PATH" --harness --global --no-agent-skills
assert_eq "1" "$RC" "--harness followed by a flag exits 1"
inst_err "$PATH" --global --no-agent-skills --harness=
assert_eq "1" "$RC" "--harness= (empty) exits 1"

# ── epic bullet: --harness codex into an empty HOME ──────────────────────────
newhome codex
inst "$PATH" --global --no-agent-skills --harness codex
assert_eq "0" "$RC" "--global --harness codex exits 0"
assert_file_absent "$HOME/.claude" "--harness codex creates no ~/.claude"
for cmd in "${TALOS_COMMANDS[@]}"; do
  assert_file_exists "$HOME/.talos/skills/$cmd/SKILL.md" "--harness codex installs ~/.talos/skills/$cmd/SKILL.md"
done
assert_contains "$OUT" "Claude Code adapter skipped (not selected" "output says the adapter was skipped and why"
assert_contains "$OUT" "--harness claude forces it" "output says how to force the adapter"
assert_not_contains "$OUT" "Restart any open" "no Claude restart note when the adapter was skipped"
assert_file_exists "$HOME/.talos/agents/developer.md" "the ~/.talos/agents copy is unconditional"
assert_not_contains "$OUT" "is not a current Talos command" "no stale-skill notice on a clean install"

# A directory under ~/.talos/skills/ that is no longer a command gets a notice;
# it is never deleted.
mkdir -p "$HOME/.talos/skills/oldcmd"
printf 'mine\n' > "$HOME/.talos/skills/oldcmd/SKILL.md"
inst "$PATH" --global --no-agent-skills --harness codex
assert_eq "0" "$RC" "a stale ~/.talos/skills/<cmd> does not fail the install"
assert_contains "$OUT" "$HOME/.talos/skills/oldcmd is not a current Talos command" "a stale ~/.talos/skills/<cmd> directory gets a notice"
assert_file_exists "$HOME/.talos/skills/oldcmd/SKILL.md" "the stale directory is never deleted"

# ── explicit list: the adapter runs iff the list contains claude ─────────────
for list in claude "codex,claude" "pi,claude,generic"; do
  newhome "sel-$list"
  inst "$PATH" --global --no-agent-skills --harness "$list"
  assert_eq "0" "$RC" "--harness $list exits 0"
  assert_claude_tree "$HOME/.claude" "--harness $list"
  assert_contains "$OUT" "Claude Code adapter ran (selected" "--harness $list: output says the adapter ran, selected"
  assert_contains "$OUT" "Restart any open" "--harness $list: restart note prints"
done
for list in generic "codex,gemini" mytool; do
  newhome "nosel-$list"
  inst "$PATH" --global --no-agent-skills --harness "$list"
  assert_file_absent "$HOME/.claude" "--harness $list creates no ~/.claude"
done
# An explicit list without claude wins over every detection signal.
newhome explicit-wins
mkdir -p "$HOME/.claude"
inst "$CLAUDE_BIN:$PATH" --global --no-agent-skills --harness codex
assert_file_absent "$HOME/.claude/agents" "--harness codex leaves an existing ~/.claude without agents/"
assert_file_absent "$HOME/.claude/skills" "--harness codex leaves an existing ~/.claude without skills/"

# ── no --harness: detection, one signal at a time (regression guard) ─────────
if [ "$CAN_STRIP" = true ]; then
  newhome nosignal
  inst "$BIN" --global --no-agent-skills
  assert_eq "0" "$RC" "no --harness, no Claude signal: exits 0"
  assert_file_absent "$HOME/.claude" "no --harness, no Claude signal: no ~/.claude is created"
  assert_contains "$OUT" "Claude Code adapter skipped (not detected" "no signal: output says not detected"
  assert_contains "$OUT" "--harness claude forces it" "no signal: output says how to force it"
  assert_file_exists "$HOME/.talos/skills/pipeline/SKILL.md" "no signal: ~/.talos/skills is still installed"
  assert_not_contains "$OUT" "Restart any open" "no signal: no Claude restart note"

  newhome sig-dir
  mkdir -p "$HOME/.claude"
  inst "$BIN" --global --no-agent-skills
  assert_claude_tree "$HOME/.claude" "signal ~/.claude directory alone"
  assert_contains "$OUT" "Claude Code adapter ran (detected: $HOME/.claude exists)" "dir signal: reason is printed"
  assert_contains "$OUT" "Restart any open" "dir signal: restart note prints"

  newhome sig-env
  inst_env_out="$(env -u TALOS_HOME CLAUDE_CONFIG_DIR="$HOME/cfg-does-not-exist-yet" PATH="$BIN" \
    "$BASH_BIN" "$INSTALL" --global --no-agent-skills 2>&1)"
  assert_claude_tree "$HOME/cfg-does-not-exist-yet" "signal CLAUDE_CONFIG_DIR alone (non-existent path)"
  assert_file_absent "$HOME/.claude" "CLAUDE_CONFIG_DIR signal: the default ~/.claude is not touched"
  assert_contains "$inst_env_out" "detected: CLAUDE_CONFIG_DIR is set" "env signal: reason is printed"
  # An empty CLAUDE_CONFIG_DIR is not a signal.
  newhome sig-env-empty
  env -u TALOS_HOME CLAUDE_CONFIG_DIR="" PATH="$BIN" "$BASH_BIN" "$INSTALL" --global --no-agent-skills >/dev/null 2>&1
  assert_file_absent "$HOME/.claude" "an empty CLAUDE_CONFIG_DIR is not a detection signal"

  newhome sig-path
  inst "$BIN:$CLAUDE_BIN" --global --no-agent-skills
  assert_claude_tree "$HOME/.claude" "signal claude on PATH alone"
  assert_contains "$OUT" "detected: claude is on PATH" "PATH signal: reason is printed"

  # Detected, no --harness == --harness claude, file for file.
  newhome same-a
  inst "$BIN" --global --no-agent-skills --harness claude
  cp -R "$HOME/.claude" "$SANDBOX/tree-explicit"
  newhome same-b
  mkdir -p "$HOME/.claude"
  inst "$BIN" --global --no-agent-skills
  if diff -r "$SANDBOX/tree-explicit" "$HOME/.claude" >/dev/null; then
    pass "detected install writes the same ~/.claude tree as --harness claude"
  else
    fail "detected install writes the same ~/.claude tree as --harness claude"
  fi
  rm -rf "${SANDBOX:?}/tree-explicit"

  # Skipped adapter + existing tree: byte-identical, one "not refreshed" line.
  newhome skip-existing
  inst "$BIN" --global --no-agent-skills --harness claude
  printf 'locally edited\n' >> "$HOME/.claude/skills/pipeline/SKILL.md"
  printf 'keep me\n' > "$HOME/.claude/agents/extra.md"
  cp -R "$HOME/.claude" "$SANDBOX/tree-before"
  inst "$BIN" --global --no-agent-skills --harness codex
  assert_eq "0" "$RC" "skipped adapter over an existing tree exits 0"
  if diff -r "$SANDBOX/tree-before" "$HOME/.claude" >/dev/null; then
    pass "existing ~/.claude tree is byte-identical after --harness codex"
  else
    fail "existing ~/.claude tree is byte-identical after --harness codex"
  fi
  assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'was not refreshed')" "exactly one line says the tree was not refreshed"
  assert_contains "$OUT" "bash $TALOS_ROOT/install.sh --global --harness claude" "the not-refreshed line prints the full command to refresh"
  rm -rf "${SANDBOX:?}/tree-before"
fi

# ── per-repo ─────────────────────────────────────────────────────────────────
newhome repo
R="$(new_repo repo-gemini)"
inst "$PATH" "$R" --no-agent-skills --harness gemini
assert_eq "0" "$RC" "per-repo --harness gemini exits 0"
assert_contains "$OUT" "context.fileName" "--harness gemini with no GEMINI.md prints the context.fileName option"
assert_contains "$OUT" "agents.runner: gemini" "gemini: Next steps name the runner"
assert_contains "$OUT" 'gemini "Read ~/.talos/skills/pipeline/SKILL.md and follow it"' "gemini: start line in the docs CLI form"
assert_contains "$OUT" "confines its file tools to the workspace" "gemini: the start line carries the workspace-confinement caveat"
assert_not_contains "$OUT" "run: /pipeline" "gemini: no Claude /pipeline start line"

R="$(new_repo repo-unknown-gemini)"
inst "$PATH" "$R" --no-agent-skills --harness my-gemini-tool
assert_not_contains "$OUT" "context.fileName" "an unknown name containing gemini does not trigger the Gemini notice"
assert_contains "$OUT" "agents.runner: custom" "unknown name: Next steps say agents.runner: custom"
assert_contains "$OUT" "agents.runner_cmd" "unknown name: Next steps mention runner_cmd"

R="$(new_repo repo-agy)"
inst "$PATH" "$R" --no-agent-skills --no-agents-md --harness antigravity
assert_contains "$OUT" "agents.runner: antigravity" "antigravity: Next steps name the runner"
assert_contains "$OUT" 'agy "Read ~/.talos/skills/pipeline/SKILL.md and follow it"' "antigravity: start line uses agy"
R="$(new_repo repo-codex)"
inst "$PATH" "$R" --no-agent-skills --no-agents-md --harness codex
assert_contains "$OUT" 'codex "Read ~/.talos/skills/pipeline/SKILL.md and follow it"' "codex: start line uses codex"
R="$(new_repo repo-pi)"
inst "$PATH" "$R" --no-agent-skills --no-agents-md --harness pi
assert_contains "$OUT" "agents.runner: pi" "pi: Next steps name the runner"
assert_contains "$OUT" "agents.subagents: false" "pi: Next steps add agents.subagents: false"
for h in cursor opencode generic; do
  R="$(new_repo "repo-$h")"
  inst "$PATH" "$R" --no-agent-skills --no-agents-md --harness "$h"
  assert_contains "$OUT" "agents.runner: custom and agents.runner_cmd" "$h: custom runner with runner_cmd"
  assert_contains "$OUT" "Read ~/.talos/skills/pipeline/SKILL.md and follow it" "$h: start sentence"
done
R="$(new_repo repo-multi)"
inst "$PATH" "$R" --no-agent-skills --no-agents-md --harness codex,pi
assert_contains "$OUT" "[codex]" "a list prints a block per harness: codex"
assert_contains "$OUT" "[pi]" "a list prints a block per harness: pi"

R="$(new_repo repo-claude)"
inst "$PATH" "$R" --no-agent-skills --no-agents-md --harness claude
assert_contains "$OUT" "Open a Claude Code session in $R and run: /talos:pipeline" "claude: /talos:pipeline start line"
assert_contains "$OUT" "install.sh --global" "claude: the --global guidance still prints"
R="$(new_repo repo-codex-noclaude)"
inst "$PATH" "$R" --no-agent-skills --no-agents-md --harness codex
assert_not_contains "$OUT" "Claude Code session" "--harness codex: no Claude start line"

# The Claude start line follows detection when there is no --harness.
R="$(new_repo repo-detected-env)"
OUT="$(env -u TALOS_HOME CLAUDE_CONFIG_DIR="$SANDBOX/plugin-less" PATH="$PATH" "$BASH_BIN" "$INSTALL" "$R" --no-agent-skills --no-agents-md 2>&1)"
assert_contains "$OUT" "run: /talos:pipeline" "no --harness, CLAUDE_CONFIG_DIR set: /talos:pipeline start line prints"
assert_contains "$OUT" "install.sh --global" "no --harness, CLAUDE_CONFIG_DIR set: --global guidance prints"
if [ "$CAN_STRIP" = true ]; then
  newhome repo-nosignal
  R="$(new_repo repo-nosignal-r)"
  inst "$BIN" "$R" --no-agent-skills --no-agents-md
  assert_not_contains "$OUT" "Claude Code session" "no --harness, nothing detected: no Claude start line"
  assert_contains "$OUT" "agents.runner: custom" "no --harness, nothing detected: generic Next steps"
fi

finish
