#!/usr/bin/env bash
# test-spec-fault-648.sh -- a spec fault that QA can only report as `vacuous` or
# `head=missing` is caught before QA or ends the run as spec-unusable (#648).
#   AC1-AC3  `pipeline-criteria.sh placement <issue>`: every (test) criterion's
#            id is in a file named on the spec's `Tests:` line
#   AC4      `spec-check` / `done pm`: a spec that leaves a test file open is
#            refused as tests-line-open
#   AC5-AC6  `talos.sh run`: a QA FAIL that only a spec change can repair stops
#            as spec-unusable instead of starting a developer fix round
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
ERR="$SANDBOX/stderr"

# ── fixture: a copied scripts dir with stubbed providers (as test-talos-run.sh)
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
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ] && [ -f "$a" ]; then cat "$a" > "$d/body"; fi
  prev="$a"
done
if [ "$n" = "hooks" ]; then cat > "$d/hooks.stdin"; fi
if [ "$n" = "notify" ] && [ "${3:-}" = "-" ]; then cat > "$d/notify.stdin"; fi
a1="${2:-}"
if [ -f "$d/$key.$a1.err" ]; then cat "$d/$key.$a1.err" >&2; elif [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
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
cat > "$GS/pipeline-agent.sh" <<'TALOS_stubagent648Xq7Lm'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
role="$1"
cat > "$d/agent.stdin"
printf "agent %s\n" "$role" >> "$d/journal"
cnt="$(grep -c "^agent $role\$" "$d/journal")"
if [ -f "$d/message.$role.$cnt" ]; then cat "$d/message.$role.$cnt"; fi
if [ "$role" = qa ] && [ -f "$d/message.$role.$cnt" ] && [ -n "$TALOS_QA_RESULTS" ]; then
  grep -E '^AC[0-9]+ FAIL ' "$d/message.$role.$cnt" > "$TALOS_QA_RESULTS"
fi
if [ -f "$d/hook.$role.$cnt" ]; then . "$d/hook.$role.$cnt"; fi
exit 0
TALOS_stubagent648Xq7Lm
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatus648Zk4Pw'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
printf 'status-file collect\n' >> "$d/journal"
printf '%s' "$(cat "$d/collect.json" 2>/dev/null || echo '{}')"
TALOS_stubstatus648Zk4Pw

RUN="$GS/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
LEASE="$SANDBOX/.git/talos-lease.ledger"
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
body() { cat "$STUB_DIR/body" 2>/dev/null; }
set_stub() { printf '%s\n' "$2" > "$STUB_DIR/$1.rc"; printf '%s' "${3:-}" > "$STUB_DIR/$1.out"; printf '%s' "${4:-}" > "$STUB_DIR/$1.err"; }
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$LEASE" "${LEASE:?}.lock.d"
  printf '%s' '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": true}, "comments": {"enabled": false}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
    > "$SANDBOX/talos.pipeline.json"
  set_stub events.cost.line 0 "spend: 12 tokens"
}

