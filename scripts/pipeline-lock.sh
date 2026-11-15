#!/usr/bin/env bash
# pipeline-lock.sh -- portable advisory locking for shared local state (two
# stages racing on one on-disk file or on one repo's worktree metadata).
#
# macOS ships no flock(1), so `mkdir` is the atomic primitive: it creates the
# directory or fails with EEXIST. The lock directory is "<resource>.lock.d", next
# to the resource it protects, so two checkouts never collide.
#
# Sourceable API:
#   with_lock <resource> <timeout_s> -- <cmd...>
#       Acquire, run <cmd...>, release; returns <cmd...>'s exit code. After
#       timeout_s it proceeds WITHOUT the lock with one stderr warning: a stuck
#       lock must never deadlock the pipeline.
#   _lock_acquire <resource> <timeout_s>
#       For a lock held across several commands. 0 with the lock held, 1 after
#       timing out (the caller proceeds without it). Registers a release-on-exit
#       hook so a crash cannot leave a stale lock.
#   _lock_release <resource>
#       Release the most recent _lock_acquire. Not reentrant: one held lock per
#       process, which matches every call site.
#
# Ownership token: an acquire writes "<pid>:<seq>" into "<lockdir>/pid", and a
# release removes the lock dir only if that token is still on disk, so a stale
# exit hook from an earlier acquisition can never destroy another holder's lock.
# Staleness: a lock whose pid is no longer a running process is reclaimed
# (#871, #923). The lock dir is never moved: a waiter that finds the holder
# dead takes the gate "<lockdir>.reclaim" (mkdir), re-reads the pid file under
# it, and deletes the lock only if it still holds the dead holder's token. Only
# that holder (dead) or a gated reclaimer can remove a lock, so a stale reading
# -- the lock changed hands after the check -- is a no-op, and a live lock is
# never absent for a third process to mkdir. A gate over a minute old is left
# by a reclaimer that died inside it and is cleared.
# Only EXIT is trapped (it also fires on SIGINT/SIGTERM; a trap of their own
# would stop bash terminating). The release hook uses _talos_on_exit from
# pipeline-cfg-cache.sh when loaded, else a minimal registry defined below.

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
  local resource="$1" timeout="${2:-5}" lockdir pidfile tries max_tries holder holder_pid token gate
  lockdir="$(_lock_dir_for "$resource")"
  pidfile="$lockdir/pid"
  gate="$lockdir.reclaim"
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
        # Gated reclaim (#923): the lock may have changed hands since the
        # holder was read, so act only under the gate and only if the pid file
        # still holds that dead holder's token. Tokens are unique (pid:seq),
        # nobody else can remove this lock meanwhile, and the lock dir is never
        # moved, so it is never absent while a live process holds it.
        if mkdir "$gate" 2>/dev/null; then
          if [ "$(cat "$pidfile" 2>/dev/null || true)" = "$holder" ]; then
            rm -rf "$lockdir" 2>/dev/null || true
          fi
          rmdir "$gate" 2>/dev/null || true
          continue    # retry mkdir immediately, doesn't count as a wait
        fi
        # Another reclaimer holds the gate; clear it only when it is over a
        # minute old (its owner died inside it -- a reclaim takes milliseconds).
        if [ -n "$(find "$gate" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
          rmdir "$gate" 2>/dev/null || true
          continue
        fi
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
