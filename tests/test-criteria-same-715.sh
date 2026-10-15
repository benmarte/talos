#!/usr/bin/env bash
# test-criteria-same-715.sh -- the `(same: <why>)` criterion kind (#715): a
# criterion for behaviour that must not change, green at the red commit (base
# code) AND at the head. Each assertion label starts with its AC id.
#   AC1  ids prints `same`                  AC5  spec-check counts (same)
#   AC2  report PASS same (both green)      AC6  qa-run end to end + verdict line
#   AC3  report FAIL same                   AC7  placement / spec-usable count (same)
#   AC4  report PASS same, red missing      AC8  the driver's spec-fault check
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

BASE_DIR="$SANDBOX"
BR=feat/issue-7-greet
trap '_is_trap_owner && :; _sandbox_cleanup' EXIT
CRIT="$TALOS_ROOT/scripts/pipeline-criteria.sh"
SHA=abcdef12

# ── AC1 ids ──────────────────────────────────────────────────────────────────
S="$SANDBOX/ids.md"
cat > "$S" <<'TALOS_Zp3nD8tLq5cA'
- [ ] AC1 keeps parsing (same: refactor)
- [ ] AC2 keeps rendering (same)
- [ ] AC3 adds a flag (test)
- [ ] AC4 plain item
- [ ] AC5 the README names it (prose: wording)
TALOS_Zp3nD8tLq5cA
assert_eq "AC1 same
AC2 same
AC3 test
AC4 test
AC5 prose" "$(bash "$CRIT" ids "$S")" "AC1 ids: same for (same: why) and (same), test for (test)/unmarked, prose for (prose: ...)"
cat > "$S" <<'TALOS_Hc6vB1yWj4sF'
- [ ] keeps parsing (same: refactor)
- [x] adds a flag (test)
- [ ] the README names it (prose: wording)
- [ ] unmarked
TALOS_Hc6vB1yWj4sF
assert_eq "AC1 same
AC2 test
AC3 prose
AC4 test" "$(bash "$CRIT" ids "$S")" "AC1 ids: the plain-checklist numbering gives the same kinds"
cat > "$S" <<'TALOS_Qk7wNa2xRf9e'
- [ ] AC1 keeps the (same) and (prose: wording) markers out of the kind (test)
- [ ] AC2 a (same: why) mention inside a test criterion (test)
- [ ] AC3 a (test) mention inside a same criterion (same)
- [ ] AC4 a (same) mention inside a prose criterion (prose: reason)
TALOS_Qk7wNa2xRf9e
assert_eq "AC1 test
AC2 test
AC3 same
AC4 prose" "$(bash "$CRIT" ids "$S")" "AC1 ids: the last marker names the kind, an earlier mention does not"

# ── AC2-AC4 report ───────────────────────────────────────────────────────────
SP="$SANDBOX/report-spec.md"
cat > "$SP" <<'TALOS_Ys9kG5rMe2uP'
- [ ] AC1 keeps parsing (same: refactor)
TALOS_Ys9kG5rMe2uP
out_of() {  # $1=red-output $2=head-output ; sets OUT, RC
  printf '%s' "$1" > "$SANDBOX/red.out"; printf '%s' "$2" > "$SANDBOX/head.out"
  OUT="$(bash "$CRIT" report --spec "$SP" --red "$SANDBOX/red.out" --head "$SANDBOX/head.out" --red-sha "$SHA" 2>&1)"; RC=$?
}
OKL='  ok  AC1 keeps parsing
'
FAILL='FAIL  AC1 keeps parsing
'
out_of "$OKL" "$OKL"
assert_eq "AC1 PASS same red@abcdef12 green@head" "$OUT" "AC2 report: pass at red and at head is PASS same red@<sha8> green@head"
assert_eq "0" "$RC" "AC2 report: exit 0"

