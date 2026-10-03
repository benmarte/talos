#!/usr/bin/env bash
# test-spend-wiring.sh -- covers issue #386 (sub-task 9 of epic #334): the
# playbook wiring of the spend line, the PR spend comment, the budget stop and
# the run summary in skills/pipeline/SKILL.md.
#   (a) presence: --model on post_stage, cost --line, the upsert with
#       --marker spend --body-file -, pipeline-budget.sh check, budget-blocked,
#       cost --summary; no positional-body upsert; no pipe from cost straight
#       into the upsert (an empty body would make the verb exit 1)
#   (b) the budget check sits before every developer fix-round record-attempt
#       (merge-base task, draft round, QA, reviewer, security, adversarial)
#       and not before the no-dispatch record-attempt, the Step 4 CI path or a
#       re-stamp; Rule 20, item 8, Step 5 item 4 and the usage section carry
#       their pieces
#   (c) behaviour: the fenced snippets, run as written against the real
#       pipeline-events.sh / pipeline-budget.sh and a recording stub for
#       pipeline-vcs.sh (never a GitHub call)
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

SKILL_MD="$TALOS_ROOT/skills/pipeline/SKILL.md"
skill_flat="$(tr '\n' ' ' < "$SKILL_MD" | tr -s ' ')"

# ── (a) presence ───────────────────────────────────────────────────────────
assert_contains "$skill_flat" 'post_stage <event> <role> <N> [--pr] [--sha] [--verdict] [--summary] [--attempt ...] [--model]' \
  "Rule 3: post_stage lists --model"
assert_contains "$skill_flat" '--model "<value passed as `model:` to the spawn>"' \
  "Rule 3: --model carries the value passed as model: to the spawn"
assert_contains "$skill_flat" 'omitting the flag when the spawn had no model' \
  "Rule 3: --model is omitted when the spawn had no model"
assert_contains "$skill_flat" 'pipeline-events.sh cost --issue <N> --pr <M> --line' \
  "spend block: cost --line"
assert_contains "$skill_flat" 'upsert-pr-comment <M> --marker spend --body-file -' \
  "spend block: upsert-pr-comment --marker spend --body-file -"
assert_contains "$skill_flat" 'pipeline-budget.sh check --issue <N>' "budget stop: pipeline-budget.sh check"
assert_contains "$skill_flat" '|| rc=$?' "budget stop: exit code captured with || rc=\$?"
assert_contains "$skill_flat" 'post_stage budget-blocked orchestrator <N> --pr <M> --summary "$out"' \
  "budget stop: post_stage budget-blocked orchestrator"
assert_contains "$skill_flat" 'pipeline-events.sh cost --summary --issue' "Step 5: cost --summary --issue"
assert_contains "$skill_flat" 'With `limits.tokens_per_issue` unset' \
  "budget stop: states the unset flow is unchanged"
assert_contains "$skill_flat" 'is unchanged' "budget stop: unchanged wording present"
assert_contains "$skill_flat" 'removing `pipeline:blocked` (each block grants one more limit) or raising `limits.tokens_per_issue`' \
  "budget stop: how the owner resumes"
assert_contains "$skill_flat" 'BLOCKED_BY="talos.pipeline.yml:limits.tokens_per_issue (explicit)"' \
  "budget stop: blocked comment BLOCKED_BY"
assert_contains "$skill_flat" 'SPEND_COMMENT' "Step 0: spend.comment variable"

# No upsert-pr-comment use without a stdin body file; no cost output piped
# straight into it (the empty-body case would exit 1 on every event-less stage).
bad_upsert="$(grep -n 'upsert-pr-comment' "$SKILL_MD" | grep -v -e '--marker spend --body-file -' || true)"
assert_eq "" "$bad_upsert" "no upsert-pr-comment line without --marker spend --body-file -"
direct_pipe="$(grep -nE 'cost .*--markdown *\|' "$SKILL_MD" || true)"
assert_eq "" "$direct_pipe" "cost --markdown is captured first, never piped straight into the upsert"
assert_contains "$skill_flat" '[ -n "$SPEND_BODY" ]' "spend block: an empty body skips the upsert"
assert_contains "$skill_flat" 'tail -1' "spend block: only the last upsert line is read"

