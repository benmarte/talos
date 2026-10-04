#!/usr/bin/env bash
# install.sh -- copy Talos scripts and skills into a target repo, or install globally.
#
# Global install (recommended for new setups):
#   bash install.sh --global [--no-legacy-aliases] [--keep-marketplace]
#   Writes scripts, agents, templates and the playbooks (skills/<command>/SKILL.md,
#   one per entry of TALOS_COMMANDS in scripts/pipeline-contract.sh) to ~/.talos/
#   (the playbooks to ~/.talos/skills/). When the Claude adapter runs (see
#   --harness below) it also copies the role profiles to ~/.claude/agents/, so
#   Claude Code's native subagent discovery finds the current profiles instead
#   of a stale plugin copy, and registers this checkout as the `talos` Claude
#   Code plugin so the commands are /talos:pipeline, /talos:setup and
#   /talos:resume, the same as after `/plugin marketplace add benmarte/talos`.
#   Registration is `claude plugin marketplace add <this checkout>` (a local
#   directory marketplace; skipped when the Claude config already has a
#   marketplace named talos from a non-directory source, repointed when it
#   points at another directory, with one line naming the old and new paths;
#   --keep-marketplace leaves an existing talos marketplace untouched) and
#   `claude plugin install talos@talos`, both guarded: a failure prints a
#   notice and never aborts the install. The plugin
#   loads from this checkout in place (moving or deleting it breaks /talos:*;
#   re-run this installer from the new location) and installing it also installs
#   its agent-skills dependency from GitHub, even with --no-agent-skills. No `claude` on PATH, or one without
#   `claude plugin`: a notice with the two commands to run inside Claude Code,
#   and nothing is deleted.
#   Legacy aliases (until v0.20): ~/.claude/skills/pipeline and
#   ~/.claude/skills/pipeline-setup are thin alias skills (marker
#   <!-- talos:alias -->) that print "renamed to /talos:<command>; this alias is
#   removed in v0.20" and then follow the ~/.talos playbook. --no-legacy-aliases
#   installs none and, once the plugin is registered, removes Talos-owned bare
#   copies (the marker, or a pre-alias full copy: frontmatter name plus a Talos
#   script or config name) including the old ~/.claude/skills/talos-resume. A
#   skill there that is not Talos's is never overwritten or deleted: the
#   installer warns and leaves it, and a symlink on the path is skipped.
#   A single update (git pull + install.sh --global) reaches every repo and harness.
#   Re-runs overwrite existing ~/.talos/ and ~/.claude/ files by default.
#   Pass --no-overwrite to skip.
#
# --harness <list>  (both modes; the installer glue, NOT agents.runner, which
#   picks the CLI that runs stages)
#   A comma-separated list. Known names: claude, codex, gemini, antigravity,
#   pi, cursor, opencode, generic. Any other name matching [a-z0-9-]+ is
#   treated as generic (one line says so and points at agents.runner: custom
#   with agents.runner_cmd); an empty item, a name with other characters
#   (names are lower-case) or a missing value exits 1.
#   Everything under ${CLAUDE_CONFIG_DIR:-$HOME/.claude} is written by one
#   function, install_claude_adapter, which runs:
#     - with --harness: if and only if the list contains claude;
#     - without --harness: if and only if Claude is detected, i.e. any of
#       CLAUDE_CONFIG_DIR is set and non-empty; ${CLAUDE_CONFIG_DIR:-$HOME/.claude}
#       is a directory (a dangling symlink there is NOT detected); or
#       claude is on PATH.
#   Override: --harness claude forces the adapter; a list without claude
#   skips it. A skipped adapter never deletes or refreshes an existing
#   ~/.claude tree; the installer says so. --global prints one line saying
#   whether the adapter ran and why.
#
#   Pointer skills for ~/.agents/skills are written by one function,
#   install_agents_pointers, which runs (--global only) iff the --harness list
#   contains codex, pi, cursor or opencode, the harnesses that read that
#   user-level directory. There is no detection: no --harness, claude,
#   antigravity, gemini, generic and unknown names write nothing under
#   ~/.agents, and per-repo mode never does. For each entry of TALOS_COMMANDS it
#   writes ${TALOS_AGENTS_HOME:-$HOME/.agents}/skills/talos-<command>/SKILL.md, a
#   thin pointer (marker <!-- talos:pointer -->) telling the agent to read
#   ~/.talos/skills/<command>/SKILL.md, so there is no second playbook to drift.
#   A SKILL.md there without the marker is never overwritten, even though
#   --global overwrites by default; a symlink anywhere on the path is skipped
#   with a notice. TALOS_AGENTS_HOME is a developer/QA-only override (like
#   TALOS_HOME and CLAUDE_CONFIG_DIR) so a manual run never touches the real
#   ~/.agents.
#
# Per-repo config (after global install):
#   bash install.sh [target-repo-path] [--harness <list>]
#                   [--no-agents-md] [--import-agents-md]
#   Writes talos.pipeline.* config and, for every harness, the Talos block in
#   <target>/AGENTS.md (scripts/pipeline-instructions.sh: created, appended or
#   repaired between its markers; commit the file). No scripts are copied into
#   the repo. Relies on the global install at ~/.talos/.
#   --no-agents-md      write no AGENTS.md.
#   --import-agents-md  also append an `@AGENTS.md` import to <target>/CLAUDE.md
#                       and <target>/GEMINI.md when they exist (never creates
#                       them, never writes the block into them).
#
# Vendored (legacy, back-compat):
#   Existing .claude/talos/ installs keep working with zero user action.
#   The scripts probe order includes .claude/talos/scripts at position 4, so old
#   vendored copies are still found. Only run install.sh --global first if you
#   want a fresh install to benefit from the new centralized location.
#
# Probe order (used by SKILL.md and all scripts):
#   1. $TALOS_HOME/scripts        -- explicit override (skipped when unset)
#   2. ~/.talos/scripts           -- global install (NEW)
#   3. $CLAUDE_PLUGIN_ROOT/scripts -- Claude Code plugin
#   4. .claude/talos/scripts      -- legacy vendored, back-compat
#   5. scripts                    -- Talos source repo
#
# Notes:
#   talos.pipeline.* config files are NEVER overwritten by any install mode.
#   Git history is never modified. Nothing is committed.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET=""
FORCE_MODE=""       # "overwrite" | "no-overwrite" | "" (default varies by mode)
# --harness: raw value, whether it was given (an empty value is an error, so it
# cannot double as "not given"), and the normalized comma-separated list.
HARNESS_RAW=""
HARNESS_GIVEN=false
HARNESSES=""
KNOWN_HARNESSES="claude codex gemini antigravity pi cursor opencode generic"
WITH_SKILLS=true
GLOBAL=false
WRITE_AGENTS_MD=true
IMPORT_AGENTS_MD=false
LEGACY_ALIASES=true
KEEP_MARKETPLACE=false
AGENT_SKILLS_REPO="${TALOS_AGENT_SKILLS_REPO:-https://github.com/addyosmani/agent-skills}"

