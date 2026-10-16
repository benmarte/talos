#!/usr/bin/env bash
# `verify.targeted_commands` (#716): a repo says how to run ONE test file of its
# own stack (dotnet, vitest, ...) and how to read that run's pass/fail lines, so
# `pipeline-criteria.sh qa-run` proves red/green outside a Talos-shaped layout.
#
# Behavioural, and needs neither dotnet nor npm: the "dotnet" here is a fake
# script that prints `Passed` / `Failed` lines once feature.txt exists / not.
# Each qa-run case builds a throwaway repo (a main branch, a tests-only red
# commit, a green commit), a stub pipeline-vcs.sh and the real scripts.
#
# AC6 note: the Tests: line parser already refuses an unsafe path, so that
# criterion is green on main too; the case pins the refusal and that nothing ran.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

BASE_DIR="$SANDBOX"
BR=feat/issue-7-greet
CRIT="$TALOS_ROOT/scripts/pipeline-criteria.sh"
CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
DEFAULTS_SH="$TALOS_ROOT/scripts/pipeline-defaults.sh"
trap '_is_trap_owner && _sandbox_cleanup' EXIT

# ── AC1: the config key ──────────────────────────────────────────────────────
PROJ="$SANDBOX/project"
GHOME="$SANDBOX/talos-home"
mkdir -p "$PROJ" "$GHOME" || exit 1
cd "$PROJ" || exit 1
export TALOS_HOME="$GHOME"
assert_eq "verify.targeted_commands	list		-	-	repo" \
  "$(grep -E '^verify\.targeted_commands	' "$DEFAULTS_SH")" \
  "AC1 verify.targeted_commands is a defaults-table row: list, scope repo"
assert_eq "true" "$(bash "$CFG_SH" verify.targeted 2>/dev/null)" "AC1 verify.targeted still defaults to true"
printf '%s' '{"verify":{"targeted_commands":[{"match":"a/*.cs","run":"PLANTED-run-9"}]}}' > "$GHOME/talos.pipeline.json"
_val="$(bash "$CFG_SH" verify.targeted_commands SENT 2>"$SANDBOX/err")"
assert_eq "SENT" "$_val" "AC1 a value in the user-level file does not apply"
assert_contains "$(cat "$SANDBOX/err")" "verify.targeted_commands" "AC1 the repo-only warning names the key"
assert_not_contains "$(cat "$SANDBOX/err")" "PLANTED-run-9" "AC1 the warning never prints the value"
rm -f "${GHOME:?}/talos.pipeline.json"

# ── AC2: map with a pass and a fail pattern ──────────────────────────────────
SPEC="$SANDBOX/spec.md"
{
  printf '**PM spec:** x\n\n**Acceptance criteria**\n'
  printf -- '- [ ] AC1 greets (test)\n- [ ] AC2 rejects (test)\n- [ ] AC3 wording (prose: doc)\n'
} > "$SPEC"
DOT="$SANDBOX/dotnet.out"
printf '%s\n' '  Passed Greet.Tests.AC1_Greets [2 ms]' '  Failed Greet.Tests.AC2_Rejects [1 ms]' \
  '  Passed Greet.Tests.AC10_Other [1 ms]' '  Failed Greet.Tests.AC11_Other [1 ms]' > "$DOT"
PASS_RE='^[[:space:]]*Passed .*\.AC{n}_'
FAIL_RE='^[[:space:]]*Failed .*\.AC{n}_'
assert_eq "AC1 pass
AC2 fail" "$(bash "$CRIT" map "$DOT" --spec "$SPEC" --pass-re "$PASS_RE" --fail-re "$FAIL_RE" 2>&1)" \
  "AC2 map reads dotnet-style Passed / Failed lines"
printf '%s\n' '  Passed Greet.Tests.AC10_Other [1 ms]' '  Failed Greet.Tests.AC11_Other [1 ms]' > "$DOT"
assert_eq "AC1 missing
AC2 missing" "$(bash "$CRIT" map "$DOT" --spec "$SPEC" --pass-re '^[[:space:]]*Passed .*AC{n}' --fail-re '^[[:space:]]*Failed .*AC{n}' 2>&1)" \
  "AC2 {n} does not let AC1 match AC10 and AC2 match AC11 (patterns that end at the number)"
printf '%s\n' '  Passed Greet.Tests.AC1_A [1 ms]' '  Failed Greet.Tests.AC1_B [1 ms]' > "$DOT"
assert_eq "AC1 fail
AC2 missing" "$(bash "$CRIT" map "$DOT" --spec "$SPEC" --pass-re "$PASS_RE" --fail-re "$FAIL_RE" 2>&1)" \
  "AC2 a criterion with both a pass and a fail line is fail"
