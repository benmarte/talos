#!/usr/bin/env bash
# test-qa-spec-fault-678.sh -- the spec-fault stop reads the results file that
# qa-run leaves for the driver (TALOS_QA_RESULTS), not QA's prose (#678).
#   AC1  vacuous line mid-sentence in QA's message -> spec-unusable
#   AC2  no AC text in QA's message                 -> spec-unusable
#   AC3  a head=fail result still gets the fix rounds
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
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
# The QA stub leaves results.qa.<n> in the file qa-run is told to write.
cat > "$GS/pipeline-agent.sh" <<'TALOS_stubagent678Qm4Hx'
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
TALOS_stubagent678Qm4Hx
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatus678Wv2Dn'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
printf 'status-file collect\n' >> "$d/journal"
printf '%s' "$(cat "$d/collect.json" 2>/dev/null || echo '{}')"
TALOS_stubstatus678Wv2Dn

RUN="$GS/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
LEASE="$SANDBOX/.git/talos-lease.ledger"
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
set_stub() { printf '%s\n' "$2" > "$STUB_DIR/$1.rc"; printf '%s' "${3:-}" > "$STUB_DIR/$1.out"; printf '%s' "${4:-}" > "$STUB_DIR/$1.err"; }
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$LEASE" "${LEASE:?}.lock.d"
  printf '%s' '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": true}, "comments": {"enabled": false}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
    > "$SANDBOX/talos.pipeline.json"
  set_stub events.cost.line 0 "spend: 12 tokens"
}

# Issue 9's PM spec (AC1, AC2 test; AC3 prose) as view-issue 9's answer.
spec() {
  {
    printf '**PM spec:** greeting\n\n**Acceptance criteria:**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n'
    printf -- '- [ ] AC2 `greet` prints bye (test)\n'
    printf -- '- [ ] AC3 the README names it (prose: doc wording)\n\n'
    printf '%s\n' '**Tests:** `tests/test-a.sh`'
  } > "$SANDBOX/spec.md"
  python3 -I -c 'import json, sys
print(json.dumps({"number": 9, "title": "t", "body": "- [ ] an item", "labels": [{"name": "pipeline:ready"}], "state": "open",
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$SANDBOX/spec.md" > "$STUB_DIR/view-issue.9"
}

rn() { OUT="$(TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 bash "$RUN" run --max-iterations 5 2>"$ERR")"; RC=$?; }
# run_fixture MESSAGE RESULTS: QA's final message, and the lines qa-run left.
run_fixture() {
  reset_stubs
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"ready"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.json"
  printf ready > "$STUB_DIR/pr-is-draft.12"; printf 1 > "$STUB_DIR/pr-is-draft.12.rc"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  spec
  printf 'https://github.com/acme/widget/pull/12\nfixed\n' > "$STUB_DIR/message.developer.1"
  printf 'https://github.com/acme/widget/pull/12\nfixed again\n' > "$STUB_DIR/message.developer.2"
  printf '%s\n' "$1" > "$STUB_DIR/message.qa.1"
  printf '%s\n' "$1" > "$STUB_DIR/message.qa.2"
  printf '%s\n' "$2" > "$STUB_DIR/results.qa.1"
  printf '%s\n' "$2" > "$STUB_DIR/results.qa.2"
  printf 'printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"\n' > "$STUB_DIR/hook.developer.1"
  printf 'printf cccccccccccccccccccccccccccccccccccccccc > "$d/pr-head.12"\n' > "$STUB_DIR/hook.developer.2"
}
devs() { journal | grep -c '^agent developer$'; }
VAC='AC4 FAIL vacuous (green at red@416530e9)'

run_fixture 'FAIL: AC4 is vacuous. `qa-run` reports "AC4 FAIL vacuous (green at red@416530e9)", so the spec is at fault.' "$VAC"
rn
assert_eq "stop reason=spec-unusable issue=9 pr=12" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC1 vacuous line mid-sentence in QA's message: spec-unusable"
assert_eq "0" "$(devs)" "AC1 vacuous line mid-sentence: no developer dispatch"

run_fixture 'FAIL: the criteria are green on main, nothing to prove.' "$VAC"
rn
assert_eq "stop reason=spec-unusable issue=9 pr=12" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC2 no AC text in QA's message: spec-unusable"
assert_eq "0" "$(devs)" "AC2 no AC text in QA's message: no developer dispatch"

run_fixture 'FAIL: AC1 FAIL vacuous (green at red@416530e9)' 'AC1 FAIL head=fail red=pass'
rn
assert_not_contains "$OUT" "spec-unusable" "AC3 a head=fail result is no spec fault, whatever the message claims"
assert_eq "2" "$(devs)" "AC3 a head=fail result: both fix rounds run"

finish
