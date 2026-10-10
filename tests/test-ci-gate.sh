#!/usr/bin/env bash
# test-ci-gate.sh -- the developer waits for required CI, and the orchestrator
# gates QA on CI state (#355).
#
# Covers:
#   (b) the developer prompt carries `Required checks:` and `CI wait budget:`;
#       local mode omits them; the draft shape sends `none`
#   (d) the exit-code/stderr contract the CI gate's routing table depends on:
#       the gate command is extracted from skills/pipeline/refs/ci-gate.md and run
#       against the real `pr-checks-required` verb and a stubbed `gh`
#   (e) `pr-checks-required <n> --wait <seconds>` (the one-call CI wait the
#       developer and QA profiles use): 0/1/2 results, bad values, no-flag baseline
#   (f) a skipped required check is pending, not failed (#435)
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

GATE_REF="$TALOS_ROOT/skills/pipeline/refs/ci-gate.md"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
GATE="$(cat "$GATE_REF")"

# ── (b) Step 3c developer prompt ─────────────────────────────────────────────
# The dispatch block moved to templates/prompts/developer.md (#468): this renders it
# with `talos.sh prompt` under each config and pins what the old prose pinned.
make_sandbox || exit 1
printf '{"merge": {"required_checks": ["test (ubuntu-latest)"]}, "verify": {"qa_mode": "ci", "ci_wait_s": 600, "timeout_ms": 300000}}' > "$SANDBOX/talos.pipeline.json"
CI_PROMPT="$(talos_prompt_text developer --issue 5)"
assert_contains "$CI_PROMPT" 'Required checks: test (ubuntu-latest)' "developer prompt carries Required checks:"
assert_contains "$CI_PROMPT" 'CI wait budget: 600 seconds' "developer prompt carries CI wait budget:"
printf '{"merge": {"required_checks": ["test (ubuntu-latest)"]}, "verify": {"qa_mode": "local"}}' > "$SANDBOX/talos.pipeline.json"
LOCAL_PROMPT="$(talos_prompt_text developer --issue 5)"
assert_not_contains "$LOCAL_PROMPT" 'Required checks:' "local mode omits the developer prompt's Required checks line"
assert_not_contains "$LOCAL_PROMPT" 'CI wait budget' "local mode omits the developer prompt's CI wait budget"

# (#435) --draft makes the brief's `Required checks:` line `none`, which is what
# tells the developer to skip the CI wait.
printf '{"merge": {"required_checks": ["test (ubuntu-latest)"]}, "verify": {"qa_mode": "ci"}}' > "$SANDBOX/talos.pipeline.json"
DRAFT_CHECKS="$(talos_prompt_text developer --issue 5 --draft | grep '^Required checks:')"
assert_eq "Required checks: none" "$DRAFT_CHECKS" "PR_DRAFT = true: the rendered brief line is Required checks: none"

# ── (d) the contract the table depends on ────────────────────────────────────
gate_cmd="$(printf '%s\n' "$GATE" | sed -n '/^```bash$/,/^```$/p' | sed '1d;$d' | sed -e 's/<PR_NUMBER>/9/' -e "s#bash scripts/#bash $TALOS_ROOT/scripts/#")"
run_gate() { eval "$gate_cmd"; printf '%s|%s' "$rc" "$out"; }

cat > talos.pipeline.json <<'TALOS_k3QzJw9xVt2mA'
{"merge": {"required_checks": ["build", "test"]}}
TALOS_k3QzJw9xVt2mA

STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://x\ntest\tfail\t2m\thttps://x')"; export STUB_PR_CHECKS
res="$(run_gate)"
assert_eq "1" "${res%%|*}" "red required check: rc 1"
assert_contains "$res" 'pr-checks-required: failed: test' "red required check: out holds the failed: line"

STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://x\ntest\tpending\t0m\thttps://x')"; export STUB_PR_CHECKS
res="$(run_gate)"
assert_eq "2" "${res%%|*}" "pending required check: rc 2"
assert_not_contains "$res" 'pr-checks-required: failed:' "pending required check: no failed: line"

STUB_PR_CHECKS="$(printf 'build\tpass\t1m\thttps://x\ntest\tpass\t2m\thttps://x')"; export STUB_PR_CHECKS
res="$(run_gate)"
assert_eq "0" "${res%%|*}" "green required checks: rc 0"

rm -f talos.pipeline.json
res="$(run_gate)"
assert_eq "1" "${res%%|*}" "no checks configured: rc 1"
assert_not_contains "$res" 'pr-checks-required: failed:' "no checks configured: rc 1 without the failed: line (routes to QA)"

