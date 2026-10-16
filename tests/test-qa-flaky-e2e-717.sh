#!/usr/bin/env bash
# QA flaky-test detection and the optional e2e step (#717).
#   AC1  report --rerun: fail at head + pass on re-run is `FAIL flaky`
#   AC2  qa-run re-runs the present Tests files once when the head run fails
#   AC3  a flaky verdict names the count; the line is in TALOS_QA_RESULTS
#   AC4  the driver stops qa-flaky (owner), no fix round, unless other FAILs
#   AC6  verify.e2e is a repo-only str key
#   AC7  verify.e2e unset: no e2e line (same: the default path must not change)
#   AC8  verify.e2e set: runs once on a green draft, failure is a QA FAIL
# AC5 and AC9 are prose. Each qa-run case builds a throwaway repo with the real
# scripts and a stub pipeline-vcs.sh; AC4 drives the run on stubs like #678.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

BASE_DIR="$SANDBOX/repo"
BR=feat/issue-7-greet
CRIT="$TALOS_ROOT/scripts/pipeline-criteria.sh"
CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
DEFAULTS_SH="$TALOS_ROOT/scripts/pipeline-defaults.sh"
trap '_is_trap_owner && _sandbox_cleanup' EXIT
export TALOS_RETRY_SLEEP_SCALE=0
mkdir -p "$BASE_DIR" || exit 1

# ── AC1: report --rerun ──────────────────────────────────────────────────────
SPEC="$SANDBOX/spec.md"
{
  printf '**PM spec:** x\n\n**Acceptance criteria**\n'
  printf -- '- [ ] AC1 greets (test)\n- [ ] AC2 rejects (test)\n- [ ] AC3 same (same: unchanged)\n- [ ] AC4 doc (prose: doc)\n'
} > "$SPEC"
RED="$SANDBOX/red.out"; HEAD_OUT="$SANDBOX/head.out"; RERUN="$SANDBOX/rerun.out"
printf '%s\n' 'FAIL  AC1 greets' 'FAIL  AC2 rejects' 'FAIL  AC3 same' > "$RED"
printf '%s\n' 'FAIL  AC1 greets' 'FAIL  AC2 rejects' 'FAIL  AC3 same' > "$HEAD_OUT"
printf '%s\n' '  ok  AC1 greets' 'FAIL  AC2 rejects' '  ok  AC3 same' > "$RERUN"
OUT="$(bash "$CRIT" report --spec "$SPEC" --red "$RED" --head "$HEAD_OUT" --red-sha abcdef12 --rerun "$RERUN" 2>&1)"; RC=$?
assert_eq "1" "$RC" "AC1 a flaky criterion makes report exit 1"
assert_contains "$OUT" "AC1 FAIL flaky (failed at head, passed on re-run)" "AC1 a test criterion that fails at head and passes on re-run is flaky"
assert_contains "$OUT" "AC3 FAIL flaky (failed at head, passed on re-run)" "AC1 a same criterion that fails at head and passes on re-run is flaky"
assert_contains "$OUT" "AC2 FAIL head=fail red=fail" "AC1 a criterion that fails in both runs keeps its line"
OUT0="$(bash "$CRIT" report --spec "$SPEC" --red "$RED" --head "$HEAD_OUT" --red-sha abcdef12 2>&1)"
assert_not_contains "$OUT0" "flaky" "AC1 without --rerun the output has no flaky line"
assert_contains "$OUT0" "AC1 FAIL head=fail red=fail" "AC1 without --rerun a head failure is today's line"

