#!/usr/bin/env bash
# pipeline-lock.sh -- portable advisory locking for shared local state
# (issue #180: issues.max_parallel > 1 lets two stages race on the same
# on-disk file, e.g. ~/.talos/threads.json, or the same repo's
# `git worktree` metadata).
#
# macOS ships no flock(1) (that binary is util-linux, Linux-only), so this
# uses `mkdir` as the atomic primitive instead: POSIX guarantees mkdir
# either creates the directory or fails with EEXIST -- there is no window
# where two racing callers can both "win".
#
# Lock directory naming: "<resource>.lock.d", created next to the resource
# it protects (not under a shared /tmp path), so two different repos or
# checkouts locking a same-named resource never collide.
#
# Sourceable API:
#   with_lock <resource> <timeout_s> -- <cmd...>
#       Acquire the lock (or give up after timeout_s and proceed anyway,
#       printing one stderr warning -- a stuck lock must never deadlock the
#       pipeline), run <cmd...>, then release. Returns <cmd...>'s exit code
#       either way.
#
#   _lock_acquire <resource> <timeout_s>
#       Lower-level primitive for callers that need the lock held across
#       more than one command. Returns 0 with the lock held, or 1 after
#       timing out (caller proceeds WITHOUT the lock -- same "never
#       deadlock" contract as with_lock). Registers a release-on-exit hook
#       so a crash mid-critical-section can't leave a stale lock behind.
#   _lock_release <resource>
#       Release the most recent _lock_acquire (the normal, fast path -- the
#       exit hook registered by _lock_acquire is only the safety net for
#       the abnormal/crash path). Not reentrant: this module tracks at most
#       one held lock at a time per process, matching every real call site
#       (pipeline-notify.sh, pipeline-worktree.sh each hold one lock at a
#       time, never nested locks on two different resources).
#
# Ownership token: each successful acquire writes "<pid>:<seq>" (seq is a
# per-process acquire counter) into "<lockdir>/pid", not just the PID. Every
# release -- explicit or via the exit-hook safety net -- only removes the
# lock dir if that token is still the one on disk. Without this, a process
# that acquires-then-releases the SAME resource N times in a loop (the
# common case: N stages each briefly locking one shared file) would leave N
# stale exit hooks queued up, and when the process finally exits, EVERY one
# of those hooks fires and unconditionally rm -rf's the lock dir -- included
# the (N+1)th holder's lock dir, if some OTHER process happened to acquire
# it in the meantime. The token turns that unconditional "release" into "release
# only if I still own it", so a stale hook from an old, already-released
# acquisition can never destroy a different, currently-valid holder's lock.
#
# Staleness: if the lock dir exists but the PID half of its token is no
# longer a running process, the lock is assumed abandoned (the holder
# crashed, was killed, or the machine rebooted without cleanup) and is
# reclaimed instead of waited out.
#
# Release-on-exit / EXIT+INT+TERM: reuses pipeline-cfg-cache.sh's
# `_talos_on_exit` composable trap registry when the sourcing script has
# already loaded it (pipeline-notify.sh, pipeline-worktree.sh both do);
# otherwise this file defines the same minimal registry itself so it works
# standalone (e.g. sourced directly by tests). Only EXIT is trapped -- in
# bash, an EXIT trap still runs when the process is killed by SIGINT or
# SIGTERM as long as those signals have no trap of their own (verified: a
# bare `trap ... EXIT` fires on SIGINT/SIGTERM termination), so one EXIT
# trap already covers EXIT+INT+TERM. Explicitly trapping INT/TERM as well
# would be actively wrong here: once a script installs its own INT/TERM
# trap, bash no longer terminates the process by default after running it,
# so "just run the release hook" would leave the process alive instead of
# letting Ctrl-C/SIGTERM stop it as expected.

if ! command -v _talos_on_exit >/dev/null 2>&1; then
  _TALOS_EXIT_HOOKS=()
  _talos_on_exit() { _TALOS_EXIT_HOOKS+=("$1"); }
  _talos_run_exit_hooks() {
    local _hook
    for _hook in "${_TALOS_EXIT_HOOKS[@]:-}"; do
      [ -n "$_hook" ] && eval "$_hook"
    done
  }
  trap _talos_run_exit_hooks EXIT
fi

_lock_dir_for() { printf '%s.lock.d' "$1"; }

# Tracks the token of the lock this process most recently acquired, for
# _lock_release's fast path. Per-process, not per-resource -- see the "not
# reentrant" note above.
_LOCK_ACQUIRED_TOKEN=""
_LOCK_TOKEN_SEQ=0

# _lock_acquire RESOURCE TIMEOUT_S
_lock_acquire() {
  local resource="$1" timeout="${2:-5}" lockdir pidfile tries max_tries holder holder_pid token
  lockdir="$(_lock_dir_for "$resource")"
  pidfile="$lockdir/pid"
  case "$timeout" in ''|*[!0-9]*) timeout=5 ;; esac
  max_tries=$((timeout * 5))   # spin at 0.2s intervals
  [ "$max_tries" -lt 1 ] && max_tries=1
  tries=0
  while :; do
    if mkdir "$lockdir" 2>/dev/null; then
      _LOCK_TOKEN_SEQ=$((_LOCK_TOKEN_SEQ + 1))
      token="$$:$_LOCK_TOKEN_SEQ"
      printf '%s\n' "$token" > "$pidfile" 2>/dev/null
      _LOCK_ACQUIRED_TOKEN="$token"
      _talos_on_exit "_lock_release_owned $(printf '%q' "$resource") $(printf '%q' "$token")"
      return 0
    fi
    # Someone else holds it (or lost a race creating it just now) -- check
    # whether the recorded holder is still alive before waiting it out.
    if [ -f "$pidfile" ]; then
      holder="$(cat "$pidfile" 2>/dev/null || true)"
      holder_pid="${holder%%:*}"
      if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
        rm -rf "$lockdir" 2>/dev/null || true
        continue    # retry mkdir immediately, doesn't count as a wait
      fi
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge "$max_tries" ]; then
      echo "pipeline-lock: timed out after ${timeout}s waiting for lock on '$resource' -- proceeding without it" >&2
      _LOCK_ACQUIRED_TOKEN=""
      return 1
    fi
    sleep 0.2
  done
}

# _lock_release_owned RESOURCE TOKEN -- remove the lock dir only if it still
# belongs to TOKEN. A no-op (not an error) if it was already released or
# handed to a new holder since TOKEN was issued.
_lock_release_owned() {
  local resource="$1" token="$2" lockdir cur
  lockdir="$(_lock_dir_for "$resource")"
  cur="$(cat "$lockdir/pid" 2>/dev/null || true)"
  if [ -n "$token" ] && [ "$cur" = "$token" ]; then
    rm -rf "$lockdir" 2>/dev/null || true
  fi
}

# _lock_release RESOURCE -- release the most recent _lock_acquire on
# RESOURCE (see the "not reentrant" note above).
_lock_release() {
  _lock_release_owned "$1" "$_LOCK_ACQUIRED_TOKEN"
  _LOCK_ACQUIRED_TOKEN=""
}

# with_lock RESOURCE TIMEOUT_S [--] CMD...
with_lock() {
  local resource="$1" timeout="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  local acquired=0
  _lock_acquire "$resource" "$timeout" || acquired=1
  "$@"
  local rc=$?
  [ "$acquired" -eq 0 ] && _lock_release "$resource"
  return "$rc"
}
