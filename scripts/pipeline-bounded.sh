#!/usr/bin/env bash
# pipeline-bounded.sh -- run one command under a wall-clock limit, portably (#552).
# Source it; it defines functions and runs nothing. macOS has no timeout(1), so
# the command runs as its own process group (set -m) and a background watchdog
# sends that group SIGTERM, then SIGKILL 0.2 s later, once the limit passes.
# The one implementation behind hooks.pre_dispatch/post_stage, notifications.cmd
# and the Buzz nak call.
#
#   talos_bounded SECS CMD [ARG...]
#     Runs CMD (a function works too) with the caller's stdio, so redirect on the
#     call: talos_bounded 5 sh -c "$c" <in >out 2>&1. Sets
#       _BOUNDED_RC         CMD's exit status (128+n when it was killed)
#       _BOUNDED_TIMED_OUT  1 when the watchdog fired, else 0
#     Always returns 0. No process of either group outlives the call.
#   talos_pos_int VALUE DEFAULT
#     Prints VALUE when it is a positive integer, else DEFAULT.
#
# Bash 3.2 safe.

talos_pos_int() {
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) [ "$1" -gt 0 ] 2>/dev/null && printf '%s' "$1" || printf '%s' "$2" ;; esac
}

talos_bounded() {
  local secs="$1" pid wd flag
  shift
  flag="$(mktemp "${TMPDIR:-/tmp}/talos-bounded.XXXXXX")" || flag=""
  set -m
  "$@" &
  pid=$!
  set +m
  # The watchdog gets its own group too, so killing it on the fast path also
  # reaps the `sleep` it forked instead of orphaning it for $secs.
  set -m
  ( sleep "$secs"
    [ -z "$flag" ] || printf 1 > "$flag"
    kill -TERM -"$pid" 2>/dev/null
    sleep 0.2
    kill -KILL -"$pid" 2>/dev/null
  ) &
  wd=$!
  set +m
  wait "$pid" 2>/dev/null
  _BOUNDED_RC=$?
  kill -- -"$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  _BOUNDED_TIMED_OUT=0
  [ -z "$flag" ] || { [ -s "$flag" ] && _BOUNDED_TIMED_OUT=1; rm -f "$flag"; }
  return 0
}
