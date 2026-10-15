#!/usr/bin/env bash
# test-frozen-run-714.sh -- the frozen run of `qa-run` (#714): the red commit's
# version of each changed Tests: file, run against the head code, so a fix round
# cannot weaken a test after the red proof. Each assertion label starts with its
# AC id.
#   AC1  report --frozen: red, green, frozen green     AC6  qa-run: changed file, frozen green
#   AC2  report --frozen: frozen red is weakened       AC7  qa-run: unchanged file, no frozen run
#   AC3  report --frozen on a (same) criterion         AC8  qa-run --ack-changed
#   AC4  report without --frozen is as before          AC9  qa-run leaves the tree as the head
#   AC5  qa-run: a weakened test is a FAIL verdict     AC10 qa-run with no red commit, no frozen run
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

BASE_DIR="$SANDBOX"
BR=feat/issue-7-greet
trap '_is_trap_owner && :; _sandbox_cleanup' EXIT
CRIT="$TALOS_ROOT/scripts/pipeline-criteria.sh"
SHA=abcdef12

# ── AC1-AC4 report ───────────────────────────────────────────────────────────
SP="$SANDBOX/report-spec.md"
cat > "$SP" <<'TALOS_Jt4mQz8vNc2R'
- [ ] AC1 greet prints hello (test)
- [ ] AC2 greet keeps its flag (same: refactor)
- [ ] AC3 the README names it (prose: wording)
TALOS_Jt4mQz8vNc2R
OKL='  ok  AC1 greet prints hello
  ok  AC2 greet keeps its flag
'
FAILL='FAIL  AC1 greet prints hello
FAIL  AC2 greet keeps its flag
'
MIXED='FAIL  AC1 greet prints hello
  ok  AC2 greet keeps its flag
