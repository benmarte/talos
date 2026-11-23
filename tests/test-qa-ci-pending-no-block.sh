#!/usr/bin/env bash
# test-qa-ci-pending-no-block.sh -- a ci-pending QA FAIL is a wait, so it never
# sets pipeline:blocked, and a QA PASS clears the block QA itself set (#1063).
#   AC1 post-verdict with a `FAIL: ci-pending` body posts its comment, adds no
#       pipeline:blocked on the PR or the issue
#   AC2 a QA PASS after a QA FAIL that blocked removes pipeline:blocked from the
#       PR and the issue
#   AC3 a QA PASS never removes a block QA did not apply (a gate, a human, or a
#       ci-pending FAIL's wait), nor one QA's PASS already cleared
#   AC4 after the ci-pending wait and a QA PASS the next routing pass answers
#       the merge route, not `wait reason=blocked`
#   AC5 (same: a defect QA FAIL still blocks as before) a FAIL for a failed
#       criterion still adds pipeline:blocked and routes to the developer
# AC6 is prose (docs/reference.md, the CHANGELOG). The vcs cases run the real
# pipeline-vcs.sh on the stateful gh stub, as tests/test-qa-fail-verdict-814.sh.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=0
TALOS_RUN_EMBED=1
. "$(dirname "$0")/talos-run-sections.sh"

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
SHA_A="aabb1122ccdd3344eeff556677889900aabb1122"
SHA_B="bbcc2233ddee4455ff00667788990011bbcc2233"
SHA_C="ccdd3344eeff5566001177889900112233445566"
export PIPELINE_REPO=acme/widget   # the env layer beats the config: never the ambient run's repo
OUTSIDE="$SANDBOX/outside"
mkdir -p "$OUTSIDE" || exit 1
CSTORE="$SANDBOX/cs1063.json"
export STUB_COMMENT_STORE="$CSTORE" STUB_CURRENT_USER=bot STUB_PR_HEAD_SHA="$SHA_A"
export STUB_PR_LABELS_JSON='[{"name":"pipeline:blocked"},{"name":"pipeline:review"},{"name":"qa:pass"}]'   # qa:pass: the stamp read after post-approval finds its label
BODY_CP=$'FAIL: ci-pending required check test (ubuntu-latest) was still pending at the 570 s CI wait budget\n\nNothing else failed.'
BODY_DEFECT=$'AC2 rejects an expired token: got 200\n\nThe handler never reads the expiry.'

fresh() { printf '[]' > "$CSTORE"; : > "$GH_LOG"; }
# verdict <body> / approve: the real verbs, PR 9 of issue 5, at $STUB_PR_HEAD_SHA.
verdict() { printf '%s\n' "$1" | (cd "$OUTSIDE" && bash "$VCS" post-verdict 9 qa --fail --issue 5 --body-file - > /dev/null 2> "$SANDBOX/v.err"); }
approve() { (cd "$OUTSIDE" && bash "$VCS" post-approval 9 qa --issue 5 > /dev/null 2> "$SANDBOX/a.err" < /dev/null); }
blocked_adds() { grep -c 'labels payload=.*pipeline:blocked' "$GH_LOG" || true; }
blocked_removed() { grep -c -- "-X DELETE .*issues/$1/labels/pipeline%3Ablocked" "$GH_LOG" || true; }
# labels_after <pr|issue number> <initial label,...>: the labels left once the
# gh log's label calls (adds and removals) are replayed over the initial ones.
labels_after() {
  python3 -I -c '
import json, re, sys
n, labels = sys.argv[1], set(x for x in sys.argv[2].split(",") if x)
for line in open(sys.argv[3]):
    m = re.search(r"issues/(\d+)/labels payload=(\{.*\})", line)
    if m and m.group(1) == n:
        labels |= set(json.loads(m.group(2))["labels"])
    m = re.search(r"-X DELETE .*issues/(\d+)/labels/(\S+)", line)
    if m and m.group(1) == n:
        labels.discard(m.group(2).replace("%3A", ":"))
print(",".join(sorted(labels)))' "$1" "$2" "$GH_LOG"
}

# ── AC1 ──────────────────────────────────────────────────────────────────────
fresh
verdict "$BODY_CP"; RC=$?
assert_eq "0" "$RC" "AC1 a ci-pending post-verdict exits 0" "$(cat "$SANDBOX/v.err")"
assert_eq "1" "$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$CSTORE")" "AC1 the verdict comment is still posted"
assert_eq "0" "$(blocked_adds)" "AC1 no pipeline:blocked is added on the PR or the issue"
assert_not_contains "$(cat "$GH_LOG")" "pipeline%3Areview" "AC1 pipeline:review stays on the PR"