out_of "$OKL" "$FAILL"
assert_eq "AC1 FAIL same red=pass head=fail" "$OUT" "AC3 report: fail at head is FAIL same"
assert_eq "1" "$RC" "AC3 report: fail at head exits 1"
out_of "$OKL" ""
assert_eq "AC1 FAIL same red=pass head=missing" "$OUT" "AC3 report: missing at head is FAIL same"
assert_eq "1" "$RC" "AC3 report: missing at head exits 1"
out_of "$FAILL" "$OKL"
assert_eq "AC1 FAIL same red=fail head=pass" "$OUT" "AC3 report: fail at red is FAIL same"
assert_eq "1" "$RC" "AC3 report: fail at red exits 1"

out_of "" "$OKL"
assert_eq "AC1 PASS same green@head (red: missing)" "$OUT" "AC4 report: no red line and pass at head is PASS same green@head (red: missing)"
assert_eq "0" "$RC" "AC4 report: a missing red state alone is no failure"

# ── AC5 spec-check ───────────────────────────────────────────────────────────
SC="$SANDBOX/check.md"
printf -- '- [ ] AC1 keeps parsing (same: refactor)\n- [ ] AC2 the README (prose: wording)\n' > "$SC"
assert_eq "spec-check: refused tests-line-missing: 1 test criteria and no usable Tests: line" "$(bash "$CRIT" spec-check "$SC")" "AC5 spec-check: only (same) criteria and no Tests: line is refused tests-line-missing"
printf -- '- [ ] AC1 keeps parsing (same: refactor)\n\n**Tests:** `tests/test-keep.sh`\n' > "$SC"
assert_eq "spec-check: ok" "$(bash "$CRIT" spec-check "$SC")" "AC5 spec-check: a (same) criterion with a valid Tests: line is ok"

