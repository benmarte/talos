#!/usr/bin/env bash
# Acceptance criteria as failing tests before implementation (#421).
#
# Drives the mechanical half (scripts/pipeline-criteria.sh: ids, map, report) on
# a worked example: a fixture spec with one (test) and one (prose) criterion and
# a stub runner. The PM/developer/QA profile wording is not pinned here (prose,
# #556). The criteria_done derivation ships with the handoff (#419): here only
# the id-in-the-test-name convention is asserted.
set -u
. "$(dirname "$0")/helpers.sh"

CRITERIA="$TALOS_ROOT/scripts/pipeline-criteria.sh"
FIX="$TALOS_ROOT/tests/fixtures/criteria-first"

# ── pipeline-criteria.sh on the worked example ──────────────────────────────
assert_file_exists "$CRITERIA" "scripts/pipeline-criteria.sh exists"

ids_out="$(bash "$CRITERIA" ids "$FIX/spec.md")"
assert_eq $'AC1 test\nAC2 prose' "$ids_out" "ids: one (test) and one (prose) criterion"

# No PM stage: ids are the 1-based positions of the issue's checklist; an
# unmarked criterion is (test).
make_sandbox || exit 1
cat > "$SANDBOX/issue.md" <<'TALOS_k3v9x2m7qd41'
## Acceptance criteria
- [ ] first behaviour
- [x] second behaviour (prose: wording only)
- [ ] third behaviour
TALOS_k3v9x2m7qd41
assert_eq $'AC1 test\nAC2 prose\nAC3 test' "$(bash "$CRITERIA" ids "$SANDBOX/issue.md")" \
  "ids: a spec with no AC ids numbers the checklist 1-based, unmarked is test"
bash "$CRITERIA" ids "$SANDBOX/missing.md" >/dev/null 2>&1
assert_exit_code "1" "$?" "ids: a missing spec file exits 1"
bash "$CRITERIA" bogus >/dev/null 2>&1
assert_exit_code "2" "$?" "an unknown subcommand exits 2"

# The worked example: red run recorded, green after implementation.
git config user.email t@t.invalid
git config user.name t
mkdir tests
cp "$FIX/stub-tests.sh" tests/stub-tests.sh
git add tests
git commit -q -m "test(#1): AC1 criterion test (red first)"
RED_SHA="$(git rev-parse HEAD)"
RED_SHA8="${RED_SHA:0:8}"
bash tests/stub-tests.sh > "$SANDBOX/red.out" 2>&1
red_rc=$?
assert_eq "1" "$red_rc" "worked example: the criterion test is red before implementation"
assert_eq "AC1 fail" "$(bash "$CRITERIA" map "$SANDBOX/red.out")" \
  "map: the red run names the failing id (red for the right reason: a labelled assertion)"
assert_eq "AC1 fail" "$(bash "$CRITERIA" map "$SANDBOX/red.out" --spec "$FIX/spec.md")" \
  "map --spec: only (test) ids are listed, prose is not"

printf 'done\n' > feature.txt
git add feature.txt
git commit -q -m "feat(#1): greet"
bash tests/stub-tests.sh > "$SANDBOX/green.out" 2>&1
assert_eq "0" "$?" "worked example: green after implementation"
assert_eq "AC1 pass" "$(bash "$CRITERIA" map "$SANDBOX/green.out")" "map: the green run passes AC1"

# Step 6 re-runs files that step 5 already ran at the same tree. Without
# --no-cache the second run is a test-cache hit: it prints only `CACHED
# tests/<file>`, no per-id lines, and `map` finds nothing (report: head=missing).
mkdir scripts
cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh
cp "$TALOS_ROOT/scripts/pipeline-verify.sh" "$TALOS_ROOT/scripts/pipeline-cfg-cache.sh" scripts/
printf '#!/usr/bin/env bash\nprintf "  ok  AC1 greet prints hello\\n"\n' > tests/test-greet.sh
git add tests scripts
git commit -q -m "chore: runner and a criterion test for the cache example"
step6_cmd=(bash scripts/pipeline-verify.sh --issue 1 --worktree "$PWD" -- bash tests/run-tests.sh --for tests/test-greet.sh)
"${step6_cmd[@]}" > "$SANDBOX/step5.out" 2>&1
assert_eq "AC1 pass" "$(bash "$CRITERIA" map "$SANDBOX/step5.out")" "cache example: step 5's first run prints the id"
"${step6_cmd[@]}" > "$SANDBOX/cached.out" 2>&1
assert_contains "$(cat "$SANDBOX/cached.out")" "CACHED tests/test-greet.sh" "cache example: a second run at the same tree is a cache hit"
assert_eq "" "$(bash "$CRITERIA" map "$SANDBOX/cached.out")" "cache example: a cached run gives map nothing (the bug)"
"${step6_cmd[@]}" --no-cache > "$SANDBOX/nocache.out" 2>&1
assert_eq "AC1 pass" "$(bash "$CRITERIA" map "$SANDBOX/nocache.out")" "cache example: step 6's --no-cache run gives map the id again"
"${step6_cmd[@]}" --no-cache > "$SANDBOX/nocache2.out" 2>&1
assert_eq "AC1 pass" "$(bash "$CRITERIA" map "$SANDBOX/nocache2.out")" "cache example: --no-cache is repeatable (never a cache hit)"

