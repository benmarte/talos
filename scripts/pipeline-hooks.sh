#!/usr/bin/env bash
# pipeline-hooks.sh — hooks.pre_dispatch: run an external command before a
# stage's prompt is built, and print its output for the caller to prepend.
#
# Usage: pipeline-hooks.sh pre_dispatch <role> <issue> [<pr>] [<worktree_path>] [files_hint...]
#
# Config (talos.pipeline.yml via pipeline-config.sh, read through the cfg()
# cache — see pipeline-cfg-cache.sh):
#   hooks.pre_dispatch   shell command to run before each stage's prompt is
#                        built. Default "" — disabled, this script prints
#                        nothing and exits 0 immediately.
#   hooks.timeout_s      positive integer seconds the hook is allowed to run.
#                        Validated by pipeline-config.sh's shared
#                        _validate_int_key() (#205 pattern, same as
#                        verify.timeout_ms / verify.ci_wait_s): a non-integer
#                        or non-positive value warns once on stderr and falls
#                        back to the default. Default: 30.
#
# Contract (mirrors pipeline-notify.sh): NEVER blocks dispatch. A non-zero
# exit, a timeout, or empty stdout from the hook command is a silent no-op
# on this script's stdout — nothing is printed — with exactly one line on
# stderr explaining why. This script itself always exits 0; its caller
# never needs to branch on failure.
#
# Stdin JSON handed to the hook command (built with python3 json.dumps —
# never string-concatenated):
#   {"role":"developer","issue":42,"pr":57,"repo":"owner/name",
#    "base_branch":"main","worktree_path":"/abs/path","files_hint":["a.sh"]}
# Fields the caller did not supply (pr, files_hint) are null / [] rather than
# omitted, so the hook can rely on the shape.
#
# Environment exported to the hook command: TALOS_ROLE, TALOS_ISSUE_NUMBER,
# TALOS_WORKTREE_PATH — same names/values pipeline-agent.sh already exports
# to runner_cmd.
#
# On success (exit 0, non-empty stdout, within the timeout) this script
# prints, and only this:
#   ## Context
#   <hook stdout>
#   ---
# On any no-op case it prints nothing on stdout.
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

  # hooks.timeout_s is already validated (positive integer, or absent so
  # the "30" default below is returned as-is) by pipeline-config.sh's
  # _validate_int_key() before it reaches cfg() -- this re-check is just a
  # backstop so a non-integer can never reach `sleep`/`-gt` below even if
  # that invariant is ever violated (e.g. this function called directly,
  # bypassing cfg()).
  local timeout_s
  timeout_s="$(cfg hooks.timeout_s "30")"
  case "$timeout_s" in
    ''|*[!0-9]*) timeout_s=30 ;;
  esac
  [ "$timeout_s" -gt 0 ] 2>/dev/null || timeout_s=30

  local repo base_branch
  repo="$(cfg repo "")"
  [ -n "$repo" ] || repo="$(cfg vcs.repo "")"
  if [ -z "$repo" ]; then
    repo="$(git remote get-url origin 2>/dev/null \
      | sed -E 's#^git@([^:/]+)[:/]#https://\1/#; s#\.git$##' \
      | sed -E 's#^https://[^/]+/##')"
  fi
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

  # ── Run the hook with a portable timeout ────────────────────────────────────
  # No `timeout(1)` on macOS by default, so this rolls its own: the hook runs
  # as its own process group (set -m) and a background watchdog subshell
  # sends it SIGTERM, then SIGKILL shortly after, once timeout_s elapses.
  # `wait` on the hook's pid returns non-zero for both a real command
  # failure and a kill-by-timeout, and both are treated identically —
  # a silent no-op — matching the "never blocks dispatch" contract.
  local in_file out_file
  in_file="$(mktemp "${TMPDIR:-/tmp}/talos-hook-in.XXXXXX" 2>/dev/null)" || {
    echo "pipeline-hooks: hooks.pre_dispatch skipped (mktemp failed)" >&2
    return 0
  }
  out_file="$(mktemp "${TMPDIR:-/tmp}/talos-hook-out.XXXXXX" 2>/dev/null)" || {
    rm -f "$in_file"
    echo "pipeline-hooks: hooks.pre_dispatch skipped (mktemp failed)" >&2
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

  if [ "$rc" -ne 0 ]; then
    echo "pipeline-hooks: hooks.pre_dispatch exited non-zero or timed out (rc=$rc) -- skipping" >&2
    return 0
  fi
  if [ -z "$out" ]; then
    echo "pipeline-hooks: hooks.pre_dispatch produced no output -- skipping" >&2
    return 0
  fi

  printf '## Context\n%s\n---\n' "$out"
  return 0
}

VERB="${1:-}"
case "$VERB" in
  pre_dispatch)
    shift
    pre_dispatch "$@"
    ;;
  *)
    echo "Usage: pipeline-hooks.sh pre_dispatch <role> <issue> [<pr>] [<worktree_path>] [files_hint...]" >&2
    exit 2
    ;;
esac