expect_harness=false
for arg in "$@"; do
  if [ "$expect_harness" = "true" ]; then
    case "$arg" in
      -*) echo "error: --harness needs a value (got '$arg')" >&2; exit 1 ;;
    esac
    HARNESS_RAW="$arg"; HARNESS_GIVEN=true; expect_harness=false; continue
  fi
  case "$arg" in
    --global)          GLOBAL=true ;;
    --force)           FORCE_MODE="overwrite" ;;
    --no-overwrite)    FORCE_MODE="no-overwrite" ;;
    --no-agent-skills) WITH_SKILLS=false ;;
    --no-agents-md)    WRITE_AGENTS_MD=false ;;
    --import-agents-md) IMPORT_AGENTS_MD=true ;;
    --no-legacy-aliases) LEGACY_ALIASES=false ;;
    --keep-marketplace)  KEEP_MARKETPLACE=true ;;
    --harness)       expect_harness=true ;;
    --harness=*)       HARNESS_RAW="${arg#*=}"; HARNESS_GIVEN=true ;;
    *)                 [ -z "$TARGET" ] && TARGET="$arg" ;;
  esac
done
if [ "$expect_harness" = "true" ]; then
  echo "error: --harness needs a value" >&2; exit 1
fi

# Default overwrite semantics:
#   --global:   overwrite by default (re-run = update); --no-overwrite opts out.
#   per-repo:   skip-if-exists by default; --force opts in.
if [ "$GLOBAL" = "true" ]; then
  [ -z "$FORCE_MODE" ] && FORCE_MODE="overwrite"
else
  [ -z "$FORCE_MODE" ] && FORCE_MODE="no-overwrite"
fi
FORCE=false
[ "$FORCE_MODE" = "overwrite" ] && FORCE=true

# Validate and normalize --harness before anything is written. Unknown names
# that match [a-z0-9-]+ become "generic" (the normalized list is what is passed
# on, so an unknown name can never trigger a harness-specific notice downstream).
if [ "$HARNESS_GIVEN" = "true" ]; then
  case ",$HARNESS_RAW," in
    *,,*) echo "error: --harness has an empty item in '$HARNESS_RAW'. Known: ${KNOWN_HARNESSES// /, }" >&2; exit 1 ;;
  esac
  _rest="$HARNESS_RAW"
  while :; do
    _h="${_rest%%,*}"
    case "$_h" in
      *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) echo "error: invalid --harness name '$_h' (lower-case letters, digits and - only). Known: ${KNOWN_HARNESSES// /, }" >&2; exit 1 ;;
    esac
    case " $KNOWN_HARNESSES " in
      *" $_h "*) ;;
      *) echo "note: unknown harness '$_h' treated as generic; set agents.runner: custom with agents.runner_cmd to drive it."
         _h="generic" ;;
    esac
    case ",$HARNESSES," in
      *",$_h,"*) ;;
      *) HARNESSES="${HARNESSES:+$HARNESSES,}$_h" ;;
    esac
    case "$_rest" in *,*) _rest="${_rest#*,}" ;; *) break ;; esac
  done
fi

has_harness() { case ",$HARNESSES," in *",$1,"*) return 0 ;; esac; return 1; }

# Decide whether the Claude adapter runs, and why (CLAUDE_ADAPTER, CLAUDE_WHY).
# Explicit list: runs iff it contains claude. No list: runs iff Claude is
# detected by any one of three signals (never `claude` on PATH alone: an
# existing ~/.claude, which every earlier --global created, must keep updating).
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
claude_decide() {
  if [ "$HARNESS_GIVEN" = "true" ]; then
    if has_harness claude; then
      CLAUDE_ADAPTER=true;  CLAUDE_WHY="selected: --harness includes claude"
    else
      CLAUDE_ADAPTER=false; CLAUDE_WHY="not selected: --harness list has no claude"
    fi
  elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    CLAUDE_ADAPTER=true;  CLAUDE_WHY="detected: CLAUDE_CONFIG_DIR is set"
  elif [ -d "$CLAUDE_DIR" ]; then
    CLAUDE_ADAPTER=true;  CLAUDE_WHY="detected: $CLAUDE_DIR exists"
  elif command -v claude >/dev/null 2>&1; then
    CLAUDE_ADAPTER=true;  CLAUDE_WHY="detected: claude is on PATH"
  else
    CLAUDE_ADAPTER=false; CLAUDE_WHY="not detected: no CLAUDE_CONFIG_DIR, no $CLAUDE_DIR, no claude on PATH"
  fi
}
claude_decide