printf '%s\n' 'ok  AC1 greets' 'FAIL  AC2 rejects' '  Passed Greet.Tests.AC3_X [1 ms]' > "$DOT"
assert_eq "AC1 pass
AC2 fail" "$(bash "$CRIT" map "$DOT" --spec "$SPEC" 2>&1)" "AC2 without the options map keeps today's ok / FAIL lines"
assert_eq "AC1 pass
AC2 fail" "$(bash "$CRIT" map "$DOT" 2>&1)" "AC2 without options and without a spec lists what it saw, as today"
printf '%s\n' 'ok  AC1 greets' '  Failed Greet.Tests.AC2_Rejects [1 ms]' > "$DOT"
assert_eq "AC1 pass
AC2 fail" "$(bash "$CRIT" map "$DOT" --spec "$SPEC" --fail-re "$FAIL_RE" 2>&1)" \
  "AC2 a missing option falls back to today's line for that side"

# ── qa-run fixtures ──────────────────────────────────────────────────────────
# new_repo [TEST_PATH] -- a sandbox repo with the real scripts, a stub
# pipeline-vcs.sh, a fake dotnet at tools/fake-dotnet.sh (prints Passed once
# feature.txt exists, else Failed; logs "file|class|dir" per run), a red commit
# holding only TEST_PATH and a green commit adding feature.txt. Leaves HEAD on $BR.
new_repo() {
  local tp="${1:-svc/tests/GreetTests.cs}"
  cd "$BASE_DIR" || exit 1
  rm -rf "${BASE_DIR:?}"/* "${BASE_DIR:?}"/.git "${BASE_DIR:?}"/.talos "${BASE_DIR:?}"/talos.pipeline.json
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  mkdir scripts tools
  cp "$TALOS_ROOT"/scripts/* scripts/
  cat > scripts/pipeline-vcs.sh <<'TALOS_q7m2x9k4dv81'
#!/usr/bin/env bash
case "$1" in
  view-issue)
    python3 -I -c 'import json, sys
print(json.dumps({"title": "t", "body": "issue body", "labels": [],
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$QA_SPEC_FILE" ;;
  pr-mergeable) echo MERGEABLE ;;
  checkout-pr) : ;;
  pr-head) git rev-parse feat/issue-7-greet ;;
  pr-head-ref) echo feat/issue-7-greet ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_q7m2x9k4dv81
  QA_LOG="$BASE_DIR/.git/qa-fake.log"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s|%%s|%%s\\n" "$1" "$2" "$3" >> "%s"\n' "$QA_LOG"
    printf 'echo "Starting test execution"\n'
    printf 'if [ -f feature.txt ]; then echo "  Passed Greet.Tests.AC1_Greets [2 ms]"; exit 0; fi\n'
    printf 'echo "  Failed Greet.Tests.AC1_Greets [2 ms]"; exit 1\n'
  } > tools/fake-dotnet.sh
  {
    printf '#!/usr/bin/env bash\n'
    printf ': > "%s"\n' "$BASE_DIR/.git/qa-second.marker"
  } > tools/second.sh
  case "$tp" in *.sh) mkdir tests; cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh ;; esac
  printf 'base\n' > README.md
  git add -A
  git commit -q -m "base"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b "$BR"
  mkdir -p "$(dirname "$tp")"
  case "$tp" in
    *.sh)
      printf '#!/usr/bin/env bash\nif [ -f feature.txt ]; then printf "  ok  AC1 greet prints hello\\n"; exit 0; fi\n' > "$tp"
      printf 'printf "FAIL  AC1 greet prints hello\\n" >&2\nexit 1\n' >> "$tp" ;;
    *) printf '// the test\n' > "$tp" ;;
  esac
  git add -A
  git commit -q -m "test(#7): AC1 greet (red first)"
  RED8="$(git rev-parse HEAD | cut -c1-8)"
  printf 'done\n' > feature.txt
  git add feature.txt
  git commit -q -m "feat(#7): greet"
  export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
  rm -f "$QA_LOG" "$BASE_DIR/.git/qa-second.marker"
}

spec() {  # spec TESTS_LINE -- AC1 (test) and AC2 (prose)
  {
    printf '**PM spec:** greeting\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n'
    printf -- '- [ ] AC2 the README names it (prose: doc wording)\n\n'
    printf '%s\n' "$1"
  } > "$QA_SPEC_FILE"
}

cfg_file() { printf '%s' "$1" > "$BASE_DIR/talos.pipeline.json"; }
qa_run() { OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?; }
log_lines() { if [ -f "$QA_LOG" ]; then wc -l < "$QA_LOG" | tr -d ' '; else echo 0; fi; }

ENTRY='{"match":"svc/**/*.cs","run":"bash tools/fake-dotnet.sh {file} {class} {dir}","pass":"^[[:space:]]*Passed .*\\.AC{n}_","fail":"^[[:space:]]*Failed .*\\.AC{n}_"}'

# ── AC3: the matching entry runs the Tests-line file, red and head ───────────
new_repo
spec '**Tests:** `svc/tests/GreetTests.cs`'
cfg_file "{\"verify\":{\"targeted_commands\":[$ENTRY]}}"
qa_run
assert_eq "0" "$RC" "AC3 a .cs Tests file runs through its entry: exit 0"
assert_contains "$OUT" "AC1 red@$RED8 green@head" "AC3 the criterion reads red@<sha> green@head from the entry's patterns"
assert_contains "$OUT" "qa-run: verdict PASS" "AC3 a PASS verdict"
assert_eq "svc/tests/GreetTests.cs|GreetTests|svc/tests" "$(sort -u "$QA_LOG" 2>/dev/null)" "AC3 {file}, {class} and {dir} are substituted"
assert_eq "2" "$(log_lines)" "AC3 the entry ran twice: the head run and the red run"

# the frozen run (the red commit's test file, changed since) uses the entry too
new_repo
spec '**Tests:** `svc/tests/GreetTests.cs`'
cfg_file "{\"verify\":{\"targeted_commands\":[$ENTRY]}}"
printf '// the test, reworded\n' > svc/tests/GreetTests.cs
git add -A
git commit -q -m "test(#7): reword"
qa_run
assert_eq "0" "$RC" "AC3 frozen: exit 0"
assert_contains "$OUT" "AC1 red@$RED8 green@head frozen@head" "AC3 frozen: the frozen run is read with the same patterns"
assert_eq "3" "$(log_lines)" "AC3 frozen: the entry ran for the head, red and frozen runs"

# ── AC4: first match wins ────────────────────────────────────────────────────
new_repo
spec '**Tests:** `svc/tests/GreetTests.cs`'
cfg_file "{\"verify\":{\"targeted_commands\":[$ENTRY,{\"match\":\"**/*.cs\",\"run\":\"bash tools/second.sh {file}\"}]}}"
qa_run
assert_eq "0" "$RC" "AC4 two matching entries: exit 0"
assert_eq "2" "$(log_lines)" "AC4 the first entry ran"
assert_file_absent "$BASE_DIR/.git/qa-second.marker" "AC4 the second entry did not run"

# ── AC5: no match, or no key: today's runner ─────────────────────────────────
new_repo tests/test-greet.sh
spec '**Tests:** `tests/test-greet.sh`'
cfg_file "{\"verify\":{\"targeted_commands\":[$ENTRY]}}"
qa_run
assert_eq "0" "$RC" "AC5 a Tests file that matches no entry: exit 0"
assert_contains "$OUT" "runner talos" "AC5 ... and it uses today's runner"
assert_contains "$OUT" "AC1 red@$RED8 green@head" "AC5 ... with today's criteria lines"
assert_eq "0" "$(log_lines)" "AC5 ... and no entry ran"
rm -f "$BASE_DIR/talos.pipeline.json"
qa_run
assert_eq "0" "$RC" "AC5 a config without the key: exit 0"
assert_contains "$OUT" "runner talos" "AC5 a config without the key uses today's runner"

# ── AC6: an unsafe path is never substituted ─────────────────────────────────
new_repo
cfg_file "{\"verify\":{\"targeted_commands\":[$ENTRY]}}"
spec '**Tests:** `svc/tests/My Test.cs`'
qa_run
assert_eq "4" "$RC" "AC6 a path with a space: exit 4"
assert_contains "$OUT" "qa-run: verdict BLOCKED spec" "AC6 ... BLOCKED spec"
assert_eq "0" "$(log_lines)" "AC6 ... and the command did not run"
spec '**Tests:** `svc/tests/a;touch pwned;.cs`'
qa_run
assert_eq "4" "$RC" "AC6 a path with shell syntax: exit 4"
assert_contains "$OUT" "qa-run: verdict BLOCKED spec" "AC6 ... BLOCKED spec for shell syntax too"
assert_file_absent "$BASE_DIR/pwned" "AC6 ... and nothing from the path ran"
assert_eq "0" "$(log_lines)" "AC6 ... and the entry did not run"

# ── AC7: a malformed entry is skipped with a note ────────────────────────────
new_repo
spec '**Tests:** `svc/tests/GreetTests.cs`'
cfg_file "{\"verify\":{\"targeted_commands\":[\"just a string\",{\"match\":\"svc/**/*.cs\"},{\"run\":\"bash tools/second.sh\"},{\"match\":\"svc/**/*.cs\",\"run\":\"bash tools/second.sh {file}\",\"pass\":\"([unclosed\"},$ENTRY]}}"
qa_run
assert_eq "0" "$RC" "AC7 malformed entries never abort qa-run: exit 0"
assert_contains "$OUT" "AC1 red@$RED8 green@head" "AC7 the valid entry after them still runs"
for _i in 0 1 2 3; do
  assert_contains "$OUT" "entry $_i" "AC7 a note names the skipped entry $_i"
done
assert_not_contains "$OUT" "entry 4" "AC7 the valid entry gets no note"
assert_not_contains "$OUT" "command not found" "AC7 no shell error"
assert_not_contains "$OUT" "syntax error" "AC7 no shell syntax error"
assert_file_absent "$BASE_DIR/.git/qa-second.marker" "AC7 no malformed entry ran"

finish
