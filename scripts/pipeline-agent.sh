#!/usr/bin/env bash
# pipeline-agent.sh — run one pipeline role stage through a headless LLM CLI.
#
# Claude Code sessions spawn native subagents and never need this script.
# Harnesses without native subagents (Codex CLI, Gemini CLI, Antigravity CLI,
# any headless runner) use it wherever the orchestrator playbook says "spawn a
# subagent".
#
# Usage: pipeline-agent.sh <role> <task-prompt>
#        pipeline-agent.sh <role> -          # read task prompt from stdin
#        pipeline-agent.sh --resolve <role>  # print the resolved runner/
#                                             # runner_cmd/model for <role>
#                                             # and exit 0 -- no prompt is
#                                             # run. One line on stdout:
#                                             #   runner=<r> runner_cmd=<c> model=<m> effort=<e>
#                                             # Shared with the orchestrator
#                                             # (skills/pipeline/SKILL.md) so
#                                             # both the adapter path and the
#                                             # native-path per-role dispatch
#                                             # decision use one resolution.
#        pipeline-agent.sh --resolve-all     # (#336) one line per role:
#                                             #   role=<r> model=<m> restamp_model=<m> origin=<project|global|session default>
#                                             # origin names the config layer
#                                             # that decided the model. Warns on
#                                             # stderr for a role file whose
#                                             # frontmatter still has model:.
#        pipeline-agent.sh --resolve-profile <role>
#                                             # (#367) print the one absolute
#                                             # path of the role definition a
#                                             # stage run would use, exit 0.
#                                             # Exit 1 (stderr lists the
#                                             # locations searched) when there
#                                             # is none, 2 on a missing or
#                                             # invalid <role>. pi inline mode
#                                             # (skills/pipeline/SKILL.md) uses
#                                             # it: same order as a stage run.
#
# The executed prompt = role definition body (the profile found by the order
# below, with its YAML frontmatter stripped — the frontmatter is Claude Code
# metadata) + a separator + the task prompt.
#
# Role definition lookup order (#367; _resolve_role_profile, one function for a
# stage run and --resolve-profile). The first file that exists wins:
#   1. $PWD/.claude/agents/<role>.md          repo override, always first
#   2. $PWD/.agents/talos/agents/<role>.md    harness-neutral repo override;
#                                              read here (adapter and pi inline
#                                              paths) and NEVER by the native
#                                              Claude path, which resolves
#                                              subagents from its own dirs.
#                                              A symlink (the file or a
#                                              directory on the way) is skipped.
#   3. the install's agents/ (via _resolve_talos_dir: $TALOS_HOME, ~/.talos,
#      $CLAUDE_PLUGIN_ROOT, .claude/talos, scripts)
#   4. self-relative fallbacks: <scripts>/../agents, <scripts>/../../agents,
#      <scripts>/../.claude/agents
# <role> must be lowercase letters and '-' (not leading); anything else exits 2
# before any path is built.
#
# --check-effort <role> (#445): native claude path only. Prints ONE notice line
#   when the resolved effort (agents.roles.<role>.effort, else agents.effort) is
#   non-empty and differs from the role file's effort: frontmatter (absent
#   counts as different); nothing on a match, an empty config, or an
#   adapter-path role (TALOS_EFFORT applies it there). Exit 0 (2 on a
#   missing/invalid <role>); writes no file.
#
# Failover verbs (#418, see agents.fallback below):
#   --resolve <role> appends " fallback=<a,b>" after effort= only when a chain
#   resolves; --resolve-all appends fallback= / fallback_origin= the same way.
#   --classify <runner> <rc> <file|->
#       print ok | provider | task for a finished runner from its exit code and
#       the last 20 lines of the text in <file> (- = stdin). Exit 0; 2 on a bad
#       argument. The native Claude path uses it on the text a dead subagent
#       returned (advisory).
#   --mark-down <runner> <class:detail>
#       record <runner> as down in .talos/providers.json for
#       agents.provider_down_s seconds.
#
# Config keys (talos.pipeline.yml via pipeline-config.sh):
#   agents.runner       claude (default) | pi | codex | gemini | antigravity | custom
#   agents.runner_args  list of extra CLI args appended to claude/pi/codex/gemini/agy
#   agents.runner_cmd   full shell command for runner=custom;
#                       receives the prompt on stdin
#   agents.roles.<role>.runner      per-role override of agents.runner (#167).
#                                    Resolved role-first: this key wins when
#                                    set, else agents.runner, else "claude".
#   agents.roles.<role>.runner_cmd  per-role override of agents.runner_cmd,
#                                    same role-first precedence. Only read
#                                    when the resolved runner is "custom".
#                                    agents.runner_args stays global-only —
#                                    no agents.roles.<role>.runner_args (S1
#                                    scope, #167).
#   agents.effort               low | medium | high | max (#271). Reasoning
#                                effort per role, resolved role-first same
#                                as agents.model: agents.roles.<role>.effort
#                                wins, else agents.effort, else empty (the
#                                runner's own default — omitted means
#                                unchanged behaviour, exactly like model).
#                                --resolve prints it. On the native claude
#                                path there is no per-spawn Agent tool
#                                parameter for effort and the orchestrator
#                                never writes to a role file, so this key is
#                                advisory only there — commit `effort:` in
#                                the role's own frontmatter to apply it; a
#                                mismatch just gets a logged notice (see
#                                skills/pipeline/SKILL.md). Every other
#                                runner gets this key applied for real, as
#                                TALOS_EFFORT in the environment (see below),
#                                so a runner_cmd can map it to its own flag.
#   agents.restamp_effort,
#   agents.roles.<role>.restamp_effort  Same chain as agents.restamp_model /
#                                agents.roles.<role>.restamp_model (#258):
#                                role restamp_effort -> global
#                                restamp_effort -> agents.effort. Resolved
#                                by pipeline-config.sh itself (unlike plain
#                                agents.effort, which pipeline-agent.sh
#                                resolves role-first below) — see
#                                skills/pipeline/SKILL.md's Step 3e re-stamp
#                                block for where it is used.
#   agents.fallback     (#418) ordered list of runner names (same ids as
#                       agents.runner), tried in turn when a runner dies with a
#                       PROVIDER error (rate limit, quota, overload, auth,
#                       network). Names only: a fallback runner uses its own
#                       default model, agents.runner_args is not forwarded to
#                       it, and a custom entry uses the role-first runner_cmd.
#   agents.roles.<role>.fallback  per-role override, role-first like runner.
#   agents.provider_down_s        seconds a provider stays marked down in
#                       .talos/providers.json (60-86400, default 900).
#                       Unset fallback = no chain: output, stderr and exit code
#                       are exactly the runner's, and providers.json is never
#                       touched. With a chain, stdout is buffered per attempt
#                       and only the final attempt's reaches the caller.
#   Exit codes with a chain: 75 from any runner is a provider error
#   (EX_TEMPFAIL, the contract for a custom runner_cmd); 69 (EX_UNAVAILABLE)
#   is ours: chain exhausted, every runner down, or failover refused because
#   the failed attempt had already written (see the write guard below).
#   hooks.pre_dispatch  command run before the prompt is built (#181); its
#                       stdout, if non-empty, is prepended to the prompt
#                       under a "## Context" heading. Default "" (disabled).
#                       See pipeline-hooks.sh for the full contract.
#   hooks.timeout_s     seconds hooks.pre_dispatch / hooks.post_stage may run
#                       before being killed. Default 30.
#   hooks.post_stage    command run once the stage runner exits (#182); gets
#                       a JSON outcome event on stdin (event "stage_complete",
#                       verdict PASS/FAIL from the runner's exit code).
#                       Default "" (disabled). See pipeline-hooks.sh for the
#                       full contract.
#
# TALOS_STAGE_DURATION_S: if the caller sets this (seconds, integer), it is
# forwarded as hooks.post_stage's duration_s field; otherwise duration_s is
# null. pipeline-agent.sh does not time the run itself.
#
# runner_cmd environment: TALOS_ROLE, TALOS_ISSUE_NUMBER, TALOS_WORKTREE_PATH,
# and TALOS_EFFORT are exported and visible to runner_cmd. TALOS_ROLE lets you
# route by role:
#   e.g. case "$TALOS_ROLE" in
#          developer|qa) exec pi -p --provider ds4 --model deepseek-v4-flash "$(cat)" ;;
#          *)            exec claude -p "$(cat)" ;;
#        esac
# TALOS_ISSUE_NUMBER is the issue number passed via TALOS_ISSUE=<N> in the caller's
# environment; empty string when the caller does not set TALOS_ISSUE.
# TALOS_WORKTREE_PATH is the $PWD at the time pipeline-agent.sh was invoked.
# TALOS_EFFORT is the role's resolved agents.effort (#271, see the config-keys
# block above) — empty string when neither agents.roles.<role>.effort nor
# agents.effort is set. A runner_cmd maps it to its own CLI's effort/reasoning
# flag, e.g. case "$TALOS_EFFORT" in low) set -- --reasoning-effort low ;; esac.
# Verify scripts can assert they are running in the correct worktree:
#   if [ "${TALOS_ISSUE_NUMBER:-}" != "$EXPECTED" ]; then exit 1; fi
#
# Runner invocations:
#   claude       claude -p --setting-sources project [args] <prompt>
#                (--setting-sources project keeps user-global CLAUDE.md
#                 instructions out of pipeline workers)
#   pi           pi -p [args] <prompt>     # pi print mode, one-shot headless stage
#   codex        codex exec [args] <prompt>
#   gemini       gemini [args] -p <prompt>
#   antigravity  agy [args] -p <prompt>
#                # invocation per Antigravity CLI docs (2026-03)
#   custom       prompt written to a temp file, then
#                sh -c "$runner_cmd" < <prompt-file>   (not a pipe -- #208)
#
# NOTE: the pi orchestrator playbook uses INLINE mode (agents.subagents: false,
# agents.runner: pi) and does NOT call this script — pi acts as each stage role
# itself, one role per turn. This pi case only covers running a single stage
# headlessly when explicitly requested.
#
# The runner must be an AGENTIC CLI (able to execute shell commands and edit
# files) — a bare model endpoint can generate text but cannot run a stage.
# Local models work through any agentic CLI that supports them (e.g. a
# runner_cmd wrapping an Ollama-backed coding agent).
#
# Exit code is the runner's exit code — the orchestrator reacts to failures.
# (hooks.post_stage, if configured, runs after the runner exits but before
# this script returns; it never changes the exit code.)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pipeline-paths.sh
. "$SCRIPT_DIR/pipeline-paths.sh"
# cfg() (#169): dumps the config once per invocation and answers lookups
# from that cache instead of re-parsing on every call. Guarded (#169 review):
# a partial install/sync may not yet ship pipeline-cfg-cache.sh: that is fatal
# (no per-call fallback: it would hide the fail-closed exit of a broken table).
if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  echo "talos: pipeline-cfg-cache.sh missing; reinstall Talos" >&2
  exit 1