# Harnesses that read user-level skills from ~/.agents/skills (no detection; the
# list must name one of them). Gemini CLI is deliberately absent: its file tools
# are confined to the workspace, so a skill cannot make it read ~/.talos.
AGENTS_POINTER_HARNESSES="codex pi cursor opencode"
AGENTS_DIR="${TALOS_AGENTS_HOME:-$HOME/.agents}"
AGENTS_POINTER_MARKER='<!-- talos:pointer -->'

# ── install_file helper ───────────────────────────────────────────────────────
install_file() {
  local src="$1" dest="$2"
  if [ -f "$dest" ] && [ "$FORCE" = "false" ]; then
    echo "  skip (exists): $dest  (pass --force to overwrite)"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  echo "  installed: $dest"
}

# ── Claude adapter ────────────────────────────────────────────────────────────
# Role profiles, in install order (--global copies each to ~/.talos/agents/ and,
# with the Claude adapter, to the Claude agents dir).
TALOS_AGENT_ROLES="validator pm developer qa reviewer security adversarial docs planner"

# agent_source <role> -- the profile source: $SRC/agents first, then $SRC/.claude/agents.
agent_source() {
  local f
  for f in "$SRC/agents/$1.md" "$SRC/.claude/agents/$1.md"; do
    if [ -f "$f" ]; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

# claude_marketplace_state -- how the Claude config knows the `talos`
# marketplace: "absent", "dir<TAB><path>", "other<TAB><source>", or "unknown"
# when the list cannot be read or parsed (never guess from that). Reads
# `claude plugin marketplace list --json`, so it only ever sees $CLAUDE_DIR.
claude_marketplace_state() {
  local json
  command -v python3 >/dev/null 2>&1 || { echo unknown; return 0; }
  json="$(claude plugin marketplace list --json </dev/null 2>/dev/null)" || { echo unknown; return 0; }
  printf '%s' "$json" | python3 -I -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("unknown"); sys.exit(0)
if not isinstance(data, list):
    print("unknown"); sys.exit(0)
for e in data:
    if isinstance(e, dict) and e.get("name") == "talos":
        path = e.get("path")
        if e.get("source") == "directory" and isinstance(path, str) and path and "\n" not in path and "\t" not in path:
            print("dir\t" + path)
        else:
            src = str(e.get("source", "?")).replace("\n", " ").replace("\t", " ")
            print("other\t" + src)
        break
else:
    print("absent")
' || echo unknown
}

# install_claude_plugin -- register this checkout as the `talos` Claude Code
# plugin (a local directory marketplace plus `claude plugin install`), so
# /talos:pipeline, /talos:setup and /talos:resume exist for a global install as
# they do for a marketplace install (#335). Claude Code gives the plugin:skill
# form to plugin skills only, so copying SKILL.md files cannot do it. Never
# fatal: every step is guarded, and CLAUDE_PLUGIN_REGISTERED stays false unless
# `claude plugin install` exited 0, which is what allows stale-copy deletions.
# The plugin loads from $SRC in place, and installing it also installs its
# agent-skills dependency from GitHub (network).
CLAUDE_PLUGIN_REGISTERED=false
install_claude_plugin() {
  local state kind val out here there
  local manual="register it from inside Claude Code: /plugin marketplace add $SRC, then /plugin install talos@talos"
  CLAUDE_PLUGIN_REGISTERED=false
  echo "  Plugin (/talos:<command>):"
  if ! command -v claude >/dev/null 2>&1; then
    echo "    notice: claude is not on PATH, so the talos plugin was not registered and there are no /talos:* commands yet; $manual."
    return 0
  fi
  if ! claude plugin --help >/dev/null 2>&1 </dev/null; then
    echo "    notice: this Claude Code has no 'claude plugin' subcommand (update it), so the talos plugin was not registered; $manual."
    return 0
  fi
  if [ ! -f "$SRC/.claude-plugin/marketplace.json" ]; then
    echo "    notice: $SRC/.claude-plugin/marketplace.json not found, so the talos plugin was not registered."
    return 0
  fi
  state="$(claude_marketplace_state)" || state="unknown"
  kind="${state%%$'\t'*}"; val=""
  case "$state" in *$'\t'*) val="${state#*$'\t'}" ;; esac
  case "$kind" in
    absent) ;;
    dir)
      here="$(cd "$SRC" 2>/dev/null && pwd -P)" || here="$SRC"
      there="$(cd "$val" 2>/dev/null && pwd -P)" || there="$val"
      if [ "$here" = "$there" ]; then
        kind="same"
      elif [ "$KEEP_MARKETPLACE" = "true" ]; then
        echo "    notice: the talos marketplace points at $val, not this checkout ($SRC); left as is (--keep-marketplace), so /talos:* loads from there."
        kind="same"
      elif [ "$FORCE" = "false" ]; then
        echo "    notice: the talos marketplace points at $val, not this checkout ($SRC); left as is (--no-overwrite), so /talos:* loads from there."
        kind="same"
      fi ;;
    other)
      # A github or other non-directory source already provides the namespace:
      # re-adding would silently repoint it at this checkout, so leave it.
      echo "    notice: the talos marketplace is already registered from a non-directory source ($val); left as is."
      kind="same" ;;
    *)
      echo "    notice: could not read 'claude plugin marketplace list --json', so the talos plugin was not registered; $manual."
      return 0 ;;
  esac
  if [ "$kind" != "same" ]; then
    if out="$(claude plugin marketplace add "$SRC" --json </dev/null 2>&1)"; then
      if [ "$kind" = "dir" ]; then
        echo "    marketplace: talos repointed from $val to $SRC (pass --keep-marketplace to leave an existing registration as it is)"
      else
        echo "    marketplace: talos added from $SRC"
      fi
    else
      echo "    notice: 'claude plugin marketplace add' failed, so the talos plugin was not registered: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
      return 0
    fi
  fi
  echo "    note: installing the plugin also installs its agent-skills dependency (github.com/addyosmani/agent-skills, needs network), even with --no-agent-skills."
  if out="$(claude plugin install talos@talos --json </dev/null 2>&1)"; then
    CLAUDE_PLUGIN_REGISTERED=true
    echo "    registered: talos@talos (user scope). It loads from $SRC in place: moving or deleting that checkout breaks /talos:*, and re-running install.sh --global from the new location repoints it."
  else
    echo "    notice: 'claude plugin install talos@talos' failed: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
    echo "            Nothing was deleted. After fixing that, re-run this installer or $manual."
  fi
  return 0
}

