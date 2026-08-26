# helpers.sh — shared assertions and sandbox setup for talos tests.
# Source this from every test file. Requires TALOS_ROOT to be exported
# by run-tests.sh (falls back to the repo root relative to this file).

TALOS_ROOT="${TALOS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STUBS_DIR="$TALOS_ROOT/tests/stubs"

_PASS=0
_FAIL=0

pass() { _PASS=$((_PASS + 1)); printf '  ok  %s\n' "$1"; }

fail() {
  _FAIL=$((_FAIL + 1))
  printf 'FAIL  %s\n' "$1" >&2
  [ -n "${2:-}" ] && printf '      %s\n' "$2" >&2
}

assert_eq() {  # $1=expected $2=actual $3=label
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected: $1 | actual: $2"; fi
}

assert_contains() {  # $1=haystack $2=needle $3=label
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3" "missing: $2 | in: $(printf '%s' "$1" | head -c 300)" ;;
  esac
}

assert_not_contains() {  # $1=haystack $2=needle $3=label
  case "$1" in
    *"$2"*) fail "$3" "unexpected: $2" ;;
    *) pass "$3" ;;
  esac
}

assert_file_exists() {  # $1=path $2=label
  if [ -f "$1" ]; then pass "$2"; else fail "$2" "file not found: $1"; fi
}

assert_file_absent() {  # $1=path $2=label
  if [ -e "$1" ]; then fail "$2" "file should not exist: $1"; else pass "$2"; fi
}

assert_exit_code() {  # $1=expected $2=actual $3=label
  assert_eq "$1" "$2" "$3"
}

# make_sandbox — create an isolated temp dir with a git repo + fake origin.
# Sets SANDBOX and cds into it. Cleaned up automatically on exit.
#
# WARNING (#121): make_sandbox cds into a temp dir and registers an EXIT trap
# that deletes it. This function must only be called inside a subprocess
# (e.g. "bash tests/my-test.sh") — never sourced into the caller's own shell.
# Sourcing it changes the caller's CWD to a directory that gets deleted when
# the subprocess exits, stranding the caller in a non-existent path.
#
# The guard below detects the sourced case by comparing BASH_SOURCE[-1]
# (the outermost file in the call stack) with $0 (the running script). When
# a test file is executed directly ("bash tests/test-foo.sh"), both equal the
# test file path. When helpers.sh is sourced into an interactive shell,
# BASH_SOURCE[-1] differs from $0 — the guard fires and returns 1.
make_sandbox() {
  # Guard: refuse when called from a sourced context.
  # BASH_SOURCE[-1] (bash 4+) is spelled out portably for bash 3.2 (macOS).
  _msb_outer="${BASH_SOURCE[${#BASH_SOURCE[@]}-1]:-}"
  if [ -n "$_msb_outer" ] && [ "$_msb_outer" != "$0" ]; then
    printf 'make_sandbox: ERROR: do not source test files — run them directly:\n' >&2
    printf '  bash %s\n' "$_msb_outer" >&2
    printf 'Sourcing make_sandbox cds the caller shell into a temp dir that is\n' >&2
    printf 'deleted on exit, stranding the caller in a non-existent path.\n' >&2
    unset _msb_outer
    return 1
  fi
  unset _msb_outer
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/talos-test.XXXXXX")"
  trap 'rm -rf "$SANDBOX"' EXIT
  cd "$SANDBOX"
  git init -q
  git remote add origin git@github.com:acme/widget.git
  # Hermetic HOME. pipeline-notify.sh scrapes ~/.hermes/.env for bot
  # credentials, so on a developer machine with Slack/Discord/Buzz configured
  # the real values bleed into the sandbox and invert credential-absence
  # assertions ("without private key produces no buzz output" starts finding a
  # key). Kept as a subdirectory so HOME is never the repo root itself, and
  # seeded with a gitconfig so suites that commit still resolve an identity.
  mkdir -p "$SANDBOX/.home"
  export HOME="$SANDBOX/.home"
  printf '[user]\n\tname = talos-test\n\temail = test@talos.invalid\n' > "$HOME/.gitconfig"
}

# use_stubs — put the gh/curl/nak stubs first on PATH and reset their logs.
# Sets GH_LOG, CURL_LOG, and NAK_LOG (files the stubs append every invocation to).
use_stubs() {
  export PATH="$STUBS_DIR:$PATH"
  export GH_LOG="$SANDBOX/gh.log"
  export CURL_LOG="$SANDBOX/curl.log"
  export CURL_QUEUE="$SANDBOX/curl.queue"        # optional: one canned response per line
  export CURL_LINK_QUEUE="$SANDBOX/curl.link.queue"  # optional: Link: next URL per call
  export NAK_LOG="$SANDBOX/nak.log"
  export NAK_QUEUE="$SANDBOX/nak.queue"     # optional: "fail" or canned event JSON per line
  : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
  : > "$NAK_LOG"; : > "$NAK_QUEUE"
}

# install_talos — run install.sh into the sandbox quietly.
install_talos() {
  bash "$TALOS_ROOT/install.sh" "$SANDBOX" >/dev/null
}

# finish — print summary for this file and exit non-zero on any failure.
finish() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$_PASS" "$_FAIL"
  [ "$_FAIL" -eq 0 ]
}