fi

# ── Per-role runner resolution (#167) ─────────────────────────────────────────
# Role-first: agents.roles.<role>.runner / .runner_cmd win over the global
# agents.runner / agents.runner_cmd when set. One function each, shared by
# --resolve below and the real dispatch further down, so there is exactly
# one place this precedence is decided.
_resolve_runner() {
  local _role="$1" _r
  _r="$(cfg "agents.roles.$_role.runner")"
  [ -n "$_r" ] || _r="$(cfg agents.runner)"
  printf '%s' "$_r"
}

_resolve_runner_cmd() {
  local _role="$1" _c
  _c="$(cfg "agents.roles.$_role.runner_cmd")"
  [ -n "$_c" ] || _c="$(cfg agents.runner_cmd)"
  printf '%s' "$_c"
}

_resolve_model() {
  local _role="$1" _m
  _m="$(cfg "agents.roles.$_role.model")"
  [ -n "$_m" ] || _m="$(cfg agents.model)"
  printf '%s' "$_m"
}

# _resolve_effort (#271): same role-first precedence as _resolve_model above
# — agents.roles.<role>.effort wins, else the global agents.effort, else
# empty (the runner's own default, unchanged behaviour). Unlike
# agents.restamp_model/.restamp_effort, this chain has no config-derived
# default to lean on, so it is resolved here rather than in
# pipeline-config.sh, exactly like _resolve_model.
_resolve_effort() {
  local _role="$1" _e
  _e="$(cfg "agents.roles.$_role.effort")"
  [ -n "$_e" ] || _e="$(cfg agents.effort)"
  printf '%s' "$_e"
}

# _resolve_fallback <role> (#418): role-first agents.fallback, one runner name
# per line (the config reader already validated the list; invalid reads absent).
_resolve_fallback() {
  local _role="$1" _f
  _f="$(cfg "agents.roles.$_role.fallback")"
  [ -n "$_f" ] || _f="$(cfg agents.fallback)"
  printf '%s' "$_f"
}

# _fallback_chain <role> <primary>: the resolved chain, one runner per line,
# without the primary (it varies by role, so config cannot check that). Notes
# each dropped entry once on stderr.
_fallback_chain() {
  local _role="$1" _primary="$2" _e
  while IFS= read -r _e; do
    [ -n "$_e" ] || continue
    if [ "$_e" = "$_primary" ]; then
      echo "pipeline-agent: agents.fallback lists the primary runner '$_primary' (role=$_role) -- dropped" >&2
    else
      printf '%s\n' "$_e"
    fi
  done <<EOF
$(_resolve_fallback "$_role")
EOF
}