'
rep() {  # $1=red $2=head $3=frozen (omitted: no --frozen) ; sets OUT, RC
  printf '%s' "$1" > "$SANDBOX/red.out"; printf '%s' "$2" > "$SANDBOX/head.out"
  if [ $# -ge 3 ]; then
    printf '%s' "$3" > "$SANDBOX/frozen.out"
    OUT="$(bash "$CRIT" report --spec "$SP" --red "$SANDBOX/red.out" --head "$SANDBOX/head.out" --red-sha "$SHA" --frozen "$SANDBOX/frozen.out" 2>&1)"; RC=$?
  else
    OUT="$(bash "$CRIT" report --spec "$SP" --red "$SANDBOX/red.out" --head "$SANDBOX/head.out" --red-sha "$SHA" 2>&1)"; RC=$?
  fi
}

rep "$MIXED" "$OKL" "$OKL"
assert_contains "$OUT" "AC1 red@abcdef12 green@head frozen@head" "AC1 report --frozen: red at red, green at head and in frozen prints the frozen@head column"
assert_not_contains "$OUT" "weakened" "AC1 report --frozen: a green frozen run is not weakened"
assert_eq "0" "$RC" "AC1 report --frozen: exit 0"

rep "$FAILL" "$OKL" "$FAILL"
assert_contains "$OUT" "AC1 FAIL weakened (red-commit test fails at head)" "AC2 report --frozen: green at head and red in frozen is FAIL weakened"
assert_eq "1" "$RC" "AC2 report --frozen: weakened exits 1"
rep "$FAILL" "$FAILL" "$FAILL"
assert_contains "$OUT" "AC1 FAIL head=fail red=fail" "AC2 report --frozen: an existing FAIL (head=fail) wins over weakened"
rep "$OKL" "$OKL" "$FAILL"
assert_contains "$OUT" "AC1 FAIL vacuous (green at red@abcdef12)" "AC2 report --frozen: an existing FAIL (vacuous) wins over weakened"
rep "$MIXED" "$OKL" "FAIL  AC1 greet prints hello
"
assert_contains "$OUT" "AC1 FAIL weakened (red-commit test fails at head)" "AC2 report --frozen: the failing id alone is weakened"
assert_contains "$OUT" "AC2 PASS same red@abcdef12 green@head
" "AC2 report --frozen: an id absent from the frozen output gets no frozen column"

rep "$MIXED" "$OKL" "$OKL"
assert_contains "$OUT" "AC2 PASS same red@abcdef12 green@head frozen@head" "AC3 report --frozen: a (same) criterion with frozen green prints PASS same ... frozen@head"
rep "$MIXED" "$OKL" "$FAILL"
assert_contains "$OUT" "AC2 FAIL weakened (red-commit test fails at head)" "AC3 report --frozen: a (same) criterion with frozen red prints the FAIL weakened line"
assert_eq "1" "$RC" "AC3 report --frozen: a (same) criterion with frozen red exits 1"

rep "$MIXED" "$OKL"
assert_eq "AC1 red@abcdef12 green@head
AC2 PASS same red@abcdef12 green@head
AC3 prose hand-checked" "$OUT" "AC4 report without --frozen: test, same and prose lines are as before"
assert_eq "0" "$RC" "AC4 report without --frozen: exit 0"
rep "$OKL" "$FAILL"
assert_eq "AC1 FAIL head=fail red=pass
AC2 FAIL same red=pass head=fail
AC3 prose hand-checked" "$OUT" "AC4 report without --frozen: the FAIL lines are as before"
rep "" "$OKL"
assert_eq "AC1 green@head (red: missing)
AC2 PASS same green@head (red: missing)
AC3 prose hand-checked" "$OUT" "AC4 report without --frozen: the red-missing lines are as before"
rep "$OKL" "$OKL"
assert_eq "AC1 FAIL vacuous (green at red@abcdef12)
AC2 PASS same red@abcdef12 green@head
AC3 prose hand-checked" "$OUT" "AC4 report without --frozen: the vacuous line is as before"

# ── AC5-AC10 on a stub repo (as tests/test-criteria-same-715.sh) ─────────────
write_test() {  # $1=path $2=check|tight|weak
  {
    printf '#!/usr/bin/env bash\n'
    case "$2" in
      weak) printf 'printf "  ok  AC1 greet prints hello\\n"; exit 0\n' ;;
      *) printf 'if grep -q hello feature.txt 2>/dev/null; then printf "  ok  AC1 greet prints hello\\n"; exit 0; fi\n'
         printf 'printf "FAIL  AC1 greet prints hello\\n"; exit 1\n' ;;
    esac
    [ "$2" != tight ] || printf '# asserts the greeting too\n'
  } > "$1"
}
new_repo() {  # $1=test at the red commit, $2=test at the head, $3=feature.txt, $4=nontest: the red commit also touches README.md
  cd "$BASE_DIR" || exit 1
  rm -rf "${BASE_DIR:?}"/* "${BASE_DIR:?}"/.git "${BASE_DIR:?}"/.talos
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  mkdir scripts tests
  cp "$TALOS_ROOT"/scripts/* scripts/
  cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh
  cat > scripts/pipeline-vcs.sh <<'TALOS_Bv7sKe3yLm9Q'
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
TALOS_Bv7sKe3yLm9Q
  printf 'base\n' > README.md
  git add -A
  git commit -q -m "base"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b "$BR"
  write_test tests/test-greet.sh "$1"
  [ "${4:-}" != nontest ] || printf 'more\n' >> README.md
  git add -A
  git commit -q -m "test(#7): AC1 greet (red first)"
  RED8="$(git rev-parse HEAD | cut -c1-8)"
  write_test tests/test-greet.sh "$2"
  printf '%s\n' "$3" > feature.txt
  git add -A
  git commit -q -m "feat(#7): greet"
  export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
}
spec() {  # $@ = the checklist lines and any Tests: line
  printf '**PM spec:** greeting\n\n**Acceptance criteria**\n' > "$QA_SPEC_FILE"
  printf '%s\n' "$@" >> "$QA_SPEC_FILE"
}
qa_run() { OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 "$@" 2>&1)"; RC=$?; }
TL='**Tests:** `tests/test-greet.sh`'

# AC5: the fix round weakened the test (head passes, the red version fails at head)
new_repo check weak done
spec '- [ ] AC1 greet prints hello (test)' '' "$TL"
qa_run
assert_contains "$OUT" "AC1 FAIL weakened (red-commit test fails at head)" "AC5 qa-run: a test weakened after the red commit prints the weakened line"
assert_contains "$OUT" "note: frozen run: tests/test-greet.sh differs from red commit $RED8" "AC5 qa-run: the note names the changed file and the red commit"
assert_contains "$OUT" "qa-run: verdict FAIL" "AC5 qa-run: the verdict is FAIL"
assert_eq "1" "$RC" "AC5 qa-run: exit 1"
assert_contains "$OUT" "frozen run failures" "AC5 qa-run: the frozen run's own failure lines are printed"

# AC6: changed after the red commit, the red version still passes at the head
new_repo check tight hello
spec '- [ ] AC1 greet prints hello (test)' '- [ ] AC2 the README names it (prose: wording)' '' "$TL"
qa_run
assert_contains "$OUT" "AC1 red@$RED8 green@head frozen@head" "AC6 qa-run: a changed file whose red version passes at head prints frozen@head"
assert_contains "$OUT" "note: frozen run: tests/test-greet.sh differs from red commit $RED8" "AC6 qa-run: the note names the changed file"
assert_contains "$OUT" "qa-run: verdict PASS (1 test criteria green, 1 prose to hand-check)" "AC6 qa-run: the verdict is PASS"
assert_eq "0" "$RC" "AC6 qa-run: exit 0"
# AC9 on the same repo
assert_eq "" "$(git status --porcelain --untracked-files=no)" "AC9 qa-run: the tracked tree is clean after a frozen run"
assert_eq "$(git show HEAD:tests/test-greet.sh)" "$(cat tests/test-greet.sh)" "AC9 qa-run: the Tests file equals the head's after a frozen run"
assert_eq "$BR" "$(git symbolic-ref -q --short HEAD)" "AC9 qa-run: the checkout is back on the branch"

# AC7: no Tests file changed since the red commit
new_repo check check hello
spec '- [ ] AC1 greet prints hello (test)' '' "$TL"
qa_run
assert_contains "$OUT" "AC1 red@$RED8 green@head" "AC7 qa-run: an unchanged file keeps the red@<sha8> green@head line"
assert_not_contains "$OUT" "frozen@head" "AC7 qa-run: an unchanged file adds no frozen@head column"
assert_not_contains "$OUT" "frozen run" "AC7 qa-run: an unchanged file adds no frozen run note"
assert_contains "$OUT" "qa-run: verdict PASS (1 test criteria green, 0 prose to hand-check)" "AC7 qa-run: the verdict is as today"
assert_eq "0" "$RC" "AC7 qa-run: exit 0"

# AC8: --ack-changed
new_repo check weak done
spec '- [ ] AC1 greet prints hello (test)' '' "$TL"
qa_run --ack-changed "fixed a wrong assertion"
assert_contains "$OUT" "AC1 weakened-ack (red-commit test fails at head; changed on purpose: fixed a wrong assertion)" "AC8 qa-run --ack-changed: the weakened criterion prints the weakened-ack line"
assert_contains "$OUT" "frozen run failures" "AC8 qa-run --ack-changed: the frozen failure is still printed"
assert_contains "$OUT" "qa-run: verdict PASS" "AC8 qa-run --ack-changed: the verdict is PASS"
assert_eq "0" "$(grep -cE '^AC[0-9]+ FAIL ' <<<"$OUT")" "AC8 qa-run --ack-changed: no criterion line is FAIL"
assert_eq "0" "$RC" "AC8 qa-run --ack-changed: exit 0"
assert_eq "" "$(git status --porcelain --untracked-files=no)" "AC9 qa-run --ack-changed: the tracked tree is clean"
qa_run --ack-changed ""
assert_eq "2" "$RC" "AC8 qa-run --ack-changed with an empty reason exits 2"
assert_contains "$OUT" "Usage:" "AC8 qa-run --ack-changed with an empty reason prints usage"
qa_run --ack-changed "$(printf 'a\tb')"
assert_eq "2" "$RC" "AC8 qa-run --ack-changed with a tab exits 2"
qa_run --ack-changed "$(printf 'caf\303\251')"
assert_eq "2" "$RC" "AC8 qa-run --ack-changed with a non-ASCII character exits 2"
qa_run --ack-changed "$(printf 'a%.0s' $(seq 1 201))"
assert_eq "2" "$RC" "AC8 qa-run --ack-changed over 200 characters exits 2"
qa_run --ack-changed
assert_eq "2" "$RC" "AC8 qa-run --ack-changed with no value exits 2"

# AC10: the red commit is not tests-only, so the red proof is skipped and nothing is frozen
new_repo check weak done nontest
spec '- [ ] AC1 greet prints hello (test)' '' "$TL"
qa_run
assert_contains "$OUT" "red proof skipped" "AC10 qa-run: a skipped red proof is still noted"
assert_not_contains "$OUT" "frozen" "AC10 qa-run: no frozen run, no frozen column, no frozen note"
assert_contains "$OUT" "AC1 green@head (red: missing)" "AC10 qa-run: the report line is as today"
assert_contains "$OUT" "qa-run: verdict PASS" "AC10 qa-run: the verdict is as today"
assert_eq "0" "$RC" "AC10 qa-run: exit 0"

finish
