#!/usr/bin/env bash
# install.sh -- copy Talos scripts and skills into a target repo, or install globally.
#
# Global install (recommended for new setups):
#   bash install.sh --global
#   Writes scripts, agents, templates and the playbooks (skills/<command>/SKILL.md,
#   one per entry of TALOS_COMMANDS in scripts/pipeline-contract.sh) to ~/.talos/
#   (the playbooks to ~/.talos/skills/). When the Claude adapter runs (see
#   --harness below) the same skills also go to ~/.claude/skills/ and the role
#   profiles to ~/.claude/agents/, so Claude Code's native subagent discovery
#   finds the current profiles instead of a stale plugin copy.
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
    --harness)         expect_harness=true ;;
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

# install_claude_adapter -- the ONLY place --global writes under
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}: role profiles to <dir>/agents/ (Claude
# Code's native subagent discovery) and the skills to <dir>/skills/ (user-scoped;
# Claude Code scans this path). Needs scripts/pipeline-contract.sh sourced.
install_claude_adapter() {
  local agent src_agent cmd
  echo ""
  echo "Claude Code adapter ($CLAUDE_DIR):"
  for agent in $TALOS_AGENT_ROLES; do
    if src_agent="$(agent_source "$agent")"; then
      install_file "$src_agent" "$CLAUDE_DIR/agents/$agent.md"
    fi
  done
  for cmd in "${TALOS_COMMANDS[@]}"; do
    install_file "$SRC/skills/$cmd/SKILL.md" "$CLAUDE_DIR/skills/$(talos_claude_skill_name "$cmd")/SKILL.md"
  done
}

# ── GLOBAL INSTALL ────────────────────────────────────────────────────────────
if [ "$GLOBAL" = "true" ]; then
  TALOS_HOME_DIR="${TALOS_HOME:-$HOME/.talos}"
  echo "Installing Talos globally into: $TALOS_HOME_DIR"
  if [ "$CLAUDE_ADAPTER" = "true" ]; then
    echo "(Skills -> $TALOS_HOME_DIR/skills and $CLAUDE_DIR/skills, Agents -> $TALOS_HOME_DIR/agents and $CLAUDE_DIR/agents)"
    _adapter_state="ran"
  else
    echo "(Skills -> $TALOS_HOME_DIR/skills, Agents -> $TALOS_HOME_DIR/agents)"
    _adapter_state="skipped"
  fi
  echo "Claude Code adapter $_adapter_state ($CLAUDE_WHY). Override: --harness claude forces it; a --harness list without claude skips it."
  echo ""

  # Scripts -- glob every *.sh in $SRC/scripts so a new script is picked up
  # automatically; a hardcoded list drifts from the repo (#276).
  echo "Scripts:"
  mkdir -p "$TALOS_HOME_DIR/scripts"
  for script_src in "$SRC"/scripts/*.sh; do
    [ -f "$script_src" ] || continue
    script="$(basename "$script_src")"
    install_file "$script_src" "$TALOS_HOME_DIR/scripts/$script"
    chmod +x "$TALOS_HOME_DIR/scripts/$script"
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
  # it). The user-scoped Claude copy is install_claude_adapter's. A new playbook
  # needs a manifest entry, not an installer edit.
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
  if ! printf '%s\n' "$_HINT_LAYERS" | grep -Eq '^agents\.(roles\.[^.]+\.)?model'; then
    echo ""
    echo "Models: no model set in a user-level Talos config ($TALOS_HOME_DIR/talos.pipeline.*), so every role inherits the session model -- run the pipeline-setup skill to choose one model for all roles or one per role."
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
    echo "        Registered at: $CLAUDE_DIR/skills/pipeline/SKILL.md"
  fi
  echo "        Playbooks for any other agent: $TALOS_HOME_DIR/skills/<command>/SKILL.md"
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

# ── /pipeline availability ────────────────────────────────────────────────────
# The skill is discovered via the global install (~/.claude/skills/pipeline/SKILL.md
# from install.sh --global) or the marketplace plugin. Per-repo installs no longer
# write scripts into the repo; run 'bash install.sh --global' first to register
# /pipeline for all sessions on this machine.
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
      echo "     [claude] Open a Claude Code session in $TARGET and run: /pipeline"
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
  echo "  NOTE: /pipeline requires the skill to be installed. If you have not run"
  echo "        'bash install.sh --global' yet, do so now -- or install the plugin:"
  echo "        /plugin marketplace add benmarte/talos"
  echo "        Skills are discovered at session start; restart any open session."
fi