# ── Role definition lookup (#367) ─────────────────────────────────────────────
# One function decides the order for a stage run and for --resolve-profile (see
# the header). The role name reaches a path, so it is validated first: lowercase
# letters and '-', not starting with '-' (no '/', no '..', no control chars).
# A glob range like [a-z] is locale-dependent in bash 3.2, so list the letters.
_valid_role_name() {
  case "$1" in
    "" | -* | *[!abcdefghijklmnopqrstuvwxyz-]*) return 1 ;;
  esac
  return 0
}

# _neutral_profile <role>: print $PWD/.agents/talos/agents/<role>.md when it is
# a regular file reached without crossing a symlink (the file, or .agents,
# .agents/talos, .agents/talos/agents), else print nothing and return 1. A
# symlink is refused outright rather than checked for where it points: a
# committed link that resolves outside the repo must never be read as a profile.
_neutral_profile() {
  local _p="$PWD/.agents/talos/agents/$1.md" _x
  for _x in "$PWD/.agents" "$PWD/.agents/talos" "$PWD/.agents/talos/agents" "$_p"; do
    [ ! -L "$_x" ] || return 1
  done
  [ -f "$_p" ] || return 1
  printf '%s\n' "$_p"
}

# _resolve_role_profile <role>: print the profile path (0), or explain on
# stderr and return 1 (not found) / 2 (invalid role name).
_resolve_role_profile() {
  local _role="$1" _scripts _agents _neutral _c
  if ! _valid_role_name "$_role"; then
    echo "pipeline-agent: invalid role name '$(printf '%s' "$_role" | tr -d '[:cntrl:]')' (lowercase letters and '-' only, not starting with '-')" >&2
    return 2
  fi
  _scripts="$(_resolve_talos_dir pipeline-vcs.sh 2>/dev/null || true)"
  _agents="${_scripts:+$(cd "$_scripts/.." && pwd)/agents}"
  _neutral="$(_neutral_profile "$_role" || true)"
  for _c in \
    "$PWD/.claude/agents/$_role.md" \
    "$_neutral" \
    "${_agents:+$_agents/$_role.md}" \
    "$SCRIPT_DIR/../agents/$_role.md" \
    "$SCRIPT_DIR/../../agents/$_role.md" \
    "$SCRIPT_DIR/../.claude/agents/$_role.md"; do
    [ -n "$_c" ] || continue
    if [ -f "$_c" ]; then printf '%s\n' "$_c"; return 0; fi
  done
  echo "pipeline-agent: role definition not found: $_role" >&2
  echo "  looked in: $PWD/.claude/agents/, $PWD/.agents/talos/agents/, ${_agents:-<no Talos install found>}/ (the install, via _resolve_talos_dir: \$TALOS_HOME, ~/.talos, \$CLAUDE_PLUGIN_ROOT, .claude/talos), $SCRIPT_DIR/../agents/, $SCRIPT_DIR/../../agents/, $SCRIPT_DIR/../.claude/agents/" >&2
  return 1
}

# --resolve <role>: print the resolved runner/runner_cmd/model/effort and
# exit, without running anything. Shared resolution for the orchestrator's
# native-path per-role dispatch decision (skills/pipeline/SKILL.md).
if [ "${1:-}" = "--resolve" ]; then
  _RESOLVE_ROLE="${2:-}"
  if [ -z "$_RESOLVE_ROLE" ]; then
    echo "Usage: pipeline-agent.sh --resolve <role>" >&2
    exit 2
  fi
  _RESOLVED_RUNNER="$(_resolve_runner "$_RESOLVE_ROLE")"
  case "$_RESOLVED_RUNNER" in
    claude | pi | codex | gemini | antigravity | custom) : ;;
    *)
      echo "pipeline-agent: unknown agents.runner '$_RESOLVED_RUNNER' (role=$_RESOLVE_ROLE). Valid: claude | pi | codex | gemini | antigravity | custom" >&2
      exit 1
      ;;
  esac
  # fallback= (#418): appended only when a chain resolves, so a role without
  # one keeps the exact line.
  _RESOLVED_FB="$(_fallback_chain "$_RESOLVE_ROLE" "$_RESOLVED_RUNNER" 2>/dev/null | paste -sd, -)"
  printf 'runner=%s runner_cmd=%s model=%s effort=%s%s\n' \
    "$_RESOLVED_RUNNER" \
    "$(_resolve_runner_cmd "$_RESOLVE_ROLE")" \
    "$(_resolve_model "$_RESOLVE_ROLE")" \
    "$(_resolve_effort "$_RESOLVE_ROLE")" \
    "${_RESOLVED_FB:+ fallback=$_RESOLVED_FB}"
  exit 0
fi

# --resolve-all (#336): one line per role -- the model it will run on, its
# re-stamp model, and which config layer decided the model ("project" = the
# repo's talos.pipeline.*, "global" = the user-level file under
# ${TALOS_HOME:-$HOME/.talos}, "session default" = neither set one, so the
# role inherits the session model). Same role-first chain as _resolve_model;
# the re-stamp chain is role restamp -> agents.restamp_model -> agents.model.
# A role with a runner / runner_cmd set (#340) gets runner=/runner_origin= and
# runner_cmd=/runner_cmd_origin= appended; a role with neither has no new columns.
# The runner_cmd value is the last field, after a TAB (#342).
# Also warns on stderr when a role file Claude Code would load still carries
# a frontmatter `model:` line: that line applies whenever the config resolves
# empty, so it defeats "the config is the only place a model is set".
if [ "${1:-}" = "--resolve-all" ]; then
  _ALL_ROLES="validator pm developer qa reviewer security adversarial docs planner"
  # key<TAB>value<TAB>layer for every agents.* key (#442); one python3 spawn.
  # "repo" is the project file; a key set by neither file (default, env) has no
  # origin to show here, so it stays empty.
  _LAYERS="$(bash "$SCRIPT_DIR/pipeline-config.sh" --show agents. 2>/dev/null)"
  _layer_of() {
    local _line _l
    while IFS= read -r _line; do
      case "$_line" in
        "$1"$'\t'*)
          _l="${_line##*$'\t'}"
          case "$_l" in
            repo) printf 'project' ;;
            global) printf 'global' ;;
          esac
          return 0 ;;
      esac
    done <<EOF
