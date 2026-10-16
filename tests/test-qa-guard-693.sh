#!/usr/bin/env bash
# test-qa-guard-693.sh -- a vacuous (test) criterion beside criteria that went
# red then green is a regression guard, not a spec stop (#693).
#   AC1  report: red-then-green + vacuous           -> guard line, no FAIL, exit 0
#   AC2  report: every criterion vacuous            -> FAIL vacuous each, exit 1
#   AC3  report: green at red, failing at head      -> FAIL head=fail red=pass, exit 1
#   AC4  report: vacuous + red-then-green + a FAIL  -> FAIL vacuous kept, exit 1
#   AC5  qa-run on a real git sandbox: verdict PASS, guard line in the output and
#        the TALOS_QA_RESULTS file; the driver's spec-fault step does not stop
#   AC6  qa-run, only vacuous criteria: verdict FAIL and the run stops spec-unusable
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

BASE_DIR="$SANDBOX"
trap '_is_trap_owner && _sandbox_cleanup' EXIT
CRIT="$TALOS_ROOT/scripts/pipeline-criteria.sh"
SHA=416530e9
SHA8="$SHA"

# ── report (AC1-AC4): fabricated runner outputs, pure text ───────────────────
W="$SANDBOX/report"
mkdir -p "$W"
{
  printf '**PM spec:** x\n\n**Acceptance criteria**\n'
  printf -- '- [ ] AC1 first (test)\n'
  printf -- '- [ ] AC2 second (test)\n'
  printf -- '- [ ] AC3 third (same: unchanged)\n'
} > "$W/spec.md"
ok_lines() {  # the runner's `ok` lines for the given ids
  local i; for i in "$@"; do printf '  ok  %s label\n' "$i"; done
}
fail_lines() {  # the runner's `FAIL` lines for the given ids
  local i; for i in "$@"; do printf 'FAIL  %s label\n' "$i"; done
}
report() {  # report RED HEAD: sets OUT and RC; RED/HEAD are output files
  OUT="$(bash "$CRIT" report --spec "$W/spec.md" --red "$1" --head "$2" --red-sha "$SHA" 2>&1)"; RC=$?
}

{ fail_lines AC1; ok_lines AC2 AC3; } > "$W/red1"
ok_lines AC1 AC2 AC3 > "$W/head1"
report "$W/red1" "$W/head1"
assert_contains "$OUT" "AC1 red@$SHA8 green@head" "AC1 the red-then-green criterion is reported as before"
assert_contains "$OUT" "AC2 guard green@head (green at red@$SHA8)" "AC1 the vacuous criterion beside it is a guard"
assert_not_contains "$OUT" "FAIL" "AC1 no FAIL line"
assert_eq "0" "$RC" "AC1 exit 0"

ok_lines AC1 AC2 AC3 > "$W/red2"
ok_lines AC1 AC2 AC3 > "$W/head2"
report "$W/red2" "$W/head2"
assert_contains "$OUT" "AC1 FAIL vacuous (green at red@$SHA8)" "AC2 AC1 is vacuous with nothing red-then-green"
assert_contains "$OUT" "AC2 FAIL vacuous (green at red@$SHA8)" "AC2 AC2 is vacuous with nothing red-then-green"
assert_not_contains "$OUT" "guard" "AC2 no guard line"
assert_eq "1" "$RC" "AC2 exit 1"

{ fail_lines AC1; ok_lines AC2 AC3; } > "$W/red3"
{ ok_lines AC1 AC3; fail_lines AC2; } > "$W/head3"
report "$W/red3" "$W/head3"
assert_contains "$OUT" "AC2 FAIL head=fail red=pass" "AC3 a criterion failing at head is a head=fail FAIL, never a guard"
assert_not_contains "$OUT" "guard" "AC3 no guard line beside a head failure"
assert_eq "1" "$RC" "AC3 exit 1"

{ fail_lines AC1 AC3; ok_lines AC2; } > "$W/red4"
{ ok_lines AC1 AC2; fail_lines AC3; } > "$W/head4"
report "$W/red4" "$W/head4"
assert_contains "$OUT" "AC2 FAIL vacuous (green at red@$SHA8)" "AC4 the vacuous criterion keeps its FAIL beside another FAIL line"
assert_contains "$OUT" "AC3 FAIL same" "AC4 the other FAIL line is reported"
assert_not_contains "$OUT" "guard" "AC4 no guard line without a clean remainder"
assert_eq "1" "$RC" "AC4 exit 1"