# Legacy aliases (#335): the pre-namespace names, kept until v0.20. Each one is
# a thin skill at ~/.claude/skills/<name>/SKILL.md carrying ALIAS_MARKER.
ALIAS_MARKER='<!-- talos:alias -->'

# alias_skill_text <name> <command> <what> -- the alias SKILL.md. The plugin's
# own skills/pipeline-setup/SKILL.md (so /talos:pipeline-setup keeps working) is
# this text for (pipeline-setup, setup, setup wizard); tests/test-legacy-aliases.sh
# asserts it.
alias_skill_text() {
  printf -- '---\nname: %s\ndescription: "Deprecated alias of /talos:%s, removed in v0.20. Prints the rename notice, then runs the Talos %s."\n---\n%s\n' "$1" "$2" "$3" "$ALIAS_MARKER"
  cat <<'TALOS_ALIAS_BODY' | sed "s/@CMD@/$2/g"
Print this line first, exactly: `renamed to /talos:@CMD@; this alias is removed in v0.20`

Then run the command it points at, unchanged and with the same arguments: read the playbook with your file-read tool and follow it exactly. Use the first of these that exists: `$TALOS_HOME/skills/@CMD@/SKILL.md` (only when TALOS_HOME is set), `~/.talos/skills/@CMD@/SKILL.md`, `$CLAUDE_PLUGIN_ROOT/skills/@CMD@/SKILL.md` (only when CLAUDE_PLUGIN_ROOT is set).
`$TALOS_HOME` is read from the Claude Code session environment, so an install into a custom TALOS_HOME is found only when that variable is exported before Claude Code starts.
If none of them exists, tell the user to run `bash install.sh --global` from the Talos repo, and stop.
TALOS_ALIAS_BODY
}

# is_talos_full_copy <file> <frontmatter name> -- a copy an installer from
# before #335 wrote: a plain file whose frontmatter `name:` is the given command
# name and whose text names a Talos script or config file. That pair is the
# whole test for "a Talos copy that predates the alias marker"; a skill that
# merely shares the directory name does not match it.
is_talos_full_copy() {
  local f="$1" want="$2"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  [ "$(awk 'NR==1 { if ($0 != "---") exit 1; next } /^---$/ { exit } /^name:/ { sub(/^name:[ \t]*/, ""); gsub(/"/, ""); print; exit }' "$f")" = "$want" ] || return 1
  grep -qE 'pipeline-vcs\.sh|pipeline-config\.sh|talos\.pipeline\.' "$f"
}

# handle_bare_skill <dir name> <old frontmatter name> <command> <what> <alias yes|no>
# -- one bare skill under $CLAUDE_DIR/skills. With alias=yes it writes the thin
# alias (replacing a Talos-owned file: the marker, or an is_talos_full_copy
# match). With alias=no (--no-legacy-aliases, and the retired talos-resume) it
# removes a Talos-owned file, but only once the plugin is registered, because
# until then that copy is the only way to run the command. A file that is not
# Talos's is never touched, and a symlink on the path is skipped.
handle_bare_skill() {
  local name="$1" old="$2" cmd="$3" what="$4" alias="$5"
  local dir="$CLAUDE_DIR/skills/$1" dest owned=false
  dest="$dir/SKILL.md"
  if [ -L "$dir" ] || [ -L "$dest" ]; then
    if [ -L "$dir" ]; then echo "    notice: $dir is a symlink; left untouched."
    else echo "    notice: $dest is a symlink; left untouched."; fi
    return 0
  fi
  if { [ -e "$dir" ] && [ ! -d "$dir" ]; } || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
    echo "    notice: $dir is not a plain directory with a plain SKILL.md; left untouched."
    return 0
  fi
  if [ -f "$dest" ]; then
    if grep -qxF "$ALIAS_MARKER" "$dest" || is_talos_full_copy "$dest" "$old"; then
      owned=true
    else
      if [ "$alias" = "yes" ]; then
        echo "    warning: $dest exists and is not a Talos alias; left untouched (/$name is not Talos's here)."
      fi
      return 0
    fi
  fi
  if [ "$alias" = "no" ]; then
    [ "$owned" = "true" ] || return 0
    if [ "$CLAUDE_PLUGIN_REGISTERED" != "true" ]; then
      echo "    kept (the talos plugin is not registered, so this is still the only way to run it): $dest"
      return 0
    fi
    rm -f -- "${dest:?}"
    rmdir "$dir" 2>/dev/null || true
    echo "    removed: $dest"
    return 0
  fi
  if [ "$owned" = "true" ] && [ "$FORCE" = "false" ]; then
    echo "    skip (exists): $dest  (pass --force to overwrite)"
    return 0
  fi
  if ! mkdir -p "$dir" 2>/dev/null || ! alias_skill_text "$name" "$cmd" "$what" > "$dest" 2>/dev/null; then
    echo "    notice: could not write $dest."
    return 0
  fi
  echo "    installed: $dest  (alias of /talos:$cmd)"
}