$_LAYERS
EOF
  }
  # Config values are untrusted text (the user-level file): strip control
  # characters, newlines and ESC included, so a value cannot forge a row or
  # drive the terminal. That is C0 + DEL and the UTF-8 C1 controls (U+0080-
  # U+009F, bytes c2 80..c2 9f; U+009B is a one-character CSI). Other UTF-8
  # text passes through. Only --resolve-all does this; --resolve stays as-is.
  _plain() {
    printf '%s' "$1" | python3 -I -c '
import re, sys
sys.stdout.buffer.write(re.sub(rb"[\x00-\x1f\x7f]|\xc2[\x80-\x9f]", b"", sys.stdin.buffer.read()))'
  }
  for _r in $_ALL_ROLES; do
    _m="$(_plain "$(_resolve_model "$_r")")"
    if [ -n "$(cfg "agents.roles.$_r.model")" ]; then
      _origin="$(_layer_of "agents.roles.$_r.model")"
    elif [ -n "$(cfg agents.model)" ]; then
      _origin="$(_layer_of agents.model)"
    else
      _origin="session default"
    fi
    _rs="$(cfg "agents.roles.$_r.restamp_model")"
    [ -n "$_rs" ] || _rs="$(cfg agents.restamp_model)"
    [ -n "$_rs" ] || _rs="$(cfg agents.model)"
    # runner / runner_cmd (#340): appended, and only when one is set, so a role
    # with neither keeps the exact four-column line. A user-level runner applies
    # to every repo, so say which layer supplied it. Same role-first chain as
    # _resolve_runner / _resolve_runner_cmd.
    _extra=""
    _rv="$(cfg "agents.roles.$_r.runner")"
    if [ -n "$_rv" ]; then
      _extra="$_extra runner=$(_plain "$_rv") runner_origin=$(_layer_of "agents.roles.$_r.runner")"
    else
      # Only an explicitly set agents.runner is shown: a table default (claude)
      # is not a configured value, so ask the layer map whether a file set it.
      _rv=""
      [ -z "$(_layer_of agents.runner)" ] || _rv="$(cfg agents.runner)"
      [ -z "$_rv" ] || _extra="$_extra runner=$(_plain "$_rv") runner_origin=$(_layer_of agents.runner)"
    fi
    # runner_cmd is free text (spaces, even the words "runner_cmd_origin="), so it
    # goes LAST and after a TAB, which _plain strips from every value: its origin
    # comes first as an ordinary column, and `cut -f2-` on the TAB yields the
    # whole `runner_cmd=<value>` field no matter what the value holds (#342).
    _cmd=""
    _rv="$(cfg "agents.roles.$_r.runner_cmd")"
    if [ -n "$_rv" ]; then
      _extra="$_extra runner_cmd_origin=$(_layer_of "agents.roles.$_r.runner_cmd")"
      _cmd="$(printf '\trunner_cmd=%s' "$(_plain "$_rv")")"
    else
      _rv="$(cfg agents.runner_cmd)"
      if [ -n "$_rv" ]; then
        _extra="$_extra runner_cmd_origin=$(_layer_of agents.runner_cmd)"
        _cmd="$(printf '\trunner_cmd=%s' "$(_plain "$_rv")")"
      fi
    fi
    # fallback / fallback_origin (#418): pre-TAB columns, only when a chain resolves.
    _fb="$(_fallback_chain "$_r" "$(_resolve_runner "$_r")" 2>/dev/null | paste -sd, -)"
    if [ -n "$_fb" ]; then
      if [ -n "$(cfg "agents.roles.$_r.fallback")" ]; then
        _fbo="$(_layer_of "agents.roles.$_r.fallback")"
      else
        _fbo="$(_layer_of agents.fallback)"
      fi
      _extra="$_extra fallback=$_fb fallback_origin=$_fbo"
    fi
    printf 'role=%s model=%s restamp_model=%s origin=%s%s%s\n' "$_r" "$_m" "$(_plain "$_rs")" "$_origin" "$_extra" "$_cmd"
    for _dir in "$PWD/.claude/agents" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents"; do
      _f="$_dir/$_r.md"
      [ -f "$_f" ] || continue
      if awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {exit} fm && /^model:/ {found=1} END {exit !found}' "$_f"; then
        echo "pipeline-agent: [warn] $_f still sets model: in its frontmatter; it applies whenever the config resolves empty -- remove the line so the Talos config is the only source" >&2
      fi
    done
    # (#367) The scan above covers only the two directories Claude Code loads:
    # the adapter strips frontmatter, so a model: line in the neutral file
    # $PWD/.agents/talos/agents/<role>.md never applies and is not warned about.
    # The neutral file itself is warned about when it is shadowed, or when the
    # native Claude path (which never reads it) would be the one running the
    # role: one stderr line per role, stdout untouched.
    _np="$(_neutral_profile "$_r" || true)"
    if [ -n "$_np" ]; then
      if [ -f "$PWD/.claude/agents/$_r.md" ]; then
        echo "pipeline-agent: [warn] $_np is shadowed by $PWD/.claude/agents/$_r.md; the adapter and pi inline paths read the .claude/agents file" >&2
      elif [ "$(_resolve_runner "$_r")" = "claude" ] && [ "$(cfg agents.subagents)" != "false" ]; then
        echo "pipeline-agent: [warn] $_np is read only by the adapter and pi inline paths; the native Claude path does not read it -- put the profile in $PWD/.claude/agents/$_r.md for role $_r" >&2
      fi
    fi
  done
  exit 0
fi

# --resolve-profile <role> (#367): print the role definition a stage run would
# use, from the same _resolve_role_profile. pi inline mode finds its profile
# with this instead of re-deriving the order in prose.
if [ "${1:-}" = "--resolve-profile" ]; then
  if [ -z "${2:-}" ]; then
    echo "Usage: pipeline-agent.sh --resolve-profile <role>" >&2
    exit 2
  fi
  _resolve_role_profile "$2"
  exit $?
fi

# --check-effort <role> (#445): the native-path effort notice, as a verb so the
# orchestrator playbook carries one call instead of the resolution prose. Config
# is advisory there (no per-spawn effort parameter; the orchestrator never writes
# a tracked file), so this only compares the resolved value with the role file's
# committed `effort:` frontmatter and names both on one stdout line.
if [ "${1:-}" = "--check-effort" ]; then
  if [ -z "${2:-}" ]; then
    echo "Usage: pipeline-agent.sh --check-effort <role>" >&2
    exit 2
  fi
  _valid_role_name "$2" || { _resolve_role_profile "$2" >/dev/null; exit $?; }
  [ "$(_resolve_runner "$2")" = "claude" ] || exit 0
  _CE_CFG="$(_resolve_effort "$2")"
  [ -n "$_CE_CFG" ] || exit 0
  _CE_FILE="$(_resolve_role_profile "$2" 2>/dev/null || true)"
  _CE_FM=""
  if [ -n "$_CE_FILE" ]; then
    _CE_FM="$(awk 'NR==1 { if ($0 !~ /^---[ \t\r]*$/) exit; next }
      /^---[ \t\r]*$/ { exit }
      /^effort:/ { sub(/^effort:[ \t]*/, ""); gsub(/[\r"'"'"' \t]/, ""); print; exit }' "$_CE_FILE")"
  fi
  [ "$_CE_CFG" != "$_CE_FM" ] || exit 0
  _CE_SHOW="${_CE_FM:+effort=$_CE_FM}"
  printf "talos: notice: role '%s' has effort=%s in config but its frontmatter has %s -- native path uses the committed frontmatter; config effort is advisory here\n" \
    "$2" "$_CE_CFG" "${_CE_SHOW:-no effort:}"
  exit 0