# ── (e) pr-checks-required --wait <seconds> ──────────────────────────────────
# A counting gh stub: the check-run read answers pending for the first
# $GH_PENDING_READS reads (state $GH_EARLY, default pending), then $GH_FINAL;
# every other REST call is the stock stub's. TALOS_RETRY_SLEEP_SCALE=0 makes
# every sleep instant; the verb's deadline still counts the nominal 30s steps.
mkdir -p "$SANDBOX/bin"
export STUBS_DIR
cat > "$SANDBOX/bin/gh" <<'TALOS_u8Rk2VxN5pQeW'
#!/usr/bin/env bash
case "$*" in
  "api -i"*"/check-runs"*)
    n="$(cat "$GH_CNT" 2>/dev/null || echo 0)"; n=$((n + 1)); printf '%s' "$n" > "$GH_CNT"
    if [ "$n" -le "${GH_PENDING_READS:-0}" ]; then st="${GH_EARLY:-pending}"; else st="${GH_FINAL:-pass}"; fi
    case "$st" in
      pass)     status=completed; conclusion='"success"' ;;
      pending)  status=in_progress; conclusion=null ;;
      skipping) status=completed; conclusion='"skipped"' ;;
      *)        status=completed; conclusion="\"$st\"" ;;
    esac
    printf 'HTTP/2.0 200 OK\nX-Stub: 1\r\n\r\n{"total_count":1,"check_runs":[{"name":"test","status":"%s","conclusion":%s}]}\n' "$status" "$conclusion" ;;
  "api -i"*) exec "$STUBS_DIR/gh" "$@" ;;
  *) exit 0 ;;
esac
TALOS_u8Rk2VxN5pQeW
chmod +x "$SANDBOX/bin/gh"
export PATH="$SANDBOX/bin:$PATH" GH_CNT="$SANDBOX/gh.cnt" TALOS_RETRY_SLEEP_SCALE=0
printf '{"merge": {"required_checks": ["test"]}}\n' > talos.pipeline.json

wait_run() {  # $1=pending reads, $2=final state, rest=verb args; sets out, rc, reads
  export GH_PENDING_READS="$1" GH_FINAL="$2"; shift 2
  rm -f "$GH_CNT"
  out="$(bash "$VCS" pr-checks-required "$@" 2>&1)"; rc=$?
  reads="$(cat "$GH_CNT" 2>/dev/null || echo 0)"
}

wait_run 2 pass 9 --wait 300
assert_eq "0" "$rc" "--wait: pending twice then pass returns 0"
assert_eq "3" "$reads" "--wait: read until the result stopped being pending"
wait_run 2 fail 9 --wait 300
assert_eq "1" "$rc" "--wait: pending twice then fail returns 1"
assert_contains "$out" 'pr-checks-required: failed: test' "--wait: the failed: line is the same"
wait_run 99 pass 9 --wait 100
assert_eq "2" "$rc" "--wait: still pending at the deadline returns 2"
assert_eq "4" "$reads" "--wait: 100s is three sleeps (30, 60, 10 -- the backoff, #554), so four reads"
wait_run 99 pass 9 --wait 0
assert_eq "2" "$rc" "--wait 0: one read, still pending returns 2"
assert_eq "1" "$reads" "--wait 0: exactly one read"
wait_run 99 pass --wait 100 9
assert_eq "4" "$reads" "--wait before the PR number is accepted too"

for bad in abc 3601 -5 1.5 ''; do
  wait_run 0 pass 9 --wait "$bad"
  assert_eq "2" "$rc" "--wait '$bad' is a usage error (exit 2)"
  assert_contains "$out" 'Usage: pipeline-vcs.sh pr-checks-required' "--wait '$bad' prints usage"
  assert_eq "0" "$reads" "--wait '$bad' makes no GitHub call"
done
wait_run 0 pass 9 --wait
assert_eq "2" "$rc" "--wait without a value is a usage error (exit 2)"
wait_run 0 pass 9 --wait 3600
assert_eq "0" "$rc" "--wait 3600 is accepted"

wait_run 99 pass 9
assert_eq "2" "$rc" "no --wait: pending returns 2 as before"
assert_eq "1" "$reads" "no --wait: one read, no polling"
wait_run 0 pass 9
assert_eq "0" "$rc" "no --wait: green returns 0 as before"

# ── (e1) the commit-status read is skipped when check runs cover every required check ──
# (#551 does this; #554 pins it.) A required check that no check run reports might be
# a legacy commit status, so then, and only then, /status is read.
status_reads() { : > "$GH_LOG"; wait_run 0 pass 9; grep -c '/commits/[^/]*/status' "$GH_LOG" || true; }
assert_eq "0" "$(status_reads)" "required check reported by a check run: no commit-status read"
printf '{"merge": {"required_checks": ["test", "legacy-ci"]}}\n' > talos.pipeline.json
assert_eq "1" "$(status_reads)" "a required check no check run reports: one commit-status read"
printf '{"merge": {"required_checks": ["test"]}}\n' > talos.pipeline.json

