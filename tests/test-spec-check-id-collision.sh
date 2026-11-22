#!/usr/bin/env bash
# test-spec-check-id-collision.sh -- `pipeline-criteria.sh spec-check` refuses a
# `(test)`/`(same)` criterion id that an existing `Tests:` file already labels
# (#975): the pure-text half of red-check's id-collision rule, before any
# developer round runs.
#   AC1  an existing Tests file that labels AC2 refuses a (test) AC2
#   AC2  a Tests file that does not exist yet passes, whatever its ids
#   AC3  ids not labelled in the existing file pass
#   AC4  a (prose: ...) criterion whose id is labelled is no collision
#   AC5  `spec-check -` (stdin) applies the same check
#   AC6  red-check's collision tests still pass
# No GitHub write, no LLM call, no network.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
trap '_is_trap_owner && _sandbox_cleanup' EXIT

CRIT="$TALOS_ROOT/scripts/pipeline-criteria.sh"
FIX="$SANDBOX/checkout"
mkdir -p "$FIX/tests" || exit 1
SPEC="$SANDBOX/spec.md"

# The existing Tests file: it labels AC2 (a quoted label) and AC10 (an ok line).
cat > "$FIX/tests/test-old.sh" <<'TALOS_OLDFILE_x7Qm2'
assert_eq "a" "a" "AC2 an earlier issue's criterion"
echo "  ok  AC10 another one"
TALOS_OLDFILE_x7Qm2

# spec TESTS_FILE: AC1 (test), AC2 (test), AC3 (prose) and the Tests: line
spec() {
  {
    printf '**PM spec:** x\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 greet prints hello (test)\n'
    printf -- '- [ ] AC2 greet is polite (test)\n'
    printf -- '- [ ] AC3 the README names it (prose: doc wording)\n\n'
    printf '**Tests:** `%s`\n' "$1"
  } > "$SPEC"
}
# run_spec: OUT and RC of spec-check from inside the fixture checkout
run_spec() { OUT="$(cd "$FIX" && bash "$CRIT" spec-check "$SPEC" 2>/dev/null)"; RC=$?; }

spec tests/test-old.sh
run_spec
assert_eq "1" "$RC" "AC1 an id already labelled in an existing Tests file exits 1"
assert_eq "spec-check: refused id-collision: AC2 is already labelled in tests/test-old.sh (an earlier issue's id): name a new test file on the Tests: line" "$OUT" "AC1 the refusal names AC2 and the file"

spec tests/test-new.sh
run_spec
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC2 a Tests file that does not exist yet passes"

# AC3: the existing file labels AC2 and AC10; AC1 is neither
{
  printf '**PM spec:** x\n\n**Acceptance criteria**\n'
  printf -- '- [ ] AC1 greet prints hello (test)\n\n'
  printf '**Tests:** `tests/test-old.sh`\n'
} > "$SPEC"
run_spec
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC3 ids not labelled in the existing file pass (AC1 is not AC10)"

# AC4: a prose criterion whose id is labelled is no collision
{
  printf '**PM spec:** x\n\n**Acceptance criteria**\n'
  printf -- '- [ ] AC1 greet prints hello (test)\n'
  printf -- '- [ ] AC2 the README names it (prose: doc wording)\n\n'
  printf '**Tests:** `tests/test-old.sh`\n'
} > "$SPEC"
run_spec
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC4 a prose criterion with a labelled id is not a collision"

# AC5: the same check from stdin
spec tests/test-old.sh
OUT="$(cd "$FIX" && bash "$CRIT" spec-check - < "$SPEC" 2>/dev/null)"; RC=$?
assert_eq "1" "$RC" "AC5 spec-check - refuses the collision with exit 1"
assert_contains "$OUT" "spec-check: refused id-collision: AC2 is already labelled in tests/test-old.sh" "AC5 spec-check - prints the id-collision line"

# AC6: red-check's own collision tests are unchanged and pass
bash "$TALOS_ROOT/tests/test-red-check-747.sh" >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "AC6 test-red-check-747.sh passes"
bash "$TALOS_ROOT/tests/test-red-check-drop-773.sh" >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "AC6 test-red-check-drop-773.sh passes"

finish