fi

# ── Provider-error classification (#418) ──────────────────────────────────────
# _classify_exit <runner> <rc> <file>... sets CLASS (ok | provider | task) and
# CLASS_DETAIL (a short fixed token, e.g. 429) -- globals, not stdout, so the
# detail survives without a subshell. ONE function holds the whole table.
#   ok        rc 0.
#   provider  rc 75 (EX_TEMPFAIL) from ANY runner or runner_cmd, the one signal
#             that is stable and the documented contract for `custom`; else a
#             runner-specific, LINE-ANCHORED error shape in the last 20 lines of
#             each <file> (at most 64 KB). A bare "429" or "rate limit" in model
#             prose never matches, because every shape starts at the line start.
#   task      everything else, including any unrecognised non-zero exit. The
#             failure mode is the existing behaviour, never a silent provider
#             switch.
# Per-runner patterns. UNVERIFIED: none of them were captured from a real CLI
# run (the only observed signal is the spend-limit 429 in tasks/lessons.md);
# they are candidates and a pattern that stops matching only means a provider
# error falls back to `task`. A runner with no entry below (codex, gemini,
# antigravity, pi, custom) ships exit-75-only until its patterns are captured.
CLASS="" CLASS_DETAIL=""
_classify_exit() {
  local _runner="$1" _rc="$2" _f _txt=""
  shift 2
  CLASS="task"; CLASS_DETAIL=""
  case "$_rc" in
    0) CLASS="ok"; return 0 ;;
    75) CLASS="provider"; CLASS_DETAIL="exit75"; return 0 ;;
  esac
  for _f in "$@"; do
    [ -r "$_f" ] || continue
    _txt="$_txt$(tail -n 20 "$_f" 2>/dev/null | tail -c 65536 | tr -d '\000')
"
  done
  _cls_has() { printf '%s' "$_txt" | LC_ALL=C grep -Eq "$1"; }
  case "$_runner" in
    claude)
      if _cls_has '^(API Error: [0-9]{3} .*)?([Cc]redit balance is too low|(Claude AI )?[Uu]sage limit reached)'; then
        CLASS="provider"; CLASS_DETAIL="quota"
      elif _cls_has '^(API Error: 401( |$)|Invalid API key|API Error: .*authentication_error)'; then
        CLASS="provider"; CLASS_DETAIL="auth"
      elif _cls_has '^API Error: 429( |$)'; then
        CLASS="provider"; CLASS_DETAIL="429"
      elif _cls_has '^API Error: (5[0-9]{2}( |$)|.*overloaded_error)'; then
        CLASS="provider"; CLASS_DETAIL="overloaded"
      elif _cls_has '^((API Error|Error): .*(ECONNRESET|ETIMEDOUT|ENOTFOUND)|getaddrinfo ENOTFOUND|connect ETIMEDOUT|read ECONNRESET)'; then
        CLASS="provider"; CLASS_DETAIL="network"
      fi
      ;;
  esac
  unset -f _cls_has
  return 0
}

# ── Provider down-tracking (#418) ─────────────────────────────────────────────
# .talos/providers.json: {"<runner>": {"down_until", "reason", "since"}}, in the
# repository's common git directory's parent (like pipeline-events.sh path), so a
# worktree and the main checkout share it. Bookkeeping never blocks a stage: a
# missing repo, an unreadable or corrupt file reads as "nothing is down" with one
# warning, and a failed write only warns. Reads are lock-free; writes are atomic
# (temp file + rename) under with_lock.
if [ -f "$SCRIPT_DIR/pipeline-lock.sh" ]; then
  # shellcheck source=pipeline-lock.sh
  . "$SCRIPT_DIR/pipeline-lock.sh"
fi

