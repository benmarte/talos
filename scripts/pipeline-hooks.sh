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
#          [--verdict V] [--summary "..." | --summary - | --summary-file F]
#          [--details-file F] [--attempt stage:count:total] [--duration-s N] [--tokens N] [--tool-uses N]
#          [--ci-runs N] [--model M] [--runner R]
#          [--input-tokens N] [--output-tokens N] [--cache-write-tokens N] [--cache-read-tokens N]
#          [--pool api|plan]
#        pipeline-hooks.sh stage_start <role> <issue> [--pr N]
#        pipeline-hooks.sh run_end <stop line> [--issue N]
#
# run_end appends one `run_end` event when a `talos.sh run` ends (talos.sh's run
# exit hook calls it with the stop line as printed). The line's verdict=,
# reason=, detail=, issue= and pr= words become fields, its role= word is the
# field `stage` (the event's role stays `orchestrator`, so no cost view counts
# it), and --issue N is the run's target when the line names no issue. Same
# only-appends, events.enabled / events.path and never-block contract as
# stage_start.
#
# stage_start (#550) appends one `stage_start` event to the events log when a
# stage is dispatched (talos.sh prompt calls it), so the status line
# (talos-status.sh) can show the stage as running. It only appends: the
# hooks.post_stage command is not run, and the event is recorded under role
# `orchestrator` (the dispatched role is in `stage`), so no cost or spend report
# counts it as a stage run. Same events.enabled / events.path rules and
# never-block contract as post_stage; a malformed argument is the only exit 2.
#
# Config (talos.pipeline.json via pipeline-config.sh, read through the cfg()
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
#   events.path          path to the events log, relative to the GIT COMMON
#                        dir (`git rev-parse --git-common-dir`, so every
#                        linked worktree of the same repo appends to the one
#                        file and the log sits outside every git tree, #517)
#                        unless already absolute. Default:
#                        "talos/events.jsonl" -- the canonical run-state
#                        directory from scripts/pipeline-paths.sh. Read with
#                        scripts/pipeline-events.sh. A relative value whose
#                        normalized form climbs out of the common dir ("../x")
#                        is refused by the WRITER: one stderr note, no append,
#                        still exit 0 (the never-block contract); talos-
#                        status.sh refuses it the same way on the READ side,
#                        and an absolute path stays the hooks-writes-it /
#                        status-refuses-it asymmetry.
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
# --ci-runs N (#332) records how many pull_request CI runs the PR consumed
# (pipeline-vcs.sh pr-ci-runs); the merged event carries it. Unlike the fields
# above it adds a "ci_runs" key (after tool_uses) only when supplied and valid,
# so every payload without it is unchanged.
# --input-tokens / --output-tokens / --cache-write-tokens / --cache-read-tokens
# (#604) split a run's usage: fresh (uncached) input, output, cache writes and
# cache reads. They follow the ci_runs rule: validated like --tokens, and each
# adds its key ("input_tokens", "output_tokens", "cache_write_tokens",
# "cache_read_tokens", after tool_uses and ci_runs, before ts) only when
# supplied and valid. `tokens` stays input + output + cache write: cache reads
# are never in it. An event with no valid cache_read_tokens is "cache-unrecorded"
# to every reader (pipeline-events.sh cost, talos-status.sh), never a zero.
# --pool api|plan (#616) names what paid for a claude stage: the plan's monthly
# API credits or the plan login (agents.claude_api_credits). It adds a "pool"
# key after the #604 keys and before ts; any other value prints one stderr line
# and the key is left out, and an event without it is "pool-unrecorded" to
# pipeline-events.sh cost.
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
# a partial install/sync may not yet ship pipeline-cfg-cache.sh: that is fatal
# (no per-call fallback: it would hide the fail-closed exit of a broken table).
if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  echo "talos: pipeline-cfg-cache.sh missing; reinstall Talos" >&2
  exit 1
fi

# _talos_state_dir (#517): the one canonical resolver for the run-state
# directory that roots events.path. Hard dependency, the same fail-closed
# pattern as pipeline-cfg-cache.sh above -- without it the log would be back
# inside the git tree (the #517 dogfood bug).
if [ -f "$SCRIPT_DIR/pipeline-paths.sh" ]; then
  . "$SCRIPT_DIR/pipeline-paths.sh"