# ── (b) wiring sites ───────────────────────────────────────────────────────
# One canonical sentence, word for word, before each developer fix-round
# record-attempt: the merge-base task, the draft round, the draft QA/CI failure
# round, QA, reviewer, security and adversarial. Counted, and each site must
# have it within the 6 lines up to its own record-attempt line.
CANON='Run the Step 3 budget check ("Budget stop") first.'
assert_eq "7" "$(grep -cF -- "$CANON" "$SKILL_MD")" "the canonical budget-check sentence appears exactly 7 times"
sites="$(grep -nE 'record-attempt <N> (developer|<that-role>|qa|reviewer|security|adversarial)' "$SKILL_MD" | cut -d: -f1)"
assert_eq "7" "$(printf '%s\n' "$sites" | wc -l | tr -d ' ')" "seven fix-round record-attempt sites"
for n in $sites; do
  window="$(sed -n "$((n > 6 ? n - 6 : 1)),${n}p" "$SKILL_MD")"
  assert_contains "$window" "$CANON" "SKILL.md:$n record-attempt is preceded by the canonical budget-check sentence"
done
# The no-dispatch record-attempt (no-PR resend, then Blocked) has no check.
no_pr_window="$(grep -n -B6 'developer` — no `--pr` yet, per Step 3' "$SKILL_MD")"
assert_not_contains "$no_pr_window" "Budget stop" "no budget check before the no-PR resend record-attempt"
# The Step 4 CI failure path and the re-stamp path never mention the check.
step4_ci="$(awk '/^## Step 4 /{p=1} /^## Step 5 /{p=0} p' "$SKILL_MD")"
assert_not_contains "$step4_ci" "pipeline-budget.sh" "Step 4 never runs the budget check"
restamp="$(grep -n 'RESTAMP_FAIL' "$SKILL_MD" | grep -i 'budget' || true)"
assert_eq "" "$restamp" "RESTAMP_FAIL lines carry no budget check"

assert_contains "$skill_flat" 'a budget stop (Step 3)' "Rule 20 lists a budget stop"
assert_contains "$skill_flat" 'once, after `post_stage merged`' "Step 4 item 8: spend refresh once, after post_stage merged"
merge_seq="$(grep -n 'merge sequence:  pr-ci-runs -> merge-pr -> post_stage merged --ci-runs' "$SKILL_MD" | wc -l | tr -d ' ')"
assert_eq "1" "$merge_seq" "the merge sequence: line is unchanged"
item4="$(grep -n '4\. \*\*Cost column' "$SKILL_MD")"
assert_contains "$item4" 'pipeline-events.sh cost --summary --issue' "Step 5 item 4 is the one --summary call"
assert_not_contains "$item4" 'loop `--issue N`' "Step 5 item 4: the per-issue loop is gone"
usage_line="$(grep -m1 'Usage-reporting spawn form' "$SKILL_MD")"
assert_contains "$usage_line" 'no input/output split, no model, no dollar cost (UNVERIFIED beyond these observed fields)' \
  "usage section: Agent notification fields only"
assert_contains "$usage_line" 'show as unrecorded' "usage section: adapter and pi-inline runs show as unrecorded"

# ── (c) behaviour: run the fenced snippets as written ──────────────────────
# fence_after ANCHOR -- the first ```bash fence after the line containing ANCHOR.
fence_after() {
  awk -v a="$1" 'index($0, a) { f = 1 } f && /^```bash$/ { p = 1; next } p && /^```$/ { exit } p' "$SKILL_MD"
}
SPEND_SNIPPET="$(fence_after '**Spend block')"
BUDGET_SNIPPET="$(fence_after '**Budget stop')"
[ -n "$SPEND_SNIPPET" ] && pass "spend block fence found" || fail "spend block fence found"
[ -n "$BUDGET_SNIPPET" ] && pass "budget stop fence found" || fail "budget stop fence found"
SPEND_SNIPPET="$(printf '%s\n' "$SPEND_SNIPPET" | sed -e 's/<N>/7/g' -e 's/<M>/9/g')"
BUDGET_SNIPPET="$(printf '%s\n' "$BUDGET_SNIPPET" | sed -e 's/<N>/7/g' -e 's/<M>/9/g')"