# ── (e2) the poll interval backs off: 30 s, 60 s, then 120 s (#554) ──────────
# A sleep stub that logs its argument and returns at once, with the real scale
# (1), so the schedule the verb asks for is what the log shows.
cat > "$SANDBOX/bin/sleep" <<'TALOS_s4Bq9LmZ2xWd'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SLEEP_LOG"
TALOS_s4Bq9LmZ2xWd
chmod +x "$SANDBOX/bin/sleep"
export SLEEP_LOG="$SANDBOX/sleep.log"
sleeps_for() {  # $1=pending reads, rest=verb args; prints the sleeps, comma-joined
  : > "$SLEEP_LOG"
  TALOS_RETRY_SLEEP_SCALE=1 wait_run "$1" pass "${@:2}"
  paste -sd, - < "$SLEEP_LOG"
}
assert_eq "30,60,120,120,120" "$(sleeps_for 99 9 --wait 450)" \
  "--wait 450: 30, 60, then the 120 s cap"
assert_eq "30,60,10" "$(sleeps_for 99 9 --wait 100)" "--wait 100: the final step is clipped to the time left"
assert_eq "30,60" "$(sleeps_for 2 9 --wait 900)" "--wait 900, green on the third read: only two sleeps"
assert_eq "" "$(sleeps_for 0 9 --wait 900)" "--wait: an immediately green read sleeps zero times"
rm -f "$SANDBOX/bin/sleep"

# ── (f) a skipped required check is pending, never a failure (#435) ──────────
# A draft push leaves a skipped required check until the ready_for_review run
# replaces it. Before: `skipping` read as failed: (exit 1) and re-dispatched the
# developer. After: pending (exit 2); it never passes by itself.
# The stub answers $GH_EARLY for the first reads and $GH_FINAL after, so the
# skipping state must be $GH_EARLY: with the default (pending) the first three
# assertions stayed green with the mapping reverted (#448).
GH_EARLY=skipping wait_run 99 pass 9
assert_eq "2" "$rc" "skipping required check: exit 2, not 1"
assert_not_contains "$out" 'pr-checks-required: failed:' "skipping required check: no failed: line"
assert_contains "$out" 'pending or missing: test' "skipping required check: reported as pending"
GH_EARLY=skipping wait_run 2 pass 9 --wait 300
assert_eq "0" "$rc" "--wait: skipping twice then the replacing run goes green returns 0"
assert_eq "3" "$reads" "--wait: kept polling through the skipped reads"
GH_EARLY=skipping wait_run 99 pass 9 --wait 100
assert_eq "2" "$rc" "--wait: a persistent skip ends exit 2 at the deadline, never a pass"
assert_not_contains "$out" 'pr-checks-required: failed:' "--wait: a persistent skip never reads as failed:"
wait_run 0 cancelled 9
assert_eq "1" "$rc" "control: another non-pass state (cancelled) still fails"

printf '{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "merge": {"required_checks": ["test"]}}\n' > talos.pipeline.json
export GITHUB_TOKEN="test-token-435"
ga_run() {  # $1 = check-runs JSON
  : > "$CURL_LOG"; : > "$CURL_LINK_QUEUE"
  printf '%s\n' '{"head":{"sha":"dd11223344556677889900aabbccddeeff11223"}}' "$1" > "$CURL_QUEUE"
  out="$(bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
}
ga_run '{"check_runs":[{"name":"test","status":"completed","conclusion":"skipped"}]}'
assert_eq "2" "$rc" "github-api: a skipped conclusion is pending (exit 2)"
assert_not_contains "$out" 'pr-checks-required: failed:' "github-api: a skipped conclusion is not failed:"
ga_run '{"check_runs":[{"name":"test","status":"completed","conclusion":"neutral"}]}'
assert_eq "2" "$rc" "github-api: a neutral conclusion is pending like gh's skipping bucket (exit 2)"
assert_not_contains "$out" 'pr-checks-required: failed:' "github-api: a neutral conclusion is not failed:"
ga_run '{"check_runs":[{"name":"test","status":"completed","conclusion":"cancelled"}]}'
assert_eq "1" "$rc" "github-api control: a cancelled conclusion still fails"
ga_run '{"check_runs":[{"name":"test","status":"completed","conclusion":"success"}]}'
assert_eq "0" "$rc" "github-api control: success still passes"

printf '{"vcs": {"provider": "gitlab"}, "merge": {"required_checks": ["test"]}}\n' > talos.pipeline.json
wait_run 0 pass 9 --wait 60
assert_eq "1" "$rc" "gitlab: --wait is dropped and the verb still fails closed (exit 1)"
assert_contains "$out" 'not implemented for gitlab' "gitlab: same not-implemented line with --wait"

finish
