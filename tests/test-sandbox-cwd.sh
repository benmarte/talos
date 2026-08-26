#!/usr/bin/env bash
# test-sandbox-cwd.sh — covers issue #121: make_sandbox CWD-stranding behaviour.
#
# Tests:
#   T1. Sandbox is removed after the subprocess exits (leak guard).
#   T2. Sandbox is removed even when the test fails (cleanup-on-failure guard).
#   T3. bash-executing a test file does not strand the caller's CWD.
#   T4. run-tests.sh rejects being sourced.
#
# Mutations that make each test RED:
#   T1/T2: remove 'rm -rf "$SANDBOX"' from the EXIT trap in make_sandbox.
#   T3:    change 'bash "$t"' to '. "$t"' in run-tests.sh.
#   T4:    remove the BASH_SOURCE guard from run-tests.sh.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

# ═════════════════════════════════════════════════════════════════════════════
# T1: Sandbox is removed after the subprocess exits
# ═════════════════════════════════════════════════════════════════════════════
before_t1="$(ls -d "${TMPDIR:-/tmp}"/talos-test.* 2>/dev/null | wc -l | tr -d ' ')"
(
  . "$TALOS_ROOT/tests/helpers.sh"
  make_sandbox
  # subshell exits here; EXIT trap fires; rm -rf "$SANDBOX" runs
)
after_t1="$(ls -d "${TMPDIR:-/tmp}"/talos-test.* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$before_t1" "$after_t1" \
  "T1: make_sandbox: sandbox dir removed when subprocess exits (mutation: omit rm -rf from trap)"

# ═════════════════════════════════════════════════════════════════════════════
# T2: Sandbox is removed even when the test fails
# ═════════════════════════════════════════════════════════════════════════════
before_t2="$(ls -d "${TMPDIR:-/tmp}"/talos-test.* 2>/dev/null | wc -l | tr -d ' ')"
(
  . "$TALOS_ROOT/tests/helpers.sh"
  make_sandbox
  exit 1   # deliberate failure — EXIT trap must still fire
) || true  # allow non-zero from the subshell
after_t2="$(ls -d "${TMPDIR:-/tmp}"/talos-test.* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$before_t2" "$after_t2" \
  "T2: make_sandbox: sandbox removed on deliberate failure (mutation: omit rm -rf from trap)"

# ═════════════════════════════════════════════════════════════════════════════
# T3: bash-executing a test file does not change the caller's CWD
# ═════════════════════════════════════════════════════════════════════════════
# run-tests.sh invokes each test via "bash \"$t\"" (a subprocess); the test's
# cd into $SANDBOX cannot propagate to the parent. This assertion goes RED if
# run-tests.sh is changed to ". \"$t\"" (sourced execution).
before_t3="$(pwd)"
bash "$TALOS_ROOT/tests/test-config.sh" >/dev/null 2>&1 || true
after_t3="$(pwd)"
assert_eq "$before_t3" "$after_t3" \
  "T3: bash-executing a test file does not strand caller CWD (mutation: source instead of bash)"

# ═════════════════════════════════════════════════════════════════════════════
# T4: run-tests.sh rejects being sourced
# ═════════════════════════════════════════════════════════════════════════════
out_t4="$(bash -c ". '$TALOS_ROOT/tests/run-tests.sh'" 2>&1 || true)"
assert_contains "$out_t4" "ERROR" \
  "T4: run-tests.sh rejects being sourced (mutation: remove BASH_SOURCE guard)"
assert_contains "$out_t4" "run-tests.sh" \
  "T4: error message names the script to invoke correctly"

finish
