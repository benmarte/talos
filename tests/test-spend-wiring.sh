#!/usr/bin/env bash
# test-spend-wiring.sh -- covers issue #386 (sub-task 9 of epic #334): the spend
# line, the PR spend comment and the budget stop, run as behaviour. The spend block
# and the role post_stage live in `talos.sh done` (#469), the budget check in
# `talos.sh gate fix-round` (#466); both are driven against the real
# pipeline-events.sh / pipeline-budget.sh and a recording stub for pipeline-vcs.sh
# (never a GitHub call). The prose and source-text pins that used to open this file
# (SKILL.md / refs wording, talos.sh function bodies) were dropped by #556.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

assert_eq "spend.comment true" "$(talos_env_key SPEND_COMMENT) $(talos_env_default SPEND_COMMENT)" "Step 0: spend.comment variable (read by talos.sh env, default true)"


# ── (c) behaviour: `talos.sh done` against the real pipeline-events.sh ────────
# The sandbox's scripts/: the real ones, except pipeline-vcs.sh is a recorder and the
# notify and hook scripts do nothing (the real hook would add events to the log).
mkdir -p scripts .git/talos
for s in "$TALOS_ROOT"/scripts/*; do ln -s "$s" "scripts/$(basename "$s")"; done
rm -f scripts/pipeline-vcs.sh scripts/pipeline-notify.sh scripts/pipeline-hooks.sh
cat > scripts/pipeline-vcs.sh <<'STUB'
#!/usr/bin/env bash
# Recording stub: one call per line in vcs-calls.log, stdin body in vcs-body.txt.
printf '%s\n' "$*" >> "$SPEND_STUB_DIR/vcs-calls.log"
cat > "$SPEND_STUB_DIR/vcs-body.txt"
echo "https://example.invalid/pull/9#issuecomment-1"
echo "upserted pr=9 comment=created"
exit "${SPEND_STUB_RC:-0}"
STUB
printf '#!/usr/bin/env bash\ncat > /dev/null\nexit 0\n' > scripts/pipeline-notify.sh
printf '#!/usr/bin/env bash\nexit 0\n' > scripts/pipeline-hooks.sh
export SPEND_STUB_DIR="$SANDBOX"
LOG=".git/talos/events.jsonl"
ev() {  # ROLE ISSUE PR TOKENS
  printf '{"event":"%s","role":"%s","issue":%s,"pr":%s,"verdict":"PASS","tokens":%s,"tool_uses":3,"duration_s":60,"ts":"2026-10-03T00:00:00Z"}\n' \
    "$1" "$1" "$2" "$3" "$4" >> "$LOG"
}
: > "$LOG"
ev developer 7 9 30000
ev qa 7 9 15000
printf 'PASS: 3 criteria verified\n' > "$SANDBOX/sum.txt"
# run_done RC ISSUE PR: a QA PASS through `done`; prints its stdout, then rc=<exit status>.
run_done() {
  rm -f vcs-calls.log vcs-body.txt
  SPEND_STUB_RC="$1" bash scripts/talos.sh done qa --issue "$2" --pr "$3" --verdict PASS --summary-file "$SANDBOX/sum.txt" 2>/dev/null < /dev/null
  echo "rc=$?"
}

# Events exist: the line is printed, the body is upserted, nothing else is read.
out="$(run_done 0 7 9)"
assert_contains "$out" 'rc=0' "spend block: exit 0 with events"
assert_contains "$out" 'spend=talos: #9 qa done' "spend block: --line printed as is"
assert_eq "upsert-pr-comment 9 --marker spend --body-file -" "$(cat vcs-calls.log)" "spend block: the stub saw exactly the documented upsert call"
assert_eq "$(bash scripts/pipeline-events.sh cost --issue 7 --pr 9 --markdown)" "$(cat vcs-body.txt)" "spend block: stdin body is the cost --markdown body"
assert_not_contains "$out" 'issuecomment' "spend block: the comment URL line is not relayed"
assert_not_contains "$out" 'warn' "spend block: no warning when the upsert works"

# Exit 1 from the upsert: reported once, never retried, `done` still exits 0.
out="$(run_done 1 7 9)"
assert_contains "$out" 'rc=0' "spend block: an upsert exit 1 does not fail the call"
assert_contains "$out" 'warn reason=spend-upsert-failed issue=7' "spend block: upsert exit 1 is warn reason=spend-upsert-failed"
assert_eq "1" "$(wc -l < vcs-calls.log | tr -d ' ')" "spend block: upsert exit 1 is not retried"

# Exit 2 (non-GitHub provider) is silent.
out="$(run_done 2 7 9)"
assert_not_contains "$out" 'warn' "spend block: upsert exit 2 is silent"

# No events for the issue: empty body, the upsert never runs.
out="$(run_done 0 8 10)"
assert_contains "$out" 'rc=0' "spend block: no events, exit 0"
assert_not_contains "$out" 'spend=' "spend block: no events, no spend line"
assert_file_absent vcs-calls.log "spend block: an empty body skips the upsert"

# Before a PR exists (a PM return): the --line only, no comment.
rm -f vcs-calls.log
out="$(bash scripts/talos.sh done pm --issue 7 --summary-file "$SANDBOX/sum.txt" 2>/dev/null < /dev/null)"
assert_contains "$out" 'spend=' "spend block: before a PR exists the --line is printed"
assert_file_absent vcs-calls.log "spend block: before a PR exists nothing is upserted"

# spend.comment=false or comments.enabled=false: the --line is still printed, nothing is upserted.
for _cfg in '{"spend": {"comment": false}}' '{"comments": {"enabled": false}}'; do
  printf '%s\n' "$_cfg" > talos.pipeline.json
  out="$(run_done 0 7 9)"
  assert_contains "$out" 'spend=talos: #9 qa done' "spend block: $_cfg still prints the --line"
  assert_file_absent vcs-calls.log "spend block: $_cfg skips the PR comment"
done
rm -f talos.pipeline.json

# The budget guard through `gate fix-round`, under `set -e`: exit 1 is captured,
# never aborts; the real pipeline-budget.sh answers, the vcs stub records.
run_budget() { rm -f vcs-calls.log; bash -e scripts/talos.sh gate fix-round 7 qa --pr 9 2>/dev/null < /dev/null; echo "rc=$?"; }
printf '%s\n' '{"limits": {"tokens_per_issue": 1000000}}' > talos.pipeline.json
out="$(run_budget)"
assert_contains "$out" 'rc=0' "budget stop: under the limit, rc 0"
assert_contains "$out" 'verdict=redispatch' "budget stop: under the limit, the fix round proceeds"
assert_not_contains "$out" 'budget=' "budget stop: an ok line is not relayed"
printf '%s\n' '{"limits": {"tokens_per_issue": 50000}}' > talos.pipeline.json
out="$(run_budget)"
assert_contains "$out" 'rc=0' "budget stop: warn is rc 0"
assert_contains "$out" 'budget=talos:budget warn issue=7' "budget stop: warn line relayed"
assert_contains "$out" 'verdict=redispatch' "budget stop: a warn still proceeds"
printf '%s\n' '{"limits": {"tokens_per_issue": 40000}}' > talos.pipeline.json
out="$(run_budget)"
assert_contains "$out" 'rc=0' "budget stop: exceeded is a verdict, the verb exits 0 and never aborts under set -e"
assert_contains "$out" 'budget=talos:budget exceeded issue=7' "budget stop: exceeded line relayed"
assert_contains "$out" 'verdict=block' "budget stop: exceeded blocks"
assert_contains "$out" 'reason=budget-exceeded' "budget stop: exceeded reason"
assert_not_contains "$(cat vcs-calls.log)" 'record-attempt' "budget stop: exceeded records no attempt and starts no fix round"
assert_contains "$(cat vcs-calls.log)" 'label-pr 9 --add pipeline:blocked' "budget stop: exceeded sets pipeline:blocked on the PR"
assert_contains "$(cat vcs-calls.log)" 'label-issue 7 --add pipeline:blocked' "budget stop: exceeded sets pipeline:blocked on the issue"
printf '%s\n' '{}' > talos.pipeline.json
out="$(run_budget)"
assert_contains "$out" 'rc=0' "budget stop: limit unset, rc 0"
assert_contains "$out" 'verdict=redispatch' "budget stop: limit unset, the fix round proceeds"
assert_not_contains "$out" 'talos:budget' "budget stop: limit unset prints nothing (flow unchanged)"
assert_contains "$(cat vcs-calls.log)" 'record-attempt 7 qa --pr 9' "budget stop: limit unset goes on to record-attempt"

finish