_prov_path() {
  local _cd
  _cd="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$_cd" ] || return 1
  case "$_cd" in
    /*) : ;;
    *) _cd="$(cd "$(dirname "$_cd")" 2>/dev/null && pwd)/$(basename "$_cd")" ;;
  esac
  printf '%s/.talos/providers.json' "$(dirname "$_cd")"
}

# _prov_down <file>: one runner name per line for every unexpired entry.
_prov_down() {
  [ -f "$1" ] || return 0
  python3 -I - "$1" <<'PYEOF'
import datetime, json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("not a mapping")
except Exception as e:
    sys.stderr.write("pipeline-agent: [warn] %r unreadable or corrupt (%s) -- treating every runner as up\n" % (path, type(e).__name__))
    sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
known = ("claude", "pi", "codex", "gemini", "antigravity", "custom")
for name, ent in data.items():
    try:
        until = datetime.datetime.strptime(ent["down_until"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except Exception:
        continue
    if name in known and until > now:
        print(name)
PYEOF
}

# _prov_write <file> <runner> <reason> <seconds>: read-modify-write; expired
# entries are pruned. Run under with_lock by _prov_mark_down.
_prov_write() {
  python3 -I - "$1" "$2" "$3" "$4" <<'PYEOF'
import datetime, json, os, sys
path, runner, reason, secs = sys.argv[1:5]
fmt = "%Y-%m-%dT%H:%M:%SZ"
utc = datetime.timezone.utc
now = datetime.datetime.now(utc)
try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
keep = {}
for name, ent in data.items():
    try:
        if datetime.datetime.strptime(ent["down_until"], fmt).replace(tzinfo=utc) > now:
            keep[name] = ent
    except Exception:
        pass
reason = "".join(c for c in reason if 32 <= ord(c) != 127)[:200]
keep[runner] = {
    "down_until": (now + datetime.timedelta(seconds=int(secs))).strftime(fmt),
    "reason": reason,
    "since": now.strftime(fmt),
}
tmp = "%s.tmp.%d" % (path, os.getpid())
with open(tmp, "w") as f:
    json.dump(keep, f, indent=1, sort_keys=True)
    f.write("\n")
os.replace(tmp, path)
PYEOF
}

# _prov_mark_down <runner> <class:detail>
_prov_mark_down() {
  local _file _secs
  _file="$(_prov_path)" || { echo "pipeline-agent: [warn] not in a git repository -- cannot record $1 as down" >&2; return 0; }
  _secs="$(cfg agents.provider_down_s)"
  mkdir -p "$(dirname "$_file")" 2>/dev/null || { echo "pipeline-agent: [warn] cannot create $(dirname "$_file") -- $1 not recorded as down" >&2; return 0; }
  if command -v with_lock >/dev/null 2>&1; then
    with_lock "$_file" 5 -- _prov_write "$_file" "$1" "$2" "$_secs" \
      || echo "pipeline-agent: [warn] could not write $_file" >&2
  else
    _prov_write "$_file" "$1" "$2" "$_secs" || echo "pipeline-agent: [warn] could not write $_file" >&2
  fi
  return 0
}

_is_runner_id() {
  case "$1" in claude | pi | codex | gemini | antigravity | custom) return 0 ;; esac
  return 1
}

# --classify <runner> <rc> <file|->: print the class on stdout, exit 0.
if [ "${1:-}" = "--classify" ]; then
  _CL_FILE="${4:-}"
  if ! _is_runner_id "${2:-}" || [ -z "${3:-}" ] || [ -z "$_CL_FILE" ]; then
    echo "Usage: pipeline-agent.sh --classify <runner> <rc> <file|->" >&2
    exit 2
  fi
  case "$3" in *[!0-9]*) echo "pipeline-agent: --classify: <rc> must be an integer" >&2; exit 2 ;; esac
  if [ "$_CL_FILE" = "-" ]; then
    _CL_TMP="$(mktemp "${TMPDIR:-/tmp}/talos-classify.XXXXXX")" || exit 2
    cat >"$_CL_TMP"
    _CL_FILE="$_CL_TMP"
  elif [ ! -r "$_CL_FILE" ]; then
    echo "pipeline-agent: --classify: cannot read '$_CL_FILE'" >&2
    exit 2
  fi
  _classify_exit "$2" "$3" "$_CL_FILE"
  [ -z "${_CL_TMP:-}" ] || rm -f "$_CL_TMP"
  printf '%s\n' "$CLASS"
  exit 0
fi

# --mark-down <runner> <class:detail>: record the runner as down.
if [ "${1:-}" = "--mark-down" ]; then
  if ! _is_runner_id "${2:-}" || [ -z "${3:-}" ]; then
    echo "Usage: pipeline-agent.sh --mark-down <runner> <class:detail>" >&2
    exit 2
  fi
  _prov_mark_down "$2" "$3"
  exit 0
fi

ROLE="${1:-}"
TASK="${2:-}"
# Export TALOS_ROLE so runner_cmd (runner=custom) can route by role.
# ROLE is kept as the local variable used for role-file lookup below.
TALOS_ROLE="$ROLE"
export TALOS_ROLE

# Export per-agent identity so verify: commands can self-check their environment.
# TALOS_ISSUE is set by the caller (e.g. TALOS_ISSUE=54 pipeline-agent.sh qa "<prompt>").
# Two-arg callers that do not set TALOS_ISSUE are unaffected: TALOS_ISSUE_NUMBER is
# exported as the empty string, which is distinct from an unset variable and lets
# verify scripts distinguish "Talos did not set this" from any real issue number.
# TALOS_WORKTREE_PATH is the working directory at invocation time — the worktree root.
#
# Validate TALOS_ISSUE: must be empty or a plain non-negative integer.
# Empty is allowed — two-arg callers never set TALOS_ISSUE and must keep working.
# Anything else (shell metacharacters, whitespace, non-digits) is rejected with exit 2.
_raw_issue="${TALOS_ISSUE:-}"
if [ -n "$_raw_issue" ]; then
  case "$_raw_issue" in
    *[!0-9]*)
      echo "pipeline-agent: TALOS_ISSUE must be a plain integer (got: $_raw_issue)" >&2
      exit 2
      ;;
  esac
fi
TALOS_ISSUE_NUMBER="$_raw_issue"
TALOS_WORKTREE_PATH="$PWD"
# TALOS_EFFORT (#271): role-first resolved agents.effort, same precedence as
# _resolve_model. Empty when neither the role nor the global key is set —
# runner_cmd (or a runner-specific branch below) maps it to that CLI's own
# effort/reasoning flag; it is not applied to the claude case below because
# claude's mechanism is the dispatched agent definition's frontmatter
# `effort:` field, which only exists on the native Claude Code subagent
# path (skills/pipeline/SKILL.md), not this script's single-shot `claude -p`.
TALOS_EFFORT="$(_resolve_effort "$ROLE")"
export TALOS_ISSUE_NUMBER TALOS_WORKTREE_PATH TALOS_EFFORT

if [ -z "$ROLE" ] || [ -z "$TASK" ]; then
  echo "Usage: pipeline-agent.sh <role> <task-prompt|->" >&2
  exit 2
fi
[ "$TASK" = "-" ] && TASK="$(cat)"

# ── Locate the role definition ────────────────────────────────────────────────
# _resolve_role_profile (above) holds the order, shared with --resolve-profile:
# $PWD/.claude/agents, $PWD/.agents/talos/agents, the install's agents/, then
# the self-relative fallbacks (see the header). The repo overrides are $PWD
# relative, $PWD being the worktree root at invocation time; .claude/agents
# also covers vendored-install back-compat (install.sh has always written
# agents there).
ROLE_FILE="$(_resolve_role_profile "$ROLE")" || exit $?

# Strip YAML frontmatter (--- ... --- at the top) — Claude Code metadata only.
ROLE_BODY="$(awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; next} !fm' "$ROLE_FILE")"

PROMPT="$ROLE_BODY

---

$TASK"

# hooks.pre_dispatch (#181): run the configured command (if any) and prepend
# its output to the prompt under a "## Context" heading. Delegated to
# pipeline-hooks.sh, which owns the disabled/failure/timeout/empty-output
# no-op contract -- this call site only prepends non-empty output, never
# branches on failure. Guarded the same way pipeline-cfg-cache.sh is above:
# a partial install/sync may not yet ship pipeline-hooks.sh.
if [ -f "$SCRIPT_DIR/pipeline-hooks.sh" ]; then
  # files_hint (#181 review): populated only when the caller provides it --
  # today that means TALOS_FILES_HINT, newline-separated paths, if set.
  _HOOK_FILES_HINT=()
  if [ -n "${TALOS_FILES_HINT:-}" ]; then
    while IFS= read -r _hook_file; do
      [ -n "$_hook_file" ] && _HOOK_FILES_HINT+=("$_hook_file")
    done <<<"$TALOS_FILES_HINT"
  fi
  _HOOK_CONTEXT="$(bash "$SCRIPT_DIR/pipeline-hooks.sh" pre_dispatch \
    "$ROLE" "$TALOS_ISSUE_NUMBER" "" "$TALOS_WORKTREE_PATH" \
    ${_HOOK_FILES_HINT[@]+"${_HOOK_FILES_HINT[@]}"})"
  if [ -n "$_HOOK_CONTEXT" ]; then
    PROMPT="$_HOOK_CONTEXT
$PROMPT"
  fi
fi

# ── Runner selection (role-first; #167) ───────────────────────────────────────
# agents.roles.<role>.runner wins over agents.runner (default claude) — see
# _resolve_runner above. Validated against the supported set up front so an
# invalid value fails clearly before any prompt-building work happens, and
# the resolution is announced once on stderr (talos:runner marker) so a run
# mixing per-role runners is legible in logs without re-deriving precedence.
RUNNER="$(_resolve_runner "$ROLE")"
case "$RUNNER" in
  claude | pi | codex | gemini | antigravity | custom) : ;;
  *)
    echo "pipeline-agent: unknown agents.runner '$RUNNER' (role=$ROLE). Valid: claude | pi | codex | gemini | antigravity | custom" >&2
    exit 1
    ;;
esac
echo "talos:runner role=$ROLE runner=$RUNNER" >&2

# agents.runner_args comes back newline-separated (list) — build an array.
RUNNER_ARGS=()
while IFS= read -r line; do
  [ -n "$line" ] && RUNNER_ARGS+=("$line")
done <<EOF
$(cfg agents.runner_args)
EOF

# RC (#182): every branch below used to `exec` straight into the runner, so
# the runner's exit code WAS this script's exit code and nothing ran after
# it. hooks.post_stage needs to fire once the runner exits (event
# stage_complete, verdict derived from its exit code), so each branch now
# runs the runner as a normal foreground command and records its exit code
# in RC instead — the post-`esac` block below fires the hook, then exits
# with RC so callers still see exactly the runner's own exit status.
#
# _run_runner <runner> (#418): the one place a runner is invoked, so the
# failover loop below reruns exactly the same invocation (same built prompt,
# every argv shape unchanged). Without a chain it is called once, inline.
RC=0
_run_runner() {
# (body not indented: tests/test-runner-conformance.sh finds the dispatch arms by column)
local RUNNER="$1"
case "$RUNNER" in
  claude)
    claude -p --setting-sources project \
      ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"} "$PROMPT"
    RC=$?
    ;;
  codex)
    codex exec ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"} "$PROMPT"
    RC=$?
    ;;
  gemini)
    gemini ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"} -p "$PROMPT"
    RC=$?
    ;;
  antigravity)
    # invocation per Antigravity CLI docs (2026-03)
    agy ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"} -p "$PROMPT"
    RC=$?
    ;;
  pi)
    # pi print mode — one-shot headless stage (inline mode is the pi default;
    # this case exists for callers that want a single headless stage).
    pi -p ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"} "$PROMPT"
    RC=$?
    ;;
  custom)
    RUNNER_CMD="$(_resolve_runner_cmd "$ROLE")"
    if [ -z "$RUNNER_CMD" ]; then
      echo "pipeline-agent: agents.runner=custom requires agents.runner_cmd (role=$ROLE)" >&2
      exit 1
    fi
    # Feed the prompt via a temp file, not a pipe (#208): piping through
    # `printf | sh -c` puts printf on the writer end, and a runner_cmd that
    # exits without reading all of stdin (or simply loses the race on a
    # loaded host) sends printf a SIGPIPE/EPIPE. Under `set -o pipefail`
    # that turns into a spurious pipeline-agent.sh exit 1 even though the
    # runner itself exited 0. Writing to a file first removes the writer
    # process entirely, so there is nothing to receive EPIPE.
    # Fail closed if mktemp -d fails (#215 review): an empty _PROMPT_DIR
    # would otherwise make _PROMPT_FILE the literal path "/prompt", writing
    # the prompt (which may contain issue-thread text) to a fixed path on a
    # root CI container, with the EXIT trap's `rm -rf "$_PROMPT_DIR"` a
    # no-op since _PROMPT_DIR was never set. Mirrors the guard pattern in
    # pipeline-cfg-cache.sh: `mktemp -d ... || VAR=""` gated by `[ -n "$VAR" ]`.
    # (#418: created once; a failover rerun reuses the same prompt file.)
    if [ -z "${_PROMPT_FILE:-}" ]; then
      _PROMPT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/talos-prompt.XXXXXX" 2>/dev/null)" || _PROMPT_DIR=""
      if [ -z "$_PROMPT_DIR" ]; then
        echo "pipeline-agent: custom runner: failed to create a temp directory for the prompt (mktemp -d)" >&2
        exit 1
      fi
      _PROMPT_FILE="$_PROMPT_DIR/prompt"
      (umask 077 && printf '%s' "$PROMPT" >"$_PROMPT_FILE")
      if command -v _talos_on_exit >/dev/null 2>&1; then
        _talos_on_exit 'rm -rf "$_PROMPT_DIR"'
      else
        trap 'rm -rf "$_PROMPT_DIR"' EXIT
      fi
    fi
    sh -c "$RUNNER_CMD" <"$_PROMPT_FILE"
    RC=$?
    ;;
    # No *) arm: RUNNER is already validated against the supported set
    # above, before the talos:runner marker is emitted -- an unknown value
    # exits there and never reaches this case.
esac
}

# ── Runner failover (#418) ────────────────────────────────────────────────────
# Only with a chain (agents.fallback / agents.roles.<role>.fallback). Each
# attempt's stdout and stderr go to temp files (mode 600, removed on exit; no
# process substitution); stderr is replayed after every attempt, stdout only for
# the final one, so two runners' output is never concatenated. The rerun reuses
# the prompt built once above (no second pre_dispatch) and the same invocation.
#
# Write guard: a failover never reruns a stage that already wrote. The runner
# gets TALOS_WRITE_LOG; pipeline-vcs.sh appends each successful non-idempotent
# verb to it. A non-empty journal, or a changed `git for-each-ref refs/remotes`
# (a push moves a remote-tracking ref), after a provider exit means NO rerun:
# the provider is marked down, talos:failover-refused is emitted, exit 69. KNOWN
# GAP: a runner that calls raw `gh` instead of pipeline-vcs.sh is not seen (the
# role profiles forbid it). Any other writer to refs/remotes (a parallel
# `git fetch`) reads as a push: the failover is refused, never forced.
_FO_FINAL="" _FO_PRIMARY="$RUNNER"
_fo_event() {  # <from> <to> <reason>
  [ -f "$SCRIPT_DIR/pipeline-hooks.sh" ] || return 0
  bash "$SCRIPT_DIR/pipeline-hooks.sh" post_stage failover orchestrator "$TALOS_ISSUE_NUMBER" \
    --summary "role=$ROLE from=$1 to=$2 reason=$3" || true
}
_fo_switch() {
  echo "talos:failover role=$ROLE from=$1 to=$2 reason=$3" >&2
  _fo_event "$1" "$2" "$3"
}
_fo_unavailable() {  # <runner>: 0 when a FALLBACK runner cannot be started
  case "$1" in
    custom) [ -z "$(_resolve_runner_cmd "$ROLE")" ] ;;
    antigravity) ! command -v agy >/dev/null 2>&1 ;;
    *) ! command -v "$1" >/dev/null 2>&1 ;;
  esac
}
_fo_checkpoint() {
  [ -n "$TALOS_ISSUE_NUMBER" ] || return 0
  local _crc=0
  if [ -f "$SCRIPT_DIR/pipeline-worktree.sh" ]; then
    bash "$SCRIPT_DIR/pipeline-worktree.sh" checkpoint "$TALOS_ISSUE_NUMBER" >/dev/null 2>&1 || _crc=$?
  else
    _crc=127
  fi
  if [ "$_crc" -ne 0 ]; then
    echo "talos:failover checkpoint-skipped role=$ROLE rc=$_crc (the files stay in the worktree)" >&2
  fi
  return 0
}
_run_chain() {
  local _order _cands=() _down _r _i _n _nxt _snap _verbs _why _reasons="" _chain_txt
  _order=("$RUNNER" "${CHAIN[@]}")
  _chain_txt="$(printf '%s,' "${_order[@]}")"; _chain_txt="${_chain_txt%,}"
  _FO_OUT="$(mktemp "${TMPDIR:-/tmp}/talos-fo-out.XXXXXX")" && _FO_ERR="$(mktemp "${TMPDIR:-/tmp}/talos-fo-err.XXXXXX")" \
    && TALOS_WRITE_LOG="$(mktemp "${TMPDIR:-/tmp}/talos-fo-wr.XXXXXX")" || {
    echo "pipeline-agent: failover: cannot create temp files (mktemp)" >&2
    RC=1; return
  }
  export TALOS_WRITE_LOG
  if command -v _talos_on_exit >/dev/null 2>&1; then
    _talos_on_exit 'rm -f "$_FO_OUT" "$_FO_ERR" "$TALOS_WRITE_LOG"'
  else
    trap 'rm -f "$_FO_OUT" "$_FO_ERR" "$TALOS_WRITE_LOG"' EXIT
  fi
  _FO_PROV="$(_prov_path)" || { echo "pipeline-agent: [warn] not in a git repository -- provider down-tracking unavailable" >&2; _FO_PROV=""; }
  _down="$(_prov_down "$_FO_PROV")"
  for _r in "${_order[@]}"; do
    if printf '%s\n' "$_down" | grep -Fxq -- "$_r"; then
      _reasons="$_reasons $_r:down-cached"
    else
      _cands+=("$_r")
    fi
  done
  _n="${#_cands[@]}"
  if [ "$_n" -gt 0 ] && [ "${_cands[0]}" != "$RUNNER" ]; then
    _fo_switch "$RUNNER" "${_cands[0]}" "down-cached"
  fi
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    _r="${_cands[$_i]}"
    _nxt=""; [ $((_i + 1)) -lt "$_n" ] && _nxt="${_cands[$((_i + 1))]}"
    _i=$((_i + 1))
    if [ "$_r" != "$_FO_PRIMARY" ] && _fo_unavailable "$_r"; then
      _reasons="$_reasons $_r:unavailable"
      _fo_switch "$_r" "${_nxt:-none}" "unavailable"
      continue
    fi
    if [ "$_r" != "$_FO_PRIMARY" ]; then RUNNER_ARGS=(); fi
    if [ "$_r" = "custom" ] && [ -z "$(_resolve_runner_cmd "$ROLE")" ]; then
      echo "pipeline-agent: agents.runner=custom requires agents.runner_cmd (role=$ROLE)" >&2
      exit 1
    fi
    : >"$TALOS_WRITE_LOG"
    _snap="$(git for-each-ref refs/remotes 2>/dev/null)"
    _FO_FINAL="$_r"
    _run_runner "$_r" >"$_FO_OUT" 2>"$_FO_ERR"
    _classify_exit "$_r" "$RC" "$_FO_ERR" "$_FO_OUT"
    cat "$_FO_ERR" >&2
    if [ "$CLASS" != "provider" ]; then
      cat "$_FO_OUT"
      return
    fi
    _why="provider:$CLASS_DETAIL"
    _prov_mark_down "$_r" "$_why"
    _verbs="$(sort -u "$TALOS_WRITE_LOG" 2>/dev/null | paste -sd, -)"
    if [ "$_snap" != "$(git for-each-ref refs/remotes 2>/dev/null)" ]; then
      _verbs="${_verbs:+$_verbs,}push"
    fi
    if [ -n "$_verbs" ]; then
      echo "talos:failover-refused role=$ROLE runner=$_r reason=wrote:$_verbs" >&2
      RC=69
      return
    fi
    _reasons="$_reasons $_r:$_why"
    _fo_checkpoint
    [ -z "$_nxt" ] || _fo_switch "$_r" "$_nxt" "$_why"
  done
  echo "pipeline-agent: provider chain exhausted role=$ROLE chain=$_chain_txt reasons=${_reasons# } (agents.fallback)" >&2
  RC=69
}

CHAIN=()
while IFS= read -r _fb_entry; do
  [ -n "$_fb_entry" ] && CHAIN+=("$_fb_entry")
done <<EOF
$(_fallback_chain "$ROLE" "$RUNNER")
EOF
if [ "${#CHAIN[@]}" -eq 0 ]; then
  _run_runner "$RUNNER"
else
  _run_chain
fi

# hooks.post_stage (#182): fire once, here, the moment the stage runner has
# exited -- this is the single adapter-path call site for the
# "stage_complete" event. Verdict is derived from RC: 0 -> PASS, anything
# else -> FAIL. Guarded the same way pipeline-hooks.sh itself is above: a
# partial install/sync may not yet ship it.
if [ -f "$SCRIPT_DIR/pipeline-hooks.sh" ]; then
  _POST_STAGE_VERDICT="PASS"
  [ "$RC" -eq 0 ] || _POST_STAGE_VERDICT="FAIL"
  _POST_STAGE_ARGS=(post_stage stage_complete "$ROLE" "$TALOS_ISSUE_NUMBER" --verdict "$_POST_STAGE_VERDICT")
  # duration_s is not tracked anywhere today (PM scope note, #182): emit it
  # only when the caller supplies it via TALOS_STAGE_DURATION_S, null
  # otherwise -- no timer plumbing added in this change.
  if [ -n "${TALOS_STAGE_DURATION_S:-}" ]; then
    _POST_STAGE_ARGS+=(--duration-s "$TALOS_STAGE_DURATION_S")
  fi
  # #418: a stage that ran on a failover-chain runner names that runner (and a
  # null model); every other stage's event is unchanged.
  if [ -n "$_FO_FINAL" ] && [ "$_FO_FINAL" != "$_FO_PRIMARY" ]; then
    _POST_STAGE_ARGS+=(--runner "$_FO_FINAL")
  fi
  bash "$SCRIPT_DIR/pipeline-hooks.sh" "${_POST_STAGE_ARGS[@]}"
fi
exit "$RC"
