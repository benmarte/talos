#!/usr/bin/env bash
# test-spend-wiring.sh -- covers issue #386 (sub-task 9 of epic #334): the
# playbook wiring of the spend line, the PR spend comment, the budget stop and
# the run summary in skills/pipeline/SKILL.md. The spend block and the role
# post_stage moved into `talos.sh done` (#469); they are pinned in scripts/talos.sh.
#   (a) presence: --model on post_stage, cost --line, the upsert with
#       --marker spend --body-file -, pipeline-budget.sh check, budget-blocked,
#       cost --summary; no positional-body upsert; no pipe from cost straight
#       into the upsert (an empty body would make the verb exit 1)
#   (b) every developer fix round goes through `talos.sh gate fix-round`, whose
#       first step is the budget check (#466 moved it out of the prose; the
#       merge-base task, draft round, QA, reviewer, security, adversarial and
#       the Step 3d CI gate are the eight sites), and the no-dispatch
#       record-attempt, the Step 4 CI path and a re-stamp have none; Rule 20,
#       item 8, Step 5 item 4 and the usage section carry their pieces
#   (c) behaviour: the spend snippet as written, and `gate fix-round` against the
#       real pipeline-events.sh / pipeline-budget.sh and a recording stub for
#       pipeline-vcs.sh (never a GitHub call)
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

SKILL_MD="$TALOS_ROOT/skills/pipeline/SKILL.md"
skill_flat="$(tr '\n' ' ' < "$SKILL_MD" | tr -s ' ')"

# ── (a) presence ───────────────────────────────────────────────────────────
done_fn="$(sed -n '/^_talos_done() {/,/^}/p' "$TALOS_ROOT/scripts/talos.sh")"
spend_fn="$(sed -n '/^_talos_spend() {/,/^}/p' "$TALOS_ROOT/scripts/talos.sh")"
assert_contains "$skill_flat" '--model <value passed as `model:` to the spawn>' \
  "Rule 3: --model carries the value passed as model: to the spawn"
assert_contains "$skill_flat" 'only when the spawn had one' \
  "Rule 3: --model is passed only when the spawn had a model"
assert_contains "$done_fn" '${_model:+--model "$_model"}' "done: --model is omitted when the spawn had no model"
assert_contains "$done_fn" '[[ "$_model" =~ ^[A-Za-z0-9._:-]+$ ]]' "done: --model passes only when it matches [A-Za-z0-9._:-]+"
assert_contains "$done_fn" '_talos_post_stage "$_role" "$_role" "$_n"' "done: post_stage follows the role relay"
assert_contains "$spend_fn" 'pipeline-events.sh" cost --issue "$_n" ${_pr:+--pr "$_pr"} --line' \
  "spend block: cost --line (without --pr before a PR exists)"
assert_contains "$spend_fn" 'upsert-pr-comment "$_pr" --marker spend --body-file -' \
  "spend block: upsert-pr-comment --marker spend --body-file -"
# The budget guard runs inside `gate fix-round` (#466); its mechanics are pinned
# in talos.sh, the owner-facing parts stay in SKILL.md Step 3.
verb_fr="$(sed -n '/^_talos_gate_fix_round() {/,/^}/p' "$TALOS_ROOT/scripts/talos.sh")"
verb_all="$(cat "$TALOS_ROOT/scripts/talos.sh")"
assert_contains "$verb_fr" 'pipeline-budget.sh" check --issue "$_n"' "budget stop: gate fix-round runs pipeline-budget.sh check --issue <N>"
assert_contains "$verb_fr" '|| _brc=$?' "budget stop: the exit code is captured with || _brc=\$?"
assert_contains "$verb_fr" '_talos_post_stage budget-blocked orchestrator "$_n"' "budget stop: gate fix-round fires post_stage budget-blocked orchestrator"
assert_contains "$verb_fr" 'printf '"'"'%s'"'"' "$_bout" | _talos_post_stage budget-blocked' "budget stop: the budget line is the hook's stdin (printf '%s' piped into the one post_stage writer)"
assert_contains "$(sed -n '/^_talos_post_stage() {/,/^}/p' "$TALOS_ROOT/scripts/talos.sh")" 'pipeline-hooks.sh" post_stage "$@"' "post_stage: the helper is the one place that runs pipeline-hooks.sh post_stage"
assert_contains "$verb_fr" '--summary -' "budget stop: the hook summary comes from stdin"
# The cost table moved into `talos.sh summary` (#467): one call, one --issue per id.
assert_contains "$verb_all" 'pipeline-events.sh" cost --summary "${_a[@]}"' "Step 5: summary runs the one cost --summary call"
assert_contains "$verb_all" 'for _i in "${_IDS[@]}"; do _a+=(--issue "$_i"); done' "Step 5: summary passes one --issue per processed issue"
assert_contains "$skill_flat" 'the one `cost --summary` call' "Step 5: the playbook names the one cost --summary call"
assert_contains "$verb_all" 'With limits.tokens_per_issue unset' \
  "budget stop: talos.sh states the unset flow is unchanged"
