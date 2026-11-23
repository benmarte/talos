#!/usr/bin/env bash
# pipeline-lock.sh -- portable advisory locking for shared local state (two
# stages racing on one on-disk file or on one repo's worktree metadata).
#
# macOS ships no flock(1). The lock directory is "<resource>.lock.d", next to the
# resource it protects, so two checkouts never collide. `mkdir` makes the
# directory but is NOT the claim: uutils mkdir (Ubuntu 26.04) lets several
# concurrent callers all exit 0 on one new path (#999). The claim is the O_EXCL
# create of "<lockdir>/pid" (bash noclobber, a builtin, so it does not depend on
# the coreutils in use): only the process whose write of its token succeeds
# holds the lock, and one whose mkdir "succeeded" but whose write failed waits.
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
# dead takes the gate "<lockdir>.reclaim" (an O_EXCL file create, like the
# claim), re-reads the pid file under it, and deletes the lock only if it still
# holds the dead holder's token. Only that holder (dead) or a gated reclaimer
# can remove a lock, so a stale reading -- the lock changed hands after the
# check -- is a no-op, and a live lock is never absent for a third process to
# claim. A lock dir with no pid file, or an empty one, is a holder that died
# inside the claim window (#1011): it is reclaimed the same way once the dir's
# mtime is over a minute old. A gate over a minute old is left by a reclaimer
# that died inside it and is cleared by renaming it aside, so of several waiters
# only the one whose rename succeeds proceeds. A lock is removed by renaming the dir aside and deleting that,
# so a racer that created its pid file in the dying dir cannot be unlinked
# halfway and left believing it holds a lock that is gone.
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

# _lock_self_pid -- set _LOCK_SELF_PID to the pid of the CURRENT (sub)shell. `$$`
# is the parent shell's pid inside a subshell, so sibling workers would share it
# and their tokens would collide (#990). $BASHPID is the real one (bash 4+); bash
# 3.2 (macOS /bin/bash) has none, so ask a child whose parent is this shell:
# `exec sh` replaces the command-substitution subshell, and that sh's PPID is the
# shell that ran the substitution. A variable, not stdout: a caller's own `$(...)`
# would be one subshell too deep and report that subshell's pid instead.
_LOCK_SELF_PID=""
_lock_self_pid() {
  if [ -n "${BASHPID:-}" ]; then
    _LOCK_SELF_PID="$BASHPID"
  else
    _LOCK_SELF_PID="$(exec sh -c 'echo "$PPID"')"
  fi
}

# _lock_excl_create FILE CONTENT -- create FILE holding CONTENT with O_EXCL
# (noclobber): 0 if this call created it, 1 if it already existed. The caller's
# own noclobber setting is restored.
_lock_excl_create() {
  local _was_set=0 _rc
  case $- in *C*) _was_set=1 ;; esac
  set -C
  printf '%s\n' "$2" 2>/dev/null > "$1"
  _rc=$?
  [ "$_was_set" -eq 1 ] || set +C
  return "$_rc"
}

# _lock_remove_dir DIR -- remove a lock dir by renaming it aside first (atomic),
# then deleting the renamed copy; a plain rm -rf is a readdir/unlink/rmdir walk
# in which a late pid file can be unlinked, leaving its writer holding nothing.
_lock_remove_dir() {
  local aside="$1.rm.$$.$RANDOM"
  if mv "$1" "$aside" 2>/dev/null; then
    rm -rf "$aside" 2>/dev/null || true
  else
    rm -rf "$1" 2>/dev/null || true
  fi
}

# _lock_older_than_grace PATH -- 0 when PATH's mtime is over a minute old (the
# grace a claim, or a reclaimer inside the gate, has to finish).
_lock_older_than_grace() {
  [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]
}

# _lock_clear_stale_gate GATE -- 0 if this call cleared a gate left by a dead
# reclaimer. The gate is renamed aside (atomic), so of several waiters that all
# read it as stale only the one whose rename succeeds proceeds. If what it moved
# turns out to be fresh (another waiter cleared the stale gate and a new
# reclaimer took the gate in between), it is linked back and this call reports 1.
# A gate left by an older version is a directory: removed with rm -rf.
_lock_clear_stale_gate() {
  local gate="$1" aside="$1.stale.$$.$RANDOM"
  _lock_older_than_grace "$gate" || return 1
  mv "$gate" "$aside" 2>/dev/null || return 1
  if ! _lock_older_than_grace "$aside"; then
    ln "$aside" "$gate" 2>/dev/null || true
    rm -rf "$aside" 2>/dev/null || true
    return 1
  fi
  rm -rf "$aside" 2>/dev/null || true
  return 0
}

# _lock_acquire RESOURCE TIMEOUT_S
_lock_acquire() {
  local resource="$1" timeout="${2:-5}" lockdir pidfile tries max_tries holder holder_pid token gate dead
  lockdir="$(_lock_dir_for "$resource")"
  pidfile="$lockdir/pid"
  gate="$lockdir.reclaim"
  case "$timeout" in ''|*[!0-9]*) timeout=5 ;; esac
  max_tries=$((timeout * 5))   # spin at 0.2s intervals
  [ "$max_tries" -lt 1 ] && max_tries=1
  tries=0
  while :; do
    # mkdir only makes sure the dir exists; its exit status is not the claim
    # (uutils mkdir succeeds for every racer). The O_EXCL pid-file create is.
    if mkdir "$lockdir" 2>/dev/null; then
      _lock_self_pid
      _LOCK_TOKEN_SEQ=$((_LOCK_TOKEN_SEQ + 1))
      token="$_LOCK_SELF_PID:$RANDOM$RANDOM-$_LOCK_TOKEN_SEQ"
      if _lock_excl_create "$pidfile" "$token"; then
        _LOCK_ACQUIRED_TOKEN="$token"
        _talos_on_exit "_lock_release_owned $(printf '%q' "$resource") $(printf '%q' "$token")"
        return 0
      fi
    fi
    # Someone else holds it (or lost a race creating it just now) -- check
    # whether the recorded holder is still alive before waiting it out. A holder
    # that died inside the claim window leaves no pid file or an empty one
    # (#1011): that counts as a dead holder once the dir is over the grace period.
    if [ -d "$lockdir" ]; then
      holder="$(cat "$pidfile" 2>/dev/null || true)"
      holder_pid="${holder%%:*}"
      dead=0
      if [ -n "$holder_pid" ]; then
        kill -0 "$holder_pid" 2>/dev/null || dead=1
      elif _lock_older_than_grace "$lockdir"; then
        dead=1
      fi
      if [ "$dead" -eq 1 ]; then
        # Gated reclaim (#923): the lock may have changed hands since the
        # holder was read, so act only under the gate and only if the pid file
        # still holds that dead holder's token (still no token and the dir still
        # old, for a holder that never wrote one). Tokens are unique (pid:seq),
        # nobody else can remove this lock meanwhile, and the lock dir is never
        # moved, so it is never absent while a live process holds it.
        if _lock_excl_create "$gate" "$$"; then
          if [ "$(cat "$pidfile" 2>/dev/null || true)" = "$holder" ] &&
             { [ -n "$holder_pid" ] || _lock_older_than_grace "$lockdir"; }; then
            _lock_remove_dir "$lockdir"
          fi
          rm -f "$gate" 2>/dev/null || true
          continue    # retry the claim immediately, doesn't count as a wait
        fi
        # Another reclaimer holds the gate; clear it only when it is over a
        # minute old (its owner died inside it -- a reclaim takes milliseconds).
        if _lock_clear_stale_gate "$gate"; then
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
    _lock_remove_dir "$lockdir"
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
