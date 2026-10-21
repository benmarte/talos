#!/usr/bin/env bash
# test-spec-usable-suite-813.sh -- spec-usable refuses a (test)/(same) criterion
# about the test suite or the diff (#813). Each assertion label starts with its AC id.
#   AC1  suite wording in a (same) criterion is refused     AC5  the four suite/diff wordings
#   AC2  the same text marked (prose: ...) is ok            AC6  qa-run ends BLOCKED spec, runs no test
#   AC3  behavioural wording still passes                   AC7  the existing faults keep text and precedence
#   AC4  a criterion about the diff is refused              AC8  agents/pm.md carries the rule and example
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

BASE_DIR="$SANDBOX"
trap '_is_trap_owner && :; _sandbox_cleanup' EXIT
TESTS='**Tests:** `tests/test-greet.sh`'
BLOCK='describes the test suite or the diff, not behaviour: mark it (prose: ...)'

new_repo() {
  cd "$BASE_DIR" || exit 1
  rm -rf "${BASE_DIR:?}"/* "${BASE_DIR:?}"/.git "${BASE_DIR:?}"/.talos
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  mkdir scripts tests
  cp "$TALOS_ROOT"/scripts/* scripts/
  cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh
  cat > scripts/pipeline-vcs.sh <<'TALOS_Bn6hGc3sXd9L'
#!/usr/bin/env bash
case "$1" in
  view-issue)
    python3 -I -c 'import json, sys
print(json.dumps({"title": "t", "body": "issue body", "labels": [],
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$QA_SPEC_FILE" ;;
  pr-mergeable) echo MERGEABLE ;;
  checkout-pr) : ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_Bn6hGc3sXd9L
  git add -A
  git commit -q -m "base"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b feat/issue-7-greet
  export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
}
spec() {  # $@ = the checklist lines and any Tests: line
  printf '**PM spec:** greeting\n\n**Acceptance criteria**\n' > "$QA_SPEC_FILE"
  printf '%s\n' "$@" >> "$QA_SPEC_FILE"
}
usable() { OUT="$(bash scripts/pipeline-criteria.sh spec-usable 7 2>&1)"; RC=$?; }

new_repo

# ── AC1 / AC2 ────────────────────────────────────────────────────────────────
spec '- [ ] AC1 greet prints hello (test)' \
  '- [ ] AC4 The e2e tests keep the same test names and count, no test is skipped or removed (same: pins existing behaviour)' '' "$TESTS"
usable
assert_eq "4" "$RC" "AC1 a (same) criterion about test names and count exits 4"
assert_contains "$OUT" "AC4 $BLOCK" "AC1 the line names AC4 and says to mark it (prose: ...)"
assert_not_contains "$OUT" "AC1 $BLOCK" "AC1 a behavioural neighbour is not named"
assert_contains "$OUT" "spec-usable: BLOCKED spec: 1 criteria describe the test suite or the diff, not behaviour" "AC1 the BLOCKED spec line follows"

spec '- [ ] AC1 greet prints hello (test)' \
  '- [ ] AC4 The e2e tests keep the same test names and count, no test is skipped or removed (prose: process rule, no harness)' '' "$TESTS"
usable
assert_eq "spec-usable: ok" "$OUT" "AC2 the same text marked (prose: ...) is ok"
assert_eq "0" "$RC" "AC2 a prose criterion exits 0"

# ── AC3 ──────────────────────────────────────────────────────────────────────
spec '- [ ] AC1 with no farm the form opens empty, as today (same: pins existing behaviour)' \
  '- [ ] AC2 a failing test is reported with exit 1 (test)' \
  '- [ ] AC3 qa-run runs no test and prints the number of tests it ran (test)' '' "$TESTS"
usable
assert_eq "spec-usable: ok" "$OUT" "AC3 behavioural (same) and (test) criteria still pass"
assert_eq "0" "$RC" "AC3 behavioural criteria exit 0"

# ── AC4 ──────────────────────────────────────────────────────────────────────
spec '- [ ] AC1 greet prints hello (test)' \
  '- [ ] AC2 git diff --name-only lists only scripts/talos.sh (test)' '' "$TESTS"
usable
assert_eq "4" "$RC" "AC4 a (test) criterion about the diff exits 4"
assert_contains "$OUT" "AC2 $BLOCK" "AC4 the line names AC2"
spec '- [ ] AC1 `git diff --name-only` lists only scripts/talos.sh (test)' '' "$TESTS"
usable
assert_eq "4" "$RC" "AC4 the diff command in a code span is still read"

# ── AC5 ──────────────────────────────────────────────────────────────────────
for w in 'no assertion is weakened' 'no test is deleted' 'the number of tests is unchanged' 'lint and type-check are clean'; do
  for k in test same; do
    spec "- [ ] AC1 $w ($k)" '' "$TESTS"
    usable
    assert_eq "4" "$RC" "AC5 '$w' on a ($k) criterion exits 4"
    assert_contains "$OUT" "AC1 $BLOCK" "AC5 '$w' on a ($k) criterion names AC1"
  done
done

# ── AC6 ──────────────────────────────────────────────────────────────────────
spec '- [ ] AC1 no test is deleted (test)' '' "$TESTS"
OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?
assert_eq "4" "$RC" "AC6 qa-run on a suite criterion exits 4"
assert_contains "$OUT" "qa-run: verdict BLOCKED spec: 1 criteria describe the test suite or the diff, not behaviour" "AC6 qa-run ends BLOCKED spec with the new reason"
assert_not_contains "$OUT" "PASS" "AC6 qa-run ran no test"

# ── AC7 the existing faults keep their text and precedence ───────────────────
spec '- [ ] AC1 no test is deleted (test)'
usable
assert_eq "spec-usable: BLOCKED spec: 1 test criteria and no Tests: line" "$OUT" "AC7 a missing Tests: line is reported before the suite fault"
spec 'no checklist here'
usable
assert_eq "spec-usable: BLOCKED spec: no criteria checklist" "$OUT" "AC7 no criteria checklist keeps its text"

# ── AC8 the PM prompt ────────────────────────────────────────────────────────
PM="$(cat "$TALOS_ROOT/agents/pm.md")"
assert_contains "$PM" "the e2e tests keep the same test names and count" "AC8 agents/pm.md carries the example"
assert_contains "$PM" 'never `(test)` or `(same)`' "AC8 agents/pm.md says such a criterion is never (test) or (same)"

finish
