#!/usr/bin/env bash
# test-sandbox-signal-race.sh — regression guard for the vanishing-sandbox CI
# flake (#566): test-talos-next.sh lost its own sandbox mid-run on Linux CI.
#
# Cause: bash >= 5 arms a fatal-signal handler as soon as an EXIT trap exists, and
# a forked child inherits it until it execs/clears traps. `( sleep 30 ) & kill $!`
# delivered SIGTERM inside that window on Linux (the parent keeps the CPU after
# fork; macOS runs the child first), so the CHILD ran make_sandbox's EXIT trap and
# `rm -rf "$SANDBOX"` deleted the live test's directory. Fix: the trap body only
# removes the sandbox in the process that created it (_sandbox_cleanup).
#
# Tests:
#   T1. A forked child that inherits the trap and "exits" never removes the sandbox.
#   T2. Racing a kill against a fresh `( sleep )` child 300 times never removes it.
#   T3. The creating process still removes the sandbox on exit (no leak).
#
# Mutation that makes T1/T2 RED on bash >= 4: replace the trap body with a bare
# `rm -rf "$SANDBOX"`. T3 goes RED if the owner check never matches.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

if [ -z "${BASHPID:-}" ]; then
  # bash 3.2: no BASHPID to tell parent from child, and the race cannot occur
  # there (verified: the same loop survives on /bin/bash 3.2.57).
  pass "T1: skipped on bash < 4 (no BASHPID; the signal-handler race does not exist)"
  pass "T2: skipped on bash < 4"
else
  # T1: deterministic -- run the trap body as a forked child would.
  ( _sandbox_cleanup )
  assert_eq "yes" "$([ -d "$SANDBOX" ] && echo yes || echo no)" \
    "T1: the sandbox cleanup is a no-op in a process that did not create it"

  # T2: the real race. Each iteration forks a child and kills it immediately.
  # (stderr silenced as a block: bash 5 prints job-table notices for the reaped
  # children that a per-command redirect does not catch.)
  _t2_ok=yes
  _t2_i=0
  {
    while [ "$_t2_i" -lt 300 ]; do
      ( sleep 30 ) & _t2_pid=$!
      kill "$_t2_pid"
      wait "$_t2_pid"
      if [ ! -d "$SANDBOX" ]; then _t2_ok="no (vanished at iteration $_t2_i)"; break; fi
      _t2_i=$((_t2_i + 1))
    done
  } 2>/dev/null
  assert_eq "yes" "$_t2_ok" \
    "T2: killing a freshly forked child never deletes the live sandbox"
fi

# T3: the creator still cleans up after itself.
_t3_out="$(
  PRIV="$(mktemp -d "${TMPDIR:-/tmp}/talos-sigrace.XXXXXX")" || exit 1
  ( export TMPDIR="$PRIV"
    . "$TALOS_ROOT/tests/helpers.sh"
    make_sandbox
    printf '%s\n' "$SANDBOX" > "$PRIV/path" )
  _p="$(cat "$PRIV/path")"
  [ -d "$_p" ] && echo leaked || echo removed
  rm -rf "${PRIV:?}"
)"
assert_eq "removed" "$_t3_out" "T3: the creating process still removes its sandbox on exit"

finish