# ── qa-run (AC5, AC6): a real git sandbox ────────────────────────────────────
BR=feat/issue-7-greet
# write_test PATH ID KIND: KIND impl = red until feature.txt exists; green = always green
write_test() {
  local body
  case "$3" in
    impl) body="if [ -f feature.txt ]; then printf '  ok  $2 greet\\n'; exit 0; fi" ;;
    *)    body="printf '  ok  $2 greet\\n'; exit 0" ;;
  esac
  printf '#!/usr/bin/env bash\n%s\nprintf "FAIL  %s greet\\n" >&2\nexit 1\n' "$body" "$2" > "$1"
}
# new_repo KIND1 KIND2: tests AC1 (tests/test-a.sh) and AC2 (tests/test-b.sh)
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
  cat > scripts/pipeline-vcs.sh <<'TALOS_stubvcs693Lk4Rp'
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
TALOS_stubvcs693Lk4Rp
  printf 'base\n' > README.md
  git add -A; git commit -q -m base
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b "$BR"
  write_test tests/test-a.sh AC1 "$1"
  write_test tests/test-b.sh AC2 "$2"
  git add tests; git commit -q -m "test(#7): red first"
  RED8="$(git rev-parse HEAD | cut -c1-8)"
  printf 'done\n' > feature.txt
  git add feature.txt; git commit -q -m "feat(#7): greet"
  export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
  {
    printf '**PM spec:** greeting\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n'
    printf -- '- [ ] AC2 `greet` still works (test)\n\n'
    printf '**Tests:** `tests/test-a.sh` `tests/test-b.sh`\n'
  } > "$QA_SPEC_FILE"
  export TALOS_QA_RESULTS="$BASE_DIR/.git/qa-results"
  rm -f "$TALOS_QA_RESULTS"
}
qa_run() { OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?; }

new_repo impl green
qa_run
assert_contains "$OUT" "AC1 red@$RED8 green@head" "AC5 the red-then-green criterion is reported"
assert_contains "$OUT" "AC2 guard green@head (green at red@$RED8)" "AC5 the vacuous criterion is a guard line in the output"
assert_contains "$OUT" "qa-run: verdict PASS" "AC5 qa-run ends verdict PASS"
assert_eq "0" "$RC" "AC5 qa-run exit 0"
GUARD_RESULTS="$(cat "$TALOS_QA_RESULTS" 2>/dev/null)"
assert_contains "$GUARD_RESULTS" "AC2 guard green@head (green at red@$RED8)" "AC5 the guard line is in the TALOS_QA_RESULTS file"

new_repo green green
qa_run
assert_contains "$OUT" "qa-run: verdict FAIL" "AC6 only vacuous criteria: verdict FAIL"
assert_contains "$OUT" "AC1 FAIL vacuous (green at red@$RED8)" "AC6 only vacuous criteria: AC1 FAIL vacuous"
assert_contains "$OUT" "AC2 FAIL vacuous (green at red@$RED8)" "AC6 only vacuous criteria: AC2 FAIL vacuous"
VAC_RESULTS="$(cat "$TALOS_QA_RESULTS" 2>/dev/null)"