# spec LINE...: issue 9's PM spec (AC1, AC2 test; AC3 prose), each argument one
# line after the criteria; posted as view-issue 9's answer.
spec() {
  {
    printf '**PM spec:** greeting\n\n**Acceptance criteria:**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n'
    printf -- '- [ ] AC2 `greet` prints bye (test)\n'
    printf -- '- [ ] AC3 the README names it (prose: doc wording)\n\n'
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
  } > "$SANDBOX/spec.md"
  python3 -I -c 'import json, sys
print(json.dumps({"number": 9, "title": "t", "body": "- [ ] an item", "labels": [{"name": "pipeline:ready"}], "state": "open",
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$SANDBOX/spec.md" > "$STUB_DIR/view-issue.9"
}
# A test file under $SANDBOX whose assertion labels are the arguments.
mk_test() {
  local f="$SANDBOX/$1" l; shift
  mkdir -p "$(dirname "$f")"; : > "$f"
  for l in "$@"; do printf 'assert_eq 1 1 "%s"\n' "$l" >> "$f"; done
}
pl() { OUT="$(cd "$SANDBOX" && bash "$GS/pipeline-criteria.sh" placement 9 2>"$ERR")"; RC=$?; }

# ── AC1: placement lists the (test) ids that no Tests: file carries ──────────
reset_stubs
mk_test tests/test-a.sh "AC1 greet prints hello"
spec '**Tests:** `tests/test-a.sh`'
pl
assert_eq "1:AC2 not-in-tests-files
placement: GAP 1" "$RC:$OUT" "AC1 placement: a missing id is one line plus GAP <n>, exit 1"
mk_test tests/test-a.sh "AC1 greet prints hello" "AC2 greet prints bye"
pl
assert_eq "0:placement: ok" "$RC:$OUT" "AC1 placement: every (test) id present is ok, exit 0"

# ── AC2: placement reads the spec as qa-run does ─────────────────────────────
reset_stubs
printf '%s' '{"number": 9, "title": "t", "body": "a body with no checklist", "labels": [], "state": "open", "comments": []}' > "$STUB_DIR/view-issue.9"
pl
assert_eq "4:placement: BLOCKED spec: no criteria checklist" "$RC:$OUT" "AC2 placement: an unusable spec is BLOCKED spec: <why>, exit 4"
printf '**PM spec:** x\n- [ ] AC1 wording (prose: docs)\n' > "$SANDBOX/prose.md"
python3 -I -c 'import json, sys
print(json.dumps({"number": 9, "title": "t", "body": "b", "labels": [], "comments": [{"body": open(sys.argv[1]).read()}]}))' "$SANDBOX/prose.md" > "$STUB_DIR/view-issue.9"
pl
assert_eq "0:placement: ok" "$RC:$OUT" "AC2 placement: a spec with no (test) criterion is ok"

# ── AC3: an id counts only in a file named on the Tests: line ────────────────
reset_stubs
mk_test tests/test-a.sh "AC1 greet prints hello"
mk_test tests/test-other.sh "AC2 greet prints bye"
spec '**Tests:** `tests/test-a.sh`'
pl
assert_eq "1:AC2 not-in-tests-files
placement: GAP 1" "$RC:$OUT" "AC3 placement: the same id in a file off the Tests: line does not count"

# ── AC4: spec-check and done pm refuse an open test file ─────────────────────
OPEN="Note: plus a new or existing file of the developer's choosing for AC2."
sc() { OUT="$(bash "$GS/pipeline-criteria.sh" spec-check "$SANDBOX/spec.md" 2>"$ERR")"; RC=$?; }
reset_stubs
spec '**Tests:** `tests/test-a.sh`' "$OPEN"
sc
case "$RC:$OUT" in
  "1:spec-check: refused tests-line-open: "*) _got=refused ;;
  *) _got="$RC:$OUT" ;;
esac
assert_eq "refused" "$_got" "AC4 spec-check: a line leaving the test file open is tests-line-open, exit 1"
for phrase in "of the developer's choice" "a New Or Existing File"; do
  spec '**Tests:** `tests/test-a.sh`' "AC2 goes in $phrase."
  sc
  assert_eq "1" "$RC" "AC4 spec-check: '$phrase' is refused, any case"
done
spec '**Tests:** `tests/test-a.sh`'
sc
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC4 spec-check: a closed Tests: line is still ok"

dn() { OUT="$(bash "$RUN" done pm --issue 9 --summary-file "$SANDBOX/summary.txt" 2>"$ERR" < /dev/null)"; RC=$?; }
printf 'greet\n' > "$SANDBOX/summary.txt"
reset_stubs
spec '**Tests:** `tests/test-a.sh`' "$OPEN"
dn
assert_contains "$OUT" "spec_check=tests-line-open" "AC4 done pm: spec_check=tests-line-open"
assert_eq "next=fix-round stage=pm" "$(printf '%s\n' "$OUT" | tail -n 1)" "AC4 done pm: next=fix-round stage=pm"
assert_contains "$(journal)" "vcs record-attempt 9 pm" "AC4 done pm: the attempt is recorded"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:confirmed --remove pipeline:dev" "AC4 done pm: the label goes back to pipeline:confirmed"
assert_contains "$(body | head -n 1)" "**Spec check:**" "AC4 done pm: the Spec check comment is posted"
reset_stubs
spec '**Tests:** `tests/test-a.sh`' "$OPEN"
set_stub record-attempt 1 "" "pipeline-vcs: record-attempt: max_fix_attempts (3) reached for pm"
dn
assert_eq "next=stop" "$(printf '%s\n' "$OUT" | tail -n 1)" "AC4 done pm: at the attempt ceiling it ends next=stop"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "AC4 done pm: at the ceiling the issue is blocked"

# ── AC5 / AC6: talos.sh run after a QA FAIL ──────────────────────────────────
rn() { OUT="$(TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 bash "$RUN" run --max-iterations 5 2>"$ERR")"; RC=$?; }
run_fixture() {  # the PR is at stage ready; QA's first report is $1, its second $2
  reset_stubs
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"ready"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.json"
  printf ready > "$STUB_DIR/pr-is-draft.12"; printf 1 > "$STUB_DIR/pr-is-draft.12.rc"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  spec '**Tests:** `tests/test-a.sh`'
  printf 'https://github.com/acme/widget/pull/12\nfixed\n' > "$STUB_DIR/message.developer.1"
  printf 'https://github.com/acme/widget/pull/12\nfixed again\n' > "$STUB_DIR/message.developer.2"
  printf 'FAIL: criteria\n%s\n' "$1" > "$STUB_DIR/message.qa.1"
  printf 'FAIL: criteria\n%s\n' "$2" > "$STUB_DIR/message.qa.2"
  printf 'printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"\n' > "$STUB_DIR/hook.developer.1"
  printf 'printf cccccccccccccccccccccccccccccccccccccccc > "$d/pr-head.12"\n' > "$STUB_DIR/hook.developer.2"
}
devs() { journal | grep -c '^agent developer$'; }
VAC='AC1 FAIL vacuous (green at red@95e76310)
AC2 FAIL vacuous (green at red@95e76310)'
MISS='AC1 FAIL head=missing red=missing'

run_fixture "$VAC" "$VAC"
rn
assert_eq "0" "$RC" "AC5 vacuous-only FAIL: the run exits 0"
assert_eq "stop reason=spec-unusable issue=9 pr=12" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC5 vacuous-only FAIL: one stop line, spec-unusable"
assert_contains "$(journal)" "vcs label-pr 12 --add pipeline:blocked" "AC5 vacuous-only FAIL: pipeline:blocked on the PR"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "AC5 vacuous-only FAIL: pipeline:blocked on the issue"
assert_contains "$(cat "$ERR")" "AC1 FAIL vacuous (green at red@95e76310)" "AC5 vacuous-only FAIL: the QA FAIL lines are relayed"
assert_eq "0" "$(journal | grep -c 'record-attempt 9 qa')" "AC5 vacuous-only FAIL: no gate fix-round"
assert_eq "0" "$(devs)" "AC5 vacuous-only FAIL: no developer dispatch"

run_fixture "$MISS" "$MISS"
rn
assert_eq "1" "$(devs)" "AC6 head=missing FAIL: exactly one fix round runs"
assert_eq "stop reason=spec-unusable issue=9 pr=12" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC6 head=missing twice at an unchanged spec: spec-unusable"
assert_contains "$(cat "$ERR")" "$MISS" "AC6 head=missing twice: the QA FAIL lines are relayed"

run_fixture "$MISS
AC2 FAIL vacuous (green at red@95e76310)" "$MISS
AC2 FAIL vacuous (green at red@95e76310)"
rn
assert_eq "1" "$(devs)" "AC6 mixed vacuous/head=missing: one fix round, then the stop"
assert_contains "$OUT" "stop reason=spec-unusable issue=9 pr=12" "AC6 mixed vacuous/head=missing twice: spec-unusable"

run_fixture "$MISS" "$MISS"
cat >> "$STUB_DIR/hook.developer.1" <<'TALOS_hookedit648Rt5Vc'
sed 's/prints hello (test)/prints hello (prose: x)/' "$d/view-issue.9" > "$d/v9" && mv "$d/v9" "$d/view-issue.9"
TALOS_hookedit648Rt5Vc
rn
assert_not_contains "$OUT" "spec-unusable" "AC6 an edited spec between the two FAILs takes the fix-round path"
assert_eq "2" "$(devs)" "AC6 an edited spec: a second fix round runs"

run_fixture 'AC1 FAIL head=fail red=pass' 'AC1 FAIL head=fail red=pass'
rn
assert_not_contains "$OUT" "spec-unusable" "AC6 a head=fail FAIL is no spec fault"
assert_eq "2" "$(devs)" "AC6 a head=fail FAIL twice: both fix rounds run"

finish