# The sandbox's scripts/: the real ones, except pipeline-vcs.sh is a recorder.
mkdir -p scripts .talos
for s in "$TALOS_ROOT"/scripts/*; do ln -s "$s" "scripts/$(basename "$s")"; done
rm -f scripts/pipeline-vcs.sh
cat > scripts/pipeline-vcs.sh <<'STUB'
#!/usr/bin/env bash
# Recording stub: one call per line in vcs-calls.log, stdin body in vcs-body.txt.
printf '%s\n' "$*" >> "$SPEND_STUB_DIR/vcs-calls.log"
cat > "$SPEND_STUB_DIR/vcs-body.txt"
echo "https://example.invalid/pull/9#issuecomment-1"
echo "upserted pr=9 comment=created"
exit "${SPEND_STUB_RC:-0}"
STUB
export SPEND_STUB_DIR="$SANDBOX"
LOG=".talos/events.jsonl"
ev() {  # ROLE ISSUE PR TOKENS
  printf '{"event":"%s","role":"%s","issue":%s,"pr":%s,"verdict":"PASS","tokens":%s,"tool_uses":3,"duration_s":60,"ts":"2026-10-03T00:00:00Z"}\n' \
    "$1" "$1" "$2" "$3" "$4" >> "$LOG"
}
: > "$LOG"
ev developer 7 9 30000
ev qa 7 9 15000

# Events exist: the line is printed, the body is upserted, one result line.
rm -f vcs-calls.log vcs-body.txt
out="$(SPEND_STUB_RC=0 bash -c "$SPEND_SNIPPET" 2>"$SANDBOX/err.txt")"; rc=$?
assert_eq "0" "$rc" "spend block: exit 0 with events"
assert_contains "$out" 'talos: #9 qa done' "spend block: --line printed as is"
assert_contains "$out" 'spend-upsert rc=0 upserted pr=9 comment=created' "spend block: one result line, last upsert line only"
assert_eq "upsert-pr-comment 9 --marker spend --body-file -" "$(cat vcs-calls.log)" "spend block: the stub saw exactly the documented upsert call"
assert_eq "$(bash scripts/pipeline-events.sh cost --issue 7 --pr 9 --markdown)" "$(cat vcs-body.txt)" "spend block: stdin body is the cost --markdown body"
assert_not_contains "$out" 'issuecomment' "spend block: the comment URL line is not relayed"

# Exit 1 from the upsert: reported on one line, never retried, block still exits 0.
rm -f vcs-calls.log
out="$(SPEND_STUB_RC=1 bash -c "$SPEND_SNIPPET" 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "spend block: an upsert exit 1 does not fail the Bash call"
assert_contains "$out" 'spend-upsert rc=1' "spend block: upsert exit 1 surfaces as rc=1"
assert_eq "1" "$(wc -l < vcs-calls.log | tr -d ' ')" "spend block: upsert exit 1 is not retried"

# Exit 2 (non-GitHub provider) is reported as rc=2 for the orchestrator to ignore.
out="$(SPEND_STUB_RC=2 bash -c "$SPEND_SNIPPET" 2>/dev/null)"
assert_contains "$out" 'spend-upsert rc=2' "spend block: upsert exit 2 surfaces as rc=2 (silent for the orchestrator)"

# No events for the issue: empty body, the upsert never runs.
rm -f vcs-calls.log
NOEV_SNIPPET="$(printf '%s\n' "$SPEND_SNIPPET" | sed -e 's/--issue 7/--issue 8/g' -e 's/--pr 9/--pr 10/g')"
out="$(bash -c "$NOEV_SNIPPET" 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "spend block: no events, exit 0"
assert_eq "" "$out" "spend block: no events, no output"
assert_file_absent vcs-calls.log "spend block: an empty body skips the upsert"

# The budget snippet under `set -e`: exit 1 is captured, never aborts.
run_budget() { bash -ec "$BUDGET_SNIPPET
echo \"rc=\$rc\"
echo \"out=\$out\"" 2>/dev/null; }
printf '%s\n' '{"limits": {"tokens_per_issue": 1000000}}' > talos.pipeline.json
out="$(run_budget)"
assert_contains "$out" 'rc=0' "budget stop: under the limit, rc 0"
assert_contains "$out" 'talos:budget ok issue=7' "budget stop: ok line captured"
printf '%s\n' '{"limits": {"tokens_per_issue": 50000}}' > talos.pipeline.json
out="$(run_budget)"
assert_contains "$out" 'rc=0' "budget stop: warn is rc 0"
assert_contains "$out" 'talos:budget warn issue=7' "budget stop: warn line captured"
printf '%s\n' '{"limits": {"tokens_per_issue": 40000}}' > talos.pipeline.json
out="$(run_budget)"
assert_contains "$out" 'rc=1' "budget stop: exceeded is rc 1, captured under set -e"
assert_contains "$out" 'talos:budget exceeded issue=7' "budget stop: exceeded line captured"
printf '%s\n' '{}' > talos.pipeline.json
out="$(run_budget)"
assert_contains "$out" 'rc=0' "budget stop: limit unset, rc 0"
assert_contains "$out" 'out=' "budget stop: limit unset, output empty"
assert_not_contains "$out" 'talos:budget' "budget stop: limit unset prints nothing (flow unchanged)"

finish