# ── AC6-AC7 on a stub repo (as tests/test-qa-run.sh) ─────────────────────────
write_test() {  # $1=path $2=green|red -- AC1 always green or always red
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$2" = green ]; then printf 'printf "  ok  AC1 greet prints hello\\n"; exit 0\n'
    else printf 'printf "FAIL  AC1 greet prints hello\\n"; exit 1\n'; fi
  } > "$1"
}
new_repo() {  # $1=head state, $2=state at the red commit (default green): green|red
  cd "$BASE_DIR" || exit 1
  rm -rf "${BASE_DIR:?}"/* "${BASE_DIR:?}"/.git "${BASE_DIR:?}"/.talos
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  mkdir scripts tests
  cp "$TALOS_ROOT"/scripts/* scripts/
  cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh
  cat > scripts/pipeline-vcs.sh <<'TALOS_Lw4jN7aXb8dT'
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
TALOS_Lw4jN7aXb8dT
  printf 'base\n' > README.md
  git add -A
  git commit -q -m "base"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b "$BR"
  write_test tests/test-greet.sh "${2:-green}"
  git add tests
  git commit -q -m "test(#7): AC1 greet (red first)"
  RED8="$(git rev-parse HEAD | cut -c1-8)"
  write_test tests/test-greet.sh "$1"
  printf 'done\n' > feature.txt
  git add -A
  git commit -q -m "feat(#7): greet"
  export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
}
spec() {  # $@ = the checklist lines and any Tests: line
  printf '**PM spec:** greeting\n\n**Acceptance criteria**\n' > "$QA_SPEC_FILE"
  printf '%s\n' "$@" >> "$QA_SPEC_FILE"
}
qa_run() { OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?; }

new_repo green
spec '- [ ] AC1 greet keeps printing hello (same: refactor)' '- [ ] AC2 the README names it (prose: wording)' '' '**Tests:** `tests/test-greet.sh`'
qa_run
assert_eq "0" "$RC" "AC6 qa-run: a (same) criterion green at red and at head exits 0"
assert_contains "$OUT" "AC1 PASS same red@$RED8 green@head" "AC6 qa-run: prints the PASS same line"
assert_contains "$OUT" "qa-run: verdict PASS (0 test criteria green, 1 same, 1 prose to hand-check)" "AC6 qa-run: the verdict line names the same count"

new_repo green
spec '- [ ] AC1 greet prints hello (test)' '- [ ] AC2 the README names it (prose: wording)' '' '**Tests:** `tests/test-greet.sh`'
qa_run
assert_contains "$OUT" "AC1 FAIL vacuous (green at red@$RED8)" "AC6 qa-run: a (test) criterion green at red is still FAIL vacuous"

new_repo green red
spec '- [ ] AC1 greet prints hello (test)' '- [ ] AC2 the README names it (prose: wording)' '' '**Tests:** `tests/test-greet.sh`'
qa_run
assert_contains "$OUT" "qa-run: verdict PASS (1 test criteria green, 1 prose to hand-check)" "AC6 qa-run: the verdict line is unchanged when no (same) criterion exists"

new_repo red
spec '- [ ] AC1 greet keeps printing hello (same: refactor)' '' '**Tests:** `tests/test-greet.sh`'
qa_run
assert_eq "1" "$RC" "AC6 qa-run: a (same) criterion red at head exits 1"
assert_contains "$OUT" "qa-run: verdict FAIL" "AC6 qa-run: a (same) criterion red at head is a FAIL verdict"
assert_contains "$OUT" "AC1 FAIL same red=" "AC6 qa-run: the FAIL same line is printed"

# AC7 placement and spec-usable
new_repo green
spec '- [ ] AC1 greet keeps printing hello (same: refactor)' '- [ ] AC2 the flag is kept (same: refactor)' '' '**Tests:** `tests/test-greet.sh`'
OUT="$(bash scripts/pipeline-criteria.sh placement 7 2>&1)"; RC=$?
assert_contains "$OUT" "AC2 not-in-tests-files" "AC7 placement: a (same) id absent from the Tests: files is reported"
assert_not_contains "$OUT" "AC1 not-in-tests-files" "AC7 placement: a (same) id present in a Tests: file is not reported"
assert_eq "1" "$RC" "AC7 placement: a gap exits 1"
spec '- [ ] AC1 greet keeps printing hello (same: refactor)' '- [ ] AC2 greet prints hello (test)' '- [ ] AC3 the README names it (prose: wording)'
OUT="$(bash scripts/pipeline-criteria.sh spec-usable 7 2>&1)"; RC=$?
assert_eq "spec-usable: BLOCKED spec: 2 test criteria and no Tests: line" "$OUT" "AC7 spec-usable: (same) ids are counted with (test) ids"
qa_run
assert_contains "$OUT" "qa-run: verdict BLOCKED spec: 2 test criteria and no Tests: line" "AC7 qa-run: step 4 counts (same) ids in the no-Tests:-line fault"

# ── AC8 the driver's spec-fault check ────────────────────────────────────────
FN="$SANDBOX/fn.sh"
awk '/^_talos_run_qa_spec_fault\(\) \{/ { p = 1 } p { print } p && /^}/ { exit }' "$TALOS_ROOT/scripts/talos.sh" > "$FN"
fault_run() {  # $1=the qa-run FAIL line ; prints "returned" when the function returns
  mkdir -p "$SANDBOX/cache"; printf '%s\n' "$1" > "$SANDBOX/cache/qa-run.12"
  rm -f "$SANDBOX/cache/stopped"
  (
    _CFG_CACHE_DIR="$SANDBOX/cache"
    _talos_block_labels() { :; }; _talos_relay() { :; }; _talos_flush() { :; }; _talos_stop() { :; }
    _talos_cap() { _RC=1; _OUT=""; }
    _talos_emit() { : > "$SANDBOX/cache/stopped"; }
    . "$FN"
    _talos_run_qa_spec_fault 12 9 && echo returned
  )
}
assert_eq "returned" "$(fault_run 'AC1 FAIL same red=pass head=fail')" "AC8 a FAIL same line returns to the ordinary fix-round path"
assert_file_absent "$SANDBOX/cache/stopped" "AC8 a FAIL same line is no spec-unusable stop"
assert_eq "returned" "$(fault_run 'AC1 PASS same red@abcdef12 green@head')" "AC8 a PASS same line is ignored"
fault_run 'AC1 FAIL vacuous (green at red@abcdef12)' > /dev/null
assert_file_exists "$SANDBOX/cache/stopped" "AC8 control: a FAIL vacuous line still stops the run"

finish
