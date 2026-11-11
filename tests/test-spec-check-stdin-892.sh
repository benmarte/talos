#!/usr/bin/env bash
# test-spec-check-stdin-892.sh -- `pipeline-criteria.sh spec-check` reads the
# spec from stdin (`-`, `/dev/stdin`, a named pipe), so a PM stage that cannot
# write a draft file can still check its spec (#892).
#   AC1  `spec-check -` gives the line and exit code of `spec-check <file>`
#   AC2  `spec-check /dev/stdin < file` and a named pipe do too
#   AC3  an empty stdin is a usage refusal (stderr, exit 2), never ok
#   AC4  the file form is unchanged: a file, a missing file, no argument
# No GitHub write, no LLM call, no network.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

CRIT="$TALOS_ROOT/scripts/pipeline-criteria.sh"
trap '_is_trap_owner && _sandbox_cleanup' EXIT

SPEC="$SANDBOX/spec.md"
ERR="$SANDBOX/stderr"

# spec LINE... -- one (test) criterion and one prose criterion, then the lines
spec() {
  {
    printf '**PM spec:** x\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 greet prints hello (test)\n'
    printf -- '- [ ] AC2 the README names it (prose: doc wording)\n\n'
    [ $# -eq 0 ] || printf '%s\n' "$@"
  } > "$SPEC"
}
# run_<form>: OUT, RC and ERR of one way to hand the spec to spec-check
run_file() { OUT="$(bash "$CRIT" spec-check "$SPEC" 2>"$ERR")"; RC=$?; }
run_dash() { OUT="$(printf '%s' "$(cat "$SPEC")" | bash "$CRIT" spec-check - 2>"$ERR")"; RC=$?; }
run_devstdin() { OUT="$(bash "$CRIT" spec-check /dev/stdin < "$SPEC" 2>"$ERR")"; RC=$?; }
run_fifo() { OUT="$(bash "$CRIT" spec-check <(cat "$SPEC") 2>"$ERR")"; RC=$?; }

# same_verdict ID LABEL: every stdin form gives the file form's line and code
same_verdict() {
  local id="$1" label="$2" want form
  run_file
  want="$RC:$OUT"
  for form in dash devstdin fifo; do
    "run_$form"
    assert_eq "$want" "$RC:$OUT" "$id $label: spec-check via $form matches the file form"
  done
}

spec '**Tests:** `tests/test-greet.sh`'
run_file
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC1 the file form says ok (fixture)"
same_verdict AC1 "ok"
spec
run_file
case "$RC:$OUT" in "1:spec-check: refused tests-line-missing: "*) _got=missing ;; *) _got="$RC:$OUT" ;; esac
assert_eq "missing" "$_got" "AC1 the file form says tests-line-missing (fixture)"
same_verdict AC1 "tests-line-missing"
spec '**Tests:** `tests/test-greet.sh` plus a new or existing file'
run_file
case "$RC:$OUT" in "1:spec-check: refused tests-line-open: "*) _got=open ;; *) _got="$RC:$OUT" ;; esac
assert_eq "open" "$_got" "AC1 the file form says tests-line-open (fixture)"
same_verdict AC1 "tests-line-open"

spec '**Tests:** `tests/test-greet.sh`'
same_verdict AC2 "ok"
spec
same_verdict AC2 "tests-line-missing"

# AC3: an empty stdin never says ok
OUT="$(printf '' | bash "$CRIT" spec-check - 2>"$ERR")"; RC=$?
assert_eq "2" "$RC" "AC3 an empty stdin to spec-check - exits 2"
assert_eq "" "$OUT" "AC3 an empty stdin prints no verdict on stdout"
assert_contains "$(cat "$ERR")" "Usage:" "AC3 an empty stdin prints the usage text on stderr"
OUT="$(bash "$CRIT" spec-check /dev/stdin < /dev/null 2>"$ERR")"; RC=$?
assert_eq "2" "$RC" "AC3 an empty /dev/stdin exits 2"

# AC4: the file form is unchanged
spec '**Tests:** `tests/test-greet.sh`'
run_file
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC4 a regular file is still checked"
OUT="$(bash "$CRIT" spec-check "$SANDBOX/absent.md" 2>"$ERR")"; RC=$?
assert_eq "2:" "$RC:$OUT" "AC4 a missing file exits 2 with no stdout"
assert_contains "$(cat "$ERR")" "no such file: $SANDBOX/absent.md" "AC4 a missing file says no such file"
OUT="$(bash "$CRIT" spec-check 2>"$ERR" < /dev/null)"; RC=$?
assert_eq "2" "$RC" "AC4 no argument exits 2"
assert_contains "$(cat "$ERR")" "Usage:" "AC4 no argument prints the usage text"

finish