assert_contains "$verb_all" 'so the fix-round flow is unchanged' "budget stop: unchanged wording present"
assert_contains "$skill_flat" 'removing `pipeline:blocked` (each block grants one more limit) or raising `limits.tokens_per_issue`' \
  "budget stop: how the owner resumes"
assert_contains "$verb_fr" 'blocked_by "talos.pipeline.yml:limits.tokens_per_issue (explicit)"' \
  "budget stop: BLOCKED_BY of the blocked comment (the blocked_by= line)"
assert_contains "$skill_flat" 'post blocked.md with BLOCKED_BY = the `blocked_by=` value' "budget stop: SKILL.md posts blocked.md with that BLOCKED_BY"
assert_eq "spend.comment true" "$(talos_env_key SPEND_COMMENT) $(talos_env_default SPEND_COMMENT)" "Step 0: spend.comment variable (read by talos.sh env, default true)"
assert_contains "$spend_fn" 'cfg spend.comment' "spend block: the comment honours spend.comment"
assert_contains "$spend_fn" 'cfg comments.enabled' "spend block: the comment honours comments.enabled"

# No upsert-pr-comment use without a stdin body file; no cost output piped
# straight into it (the empty-body case would exit 1 on every event-less stage).
bad_upsert="$(grep -n 'upsert-pr-comment' "$SKILL_MD" | grep -v -e '--marker spend --body-file -' || true)"
assert_eq "" "$bad_upsert" "no upsert-pr-comment line without --marker spend --body-file -"
direct_pipe="$(grep -nE 'cost .*--markdown *\|' "$SKILL_MD" || true)"
assert_eq "" "$direct_pipe" "cost --markdown is captured first, never piped straight into the upsert"
assert_contains "$spend_fn" '[ -n "$_body" ]' "spend block: an empty body skips the upsert"
assert_eq "" "$(grep -nE 'cost .*--markdown *\|' "$TALOS_ROOT/scripts/talos.sh" || true)" "spend block: talos.sh never pipes cost straight into the upsert"
assert_not_contains "$spend_fn" 'cat "$_CFG_CACHE_DIR/spend"' "spend block: the upsert's own output is never read, only its exit status"

# ── (b) wiring sites ───────────────────────────────────────────────────────
# Every developer fix-round site is a `gate fix-round` call (the verb's first step
# is the budget check, in front of record-attempt: tests/test-ci-gate.sh pins the
# order): the merge-base task, the draft round, the draft QA/CI failure round, QA,
# reviewer, security, adversarial and the Step 3d CI gate (#355). No raw
# record-attempt of a fix round is left to skip the check.
CANON='Run the Step 3 budget check ("Budget stop") first.'
assert_eq "0" "$(grep -cF -- "$CANON" "$SKILL_MD")" "the old budget-check sentence is gone (the verb runs the check)"
# Six sites since #469: the reviewer, security and adversarial rounds share one `<role>` site
# (`done` answers next=fix-round stage=<role>), the other five are as before.
assert_eq "6" "$(grep -cE 'gate fix-round <N> (developer|<that-role>|<role>|qa|reviewer|security|adversarial) --pr' "$SKILL_MD")" "six fix-round gate fix-round sites"
raw="$(grep -nE 'record-attempt <N> (developer|<that-role>|<role>|qa|reviewer|security|adversarial)' "$SKILL_MD" | grep -v 'no fix round follows' || true)"
assert_eq "" "$raw" "no fix round calls record-attempt directly (only the no-dispatch resend does)"
# The no-dispatch record-attempt (no-PR resend, then Blocked) has no check.
no_pr_window="$(grep -n -B6 'no fix round follows, so no budget check' "$SKILL_MD")"
assert_not_contains "$no_pr_window" "gate fix-round" "no budget check before the no-PR resend record-attempt"
# The Step 4 CI failure path and the re-stamp path never mention the check.
step4_ci="$(awk '/^## Step 4 /{p=1} /^## Step 5 /{p=0} p' "$SKILL_MD")"
assert_not_contains "$step4_ci" "pipeline-budget.sh" "Step 4 never runs the budget check"
assert_not_contains "$step4_ci" "gate fix-round" "Step 4 never runs gate fix-round"
restamp="$(grep -n 'RESTAMP_FAIL' "$SKILL_MD" | grep -i 'budget' || true)"
assert_eq "" "$restamp" "RESTAMP_FAIL lines carry no budget check"