# ── qa-run fixtures ──────────────────────────────────────────────────────────
# new_repo KIND -- a sandbox repo with the real scripts, a stub pipeline-vcs.sh,
# a red commit holding only tests/test-greet.sh and a green commit adding
# feature.txt. KIND: stable (green at head), flaky (fails the first run at the
# head, passes the second), broken (fails at head always). Every run of the test
# is logged to .git/qa-runs.log.
new_repo() {
  local kind="$1"
  cd "$BASE_DIR" || exit 1
  rm -rf "${BASE_DIR:?}"/* "${BASE_DIR:?}"/.git "${BASE_DIR:?}"/.talos "${BASE_DIR:?}"/talos.pipeline.json
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  mkdir scripts tools tests
  cp "$TALOS_ROOT"/scripts/* scripts/
  cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh
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
  QA_LOG="$BASE_DIR/.git/qa-runs.log"
  E2E_LOG="$BASE_DIR/.git/qa-e2e.log"
  HEAD_LOG="$BASE_DIR/.git/qa-head.log"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s|%%s|%%s\\n" "$(pwd)" "$(git rev-parse HEAD)" "$(ls feature.txt 2>/dev/null)" >> "%s"\n' "$E2E_LOG"
    printf 'cat "%s/.git/e2e.out" 2>/dev/null\n' "$BASE_DIR"
    printf 'exit "$(cat "%s/.git/e2e.rc" 2>/dev/null || echo 0)"\n' "$BASE_DIR"
  } > tools/e2e.sh
  printf 'base\n' > README.md
  git add -A
  git commit -q -m "base"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b "$BR"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo run >> "%s"\n' "$QA_LOG"
    printf 'if [ ! -f feature.txt ]; then printf "FAIL  AC1 greet prints hello\\n"; exit 1; fi\n'
    case "$kind" in
      stable) printf 'printf "  ok  AC1 greet prints hello\\n"; exit 0\n' ;;
      broken) printf 'printf "FAIL  AC1 greet prints hello\\n"; exit 1\n' ;;
      flaky)
        printf 'n=$(grep -c . "%s")\n' "$HEAD_LOG"
        printf 'echo x >> "%s"\n' "$HEAD_LOG"
        printf 'if [ "$n" -eq 0 ]; then printf "FAIL  AC1 greet prints hello\\n"; exit 1; fi\n'
        printf 'printf "  ok  AC1 greet prints hello\\n"; exit 0\n' ;;
    esac
  } > tests/test-greet.sh
  git add -A
  git commit -q -m "test(#7): AC1 greet (red first)"
  RED8="$(git rev-parse HEAD | cut -c1-8)"
  printf 'done\n' > feature.txt
  git add feature.txt
  git commit -q -m "feat(#7): greet"
  export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
  rm -f "$QA_LOG" "$E2E_LOG" "$BASE_DIR/.git/e2e.out" "$BASE_DIR/.git/e2e.rc"
  : > "$HEAD_LOG"
}

spec() {  # spec -- AC1 (test) and AC2 (prose)
  {
    printf '**PM spec:** greeting\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n'
    printf -- '- [ ] AC2 the README names it (prose: doc wording)\n\n'
    printf '%s\n' '**Tests:** `tests/test-greet.sh`'
  } > "$QA_SPEC_FILE"
}
cfg_file() { printf '%s' "$1" > "$BASE_DIR/talos.pipeline.json"; }
qa_run() {
  rm -f "$BASE_DIR/.git/qa-results"
  OUT="$(TALOS_QA_RESULTS="$BASE_DIR/.git/qa-results" bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?
}
runs() { if [ -f "$QA_LOG" ]; then wc -l < "$QA_LOG" | tr -d ' '; else echo 0; fi; }
e2e_runs() { if [ -f "$E2E_LOG" ]; then wc -l < "$E2E_LOG" | tr -d ' '; else echo 0; fi; }
E2E_CFG='{"verify":{"e2e":"bash tools/e2e.sh"}}'

# ── AC2 / AC3: the re-run and the flaky verdict ──────────────────────────────
new_repo flaky
spec
qa_run
assert_eq "1" "$RC" "AC3 a flaky head failure: exit 1"
assert_contains "$OUT" "AC1 FAIL flaky (failed at head, passed on re-run)" "AC3 the flaky line is printed"
assert_contains "$OUT" "qa-run: verdict FAIL 1 test criteria FAIL (1 flaky)" "AC3 the verdict names the flaky count"
assert_contains "$(cat "$BASE_DIR/.git/qa-results" 2>/dev/null)" "AC1 FAIL flaky" "AC3 the flaky line is in the results file the driver reads"
assert_eq "3" "$(runs)" "AC2 the test ran at the head, again at the head, then at the red commit"

new_repo broken
spec
qa_run
assert_eq "1" "$RC" "AC2 a real failure: exit 1"
assert_contains "$OUT" "AC1 FAIL head=fail red=fail" "AC2 a failure in both runs keeps today's line"
assert_not_contains "$OUT" "flaky" "AC2 ... and is not called flaky"
assert_eq "3" "$(runs)" "AC2 a failing head run is re-run once"

new_repo stable
spec
qa_run
assert_eq "0" "$RC" "AC2 a green head run: exit 0"
assert_eq "2" "$(runs)" "AC2 a green head run causes no re-run (head and red only)"

# ── AC6: the config key ──────────────────────────────────────────────────────
PROJ="$SANDBOX/project"; GHOME="$SANDBOX/talos-home"
mkdir -p "$PROJ" "$GHOME" || exit 1
printf '%s' '{"verify":{"e2e":"PLANTED-run-9"}}' > "$GHOME/talos.pipeline.json"
E2E_VAL="$(cd "$PROJ" && TALOS_HOME="$GHOME" bash "$CFG_SH" verify.e2e SENT 2>"$SANDBOX/err")"
assert_eq "verify.e2e	str		-	-	repo" "$(grep -E '^verify\.e2e	' "$DEFAULTS_SH")" "AC6 verify.e2e is a defaults-table row: str, scope repo"
assert_eq "SENT" "$E2E_VAL" "AC6 a value in the user-level file does not apply"
assert_contains "$(cat "$SANDBOX/err")" "verify.e2e" "AC6 the repo-only warning names the key"
assert_not_contains "$(cat "$SANDBOX/err")" "PLANTED-run-9" "AC6 the warning never prints the value"
assert_contains "$(cat "$TALOS_ROOT/talos.pipeline.json.example")" "e2e" "AC6 the example config mentions verify.e2e"
assert_contains "$(grep -E '^\| `verify\.e2e` \| str' "$TALOS_ROOT/docs/reference.md")" "repo" "AC6 docs/reference.md has the config-table row"
assert_contains "$(grep -E '^Repo-only keys:' "$TALOS_ROOT/docs/reference.md")" '`verify.e2e`' "AC6 docs/reference.md lists it among the repo-only keys"

# ── AC7: unset or empty changes nothing ──────────────────────────────────────
new_repo stable
spec
qa_run
assert_not_contains "$OUT" "e2e" "AC7 unset: no e2e line"
assert_contains "$OUT" "qa-run: verdict PASS (1 test criteria green, 1 prose to hand-check)" "AC7 unset: the PASS line is today's"
cfg_file '{"verify":{"e2e":""}}'
qa_run
assert_not_contains "$OUT" "e2e" "AC7 empty: no e2e line"
assert_eq "0" "$(e2e_runs)" "AC7 empty: nothing ran"

# ── AC8: the e2e step ────────────────────────────────────────────────────────
new_repo stable
spec
cfg_file "$E2E_CFG"
qa_run
assert_eq "0" "$RC" "AC8 e2e exit 0: exit 0"
assert_contains "$OUT" "qa-run: e2e ok" "AC8 e2e exit 0 prints qa-run: e2e ok"
assert_contains "$OUT" "prose to hand-check) e2e ok" "AC8 ... and ' e2e ok' is appended to the PASS line"
assert_eq "1" "$(e2e_runs)" "AC8 e2e ran once"
assert_eq "$BASE_DIR|$(git rev-parse HEAD)|feature.txt" "$(cat "$E2E_LOG")" "AC8 e2e ran from the repo root at the PR head"

new_repo stable
spec
cfg_file "$E2E_CFG"
for i in $(seq 1 30); do printf 'step %s %s\n' "$i" "$(printf 'x%.0s' $(seq 1 250))"; done > "$BASE_DIR/.git/e2e.out"
printf '3\n' > "$BASE_DIR/.git/e2e.rc"
qa_run
assert_eq "1" "$RC" "AC8 e2e non-zero: exit 1"
assert_contains "$OUT" "qa-run: verdict FAIL e2e exited 3" "AC8 e2e failure is a QA FAIL naming the exit code"
assert_contains "$OUT" "e2e failure output (data):" "AC8 the output tail is introduced as data"
assert_contains "$OUT" "  step 30 " "AC8 the tail has the last line, indented two spaces"
assert_not_contains "$OUT" "  step 6 " "AC8 the tail is the last 24 lines"
assert_contains "$OUT" "  step 7 " "AC8 ... the 24th from the end is in"
assert_eq "0" "$(printf '%s\n' "$OUT" | grep '^  step' | awk 'length($0) > 202' | wc -l | tr -d ' ')" "AC8 each tail line is cut to 200 characters (plus the indent)"
assert_not_contains "$OUT" "e2e ok" "AC8 a failing e2e is not ok"

new_repo broken
spec
cfg_file "$E2E_CFG"
qa_run
assert_eq "1" "$RC" "AC8 a failing verdict: exit 1"
assert_eq "0" "$(e2e_runs)" "AC8 e2e never runs on a failing verdict"

new_repo flaky
spec
cfg_file "$E2E_CFG"
qa_run
assert_eq "0" "$(e2e_runs)" "AC8 e2e never runs on a flaky verdict"

new_repo stable
printf '**PM spec:** x\n\n**Acceptance criteria**\n- [ ] AC1 the README names it (prose: doc wording)\n' > "$QA_SPEC_FILE"
cfg_file "$E2E_CFG"
qa_run
assert_eq "0" "$(e2e_runs)" "AC8 e2e does not run when the spec has no tests to run"
assert_not_contains "$OUT" "e2e" "AC8 ... and prints no e2e line"

new_repo stable
spec
printf '%s\n' '**Tests:** `tests/test-greet.sh`, `tests/test-absent.sh`' >> "$QA_SPEC_FILE"
cfg_file "$E2E_CFG"
qa_run
assert_eq "0" "$(e2e_runs)" "AC8 e2e does not run with a missing test file"

# ── AC4: the driver ──────────────────────────────────────────────────────────
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR CLAUDE_CONFIG_DIR="$SANDBOX/cc"
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
cat > "$GS/pipeline-agent.sh" <<'TALOS_stubagent717Zk3Rb'
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
TALOS_stubagent717Zk3Rb
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatus717Yp5Lc'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
printf 'status-file collect\n' >> "$d/journal"
printf '%s' "$(cat "$d/collect.json" 2>/dev/null || echo '{}')"
TALOS_stubstatus717Yp5Lc

RUN="$GS/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
LEASE="$SANDBOX/.git/talos-lease.ledger"
ERR="$SANDBOX/stderr"
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$LEASE" "${LEASE:?}.lock.d"
  printf '%s' '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": true}, "comments": {"enabled": false}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
    > "$SANDBOX/talos.pipeline.json"
  printf '%s\n' 0 > "$STUB_DIR/events.cost.line.rc"; printf '%s' "spend: 12 tokens" > "$STUB_DIR/events.cost.line.out"
}
drv_spec() {
  {
    printf '**PM spec:** greeting\n\n**Acceptance criteria:**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n- [ ] AC2 `greet` prints bye (test)\n\n'
    printf '%s\n' '**Tests:** `tests/test-a.sh`'
  } > "$SANDBOX/drv-spec.md"
  python3 -I -c 'import json, sys
print(json.dumps({"number": 9, "title": "t", "body": "- [ ] an item", "labels": [{"name": "pipeline:ready"}], "state": "open",
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$SANDBOX/drv-spec.md" > "$STUB_DIR/view-issue.9"
}
rn() { OUT="$(TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 bash "$RUN" run --max-iterations 5 2>"$ERR")"; RC=$?; }
run_fixture() {  # RESULTS: the lines qa-run left for the driver
  reset_stubs
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"ready"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.json"
  printf ready > "$STUB_DIR/pr-is-draft.12"; printf 1 > "$STUB_DIR/pr-is-draft.12.rc"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  drv_spec
  printf 'https://github.com/acme/widget/pull/12\nfixed\n' > "$STUB_DIR/message.developer.1"
  printf 'https://github.com/acme/widget/pull/12\nfixed again\n' > "$STUB_DIR/message.developer.2"
  printf 'FAIL: see the results\n' > "$STUB_DIR/message.qa.1"
  printf 'FAIL: see the results\n' > "$STUB_DIR/message.qa.2"
  printf '%s\n' "$1" > "$STUB_DIR/results.qa.1"
  printf '%s\n' "$1" > "$STUB_DIR/results.qa.2"
  printf 'printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"\n' > "$STUB_DIR/hook.developer.1"
  printf 'printf cccccccccccccccccccccccccccccccccccccccc > "$d/pr-head.12"\n' > "$STUB_DIR/hook.developer.2"
}
devs() { journal | grep -c '^agent developer$'; }
FLAKY='AC1 FAIL flaky (failed at head, passed on re-run)'

run_fixture "$FLAKY"
rn
assert_eq "0" "$RC" "AC4 flaky only: exit 0"
assert_eq "stop reason=qa-flaky issue=9 pr=12" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC4 flaky only: stop reason=qa-flaky"
assert_eq "0" "$(devs)" "AC4 flaky only: no developer fix round"
assert_contains "$(journal)" "vcs label-pr 12 --add pipeline:blocked" "AC4 flaky only: the PR is blocked"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "AC4 flaky only: the issue is blocked"
assert_not_contains "$(journal)" "gate " "AC4 flaky only: no gate, so no attempt is recorded"
assert_contains "$OUT" "AC1 FAIL flaky" "AC4 flaky only: the flaky line is relayed"

run_fixture "$FLAKY
AC2 FAIL head=fail red=fail"
rn
assert_not_contains "$OUT" "qa-flaky" "AC4 flaky mixed with another FAIL: not the owner stop"
assert_eq "2" "$(devs)" "AC4 flaky mixed with another FAIL: the fix rounds run as before"

finish