# criteria_done is derived from names: the passing ids map to 1-based positions.
done_positions="$(bash "$CRITERIA" map "$SANDBOX/green.out" | awk '$2=="pass"{sub(/^AC/,"",$1); print $1}')"
assert_eq "1" "$done_positions" "ids derivable by name: AC1 is spec position 1 (criteria_done)"

report="$(bash "$CRITERIA" report --spec "$FIX/spec.md" --red "$SANDBOX/red.out" --head "$SANDBOX/green.out" --red-sha "$RED_SHA8")"
report_rc=$?
assert_eq "0" "$report_rc" "report: red then green exits 0"
assert_contains "$report" "AC1 red@$RED_SHA8 green@head" "report: AC1 is red at the red commit and green at head"
assert_contains "$report" "AC2 prose hand-checked" "report: the prose criterion is marked hand-checked"

# Red-at-base failure cases.
printf '  ok  AC1 greet prints hello when feature.txt says done\n' > "$SANDBOX/vacuous.out"
vac="$(bash "$CRITERIA" report --spec "$FIX/spec.md" --red "$SANDBOX/vacuous.out" --head "$SANDBOX/green.out" --red-sha "$RED_SHA8")"
vac_rc=$?
assert_eq "1" "$vac_rc" "report: a test green at the red commit fails the report"
assert_contains "$vac" "AC1 FAIL vacuous" "report: green at the red commit is FAIL (vacuous)"

: > "$SANDBOX/crash.out"
crash="$(bash "$CRITERIA" report --spec "$FIX/spec.md" --red "$SANDBOX/crash.out" --head "$SANDBOX/green.out" --red-sha "$RED_SHA8")"
crash_rc=$?
assert_eq "0" "$crash_rc" "report: missing at red (a crash, no per-id output) is reported, not failed"
assert_contains "$crash" "AC1 green@head (red: missing)" "report: red with no per-id output is a note"

headfail="$(bash "$CRITERIA" report --spec "$FIX/spec.md" --red "$SANDBOX/red.out" --head "$SANDBOX/red.out" --red-sha "$RED_SHA8")"
headfail_rc=$?
assert_eq "1" "$headfail_rc" "report: a test that is not green at head fails the report"
assert_contains "$headfail" "AC1 FAIL head=fail" "report: names the head result"

# report: --red-sha is printed, so it must be hex of 7-40 chars.
bad_sha="$(bash "$CRITERIA" report --spec "$FIX/spec.md" --red "$SANDBOX/red.out" --head "$SANDBOX/green.out" --red-sha 'ab12$(id)' 2>&1)"
assert_eq "2" "$?" "report: a non-hex --red-sha is rejected"
assert_not_contains "$bad_sha" 'red@' "report: a non-hex --red-sha prints no verdict line"
short_sha="$(bash "$CRITERIA" report --spec "$FIX/spec.md" --red "$SANDBOX/red.out" --head "$SANDBOX/green.out" --red-sha abc12 2>&1)"
assert_eq "2" "$?" "report: a --red-sha shorter than 7 chars is rejected"
long_sha="$(bash "$CRITERIA" report --spec "$FIX/spec.md" --red "$SANDBOX/red.out" --head "$SANDBOX/green.out" --red-sha 0123456789012345678901234567890123456789a 2>&1)"
assert_eq "2" "$?" "report: a --red-sha longer than 40 chars is rejected"
full_sha="$(bash "$CRITERIA" report --spec "$FIX/spec.md" --red "$SANDBOX/red.out" --head "$SANDBOX/green.out" --red-sha 0123456789012345678901234567890123456789 2>&1)"
assert_eq "0" "$?" "report: a 40-char hex --red-sha is accepted"

# An id with both an ok and a FAIL line: fail wins.
printf '  ok  AC1 first assertion\nFAIL  AC1 second assertion\n' > "$SANDBOX/mixed.out"
mixed="$(bash "$CRITERIA" map "$SANDBOX/mixed.out")"
assert_contains "$mixed" "AC1 fail" "map: an id with an ok and a FAIL line is fail"


finish