# ── AC2: the block QA set is the block its PASS clears (PR and issue) ────────
fresh
verdict "$BODY_DEFECT"
assert_eq "2" "$(blocked_adds)" "AC2 the defect FAIL blocked the PR and the issue"
STUB_PR_HEAD_SHA="$SHA_B" approve; RC=$?
assert_eq "0" "$RC" "AC2 the QA PASS at the next head exits 0" "$(cat "$SANDBOX/a.err")"
assert_eq "1" "$(blocked_removed 9)" "AC2 the PASS removes pipeline:blocked from the PR"
assert_eq "1" "$(blocked_removed 5)" "AC2 the PASS removes pipeline:blocked from the issue"

# ── AC3: a block QA did not apply stays ──────────────────────────────────────
fresh   # a gate or a human blocked; QA never failed
approve; RC=$?
assert_eq "0" "$RC" "AC3 a PASS on a PR no QA FAIL blocked exits 0" "$(cat "$SANDBOX/a.err")"
assert_eq "0" "$(blocked_removed 9)" "AC3 no QA FAIL on the PR: the PR's pipeline:blocked stays"
assert_eq "0" "$(blocked_removed 5)" "AC3 no QA FAIL on the PR: the issue's pipeline:blocked stays"
fresh   # a ci-pending FAIL, then a gate's block, then the PASS
verdict "$BODY_CP"
STUB_PR_HEAD_SHA="$SHA_B" approve
assert_eq "0" "$(blocked_removed 9)" "AC3 a ci-pending FAIL is not QA's block: the PR's pipeline:blocked stays"
assert_eq "0" "$(blocked_removed 5)" "AC3 a ci-pending FAIL is not QA's block: the issue's pipeline:blocked stays"
fresh   # QA's block, cleared by its PASS; a human blocks again; the next PASS
verdict "$BODY_DEFECT"
STUB_PR_HEAD_SHA="$SHA_B" approve
: > "$GH_LOG"
STUB_PR_HEAD_SHA="$SHA_C" approve
assert_eq "0" "$(blocked_removed 9)" "AC3 a block QA's earlier PASS already cleared is not QA's again"

# ── AC4: after the wait and the PASS, routing merges ─────────────────────────
# The labels the verbs leave are replayed from the gh log; the collect stage is
# what the router makes of them (a blocked label wins, else the PR is merge-ready).
fresh
verdict "$BODY_CP"
STUB_PR_HEAD_SHA="$SHA_B" approve
PR_LABELS="$(labels_after 9 pipeline:review)"
ISSUE_LABELS="$(labels_after 5 '')"
STAGE=merge
case ",$PR_LABELS,$ISSUE_LABELS," in *,pipeline:blocked,*) STAGE=blocked ;; esac
reset_stubs; LEASE_RESET
printf '{"prs":[{"n":9,"issue":5,"head":"b7c1","owner":false,"stage":"%s"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' \
  "$STAGE" > "$STUB_DIR/collect.json"
NEXT_OUT="$(bash "$RUN" next 2>/dev/null)"
assert_eq "action=merge pr=9 issue=5" "$NEXT_OUT" "AC4 the routing pass after the ci-pending wait and a PASS answers the merge route"
assert_not_contains "$NEXT_OUT" "reason=blocked" "AC4 the routing pass does not answer wait reason=blocked"

# ── AC5 (same): a defect FAIL still blocks and goes to the developer ─────────
fresh
verdict "$BODY_DEFECT"
assert_eq "2" "$(blocked_adds)" "AC5 a QA FAIL for a failed criterion adds pipeline:blocked on the PR and the issue"
assert_contains "$(cat "$GH_LOG")" "-X DELETE -H Accept: application/vnd.github+json repos/acme/widget/issues/9/labels/pipeline%3Areview" "AC5 the defect FAIL still removes pipeline:review"
unset STUB_COMMENT_STORE STUB_PR_LABELS_JSON
reset_stubs; LEASE_RESET
cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": true}, "ci": {"parallel_with_qa": true}, "merge": {"required_checks": ["test (ubuntu-latest)"]}, "verify": {"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900}}'
printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "- [ ] AC1 the suite is green (prose: fixture)", "state": "open"}' > "$STUB_DIR/view-issue.9"
printf '{"prs": [{"n": 12, "issue": 9, "head": "a4f9", "owner": false, "stage": "qa"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}' > "$STUB_DIR/collect.json"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
printf ready > "$STUB_DIR/pr-is-draft.12"; printf 1 > "$STUB_DIR/pr-is-draft.12.rc"
printf 'https://github.com/acme/widget/pull/12\nfixed it\n' > "$STUB_DIR/message.developer"
printf 'FAIL: AC2 rejects an expired token: got 200\n' > "$STUB_DIR/message.qa.1"
printf 'PASS: criteria met\n' > "$STUB_DIR/message.qa.2"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 1
assert_contains "$(journal)" "agent developer" "AC5 a QA FAIL for a failed criterion dispatches the developer" "$OUT"
assert_contains "$(journal)" "vcs record-attempt 9 qa --pr 12" "AC5 the defect FAIL records its attempt"

finish