# install_claude_adapter -- the ONLY place --global writes under
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}: role profiles to <dir>/agents/ (Claude
# Code's native subagent discovery), the talos plugin registration (so
# /talos:<command> exists), and the legacy /pipeline and /pipeline-setup alias
# skills in <dir>/skills/. A bare /pipeline alias runs without
# CLAUDE_PLUGIN_ROOT, so SKILL.md's subagent names fall to the agents/ copies.
# Needs scripts/pipeline-contract.sh sourced.
install_claude_adapter() {
  local agent src_agent
  echo ""
  echo "Claude Code adapter ($CLAUDE_DIR):"
  for agent in $TALOS_AGENT_ROLES; do
    if src_agent="$(agent_source "$agent")"; then
      install_file "$src_agent" "$CLAUDE_DIR/agents/$agent.md"
    fi
  done
  install_claude_plugin
  echo "  Legacy aliases ($CLAUDE_DIR/skills, removed in v0.20):"
  if [ "$LEGACY_ALIASES" = "true" ]; then
    handle_bare_skill pipeline pipeline pipeline "pipeline orchestrator" yes
    handle_bare_skill pipeline-setup pipeline-setup setup "setup wizard" yes
  else
    echo "    --no-legacy-aliases: no bare /pipeline or /pipeline-setup is installed."
    handle_bare_skill pipeline pipeline pipeline "pipeline orchestrator" no
    handle_bare_skill pipeline-setup pipeline-setup setup "setup wizard" no
  fi
  # The provisional bare copy of resume (#348): /talos:resume replaces it.
  handle_bare_skill talos-resume resume resume "resume briefing" no
}

# install_agents_pointers -- the ONLY place --global writes under
# ${TALOS_AGENTS_HOME:-$HOME/.agents}: one thin pointer skill per TALOS_COMMANDS
# entry at <dir>/skills/talos-<command>/SKILL.md. Needs pipeline-contract.sh
# sourced and the ~/.talos/skills copies installed (the pointers name them).
# Not install_file: --global overwrites by default and a pointer must never
# replace a file that does not carry the marker. Never aborts the install.
AGENTS_POINTERS_WRITTEN=false
install_agents_pointers() {
  local h want="" skills="$AGENTS_DIR/skills" cmd name src dest desc
  for h in $AGENTS_POINTER_HARNESSES; do
    if has_harness "$h"; then want="${want:+$want, }$h"; fi
  done
  if [ -z "$want" ]; then
    echo "Agents pointer skills skipped (not selected: --harness has none of ${AGENTS_POINTER_HARNESSES// /, }; nothing is written under $AGENTS_DIR)."
    return 0
  fi
  echo ""
  echo "Agents pointer skills ($skills; selected: $want):"
  # Links and non-directories first, before any mkdir (a dangling link too).
  if [ -L "$AGENTS_DIR" ] || [ -L "$skills" ]; then
    [ -L "$AGENTS_DIR" ] && echo "  notice: $AGENTS_DIR is a symlink; nothing was written through it." \
                         || echo "  notice: $skills is a symlink; nothing was written through it."
    return 0
  fi
  if { [ -e "$AGENTS_DIR" ] && [ ! -d "$AGENTS_DIR" ]; } || { [ -e "$skills" ] && [ ! -d "$skills" ]; }; then
    echo "  notice: $AGENTS_DIR or $skills is not a directory; nothing was written."
    return 0
  fi
  for cmd in "${TALOS_COMMANDS[@]}"; do
    name="talos-$cmd"
    src="$SRC/skills/$cmd/SKILL.md"
    dest="$skills/$name/SKILL.md"
    desc="$(awk 'NR>1 && /^---$/{exit} /^description:/{print; exit}' "$src")"
    if [ -z "$desc" ]; then
      echo "  notice: $src has no description line; $name was not written."
      continue
    fi
    if [ -L "$skills/$name" ] || [ -L "$dest" ]; then
      [ -L "$skills/$name" ] && echo "  notice: $skills/$name is a symlink; nothing was written through it." \
                             || echo "  notice: $dest is a symlink; nothing was written through it."
      continue
    fi
    if { [ -e "$skills/$name" ] && [ ! -d "$skills/$name" ]; } || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
      echo "  notice: $skills/$name is not a plain directory with a plain SKILL.md; nothing was written."
      continue
    fi
    if [ -f "$dest" ]; then
      if ! grep -qxF "$AGENTS_POINTER_MARKER" "$dest"; then
        echo "  warning: $dest exists and is not a Talos pointer; left untouched."
        continue
      fi
      if [ "$FORCE" = "false" ]; then
        echo "  skip (exists): $dest  (pass --force to overwrite)"
        continue
      fi
    fi
    if ! mkdir -p "$skills/$name" 2>/dev/null; then
      echo "  notice: could not create $skills/$name; $name was not written."
      continue
    fi
    {
      printf -- '---\nname: %s\n%s\n---\n%s\n' "$name" "$desc" "$AGENTS_POINTER_MARKER"
      cat <<'TALOS_POINTER_BODY' | sed "s/@CMD@/$cmd/g"
This is a thin Talos pointer; the playbook is not copied here, so it cannot drift.
Read `~/.talos/skills/@CMD@/SKILL.md` (or `$TALOS_HOME/skills/@CMD@/SKILL.md` when TALOS_HOME is set) with your file-read tool, then follow it exactly.
If that file does not exist, tell the user to run `bash install.sh --global` from the Talos repo, and stop.
TALOS_POINTER_BODY
    } > "$dest" 2>/dev/null || { echo "  notice: could not write $dest."; continue; }
    echo "  installed: $dest"
    AGENTS_POINTERS_WRITTEN=true
  done
  if has_harness claude; then
    echo "  note: with claude selected too, cursor and opencode also scan ~/.claude/skills and may see both sets (the bare pipeline and pipeline-setup aliases, and talos-pipeline, talos-setup and talos-resume). Whether Claude Code reads ~/.agents/skills is unverified."
  fi
}

# ── GLOBAL INSTALL ────────────────────────────────────────────────────────────
if [ "$GLOBAL" = "true" ]; then
  TALOS_HOME_DIR="${TALOS_HOME:-$HOME/.talos}"
  echo "Installing Talos globally into: $TALOS_HOME_DIR"
  if [ "$CLAUDE_ADAPTER" = "true" ]; then
    echo "(Skills -> $TALOS_HOME_DIR/skills, plus the talos plugin and the legacy aliases in $CLAUDE_DIR/skills; Agents -> $TALOS_HOME_DIR/agents and $CLAUDE_DIR/agents)"
    _adapter_state="ran"
  else
    echo "(Skills -> $TALOS_HOME_DIR/skills, Agents -> $TALOS_HOME_DIR/agents)"
    _adapter_state="skipped"
  fi
  echo "Claude Code adapter $_adapter_state ($CLAUDE_WHY). Override: --harness claude forces it; a --harness list without claude skips it."
  echo ""

  # Scripts -- glob every *.sh (and *.py, below) in $SRC/scripts so a new script is picked up
  # automatically; a hardcoded list drifts from the repo (#276).
  echo "Scripts:"
  mkdir -p "$TALOS_HOME_DIR/scripts"
  for script_src in "$SRC"/scripts/*.sh; do
    [ -f "$script_src" ] || continue
    script="$(basename "$script_src")"
    install_file "$script_src" "$TALOS_HOME_DIR/scripts/$script"
    chmod +x "$TALOS_HOME_DIR/scripts/$script"
  done
  # Python helpers imported by the scripts (pipeline-spend-format.py, #393):
  # same install_file / --force rules, no chmod -- they are imported, not run.
  for script_src in "$SRC"/scripts/*.py; do
    [ -f "$script_src" ] || continue
    install_file "$script_src" "$TALOS_HOME_DIR/scripts/$(basename "$script_src")"
  done

  # Agents -> ~/.talos/agents/ (read by pipeline-agent.sh for pi/codex/gemini/
  # antigravity). The Claude copy (~/.claude/agents/) is install_claude_adapter's.
  # A repo-level .claude/agents/<role>.md still wins over either -- see
  # SKILL.md's subagent-name resolution rules.
  echo ""
  echo "Agents:"
  for agent in $TALOS_AGENT_ROLES; do
    if src_agent="$(agent_source "$agent")"; then
      install_file "$src_agent" "$TALOS_HOME_DIR/agents/$agent.md"
    fi
  done

  # Templates -- glob every subdirectory of $SRC/templates so a new template
  # dir (e.g. ci) is picked up automatically; a hardcoded list drifts from the
  # repo (#276).
  echo ""
  echo "Templates:"
  for dir_path in "$SRC"/templates/*/; do
    [ -d "$dir_path" ] || continue
    dir="$(basename "$dir_path")"
    for tmpl in "$dir_path"*; do
      [ -f "$tmpl" ] || continue
      install_file "$tmpl" "$TALOS_HOME_DIR/templates/$dir/$(basename "$tmpl")"
    done
    # One level deeper, globbed the same way so a nested template dir needs no
    # installer edit. #280 shipped notifications/<platform>/<event>.md here;
    # #284 flattened that back to a single notifications/<event>.md, which the
    # file loop above already installs. Kept because the cost is one no-op glob
    # and the alternative -- rediscovering this the next time a template dir
    # nests -- is a silently incomplete --global install (#276).
    for sub_path in "$dir_path"*/; do
      [ -d "$sub_path" ] || continue
      sub="$(basename "$sub_path")"
      for tmpl in "$sub_path"*; do
        [ -f "$tmpl" ] || continue
        install_file "$tmpl" "$TALOS_HOME_DIR/templates/$dir/$sub/$(basename "$tmpl")"
      done
    done
  done

  # Skills: every command in TALOS_COMMANDS (scripts/pipeline-contract.sh) goes
  # to ~/.talos/skills/<command>/ (harness-neutral: any agent can be pointed at
  # it). Claude's /talos:<command> names and legacy aliases are
  # install_claude_adapter's. A new playbook needs a manifest entry, not an
  # installer edit.
  _CONTRACT="$SRC/scripts/pipeline-contract.sh"
  if [ ! -f "$_CONTRACT" ]; then
    echo "error: $_CONTRACT not found; cannot read the command manifest" >&2
    exit 1
  fi
  . "$_CONTRACT"
  echo ""
  echo "Orchestrator skills (~/.talos/skills):"
  for cmd in "${TALOS_COMMANDS[@]}"; do
    install_file "$SRC/skills/$cmd/SKILL.md" "$TALOS_HOME_DIR/skills/$cmd/SKILL.md"
  done

  install_agents_pointers

  if [ "$CLAUDE_ADAPTER" = "true" ]; then
    install_claude_adapter
  elif [ -f "$CLAUDE_DIR/skills/pipeline/SKILL.md" ]; then
    echo ""
    echo "Claude Code adapter skipped: $CLAUDE_DIR was not refreshed (nothing was changed or deleted). To refresh it, re-run with --harness claude (or --harness claude,<others>)."
  fi

  # Model hint (#336). Role models are set only in the Talos config (the agent
  # files carry no model:). Stay non-interactive and never write the user-level
  # file: just say so when it has no model keys. Asked of the freshly installed
  # pipeline-config.sh from a scratch dir so neither a repo config in the cwd
  # nor an ambient $PIPELINE_CONFIG can answer for the user-level file.
  _HINT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/talos-hint.XXXXXX" 2>/dev/null)" || _HINT_DIR=""
  _HINT_LAYERS=""
  if [ -n "$_HINT_DIR" ]; then
    _HINT_LAYERS="$(cd "$_HINT_DIR" && env -u PIPELINE_CONFIG TALOS_HOME="$TALOS_HOME_DIR" \
      bash "$TALOS_HOME_DIR/scripts/pipeline-config.sh" --dump-layers 2>/dev/null)"
    rm -rf "$_HINT_DIR"
  fi
  if ! grep -Eq '^agents\.(roles\.[^.]+\.)?model' <<<"$_HINT_LAYERS"; then
    echo ""
    echo "Models: no model set in a user-level Talos config ($TALOS_HOME_DIR/talos.pipeline.*), so every role inherits the session model -- run the setup skill (/talos:setup in Claude Code, or read $TALOS_HOME_DIR/skills/setup/SKILL.md) to choose one model for all roles or one per role."
  fi

  echo ""
  echo "Done. Global Talos install at $TALOS_HOME_DIR"
  echo ""
  echo "Next: run per-repo config in each repository:"
  echo "  bash $SRC/install.sh /path/to/your-repo"
  echo ""
  if [ "$CLAUDE_ADAPTER" = "true" ]; then
    echo "  NOTE: skills are discovered when a session starts. Restart any open"
    echo "        Claude Code session to pick up the newly installed skills."
    if [ "$CLAUDE_PLUGIN_REGISTERED" = "true" ]; then
      echo "        Commands: /talos:pipeline, /talos:setup, /talos:resume (plugin talos@talos,"
      echo "        loaded from $SRC: keep that checkout where it is, or re-run this installer from its new location)."
    else
      echo "        The talos plugin is not registered, so /talos:* commands are missing (see the plugin notice above)."
    fi
    if [ "$LEGACY_ALIASES" = "true" ]; then
      echo "        Old names /pipeline and /pipeline-setup still work as aliases until v0.20: $CLAUDE_DIR/skills/<name>/SKILL.md"
    fi
  fi
  echo "        Playbooks for any other agent: $TALOS_HOME_DIR/skills/<command>/SKILL.md"
  if [ "$AGENTS_POINTERS_WRITTEN" = "true" ]; then
    echo "        Pointer skills registered at: $AGENTS_DIR/skills/talos-<command>/SKILL.md"
  fi
  if [ "$CLAUDE_ADAPTER" = "true" ]; then
    echo "        Role profiles registered at: $CLAUDE_DIR/agents/<role>.md"
  fi
  exit 0
fi

# ── PER-REPO CONFIG INSTALL ───────────────────────────────────────────────────
[ -z "$TARGET" ] && TARGET="$(pwd)"

# Ensure target looks like a repo
if [ ! -d "$TARGET" ]; then
  echo "error: target directory not found: $TARGET" >&2
  exit 1
fi

# Legacy layout: Talos used to install into .claude/pipeline/
if [ -d "$TARGET/.claude/pipeline" ]; then
  echo "NOTE: legacy install detected at $TARGET/.claude/pipeline -- Talos now lives in .claude/talos/."
  echo "      Move any customized templates or .env out of the old directory, then remove it:"
  echo "        rm -rf $TARGET/.claude/pipeline"
  echo ""
fi

echo "Configuring Talos for repo: $TARGET"
echo "(scripts are NOT copied into repos -- run 'bash install.sh --global' once per machine)"
echo ""

# ── agent-skills ─────────────────────────────────────────────────────────────
# The role profiles delegate their methodology to these skills instead of
# restating it, so a vendored install without them runs every stage from a
# paragraph rather than a rubric. The PLUGIN gets them via a declared dependency;
# install.sh has to fetch them itself. For per-repo installs, agent-skills still
# goes into the repo's .claude/skills/ so role profiles can find them locally.
#
# Only skills/ is vendored. The roles invoke skills, never agents -- they have no
# Task tool -- so agent-skills' own agents would be dead weight in the target repo.
#
# Never fatal: a failure here degrades the install, it does not break it.
if [ "$WITH_SKILLS" = "true" ]; then
  echo "agent-skills (required by the role profiles -- Talos installs it for you):"
  if ! command -v git >/dev/null 2>&1; then
    echo "  SKIPPED: git not found. Install agent-skills manually:"
    echo "    $AGENT_SKILLS_REPO"
  else
    as_tmp="$(mktemp -d)"
    if git clone --depth 1 --quiet "$AGENT_SKILLS_REPO" "$as_tmp/agent-skills" 2>/dev/null \
       && [ -d "$as_tmp/agent-skills/skills" ]; then
      as_n=0
      for skill_dir in "$as_tmp/agent-skills/skills"/*/; do
        [ -f "$skill_dir/SKILL.md" ] || continue
        name="$(basename "$skill_dir")"
        dest="$TARGET/.claude/skills/$name/SKILL.md"
        if [ -f "$dest" ] && [ "$FORCE" = "false" ]; then
          echo "  skip (exists): $dest"
        else
          mkdir -p "$(dirname "$dest")"
          cp "$skill_dir/SKILL.md" "$dest"
          as_n=$((as_n + 1))
        fi
      done
      # Ship the licence alongside the copy -- this is third-party MIT content.
      for lic in LICENSE LICENSE.md; do
        if [ -f "$as_tmp/agent-skills/$lic" ]; then
          mkdir -p "$TARGET/.claude/skills"
          cp "$as_tmp/agent-skills/$lic" "$TARGET/.claude/skills/AGENT-SKILLS-LICENSE"
          break
        fi
      done
      echo "  installed: $as_n skill(s) into $TARGET/.claude/skills/"
      echo "  source:    $AGENT_SKILLS_REPO (MIT, unmodified)"
      echo "  skip with: --no-agent-skills"
    else
      echo "  SKIPPED: could not fetch $AGENT_SKILLS_REPO (offline?)."
      echo "           The pipeline still runs; roles fall back to their embedded"
      echo "           instructions. Re-run this installer when you have network."
    fi
    rm -rf "$as_tmp"
  fi
else
  echo "agent-skills: skipped (--no-agent-skills)."
  echo "  The role profiles delegate their methodology to these skills; without"
  echo "  them each stage falls back to its embedded instructions."
fi

# AGENTS.md: one marker-fenced Talos block for every harness, written by
# scripts/pipeline-instructions.sh from this source tree (so it works before a
# global install). It creates, appends or repairs the block and prints any
# CLAUDE.md / GEMINI.md import notice; it never fails the install.
if [ "$WRITE_AGENTS_MD" = "true" ]; then
  echo ""
  echo "AGENTS.md (Talos block):"
  _INSTR_ARGS=()
  [ "$HARNESS_GIVEN" = "true" ] && _INSTR_ARGS+=(--harness "$HARNESSES")
  [ "$IMPORT_AGENTS_MD" = "true" ] && _INSTR_ARGS+=(--import-agents-md)
  bash "$SRC/scripts/pipeline-instructions.sh" write "$TARGET" ${_INSTR_ARGS[@]+"${_INSTR_ARGS[@]}"} \
    || echo "  warning: could not write the Talos block into $TARGET/AGENTS.md"
fi

# Offer to copy config example. talos.pipeline.* is NEVER overwritten.
echo ""
if [ ! -f "$TARGET/talos.pipeline.yml" ] && [ ! -f "$TARGET/talos.pipeline.json" ]; then
  echo "Config template:"
  echo "  Copy talos.pipeline.yml.example to talos.pipeline.yml and edit it:"
  echo "    cp $SRC/talos.pipeline.yml.example $TARGET/talos.pipeline.yml"
else
  echo "Config: talos.pipeline.* already exists -- not overwriting."
fi

# ── /talos:pipeline availability ──────────────────────────────────────────────
# The commands come from the talos plugin, registered by install.sh --global
# (a local directory marketplace) or by the marketplace install. Per-repo
# installs no longer write scripts into the repo; run 'bash install.sh --global'
# first to register /talos:pipeline for all sessions on this machine.
#
# Skills are enumerated at session start, so a session already open in $TARGET
# will not see the skill until it restarts.
echo ""
echo "Done. Next steps:"
echo "  1. Edit $TARGET/talos.pipeline.yml for your project"
echo "  2. Bootstrap labels (if using GitHub/GitLab/Azure):"

TALOS_HOME_DIR="${TALOS_HOME:-$HOME/.talos}"
if [ -f "$TALOS_HOME_DIR/scripts/bootstrap-labels.sh" ]; then
  echo "     bash $TALOS_HOME_DIR/scripts/bootstrap-labels.sh"
else
  echo "     bash <talos-scripts>/bootstrap-labels.sh"
  echo "     (run 'bash $SRC/install.sh --global' first to install scripts globally)"
fi
echo "  3. Add 'pipeline:ready' to a GitHub issue"
echo "  4. Start the pipeline (--harness picks installer glue; agents.runner picks the CLI that runs stages):"

# Harnesses the next steps cover: the explicit list, else claude when detected,
# else generic.
if [ "$HARNESS_GIVEN" = "true" ]; then
  _NEXT="$HARNESSES"
elif [ "$CLAUDE_ADAPTER" = "true" ]; then
  _NEXT="claude"
else
  _NEXT="generic"
fi

_START_PHRASE="Read ~/.talos/skills/pipeline/SKILL.md and follow it"
for _h in ${_NEXT//,/ }; do
  case "$_h" in
    claude)
      echo "     [claude] Open a Claude Code session in $TARGET and run: /talos:pipeline"
      continue ;;
    pi)
      echo "     [pi] in talos.pipeline.yml set agents.runner: pi and agents.subagents: false"
      _start="$_START_PHRASE" ;;
    codex|gemini)
      echo "     [$_h] in talos.pipeline.yml set agents.runner: $_h"
      _start="$_h \"$_START_PHRASE\"" ;;
    antigravity)
      echo "     [antigravity] in talos.pipeline.yml set agents.runner: antigravity"
      _start="agy \"$_START_PHRASE\"" ;;
    *)
      echo "     [$_h] in talos.pipeline.yml set agents.runner: custom and agents.runner_cmd"
      _start="$_START_PHRASE" ;;
  esac
  echo "          start: $_start"
done

if [ "$CLAUDE_ADAPTER" = "true" ]; then
  echo ""
  echo "  NOTE: /talos:pipeline requires the talos plugin. If you have not run"
  echo "        'bash install.sh --global' yet, do so now -- or install the plugin:"
  echo "        /plugin marketplace add benmarte/talos"
  echo "        Skills are discovered at session start; restart any open session."
fi
