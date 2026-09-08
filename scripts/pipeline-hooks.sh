#!/usr/bin/env bash
# pipeline-hooks.sh — external commands wired into the pipeline at fixed
# points, sharing one never-block-the-pipeline contract:
#
#   pre_dispatch  runs before a stage's prompt is built; its stdout is
#                 prepended to that prompt (#181).
#   post_stage    runs after every verdict, approval, block or merge is
#                 known; receives a JSON outcome event on stdin, fire-and-
#                 forget (#182). The same payload is also appended as one
#                 JSON line to the local events log (#183) -- see
#                 events.enabled / events.path below -- independently of
#                 whether hooks.post_stage is configured at all.
#
# Usage: pipeline-hooks.sh pre_dispatch <role> <issue> [<pr>] [<worktree_path>] [files_hint...]
#        pipeline-hooks.sh post_stage <event> <role> <issue> [--pr N] [--sha S]
#          [--verdict V] [--summary "..."] [--details-file F]
#          [--attempt stage:count:total] [--duration-s N] [--tokens N] [--tool-uses N]
#
# Config (talos.pipeline.yml via pipeline-config.sh, read through the cfg()
# cache — see pipeline-cfg-cache.sh):
#   hooks.pre_dispatch   shell command to run before each stage's prompt is
#                        built. Default "" — disabled.
#   hooks.post_stage     shell command to run after every verdict, approval,
#                        merge or block. Default "" — disabled.
#   hooks.timeout_s      positive integer seconds either hook is allowed to
#                        run. Validated by pipeline-config.sh's shared
#                        _validate_int_key() (#205 pattern, same as
#                        verify.timeout_ms / verify.ci_wait_s): a non-integer
#                        or non-positive value warns once on stderr and falls
#                        back to the default. Default: 30.
#   events.enabled       whether every post_stage payload is also appended,
#                        as one JSON line, to the local events log (#183).
#                        Default: true.
#   events.path          path to the events log, relative to the MAIN
#                        repository root (resolved via `git rev-parse
#                        --git-common-dir`, so every linked worktree of the
#                        same repo appends to the one file) unless already
#                        absolute. Default: ".talos/events.jsonl". Read with
#                        scripts/pipeline-events.sh.
#
# Contract (mirrors pipeline-notify.sh): NEVER blocks the pipeline. A
# non-zero exit, a timeout, or (pre_dispatch only) empty stdout from the
# hook command is a silent no-op — with exactly one line on stderr
# explaining why. Both verbs always exit 0; callers never branch on failure.
#
# pre_dispatch stdin JSON (built with python3 json.dumps — never
# string-concatenated):
#   {"role":"developer","issue":42,"pr":57,"repo":"owner/name",
#    "base_branch":"main","worktree_path":"/abs/path","files_hint":["a.sh"]}
# Fields the caller did not supply (pr, files_hint) are null / [] rather than
# omitted, so the hook can rely on the shape.
#
# post_stage stdin JSON:
#   {"event":"qa","role":"qa","issue":42,"pr":57,"repo":"owner/name",
#    "sha":"<40hex or null>","verdict":"PASS","summary":"...","details":"...",
#    "attempt":{"stage":"qa","count":1,"total":3},"model":"claude-sonnet-5",
#    "runner":"claude","duration_s":312,"tokens":48213,"tool_uses":19,
#    "ts":"2026-09-07T14:00:00Z"}
# pr/sha/verdict/model/runner are null when the caller did not supply them
# (or they can't be resolved); attempt/duration_s/tokens/tool_uses are null
# unless the caller passes --attempt/--duration-s/--tokens/--tool-uses (#202).
# --tokens and --tool-uses are validated as non-negative integers -- an
# invalid or missing value is null in the payload, with one stderr note for
# an invalid (non-empty, non-numeric) value. Schema field order is stable:
# tokens and tool_uses are appended after duration_s, never inserted earlier.
# model comes from agents.roles.<role>.model, falling back to agents.model;
# runner from agents.runner. ts is UTC ISO-8601.
#
# Environment exported to both hook commands: TALOS_ROLE, TALOS_ISSUE_NUMBER,
# TALOS_WORKTREE_PATH — same names/values pipeline-agent.sh already exports
# to runner_cmd. post_stage callers rarely have a worktree path handy, so
# TALOS_WORKTREE_PATH is commonly empty for that verb.
#
# On pre_dispatch success (exit 0, non-empty stdout, within the timeout)
# this script prints, and only this:
#   ## Context
#   <hook stdout>
#   ---
# On any pre_dispatch no-op case it prints nothing on stdout. post_stage
# never prints anything on stdout — it is fire-and-forget — but this helper
# is itself foreground and returns only once the hook command has exited or
# been killed at the timeout (rule 17: no background children left behind).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# cfg() (#169): dumps the config once per invocation and answers lookups
# from that cache instead of re-parsing on every call. Guarded (#169 review):
# a partial install/sync may not yet ship pipeline-cfg-cache.sh, so fall back
# to the old per-call cfg() instead of leaving cfg undefined.
if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$@"; }
  echo "pipeline: config cache helper missing, falling back to per-call parsing" >&2
