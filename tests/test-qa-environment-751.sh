#!/usr/bin/env bash
# A broken environment is not a failing change (#751).
#   AC1  verify.ready is a repo-only list key
#   AC2  it runs from the repo root before the head run and the flaky re-run
#   AC3  ... and before the red run and the frozen run
#   AC4  a failing command is `BLOCKED environment`: exit 5, no AC line, no Tests file
#   AC5  TALOS_QA_RESULTS holds `BLOCKED environment: ...` first, no AC FAIL line
#   AC6  the driver stops reason=environment on that file, no developer round
#   AC7  a QA that ends `BLOCKED: environment: <why>` stops the same way
#   AC8  a FAIL keeps head.out/red.out under .talos/qa-run-<pr>/; a PASS leaves none
#   AC9  qa-run names the config file that supplied verify.targeted_commands
#   AC10 no verify.ready: the default path is unchanged (same)
# AC11 is prose. Each qa-run case builds a throwaway repo with the real scripts and
# a stub pipeline-vcs.sh (as tests/test-qa-flaky-e2e-717.sh does); AC6/AC7 drive
# the run on stubs (as tests/test-qa-spec-fault-678.sh does).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

BASE_DIR="$SANDBOX/repo"
BR=feat/issue-7-greet
CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
DEFAULTS_SH="$TALOS_ROOT/scripts/pipeline-defaults.sh"
trap '_is_trap_owner && _sandbox_cleanup' EXIT
export TALOS_RETRY_SLEEP_SCALE=0
mkdir -p "$BASE_DIR" || exit 1

# ── AC1: the config key ──────────────────────────────────────────────────────
PROJ="$SANDBOX/project"; GHOME="$SANDBOX/talos-home"
mkdir -p "$PROJ" "$GHOME" || exit 1
printf '%s' '{"verify":{"ready":["PLANTED-run-9"]}}' > "$GHOME/talos.pipeline.json"
READY_VAL="$(cd "$PROJ" && TALOS_HOME="$GHOME" bash "$CFG_SH" verify.ready SENT 2>"$SANDBOX/err")"
assert_eq "verify.ready	list		-	-	repo" "$(grep -E '^verify\.ready	' "$DEFAULTS_SH")" "AC1 verify.ready is a defaults-table row: list, scope repo"
assert_eq "SENT" "$READY_VAL" "AC1 a value in the user-level file does not apply"
assert_contains "$(cat "$SANDBOX/err")" "verify.ready" "AC1 the repo-only note names the key"
assert_not_contains "$(cat "$SANDBOX/err")" "PLANTED-run-9" "AC1 the note never prints the value"

# ── qa-run fixtures ──────────────────────────────────────────────────────────
# new_repo KIND [frozen] -- a sandbox repo with the real scripts, a stub
# pipeline-vcs.sh, a red commit holding only tests/test-greet.sh and a green
# commit adding feature.txt; `frozen` adds a later commit that edits the test
# file. KIND: stable (green at head), flaky (fails the first run at the head),
# broken (fails at head always). Every test run logs `run` to .git/qa-runs.log;
# tools/ready.sh logs `ready` there and `pwd|HEAD` to .git/ready.log, counts its
# calls in .git/ready.count and fails (exit 3, 35 long output lines) on the call
# numbered in .git/ready.failat.
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
  cat > scripts/pipeline-vcs.sh <<'TALOS_q751m2x9k4dv'
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
TALOS_q751m2x9k4dv
  QA_LOG="$BASE_DIR/.git/qa-runs.log"
  READY_LOG="$BASE_DIR/.git/ready.log"
  HEAD_LOG="$BASE_DIR/.git/qa-head.log"
  cat > tools/ready.sh <<'TALOS_r751p7w3hc92'
