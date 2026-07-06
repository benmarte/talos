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

assert_exit_code() {  # $1=expected $2=actual $3=label
  assert_eq "$1" "$2" "$3"
}

# make_sandbox — create an isolated temp dir with a git repo + fake origin.
# Sets SANDBOX and cds into it. Cleaned up automatically on exit.
make_sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/talos-test.XXXXXX")"
  trap 'rm -rf "$SANDBOX"' EXIT
  cd "$SANDBOX"
  git init -q
  git remote add origin git@github.com:acme/widget.git
}

# use_stubs — put the gh/curl stubs first on PATH and reset their logs.
# Sets GH_LOG and CURL_LOG (files the stubs append every invocation to).
use_stubs() {
  export PATH="$STUBS_DIR:$PATH"
  export GH_LOG="$SANDBOX/gh.log"
  export CURL_LOG="$SANDBOX/curl.log"
  export CURL_QUEUE="$SANDBOX/curl.queue"   # optional: one canned response per line
  : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CURL_QUEUE"
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