fi

# ── Shared helpers (pre_dispatch and post_stage both use these) ────────────

# _hooks_timeout_s -> prints hooks.timeout_s, validated.
# hooks.timeout_s is already validated (positive integer, or absent so the
# "30" default below is returned as-is) by pipeline-config.sh's
# _validate_int_key() before it reaches cfg() -- this re-check is just a
# backstop so a non-integer can never reach `sleep`/`-gt` below even if that
# invariant is ever violated (e.g. this function called directly, bypassing
# cfg()).
_hooks_timeout_s() {
  local timeout_s
  timeout_s="$(cfg hooks.timeout_s "30")"
  case "$timeout_s" in
    ''|*[!0-9]*) timeout_s=30 ;;
  esac
  [ "$timeout_s" -gt 0 ] 2>/dev/null || timeout_s=30
  printf '%s' "$timeout_s"
}

# _events_log_path -> prints the absolute path to the events.jsonl log, or
# nothing (rc 1) if it can't be resolved (not a git repo, etc).
#
# Resolved via `git rev-parse --git-common-dir`, NOT --git-dir: the common
# dir is shared by every linked worktree of a repo (git-common-dir(5)), so a
# developer/QA/reviewer stage running from inside a per-issue worktree still
# appends to the one log file at the main repository's root -- never a
# worktree-local copy. --git-common-dir can print a path relative to the
# caller's cwd (e.g. ".git" from the main repo, "../../.git" from a linked
# worktree two levels down), so it's resolved to absolute here before use;
# events.path (default ".talos/events.jsonl") is then joined onto that
# resolved root when it isn't already absolute.
_events_log_path() {
  local common_dir root path_cfg
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common_dir" ] || return 1
  case "$common_dir" in
    /*) : ;;
    *) common_dir="$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd)/$(basename "$common_dir")" ;;
  esac
  [ -n "$common_dir" ] || return 1
  root="$(dirname "$common_dir")"

  path_cfg="$(cfg events.path ".talos/events.jsonl")"
  case "$path_cfg" in
    /*) printf '%s' "$path_cfg" ;;
    *) printf '%s/%s' "$root" "$path_cfg" ;;
  esac
}

# _events_append <json_line> -- appends one JSON object, as a single line, to
# the events log (see _events_log_path), when events.enabled (default true).
# Best-effort only: any failure (disabled, unresolvable path, mkdir/write
# error) is a stderr note, never a non-zero return -- this must never affect
# post_stage's own always-exit-0 contract.
#
# Concurrency: a single `printf '%s\n' >>` is one O_APPEND write syscall; on
# POSIX a write below PIPE_BUF (a JSON event line is well under the 4KB
# typical minimum) is atomic, so concurrent post_stage calls (e.g. several
# stages finishing at once under issues.max_parallel) interleave whole lines,
# never partial ones. No flock/lockfile needed.
_events_append() {
  local json_line="$1"
  local enabled log_path log_dir
  enabled="$(cfg events.enabled "true")"
  [ "$enabled" = "false" ] && return 0

  log_path="$(_events_log_path)"
  if [ -z "$log_path" ]; then
    echo "pipeline-hooks: events log path could not be resolved -- skipping" >&2
    return 0
  fi

  log_dir="$(dirname "$log_path")"
  if ! mkdir -p "$log_dir" 2>/dev/null; then
    echo "pipeline-hooks: could not create events log directory ($log_dir) -- skipping" >&2
    return 0
  fi

  if ! printf '%s\n' "$json_line" >> "$log_path" 2>/dev/null; then
    echo "pipeline-hooks: could not write to events log ($log_path) -- skipping" >&2
  fi
  return 0
}

# _validate_nonneg_int <flag_label> <raw_value> -> prints <raw_value> back out
# when it is empty (not supplied) or a valid non-negative integer; otherwise
# prints nothing and writes one stderr note. Used for --tokens/--tool-uses
# (#202): a bad value must degrade to null in the payload, never abort
# post_stage's always-exit-0 contract.
_validate_nonneg_int() {
  local flag_label="$1" raw="$2"
  [ -z "$raw" ] && return 0
  case "$raw" in
    ''|*[!0-9]*)
      echo "pipeline-hooks: --$flag_label value '$raw' is not a non-negative integer -- using null" >&2
      return 0
      ;;
  esac
  printf '%s' "$raw"
}

# _hooks_repo -> prints "owner/name", resolved from config or the origin remote.
_hooks_repo() {
  local repo
  repo="$(cfg repo "")"
  [ -n "$repo" ] || repo="$(cfg vcs.repo "")"
  if [ -z "$repo" ]; then
    repo="$(git remote get-url origin 2>/dev/null \
      | sed -E 's#^git@([^:/]+)[:/]#https://\1/#; s#\.git$##' \
      | sed -E 's#^https://[^/]+/##')"
  fi
  printf '%s' "$repo"
}

# _hooks_run <hook_cmd> <timeout_s> <stdin_json> <role> <issue> <worktree>
# Runs <hook_cmd> with <stdin_json> on stdin under a portable timeout, and
# sets two globals the caller reads immediately after:
#   _HOOKS_RUN_RC   the command's exit code, or non-zero if it was killed at
#                   the timeout (both cases are indistinguishable on
#                   purpose -- both mean "no-op" to the caller)
#   _HOOKS_RUN_OUT  captured stdout, only populated when _HOOKS_RUN_RC = 0
# No `timeout(1)` on macOS by default, so this rolls its own: the hook runs
# as its own process group (set -m) and a background watchdog subshell
# sends it SIGTERM, then SIGKILL shortly after, once timeout_s elapses.
_hooks_run() {
  local hook_cmd="$1" timeout_s="$2" stdin_json="$3"
  local role="$4" issue="$5" worktree="$6"

  _HOOKS_RUN_RC=1
  _HOOKS_RUN_OUT=""

  local in_file out_file
  in_file="$(mktemp "${TMPDIR:-/tmp}/talos-hook-in.XXXXXX" 2>/dev/null)" || {
    echo "pipeline-hooks: hook skipped (mktemp failed)" >&2
    return 0
  }
  out_file="$(mktemp "${TMPDIR:-/tmp}/talos-hook-out.XXXXXX" 2>/dev/null)" || {
    rm -f "$in_file"
    echo "pipeline-hooks: hook skipped (mktemp failed)" >&2
    return 0
  }
  printf '%s' "$stdin_json" > "$in_file"

  set -m
  TALOS_ROLE="$role" TALOS_ISSUE_NUMBER="$issue" TALOS_WORKTREE_PATH="$worktree" \
    sh -c "$hook_cmd" < "$in_file" > "$out_file" 2>/dev/null &
  local hook_pid=$!
  set +m

  # The watchdog also gets its own process group (set -m), same as the hook
  # above: on the fast-success path below we need to kill the *group*, not
  # just the subshell pid, or the "sleep $timeout_s" it already forked is
  # orphaned and keeps running for up to hooks.timeout_s (#181 review).
  set -m
  ( sleep "$timeout_s"
    kill -TERM -"$hook_pid" 2>/dev/null
    sleep 0.2
    kill -KILL -"$hook_pid" 2>/dev/null
  ) &
  local watchdog_pid=$!
  set +m

  local rc=0
  wait "$hook_pid" 2>/dev/null
  rc=$?

  # Kill the watchdog's whole process group (negative pid) so its "sleep
  # $timeout_s" child is reaped too, not just the subshell leader.
  kill -- -"$watchdog_pid" 2>/dev/null
  wait "$watchdog_pid" 2>/dev/null

  local out=""
  [ "$rc" -eq 0 ] && out="$(cat "$out_file" 2>/dev/null)"
  rm -f "$in_file" "$out_file"

  _HOOKS_RUN_RC="$rc"
  _HOOKS_RUN_OUT="$out"
  return 0
}

# pre_dispatch ROLE ISSUE [PR] [WORKTREE_PATH] [FILES_HINT...]
pre_dispatch() {
  local role="${1:-}" issue="${2:-}" pr="${3:-}" worktree="${4:-}"
  local _shift_n=$(( $# >= 4 ? 4 : $# ))
  shift "$_shift_n" 2>/dev/null || true
  local files_hint=("$@")

  local hook_cmd
  hook_cmd="$(cfg hooks.pre_dispatch "")"
  if [ -z "$hook_cmd" ]; then
    return 0
  fi

  local timeout_s
  timeout_s="$(_hooks_timeout_s)"

  local repo base_branch
  repo="$(_hooks_repo)"
  base_branch="$(cfg base_branch "")"

  # ── Build the stdin JSON via python3 json.dumps (never string-concat) ──────
  local stdin_json
  stdin_json="$(TALOS_HOOK_ROLE="$role" TALOS_HOOK_ISSUE="$issue" TALOS_HOOK_PR="$pr" \
    TALOS_HOOK_REPO="$repo" TALOS_HOOK_BASE="$base_branch" TALOS_HOOK_WT="$worktree" \
    python3 -c '
import json
import os
import sys


def _int_or_none(raw):
    raw = (raw or "").strip()
    if raw == "":
        return None
    try:
        return int(raw)
    except ValueError:
        return raw


payload = {
    "role": os.environ.get("TALOS_HOOK_ROLE", ""),
    "issue": _int_or_none(os.environ.get("TALOS_HOOK_ISSUE")),
    "pr": _int_or_none(os.environ.get("TALOS_HOOK_PR")),
    "repo": os.environ.get("TALOS_HOOK_REPO", ""),
    "base_branch": os.environ.get("TALOS_HOOK_BASE", ""),
    "worktree_path": os.environ.get("TALOS_HOOK_WT", ""),
    "files_hint": sys.argv[1:],
}
json.dump(payload, sys.stdout)
' ${files_hint[@]+"${files_hint[@]}"})"

  _hooks_run "$hook_cmd" "$timeout_s" "$stdin_json" "$role" "$issue" "$worktree"

  if [ "$_HOOKS_RUN_RC" -ne 0 ]; then
    echo "pipeline-hooks: hooks.pre_dispatch exited non-zero or timed out (rc=$_HOOKS_RUN_RC) -- skipping" >&2
    return 0
  fi
  if [ -z "$_HOOKS_RUN_OUT" ]; then
    echo "pipeline-hooks: hooks.pre_dispatch produced no output -- skipping" >&2
    return 0
  fi

  printf '## Context\n%s\n---\n' "$_HOOKS_RUN_OUT"
  return 0
}

# post_stage EVENT ROLE ISSUE [--pr N] [--sha S] [--verdict V] [--summary S]
#            [--details-file F] [--attempt stage:count:total] [--duration-s N]
#            [--tokens N] [--tool-uses N]
post_stage() {
  local event="${1:-}" role="${2:-}" issue="${3:-}"
  local _shift_n=$(( $# >= 3 ? 3 : $# ))
  shift "$_shift_n" 2>/dev/null || true

  local pr="" sha="" verdict="" summary="" details_file="" attempt="" duration_s="" tokens="" tool_uses=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) pr="${2:-}"; shift 2 ;;
      --sha) sha="${2:-}"; shift 2 ;;
      --verdict) verdict="${2:-}"; shift 2 ;;
      --summary) summary="${2:-}"; shift 2 ;;
      --details-file) details_file="${2:-}"; shift 2 ;;
      --attempt) attempt="${2:-}"; shift 2 ;;
      --duration-s) duration_s="${2:-}"; shift 2 ;;
      --tokens) tokens="${2:-}"; shift 2 ;;
      --tool-uses) tool_uses="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  # #202: --tokens/--tool-uses are validated non-negative integers -- an
  # invalid value becomes empty here (-> null in the payload below) with one
  # stderr note; missing (never supplied) is already empty and silent.
  tokens="$(_validate_nonneg_int tokens "$tokens")"
  tool_uses="$(_validate_nonneg_int tool-uses "$tool_uses")"

  local hook_cmd
  hook_cmd="$(cfg hooks.post_stage "")"

  local repo
  repo="$(_hooks_repo)"

  local model runner
  runner="$(cfg agents.runner "claude")"
  model="$(cfg "agents.roles.$role.model" "")"
  [ -n "$model" ] || model="$(cfg agents.model "")"

  local details=""
  [ -n "$details_file" ] && [ -f "$details_file" ] && details="$(cat "$details_file")"

  local ts
  ts="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

  local attempt_stage="" attempt_count="" attempt_total=""
  if [ -n "$attempt" ]; then
    attempt_stage="${attempt%%:*}"
    local _rest="${attempt#*:}"
    attempt_count="${_rest%%:*}"
    attempt_total="${_rest#*:}"
  fi

  # ── Build the stdin JSON via python3 json.dumps (never string-concat) ──────
  local stdin_json
  stdin_json="$(TALOS_HOOK_EVENT="$event" TALOS_HOOK_ROLE="$role" TALOS_HOOK_ISSUE="$issue" \
    TALOS_HOOK_PR="$pr" TALOS_HOOK_REPO="$repo" TALOS_HOOK_SHA="$sha" \
    TALOS_HOOK_VERDICT="$verdict" TALOS_HOOK_SUMMARY="$summary" TALOS_HOOK_DETAILS="$details" \
    TALOS_HOOK_ATTEMPT_STAGE="$attempt_stage" TALOS_HOOK_ATTEMPT_COUNT="$attempt_count" \
    TALOS_HOOK_ATTEMPT_TOTAL="$attempt_total" TALOS_HOOK_MODEL="$model" TALOS_HOOK_RUNNER="$runner" \
    TALOS_HOOK_DURATION="$duration_s" TALOS_HOOK_TOKENS="$tokens" TALOS_HOOK_TOOL_USES="$tool_uses" \
    TALOS_HOOK_TS="$ts" \
    python3 -c '
import json
import os
import sys


def _int_or_none(raw):
    raw = (raw or "").strip()
    if raw == "":
        return None
    try:
        return int(raw)
    except ValueError:
        return raw


attempt = None
_stage = os.environ.get("TALOS_HOOK_ATTEMPT_STAGE", "")
if _stage:
    attempt = {
        "stage": _stage,
        "count": _int_or_none(os.environ.get("TALOS_HOOK_ATTEMPT_COUNT")),
        "total": _int_or_none(os.environ.get("TALOS_HOOK_ATTEMPT_TOTAL")),
    }

payload = {
    "event": os.environ.get("TALOS_HOOK_EVENT", ""),
    "role": os.environ.get("TALOS_HOOK_ROLE", ""),
    "issue": _int_or_none(os.environ.get("TALOS_HOOK_ISSUE")),
    "pr": _int_or_none(os.environ.get("TALOS_HOOK_PR")),
    "repo": os.environ.get("TALOS_HOOK_REPO", ""),
    "sha": os.environ.get("TALOS_HOOK_SHA") or None,
    "verdict": os.environ.get("TALOS_HOOK_VERDICT") or None,
    "summary": os.environ.get("TALOS_HOOK_SUMMARY", ""),
    "details": os.environ.get("TALOS_HOOK_DETAILS", ""),
    "attempt": attempt,
    "model": os.environ.get("TALOS_HOOK_MODEL") or None,
    "runner": os.environ.get("TALOS_HOOK_RUNNER") or None,
    "duration_s": _int_or_none(os.environ.get("TALOS_HOOK_DURATION")),
    "tokens": _int_or_none(os.environ.get("TALOS_HOOK_TOKENS")),
    "tool_uses": _int_or_none(os.environ.get("TALOS_HOOK_TOOL_USES")),
    "ts": os.environ.get("TALOS_HOOK_TS", ""),
}
json.dump(payload, sys.stdout)
')"

  # Local audit log (#183): written from the same payload regardless of
  # whether hooks.post_stage is configured -- independent concerns, see
  # _events_append.
  _events_append "$stdin_json"

  if [ -z "$hook_cmd" ]; then
    return 0
  fi

  local timeout_s
  timeout_s="$(_hooks_timeout_s)"

  _hooks_run "$hook_cmd" "$timeout_s" "$stdin_json" "$role" "$issue" ""

  if [ "$_HOOKS_RUN_RC" -ne 0 ]; then
    echo "pipeline-hooks: hooks.post_stage exited non-zero or timed out (rc=$_HOOKS_RUN_RC) -- skipping" >&2
  fi
  return 0
}

VERB="${1:-}"
case "$VERB" in
  pre_dispatch)
    shift
    pre_dispatch "$@"
    ;;
  post_stage)
    shift
    post_stage "$@"
    ;;
  *)
    echo "Usage: pipeline-hooks.sh pre_dispatch <role> <issue> [<pr>] [<worktree_path>] [files_hint...]" >&2
    echo "       pipeline-hooks.sh post_stage <event> <role> <issue> [--pr N] [--sha S] [--verdict V] [--summary \"...\"] [--details-file F] [--attempt stage:count:total] [--duration-s N] [--tokens N] [--tool-uses N]" >&2
    exit 2
    ;;
esac