else
  echo "talos: pipeline-paths.sh missing; reinstall Talos" >&2
  exit 1
fi

# talos_bounded / talos_pos_int (#552): the one portable "run under a timeout"
# shared with pipeline-notify.sh (notifications.cmd, the Buzz nak call).
if [ -f "$SCRIPT_DIR/pipeline-bounded.sh" ]; then
  . "$SCRIPT_DIR/pipeline-bounded.sh"
else
  echo "talos: pipeline-bounded.sh missing; reinstall Talos" >&2
  exit 1
fi

# ── Shared helpers (pre_dispatch and post_stage both use these) ────────────

# _hooks_timeout_s -> prints hooks.timeout_s: a positive integer, else 30.
# pipeline-config.sh already validates the key; this is the backstop so a
# non-integer can never reach `sleep`.
_hooks_timeout_s() { talos_pos_int "$(cfg hooks.timeout_s)" 30; }

# _events_log_path and _events_path_leaves_common, the resolver of events.path
# and its containment check, are pipeline-paths.sh's (sourced above).

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
  local enabled path_cfg log_path log_dir
  enabled="$(cfg events.enabled)"
  [ "$enabled" = "false" ] && return 0

  # Containment at the WRITER (mirrors talos-status.sh's refusal, fix round
  # of #517 / PR #527 review): a RELATIVE events.path whose normalized form
  # climbs out of the git common dir is refused -- one stderr note and a
  # skipped append, never a non-zero exit (the never-block contract). An
  # absolute events.path is still used as-is: the documented
  # hooks-writes-it / status-refuses-it asymmetry. The second cfg read is a
  # per-invocation cache hit (pipeline-cfg-cache.sh), not a second parse.
  path_cfg="$(cfg events.path)"
  case "$path_cfg" in
    /*|'') : ;;
    *)
      if _events_path_leaves_common "$path_cfg"; then
        echo "pipeline-hooks: events.path '$path_cfg' leaves the git common dir -- appending skipped" >&2
        return 0
      fi
      ;;
  esac

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
  repo="$(cfg repo)"
  [ -n "$repo" ] || repo="$(cfg vcs.repo)"
  if [ -z "$repo" ]; then
    repo="$(git remote get-url origin 2>/dev/null \
      | sed -E 's#^git@([^:/]+)[:/]#https://\1/#; s#\.git$##' \
      | sed -E 's#^https://[^/]+/##')"
  fi
  printf '%s' "$repo"
}

# _hooks_run <hook_cmd> <timeout_s> <stdin_json> <role> <issue> <worktree>
# Runs <hook_cmd> with <stdin_json> on stdin under talos_bounded and sets:
#   _HOOKS_RUN_RC   the command's exit code, or non-zero if it was killed at the
#                   timeout (both mean "no-op" to the caller, on purpose)
#   _HOOKS_RUN_OUT  captured stdout, only populated when _HOOKS_RUN_RC = 0
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

  TALOS_ROLE="$role" TALOS_ISSUE_NUMBER="$issue" TALOS_WORKTREE_PATH="$worktree" \
    talos_bounded "$timeout_s" sh -c "$hook_cmd" < "$in_file" > "$out_file" 2>/dev/null

  _HOOKS_RUN_RC="$_BOUNDED_RC"
  [ "$_BOUNDED_RC" -eq 0 ] && _HOOKS_RUN_OUT="$(cat "$out_file" 2>/dev/null)"
  rm -f "$in_file" "$out_file"
  return 0
}

# pre_dispatch ROLE ISSUE [PR] [WORKTREE_PATH] [FILES_HINT...]
pre_dispatch() {
  local role="${1:-}" issue="${2:-}" pr="${3:-}" worktree="${4:-}"
  local _shift_n=$(( $# >= 4 ? 4 : $# ))
  shift "$_shift_n" 2>/dev/null || true
  local files_hint=("$@")

  local hook_cmd
  hook_cmd="$(cfg hooks.pre_dispatch)"
  if [ -z "$hook_cmd" ]; then
    return 0
  fi

  local timeout_s
  timeout_s="$(_hooks_timeout_s)"

  local repo base_branch
  repo="$(_hooks_repo)"
  base_branch="$(cfg base_branch)"

  # ── Build the stdin JSON via python3 json.dumps (never string-concat) ──────
  local stdin_json
  stdin_json="$(TALOS_HOOK_ROLE="$role" TALOS_HOOK_ISSUE="$issue" TALOS_HOOK_PR="$pr" \
    TALOS_HOOK_REPO="$repo" TALOS_HOOK_BASE="$base_branch" TALOS_HOOK_WT="$worktree" \
    python3 -I -c '
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

# Length cap (characters) shared by --summary, --summary - and --summary-file.
_HOOKS_SUMMARY_MAX=4096

# _hooks_usage -- the usage text, shared by the bad-verb and missing-value exits.
_hooks_usage() {
  echo "Usage: pipeline-hooks.sh pre_dispatch <role> <issue> [<pr>] [<worktree_path>] [files_hint...]" >&2
  echo "       pipeline-hooks.sh stage_start <role> <issue> [--pr N]" >&2
  echo "       pipeline-hooks.sh run_end <stop line> [--issue N]" >&2
  echo "       pipeline-hooks.sh post_stage <event> <role> <issue> [--pr N] [--sha S] [--verdict V] [--summary \"...\" | --summary - | --summary-file F] [--details-file F] [--attempt stage:count:total] [--duration-s N] [--tokens N] [--tool-uses N] [--ci-runs N] [--model M] [--runner R] [--input-tokens N] [--output-tokens N] [--cache-write-tokens N] [--cache-read-tokens N] [--pool api|plan]" >&2
}

# _hooks_need_value OPTION ARGC -- exit 2 with usage when a value-taking
# option is the last argument.
_hooks_need_value() {
  if [ "$2" -lt 2 ]; then
    echo "pipeline-hooks: $1 needs a value" >&2
    _hooks_usage
    exit 2
  fi
}

# post_stage EVENT ROLE ISSUE [--pr N] [--sha S] [--verdict V] [--summary S]
#            [--summary-file F] [--details-file F] [--attempt stage:count:total] [--duration-s N]
#            [--tokens N] [--tool-uses N] [--ci-runs N] [--model M] [--runner R]
#            [--input-tokens N] [--output-tokens N] [--cache-write-tokens N] [--cache-read-tokens N]
#            [--pool api|plan]
# --runner R (#418): the runner the stage actually ran on. pipeline-agent.sh
# passes it only for a stage that ran on a failover-chain runner; the event's
# runner is then R and its model is null (a fallback runner uses its own
# default model) unless --model is given. Without the flag nothing changes.
# Event "failover" (#418) is recorded under role "orchestrator", like
# "budget-blocked", so it never counts as an unrecorded stage run.
post_stage() {
  local event="${1:-}" role="${2:-}" issue="${3:-}"
  local _shift_n=$(( $# >= 3 ? 3 : $# ))
  shift "$_shift_n" 2>/dev/null || true

  local pr="" sha="" verdict="" summary="" details_file="" attempt="" duration_s="" tokens="" tool_uses="" ci_runs="" model_arg="" runner_arg=""
  local summary_file="" summary_stdin=0
  local input_tokens="" output_tokens="" cache_write_tokens="" cache_read_tokens="" pool=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr|--sha|--verdict|--summary|--summary-file|--details-file|--attempt|--duration-s|--tokens|--tool-uses|--ci-runs|--model|--runner|--input-tokens|--output-tokens|--cache-write-tokens|--cache-read-tokens|--pool)
        # A value flag as the last argument used to loop forever (`shift 2`
        # with one argument left shifts nothing): exit 2 with usage instead.
        _hooks_need_value "$1" $#
        ;;
    esac
    case "$1" in
      --pr) pr="$2"; shift 2 ;;
      --sha) sha="$2"; shift 2 ;;
      --verdict) verdict="$2"; shift 2 ;;
      --summary)
        # `--summary -` reads the summary from stdin (never put free text
        # in a command line); a later --summary / --summary-file wins.
        summary="$2"; summary_file=""; summary_stdin=0
        [ "$2" != "-" ] || summary_stdin=1
        shift 2 ;;
      --summary-file) summary_file="$2"; summary=""; summary_stdin=0; shift 2 ;;
      --details-file) details_file="$2"; shift 2 ;;
      --attempt) attempt="$2"; shift 2 ;;
      --duration-s) duration_s="$2"; shift 2 ;;
      --tokens) tokens="$2"; shift 2 ;;
      --tool-uses) tool_uses="$2"; shift 2 ;;
      --ci-runs) ci_runs="$2"; shift 2 ;;
      --model) model_arg="$2"; shift 2 ;;
      --runner) runner_arg="$2"; shift 2 ;;
      --input-tokens) input_tokens="$2"; shift 2 ;;
      --output-tokens) output_tokens="$2"; shift 2 ;;
      --cache-write-tokens) cache_write_tokens="$2"; shift 2 ;;
      --cache-read-tokens) cache_read_tokens="$2"; shift 2 ;;
      --pool) pool="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # --summary - / --summary-file: read at most the cap in bytes, then cap the
  # characters, so every summary source shares one length limit.
  if [ "$summary_stdin" = "1" ]; then
    summary="$(head -c "$((_HOOKS_SUMMARY_MAX * 4))")"
  elif [ -n "$summary_file" ]; then
    if [ -f "$summary_file" ]; then
      # Redirection, never a path argument: a path starting with `-` is not
      # parsed as an option, and the file is opened exactly once.
      summary="$(head -c "$((_HOOKS_SUMMARY_MAX * 4))" < "$summary_file")"
    else
      echo "pipeline-hooks: --summary-file '$summary_file' is not a file -- using an empty summary" >&2
    fi
  fi
  summary="${summary:0:_HOOKS_SUMMARY_MAX}"

  # #202: --tokens/--tool-uses are validated non-negative integers -- an
  # invalid value becomes empty here (-> null in the payload below) with one
  # stderr note; missing (never supplied) is already empty and silent.
  tokens="$(_validate_nonneg_int tokens "$tokens")"
  tool_uses="$(_validate_nonneg_int tool-uses "$tool_uses")"
  ci_runs="$(_validate_nonneg_int ci-runs "$ci_runs")"
  # #604: the usage split; an invalid value drops that one key (see the header).
  input_tokens="$(_validate_nonneg_int input-tokens "$input_tokens")"
  output_tokens="$(_validate_nonneg_int output-tokens "$output_tokens")"
  cache_write_tokens="$(_validate_nonneg_int cache-write-tokens "$cache_write_tokens")"
  cache_read_tokens="$(_validate_nonneg_int cache-read-tokens "$cache_read_tokens")"
  # #616: the pool that paid; anything but api or plan drops the key.
  case "$pool" in
    ''|api|plan) ;;
    *) echo "pipeline-hooks: --pool value is not api or plan -- leaving it out" >&2; pool="" ;;
  esac

  local hook_cmd
  hook_cmd="$(cfg hooks.post_stage)"

  local repo
  repo="$(_hooks_repo)"

  local model runner
  runner="$(cfg agents.runner)"
  # #418: a stage that ran on a failover-chain runner names that runner.
  [ -z "$runner_arg" ] || runner="$(printf '%s' "$runner_arg" | LC_ALL=C tr -d '\000-\037\177')"
  # #379: the model the stage ran with. --model (the spawn `model:` the
  # orchestrator passed) wins. Otherwise a re-stamp verdict follows the
  # restamp_model chain the orchestrator spawned with (skills/pipeline/SKILL.md
  # restamp_model): role restamp -> global restamp -> role model ->
  # agents.model. Any other verdict: role model -> agents.model. Empty stays
  # empty, which the payload records as null ("session default").
  model="$(printf '%s' "$model_arg" | LC_ALL=C tr -d '\000-\037\177')"
  model="${model:0:100}"
  # A model outside [A-Za-z0-9._:-]+ is dropped (one stderr line); the hook
  # still fires, with the configured model chain below as the fallback.
  case "$model" in
    *[!A-Za-z0-9._:-]*)
      echo "pipeline-hooks: --model value is outside [A-Za-z0-9._:-] -- ignoring it" >&2
      model=""
      ;;
  esac
  if [ -z "$model" ]; then
    case "$verdict" in
      RESTAMP_PASS|RESTAMP_FAIL)
        model="$(cfg "agents.roles.$role.restamp_model")"
        [ -n "$model" ] || model="$(cfg agents.restamp_model)"
        ;;
    esac
  fi
  if [ -z "$runner_arg" ]; then
    [ -n "$model" ] || model="$(cfg "agents.roles.$role.model")"
    [ -n "$model" ] || model="$(cfg agents.model)"
  fi

  local details=""
  [ -n "$details_file" ] && [ -f "$details_file" ] && details="$(cat "$details_file")"

  local ts
  ts="$(python3 -I -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

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
    TALOS_HOOK_CI_RUNS="$ci_runs" TALOS_HOOK_TS="$ts" \
    TALOS_HOOK_INPUT_TOKENS="$input_tokens" TALOS_HOOK_OUTPUT_TOKENS="$output_tokens" \
    TALOS_HOOK_CACHE_WRITE_TOKENS="$cache_write_tokens" TALOS_HOOK_CACHE_READ_TOKENS="$cache_read_tokens" \
    TALOS_HOOK_POOL="$pool" \
    python3 -I -c '
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
}
# #332: ci_runs only when supplied, so a payload without it is unchanged.
_ci_runs = _int_or_none(os.environ.get("TALOS_HOOK_CI_RUNS"))
if _ci_runs is not None:
    payload["ci_runs"] = _ci_runs
# #604: the usage split, each key only when supplied (same rule as ci_runs).
for _key in ("input_tokens", "output_tokens", "cache_write_tokens", "cache_read_tokens"):
    _n = _int_or_none(os.environ.get("TALOS_HOOK_" + _key.upper()))
    if _n is not None:
        payload[_key] = _n
# #616: the pool that paid, only when supplied.
if os.environ.get("TALOS_HOOK_POOL"):
    payload["pool"] = os.environ["TALOS_HOOK_POOL"]
payload["ts"] = os.environ.get("TALOS_HOOK_TS", "")
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

# stage_start ROLE ISSUE [--pr N]: see the header.
stage_start() {
  local role="${1:-}" issue="${2:-}" pr=""
  case "$role" in ''|*[!a-z-]*) _hooks_usage; exit 2 ;; esac
  case "$issue" in ''|*[!0-9]*) _hooks_usage; exit 2 ;; esac
  shift 2
  if [ "${1:-}" = "--pr" ]; then
    case "${2:-}" in ''|*[!0-9]*) _hooks_usage; exit 2 ;; esac
    pr="$2"
  fi
  _events_append "$(TALOS_ST_STAGE="$role" TALOS_ST_ISSUE="$issue" TALOS_ST_PR="$pr" python3 -I -c '
import datetime, json, os
e = os.environ
print(json.dumps({
    "event": "stage_start", "role": "orchestrator", "stage": e["TALOS_ST_STAGE"],
    "issue": int(e["TALOS_ST_ISSUE"]), "pr": int(e["TALOS_ST_PR"]) if e["TALOS_ST_PR"] else None,
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}))
')"
}

# run_end STOP_LINE [--issue N]: see the header.
run_end() {
  local line="${1:-}" issue=""
  [ -n "$line" ] || { _hooks_usage; exit 2; }
  shift
  if [ "${1:-}" = "--issue" ]; then
    case "${2:-}" in ''|*[!0-9]*) _hooks_usage; exit 2 ;; esac
    issue="$2"
  fi
  _events_append "$(TALOS_RE_LINE="$line" TALOS_RE_ISSUE="$issue" TALOS_RE_REPO="$(_hooks_repo)" python3 -I -c '
import datetime, json, os
e = os.environ
words = {}
for w in e["TALOS_RE_LINE"].split():
    k, eq, v = w.partition("=")
    if eq and k not in words:
        words[k] = v
def text(k):
    return words.get(k) or None
def num(v):
    return int(v) if v and v.isascii() and v.isdigit() else None
issue = num(words.get("issue")) or num(e["TALOS_RE_ISSUE"])
print(json.dumps({
    "event": "run_end", "role": "orchestrator", "stage": text("role"),
    "issue": issue, "pr": num(words.get("pr")), "repo": e["TALOS_RE_REPO"] or None,
    "verdict": text("verdict"), "reason": text("reason"), "detail": text("detail"),
    "line": e["TALOS_RE_LINE"][:1024],
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}))
')"
}

VERB="${1:-}"
case "$VERB" in
  stage_start)
    shift
    stage_start "$@"
    ;;
  run_end)
    shift
    run_end "$@"
    ;;
  pre_dispatch)
    shift
    pre_dispatch "$@"
    ;;
  post_stage)
    shift
    post_stage "$@"
    ;;
  *)
    _hooks_usage
    exit 2
    ;;
esac