assert_contains "$skill_flat" 'a budget stop (Step 3)' "Rule 20 lists a budget stop"
# The post-merge items moved into `talos.sh post-merge` (#467): the spend block runs
# once, after the merged event, and only for a first run (tests/test-talos-postmerge.sh).
pm_run="$(sed -n '/^_talos_post_merge_run() {/,/^}/p' "$TALOS_ROOT/scripts/talos.sh")"
spend_fn="$(sed -n '/^_talos_spend() {/,/^}/p' "$TALOS_ROOT/scripts/talos.sh")"
assert_eq "1" "$(printf '%s\n' "$spend_fn" | grep -c 'cost --issue "$_n" ${_pr:+--pr "$_pr"} --line')" "spend helper: the spend --line runs once"
assert_eq "1" "$(printf '%s\n' "$spend_fn" | grep -c 'upsert-pr-comment "$_pr" --marker spend --body-file -')" "spend helper: the spend upsert runs once"
assert_eq "1" "$(printf '%s\n' "$pm_run" | grep -c '_talos_spend "$_n" "$_pr"')" "post-merge: the spend block is the one _talos_spend call"
assert_eq "1" "$(printf '%s\n' "$pm_run" | awk '/_talos_post_stage merged/{m=NR} /_talos_spend/ && !c{c=NR} END{print (m && c && m < c) ? 1 : 0}')" "post-merge: the spend block is after post_stage merged"
assert_eq "0" "$(grep -c 'pipeline-hooks.sh" post_stage\|pipeline-events.sh" cost --issue' <<< "$pm_run")" "post-merge: no direct post_stage or spend writer is left (the helpers own them)"
assert_contains "$skill_flat" 'the `merged` and `issue-closed` `post_stage` events and the spend block' "Step 4: the post-merge call includes the spend block"
merge_seq="$(grep -n 'merge sequence:  pr-ci-runs -> merge-pr -> post_stage merged --ci-runs' "$SKILL_MD" | wc -l | tr -d ' ')"
assert_eq "1" "$merge_seq" "the merge sequence: line is unchanged"
item4="$(grep -n '3\. \*\*Cost column' "$SKILL_MD")"
assert_contains "$item4" 'print item 1'"'"'s `cost=` lines' "Step 5 item 3 prints the one --summary call's lines"
assert_not_contains "$item4" 'loop `--issue N`' "Step 5 item 3: the per-issue loop is gone"
usage_line="$(grep -m1 'Usage-reporting spawn form' "$SKILL_MD")"
assert_contains "$usage_line" 'no input/output split, no model, no dollar cost (UNVERIFIED beyond these observed fields)' \
  "usage section: Agent notification fields only"
assert_contains "$usage_line" 'show as unrecorded' "usage section: adapter and pi-inline runs show as unrecorded"

# ── (c) behaviour: `talos.sh done` against the real pipeline-events.sh ────────
# The sandbox's scripts/: the real ones, except pipeline-vcs.sh is a recorder and the
# notify and hook scripts do nothing (the real hook would add events to the log).
mkdir -p scripts .talos
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
LOG=".talos/events.jsonl"
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