#!/usr/bin/env bash
g="$(git rev-parse --git-common-dir)"
echo ready >> "$g/qa-runs.log"
printf '%s|%s\n' "$(pwd -P)" "$(git rev-parse HEAD)" >> "$g/ready.log"
n=$(( $(cat "$g/ready.count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$g/ready.count"
if [ "$n" = "$(cat "$g/ready.failat" 2>/dev/null)" ]; then
  for i in $(seq 1 35); do printf 'app line %s %s\n' "$i" "$(printf 'x%.0s' $(seq 1 250))"; done
  exit 3
fi
TALOS_r751p7w3hc92
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
  RED="$(git rev-parse HEAD)"
  printf 'done\n' > feature.txt
  git add feature.txt
  git commit -q -m "feat(#7): greet"
  if [ "${2:-}" = frozen ]; then
    printf '# reworded\n' >> tests/test-greet.sh
    git add -A
    git commit -q -m "test(#7): reword"
  fi
  HEADSHA="$(git rev-parse HEAD)"
  export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
  rm -f "$QA_LOG" "$READY_LOG" "$BASE_DIR/.git/ready.count" "$BASE_DIR/.git/ready.failat"
  : > "$HEAD_LOG"
}

spec() {
  {
    printf '**PM spec:** greeting\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n'
    printf -- '- [ ] AC2 the README names it (prose: doc wording)\n\n'
    printf '%s\n' '**Tests:** `tests/test-greet.sh`'
  } > "$QA_SPEC_FILE"
}
cfg_file() { printf '%s' "$1" > "$BASE_DIR/talos.pipeline.json"; }
READY_CFG='{"verify":{"ready":["bash tools/ready.sh"]}}'
qa_run() {
  rm -f "$BASE_DIR/.git/qa-results"
  OUT="$(TALOS_QA_RESULTS="$BASE_DIR/.git/qa-results" bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?
}
qa_log() { tr '\n' ' ' < "$QA_LOG" 2>/dev/null; }
root_real() { (cd "$BASE_DIR" && pwd -P); }

# ── AC2: before the head run and the flaky re-run ────────────────────────────
new_repo flaky
spec
cfg_file "$READY_CFG"
qa_run
assert_eq "ready run ready run ready run " "$(qa_log)" "AC2 ready runs before the head run, before the re-run, and before the red run"
assert_eq "$(root_real)|$HEADSHA" "$(sed -n 1p "$READY_LOG")" "AC2 the first call ran from the repo root at the PR head"
assert_eq "$(root_real)|$HEADSHA" "$(sed -n 2p "$READY_LOG")" "AC2 the re-run's call ran from the repo root at the PR head"

# ── AC3: before the red run and the frozen run ───────────────────────────────
new_repo stable frozen
spec
cfg_file "$READY_CFG"
qa_run
assert_eq "ready run ready run ready run " "$(qa_log)" "AC3 ready runs before the head, red and frozen runs"
assert_eq "$(root_real)|$RED" "$(sed -n 2p "$READY_LOG")" "AC3 the red run's call ran with the red commit checked out"
assert_eq "$(root_real)|$HEADSHA" "$(sed -n 3p "$READY_LOG")" "AC3 the frozen run's call ran at the PR head"

# ── AC4 / AC5: a failing command ─────────────────────────────────────────────
new_repo stable
spec
cfg_file "$READY_CFG"
printf '1\n' > "$BASE_DIR/.git/ready.failat"
qa_run
assert_eq "5" "$RC" "AC4 a failing ready command: exit 5"
assert_contains "$OUT" "qa-run: verdict BLOCKED environment: bash tools/ready.sh exited 3" "AC4 the verdict names the command and its exit code"
assert_contains "$OUT" "environment failure output (data):" "AC4 the output tail is introduced as data"
assert_contains "$OUT" "  app line 35 " "AC4 the tail has the last line, indented two spaces"
assert_contains "$OUT" "  app line 6 " "AC4 the 30th line from the end is in"
assert_not_contains "$OUT" "  app line 5 " "AC4 the tail is the last 30 lines"
assert_eq "0" "$(printf '%s\n' "$OUT" | grep '^  app line' | awk 'length($0) > 202' | wc -l | tr -d ' ')" "AC4 each tail line is cut to 200 characters (plus the indent)"
assert_not_contains "$OUT" "AC1" "AC4 no AC line is printed"
assert_eq "ready " "$(qa_log)" "AC4 no Tests file ran"
assert_eq "$BR" "$(git symbolic-ref --short HEAD)" "AC4 the checkout is on the PR head"
assert_eq "BLOCKED environment: bash tools/ready.sh exited 3" "$(sed -n 1p "$BASE_DIR/.git/qa-results")" "AC5 the results file starts with the verdict"
assert_contains "$(cat "$BASE_DIR/.git/qa-results")" "  app line 35 " "AC5 the results file holds the indented tail"
assert_not_contains "$(cat "$BASE_DIR/.git/qa-results")" "AC1 FAIL" "AC5 the results file has no AC FAIL line"

# ... also when the call that fails runs at the red commit, and at the frozen run
new_repo stable frozen
spec
cfg_file "$READY_CFG"
printf '2\n' > "$BASE_DIR/.git/ready.failat"
qa_run
assert_eq "5" "$RC" "AC4 a ready command failing before the red run: exit 5"
assert_contains "$OUT" "qa-run: verdict BLOCKED environment: bash tools/ready.sh exited 3" "AC4 ... the same verdict"
assert_eq "$BR" "$(git symbolic-ref --short HEAD)" "AC4 ... and the checkout is back on the PR head"
assert_eq "" "$(git status --porcelain --untracked-files=no)" "AC4 ... with no tracked file modified"
new_repo stable frozen
spec
cfg_file "$READY_CFG"
printf '3\n' > "$BASE_DIR/.git/ready.failat"
qa_run
assert_eq "5" "$RC" "AC4 a ready command failing before the frozen run: exit 5"
assert_eq "" "$(git status --porcelain --untracked-files=no)" "AC4 ... the head's test file is back"
assert_eq "$BR" "$(git symbolic-ref --short HEAD)" "AC4 ... and the checkout is on the PR head"

# ── AC2 / AC10: unset or empty changes nothing ───────────────────────────────
new_repo stable
spec
qa_run
assert_eq "0" "$RC" "AC10 unset: exit 0"
assert_eq "run run " "$(qa_log)" "AC10 unset: only the head and red runs"
assert_not_contains "$OUT" "environment" "AC10 unset: no environment line"
assert_not_contains "$OUT" "raw output kept" "AC10 a PASS prints no raw-output line"
assert_contains "$OUT" "qa-run: verdict PASS (1 test criteria green, 1 prose to hand-check)" "AC10 unset: the PASS line is today's"
cfg_file '{"verify":{"ready":[]}}'
: > "$QA_LOG"
qa_run
assert_eq "run run " "$(qa_log)" "AC2 empty: nothing extra ran"
assert_not_contains "$OUT" "environment" "AC2 empty: nothing extra printed"
new_repo broken
spec
qa_run
assert_eq "1" "$RC" "AC10 a failing head without verify.ready: exit 1"
assert_contains "$OUT" "AC1 FAIL head=fail red=fail" "AC10 ... with today's AC line"
assert_contains "$OUT" "qa-run: verdict FAIL 1 test criteria FAIL" "AC10 ... and today's verdict"
assert_not_contains "$OUT" "environment" "AC10 ... and no environment word"

# ── AC8: the raw output survives a FAIL ──────────────────────────────────────
new_repo broken frozen
spec
qa_run
KEPT="$BASE_DIR/.talos/qa-run-9"
assert_contains "$OUT" "qa-run: raw output kept in $(root_real)/.talos/qa-run-9" "AC8 the kept path is named"
assert_eq "$(( $(printf '%s\n' "$OUT" | grep -n 'qa-run: verdict' | cut -d: -f1) - 1 ))" "$(printf '%s\n' "$OUT" | grep -n 'raw output kept' | cut -d: -f1)" "AC8 the line comes just before the verdict line"
assert_contains "$(cat "$KEPT/head.out" 2>/dev/null)" "FAIL  AC1 greet prints hello" "AC8 head.out is kept"
assert_contains "$(cat "$KEPT/red.out" 2>/dev/null)" "FAIL  AC1 greet prints hello" "AC8 red.out is kept"
assert_eq "yes" "$([ -f "$KEPT/rerun.out" ] && echo yes || echo no)" "AC8 rerun.out is kept when the re-run happened"
assert_eq "yes" "$([ -f "$KEPT/frozen.out" ] && echo yes || echo no)" "AC8 frozen.out is kept when the frozen run happened"
printf 'stale\n' > "$KEPT/stale.out"
qa_run
assert_eq "no" "$([ -f "$KEPT/stale.out" ] && echo yes || echo no)" "AC8 the directory is replaced on each run"
new_repo stable
spec
mkdir -p "$BASE_DIR/.talos/qa-run-9" && printf 'old\n' > "$BASE_DIR/.talos/qa-run-9/head.out"
qa_run
assert_eq "0" "$RC" "AC8 a PASS: exit 0"
assert_eq "no" "$([ -e "$BASE_DIR/.talos/qa-run-9" ] && echo yes || echo no)" "AC8 a PASS leaves no .talos/qa-run-9"
new_repo stable
spec
cfg_file "$READY_CFG"
printf '1\n' > "$BASE_DIR/.git/ready.failat"
qa_run
assert_contains "$OUT" "qa-run: raw output kept in" "AC8 a BLOCKED verdict keeps the output too"
assert_eq "yes" "$([ -f "$BASE_DIR/.talos/qa-run-9/head.out" ] && echo yes || echo no)" "AC8 ... head.out exists there"

# ── AC9: where verify.targeted_commands came from ────────────────────────────
new_repo stable
spec
qa_run
assert_not_contains "$OUT" "targeted_commands from" "AC9 no entries: no provenance line"
cfg_file '{"verify":{"targeted_commands":[{"match":"tests/*.sh","run":"bash {file}"}]}}'
qa_run
assert_contains "$OUT" "qa-run: targeted_commands from $(root_real)/talos.pipeline.json" "AC9 entries loaded: the repo config file is named"
cfg_file '{"verify":{"targeted_commands":[{"match":"svc/*.cs"}]}}'
qa_run
assert_not_contains "$OUT" "targeted_commands from" "AC9 only a skipped entry: no provenance line"

# ── AC6 / AC7: the driver ────────────────────────────────────────────────────
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR CLAUDE_CONFIG_DIR="$SANDBOX/cc"
mkdir -p "$GS" "$STUB_DIR" "$SANDBOX/templates"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cp -R "$TALOS_ROOT/templates/prompts" "$SANDBOX/templates/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null
cat > "$SANDBOX/stub-body" <<'TALOS_stubbody751Lw5Vc'
#!/usr/bin/env bash
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
TALOS_stubbody751Lw5Vc
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-events.sh pipeline-status.sh; do
  cp "$SANDBOX/stub-body" "$GS/$s"
done
cat > "$GS/pipeline-agent.sh" <<'TALOS_stubagent751Bq6Nf'
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
TALOS_stubagent751Bq6Nf
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatus751Gd8Jk'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
printf 'status-file collect\n' >> "$d/journal"
printf '%s' "$(cat "$d/collect.json" 2>/dev/null || echo '{}')"
TALOS_stubstatus751Gd8Jk

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
run_fixture() {  # MESSAGE RESULTS: QA's final message, and the lines qa-run left
  reset_stubs
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"ready"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.json"
  printf ready > "$STUB_DIR/pr-is-draft.12"; printf 1 > "$STUB_DIR/pr-is-draft.12.rc"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  drv_spec
  printf 'https://github.com/acme/widget/pull/12\nfixed\n' > "$STUB_DIR/message.developer.1"
  printf '%s\n' "$1" > "$STUB_DIR/message.qa.1"
  printf '%s\n' "$1" > "$STUB_DIR/message.qa.2"
  printf '%s\n' "$2" > "$STUB_DIR/results.qa.1"
  printf '%s\n' "$2" > "$STUB_DIR/results.qa.2"
  printf 'https://github.com/acme/widget/pull/12\nfixed again\n' > "$STUB_DIR/message.developer.2"
  printf 'printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"\n' > "$STUB_DIR/hook.developer.1"
  printf 'printf cccccccccccccccccccccccccccccccccccccccc > "$d/pr-head.12"\n' > "$STUB_DIR/hook.developer.2"
}
devs() { journal | grep -c '^agent developer$'; }
ENVRES='BLOCKED environment: bash tools/ready.sh exited 3
  app line 34 down
  app line 35 down'

run_fixture 'FAIL: see the results' "$ENVRES"
rn
assert_eq "0" "$RC" "AC6 an environment result: exit 0"
assert_eq "stop reason=environment issue=9 pr=12" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC6 stop reason=environment"
assert_eq "0" "$(devs)" "AC6 no developer dispatch"
assert_contains "$(journal)" "vcs label-pr 12 --add pipeline:blocked" "AC6 the PR is blocked"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "AC6 the issue is blocked"
assert_not_contains "$(journal)" "gate fix-round" "AC6 no fix-round gate"
assert_contains "$(cat "$ERR")" "BLOCKED environment: bash tools/ready.sh exited 3" "AC6 the first line is relayed"
assert_contains "$(cat "$ERR")" "app line 35 down" "AC6 the tail is relayed"

run_fixture 'FAIL: see the results' 'AC1 FAIL head=fail red=fail'
rn
assert_not_contains "$OUT" "reason=environment" "AC6 an ordinary FAIL is not an environment stop"
assert_eq "2" "$(devs)" "AC6 an ordinary FAIL still gets its fix rounds"

run_fixture 'FAIL: see the results' 'AC1 FAIL head=fail red=fail
BLOCKED environment: not the first line'
rn
assert_not_contains "$OUT" "reason=environment" "AC6 only the first line of the results file counts"

run_fixture 'BLOCKED: environment: the app on :3000 is down' ''
rn
assert_eq "0" "$RC" "AC7 a QA BLOCKED: environment: ends the run clean"
assert_eq "stop reason=environment issue=9 pr=12" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC7 it is the environment stop, not stage-blocked"
assert_eq "0" "$(devs)" "AC7 no developer dispatch"
assert_contains "$(journal)" "vcs label-pr 12 --add pipeline:blocked" "AC7 the PR is blocked"

finish