# ── the driver's spec-fault step over those results (AC5, AC6) ───────────────
# Same stubs as test-qa-spec-fault-678.sh: no GitHub write, no LLM call.
cd "$SANDBOX" || exit 1
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
unset TALOS_QA_RESULTS
ERR="$SANDBOX/stderr"
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR" "$SANDBOX/templates"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cp -R "$TALOS_ROOT/templates/prompts" "$SANDBOX/templates/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="$1"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
if [ -f "$d/hook.$key" ]; then . "$d/hook.$key"; fi
if [ "$key" = "list-prs" ] || [ "$key" = "list-needs-owner" ] || [ "$key" = "list-issues" ]; then printf "[]"; exit 0; fi
if [ "$n" = "hooks" ]; then cat > "$d/hooks.stdin"; fi
if [ "$n" = "notify" ] && [ "${3:-}" = "-" ]; then cat > "$d/notify.stdin"; fi
a1="${2:-}"
if [ -f "$d/$key.$a1.out" ]; then cat "$d/$key.$a1.out"
elif [ -f "$d/$key.$a1" ]; then cat "$d/$key.$a1"
elif [ -f "$d/$key.out" ]; then cat "$d/$key.out"
elif [ -f "$d/$key" ]; then cat "$d/$key"; fi
rc=0
if [ -f "$d/$key.$a1.rc" ]; then rc="$(cat "$d/$key.$a1.rc")"; elif [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-events.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
cat > "$GS/pipeline-agent.sh" <<'TALOS_stubagent693Hd7Ws'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
role="$1"
cat > "$d/agent.stdin"
printf "agent %s\n" "$role" >> "$d/journal"
cnt="$(grep -c "^agent $role\$" "$d/journal")"
if [ -f "$d/message.$role.$cnt" ]; then cat "$d/message.$role.$cnt"; fi
if [ "$role" = qa ] && [ -f "$d/results.qa.$cnt" ] && [ -n "$TALOS_QA_RESULTS" ]; then
  cat "$d/results.qa.$cnt" > "$TALOS_QA_RESULTS"
fi
if [ -f "$d/hook.$role.$cnt" ]; then . "$d/hook.$role.$cnt"; fi
exit 0
TALOS_stubagent693Hd7Ws
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatus693Jn3Yb'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
printf 'status-file collect\n' >> "$d/journal"
printf '%s' "$(cat "$d/collect.json" 2>/dev/null || echo '{}')"
TALOS_stubstatus693Jn3Yb
RUN="$GS/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
LEASE="$SANDBOX/.git/talos-lease.ledger"
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
run_fixture() {  # run_fixture RESULTS MESSAGE: the lines qa-run left, QA's final message
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$LEASE" "${LEASE:?}.lock.d"
  printf '%s' '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": true}, "comments": {"enabled": false}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
    > "$SANDBOX/talos.pipeline.json"
  printf '0\n' > "$STUB_DIR/events.cost.line.rc"; printf 'spend: 12 tokens' > "$STUB_DIR/events.cost.line.out"
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"ready"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.json"
  printf ready > "$STUB_DIR/pr-is-draft.12"; printf 1 > "$STUB_DIR/pr-is-draft.12.rc"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  {
    printf '**PM spec:** greeting\n\n**Acceptance criteria:**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n'
    printf -- '- [ ] AC2 `greet` still works (test)\n\n'
    printf '%s\n' '**Tests:** `tests/test-a.sh`'
  } > "$SANDBOX/spec.md"
  python3 -I -c 'import json, sys
print(json.dumps({"number": 9, "title": "t", "body": "- [ ] an item", "labels": [{"name": "pipeline:ready"}], "state": "open",
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$SANDBOX/spec.md" > "$STUB_DIR/view-issue.9"
  printf 'https://github.com/acme/widget/pull/12\nfixed\n' > "$STUB_DIR/message.developer.1"
  printf 'https://github.com/acme/widget/pull/12\nfixed again\n' > "$STUB_DIR/message.developer.2"
  printf '%s\n' "$2" > "$STUB_DIR/message.qa.1"
  printf '%s\n' "$2" > "$STUB_DIR/message.qa.2"
  printf '%s\n' "$1" > "$STUB_DIR/results.qa.1"
  printf '%s\n' "$1" > "$STUB_DIR/results.qa.2"
  printf 'printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"\n' > "$STUB_DIR/hook.developer.1"
  printf 'printf cccccccccccccccccccccccccccccccccccccccc > "$d/pr-head.12"\n' > "$STUB_DIR/hook.developer.2"
  OUT="$(TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 bash "$RUN" run --max-iterations 5 2>"$ERR")"; RC=$?
}

# A FAIL message forces the spec-fault step to read the results file; a guard line is no FAIL line.
run_fixture "$GUARD_RESULTS" 'FAIL: some other fault, the results file holds only a guard line.'
assert_not_contains "$OUT" "spec-unusable" "AC5 the spec-fault step does not stop on a guard line"

run_fixture "$VAC_RESULTS" 'FAIL: every criterion is vacuous, nothing to prove.'
assert_eq "stop reason=spec-unusable issue=9 pr=12" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC6 only vacuous criteria: the run stops spec-unusable"

finish
