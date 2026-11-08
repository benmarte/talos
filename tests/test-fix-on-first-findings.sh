#!/usr/bin/env bash
# test-fix-on-first-findings.sh -- `roles.fix_on_first_findings` (#833, part 3
# of #826): QA is ordered after the three review roles on every PR, so one fix
# round runs on the reviewer, security and adversarial findings before QA has
# spent a run, and QA then verifies the fix head once. Default off.
#   AC1  next_stage (through `pipeline-status-file.sh collect`): key on, a
#        non-draft PR walks docs, reviewer, security, adversarial, then qa
#   AC2  `done` answers next=batch on a non-draft PR and the run finishes the
#        review roles, then one fix round, with no QA dispatch before it
#   AC3  after the fix push QA is dispatched once at the fix head
#   AC4  stamps stay bound to the head SHA (check-approval-sha, gate merge)
#   AC5  key absent or false: today's order; a draft PR is the same either way
#   AC6  the defaults row and docs/reference.md name the key
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
# The run fixture (the sandbox, the stubbed scripts dir GS, rn, journal) is
# tests/talos-run-sections.sh's; none of its parts runs here.
TALOS_RUN_PART=833 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

# ── AC1, AC3, AC5: the stage order, through the real collect ─────────────────
PARENT="$SANDBOX/collect"
FX="$PARENT/fx"
SCR="$PARENT/scripts"
mkdir -p "$FX" || exit 1
export SF_FX="$FX"
cp -R "$TALOS_ROOT/scripts" "$SCR"
cat > "$SCR/pipeline-vcs.sh" <<'TALOS_stubvcs833Kq7WmXz'
#!/usr/bin/env bash
# Verb-level stub: a read verb answers from $SF_FX, any other verb is a WRITE.
FX="${SF_FX:?}"
verb="${1:-}"; shift
rc_of() { if [ -f "$FX/$1" ]; then cat "$FX/$1"; else echo "${2:-0}"; fi; }
case "$verb" in
  list-prs) cat "$FX/prs.json"; exit 0 ;;
  list-issues) cat "$FX/issues.json"; exit 0 ;;
  list-needs-owner) echo '[]'; exit 0 ;;
  pr-head) cat "$FX/head.$1"; exit 0 ;;
  check-approval-sha)
    [ "${2:-}" != "--evidence-list" ] || exit 0
    [ -f "$FX/stale.$1" ] && cat "$FX/stale.$1"
    exit "$(rc_of "stale.$1.rc" 0)" ;;
  pr-checks-required) exit 0 ;;
  pr-is-draft)
    rc="$(rc_of "draft.$1.rc" 1)"
    [ "$rc" = 0 ] && echo draft
    [ "$rc" = 1 ] && echo ready
    exit "$rc" ;;
  current-user) exit 1 ;;
  *) printf 'WRITE %s\n' "$verb" >> "$FX/writes.log"; exit 99 ;;
esac
TALOS_stubvcs833Kq7WmXz

CASE_PRS=(); CASE_ISS=(); CASE_N=10; CASE_WANT=()
case_reset() { rm -rf "${FX:?}"/*; CASE_PRS=(); CASE_ISS=(); CASE_N=10; CASE_WANT=(); }
case_add() {  # <want-stage> <label> <pr labels, comma list> [stale lines] [draft: 0|1]
  local n="$CASE_N" l out="" IFS=,
  for l in $3; do out="${out:+$out,}{\"name\":\"$l\"}"; done
  CASE_PRS+=("{\"number\":$n,\"title\":\"PR $n\",\"headRefName\":\"fix/issue-$n-x\",\"baseRefName\":\"main\",\"isCrossRepository\":false,\"labels\":[$out]}")
  CASE_ISS+=("{\"number\":$n,\"title\":\"Issue $n\",\"labels\":[],\"body\":\"\"}")
  printf '%040d\n' "$n" > "$FX/head.$n"
  if [ -n "${4:-}" ]; then printf '%s\n' "$4" > "$FX/stale.$n"; echo 1 > "$FX/stale.$n.rc"; fi
  [ "${5:-}" != 1 ] || echo 0 > "$FX/draft.$n.rc"
  CASE_WANT+=("$n=${1#*=}:$2"); CASE_N=$((n + 1))
}
case_run() {  # <name>: collect once, one assertion per case
  local IFS=, w stages
  printf '[%s]' "${CASE_PRS[*]}" > "$FX/prs.json"
  printf '[%s]' "${CASE_ISS[*]}" > "$FX/issues.json"
  stages="$(bash "$SCR/pipeline-status-file.sh" collect 2>"$PARENT/err" | python3 -I -c '
import json, sys
print(" ".join("%d=%s" % (p["n"], p["stage"]) for p in json.load(sys.stdin)["prs"]))')"
  for w in "${CASE_WANT[@]}"; do
    assert_eq "${w%%:*}" "$(printf '%s\n' "$stages" | tr ' ' '\n' | grep "^${w%%=*}=")" "$1: ${w#*:}"
  done
  assert_eq "" "$(cat "$FX/writes.log" 2>/dev/null)" "$1: collect made no write"
}
# stage cases name the PR (first field of the id) so a failure reads at once
stage_cfg() {  # <roles members after docs:false> <pr.draft> [pr extra]
  printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main", "roles": {"docs": false%s}, "pr": {"draft": %s%s}}\n' \
    "$1" "$2" "${3:-}" > "$SANDBOX/talos.pipeline.json"
}
SEC_STALE=$'stale role=qa label=qa:pass'
REV_STALE=$'stale role=reviewer label=review:approved'

# AC1: key on, non-draft: the review roles first, QA after them.
stage_cfg ', "fix_on_first_findings": true, "adversarial": true' false
case_reset
case_add 10=reviewer "AC1 no approval labels -> reviewer, not qa" ""
case_add 11=security "AC1 reviewer approved -> security" "review:approved"
case_add 12=adversarial "AC1 reviewer and security approved -> adversarial" "review:approved,security:approved"
case_add 13=qa "AC1 the three review roles fresh, qa:pass missing -> qa" "review:approved,security:approved,adversarial:approved"
case_add 14=merge "AC1 every role approved -> merge" "review:approved,security:approved,adversarial:approved,qa:pass"
# AC3: after the fix push the stamps are stale; the review roles re-run, then qa once.
case_add 15=reviewer "AC3 reviewer stale at the fix head -> reviewer first, though qa:pass is fresh" "review:approved,security:approved,adversarial:approved,qa:pass" "$REV_STALE"
case_add 16=qa "AC3 review roles re-approved at the fix head, qa:pass stale -> qa" "review:approved,security:approved,adversarial:approved,qa:pass" "$SEC_STALE"
case_add 17=qa "AC3 review roles re-approved at the fix head, qa:pass missing -> qa" "review:approved,security:approved,adversarial:approved"
case_run "key on"
# AC5: the draft order is the same with the key on (qa stays out of the walk).
stage_cfg ', "fix_on_first_findings": true' true
case_reset
case_add 10=reviewer "AC5 key on, draft, no labels -> reviewer" "" "" 1
case_add 11=ready "AC5 key on, draft, review roles fresh -> ready (no qa in the draft walk)" "review:approved,security:approved" "" 1
case_run "key on, draft"
stage_cfg ', "fix_on_first_findings": true' true ', "ready_gate": "qa-local"'
case_reset
case_add 10=qa "AC5 key on, draft, qa-local gate, review roles fresh -> qa last" "review:approved,security:approved" "" 1
case_run "key on, draft, qa-local"

# AC5: key absent, then false: qa first on a non-draft PR, the draft order as before.
for _k in "" ', "fix_on_first_findings": false'; do
  _w="absent"; [ -z "$_k" ] || _w="false"
  stage_cfg "$_k" false
  case_reset
  case_add 10=qa "AC5 key $_w, non-draft, no labels -> qa first" ""
  case_add 11=reviewer "AC5 key $_w, non-draft, qa:pass -> reviewer" "qa:pass"
  case_add 12=merge "AC5 key $_w, non-draft, all approved -> merge" "qa:pass,review:approved,security:approved"
  case_run "key $_w"
  stage_cfg "$_k" true
  case_reset
  case_add 10=reviewer "AC5 key $_w, draft, no labels -> reviewer" "" "" 1
  case_add 11=ready "AC5 key $_w, draft, review roles fresh -> ready" "review:approved,security:approved" "" 1
  case_run "key $_w, draft"
done

# ── AC2, AC3, AC5: `done` and the run ────────────────────────────────────────
rev_cfg() {  # $1 = extra roles members
  printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": false, "reviewer": true, "security": true, "adversarial": true%s}, "pr": {"draft": false}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
    "${1:-}" > "$SANDBOX/talos.pipeline.json"
}
rev_collect() {  # $1 = the PR's collect stage
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"%s"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' \
    "$1" > "$STUB_DIR/collect.json"
}
rev_fixture() {  # $1 = extra roles members: a non-draft PR at the reviewer stage, the fix round pushes
  reset_stubs
  LEASE_RESET
  rev_cfg "$1"
  rev_collect reviewer
  printf '{"labels": [], "state": "open"}' > "$STUB_DIR/view-pr.12"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  printf 'https://github.com/acme/widget/pull/12\nfixed the findings\n' > "$STUB_DIR/message.developer"
  printf 'CHANGES: 1 findings\n1. scripts/x.sh:12 asserts nothing (the-reviewer-finding)\n' > "$STUB_DIR/message.reviewer.1"
  printf 'CLEAR: nothing exploitable\n' > "$STUB_DIR/message.security.1"
  printf 'FINDINGS: 1 findings\n1. scripts/y.sh:3 leaks (the-adversarial-finding)\n' > "$STUB_DIR/message.adversarial.1"
  printf 'PASS: every criterion verified\n' > "$STUB_DIR/message.qa.1"
  # The fix round pushes a new head; the collect then names qa (the review roles
  # re-approved at the fix head) as the next stage.
  cat > "$STUB_DIR/hook.developer.1" <<'HOOK'
printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"
printf '{"prs":[{"n":12,"issue":9,"head":"b4f9","owner":false,"stage":"qa"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$d/collect.json"
HOOK
}
rev_order() { grep -oE 'agent [a-z]+|vcs record-attempt 9 [a-z]+ --pr 12|label-pr 12 --remove pipeline:blocked' "$STUB_DIR/journal" | tr '\n' '>' | sed 's/>$//'; }
UNBLOCK="label-pr 12 --remove pipeline:blocked"
ON=', "fix_on_first_findings": true'

# AC2: `done` answers next=batch for a non-draft PR with the key on.
reset_stubs
rev_cfg "$ON"
printf 'CHANGES: 1 findings\n' > "$SANDBOX/sum"
_done_next() { bash "$RUN" done "$1" --issue 9 --pr 12 --verdict "$2" --summary-file "$SANDBOX/sum" 2>/dev/null | grep '^next=' | tail -n 1; }
assert_eq "next=batch" "$(_done_next reviewer CHANGES)" "AC2 key on, non-draft: done reviewer CHANGES answers next=batch"
assert_eq "next=batch" "$(_done_next security FINDINGS)" "AC2 key on, non-draft: done security FINDINGS answers next=batch"
assert_eq "next=batch" "$(_done_next adversarial FINDINGS)" "AC2 key on, non-draft: done adversarial FINDINGS answers next=batch"
assert_eq "next=fix-round stage=qa" "$(_done_next qa FAIL)" "AC2 key on: a QA FAIL is still its own fix round"
rev_cfg ""
assert_eq "next=fix-round stage=reviewer" "$(_done_next reviewer CHANGES)" "AC5 key absent, non-draft: done reviewer CHANGES answers fix-round stage=reviewer"
rev_cfg ', "fix_on_first_findings": false'
assert_eq "next=fix-round stage=reviewer" "$(_done_next reviewer CHANGES)" "AC5 key false, non-draft: done reviewer CHANGES answers fix-round stage=reviewer"

# AC2 and AC3: reviewer CHANGES with QA unreported: the review roles finish, one
# fix round, then QA once at the fix head.
rev_fixture "$ON"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 2
assert_eq "0" "$RC" "AC2 the run exits 0"
assert_eq "agent reviewer>agent security>agent adversarial>vcs record-attempt 9 reviewer --pr 12>$UNBLOCK>agent developer>agent qa" "$(rev_order)" \
  "AC2 reviewer, the other review roles, gate fix-round, the unblock, the developer; AC3 then qa at the fix head"
assert_eq "1" "$(journal | grep -c '^agent developer$')" "AC2 one developer fix round for every finding"
assert_eq "1" "$(journal | grep -c '^agent qa$')" "AC3 qa is dispatched once, at the fix head"
assert_eq "0" "$(rev_order | sed 's/>agent developer.*//' | grep -c 'agent qa')" "AC2 no qa dispatch before the fix round"

# AC5: the key off keeps today's non-draft round: a reviewer CHANGES is a fix round at once.
rev_fixture ""
TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 1
assert_eq "agent reviewer>vcs record-attempt 9 reviewer --pr 12>$UNBLOCK>agent developer" "$(rev_order)" \
  "AC5 key absent: reviewer CHANGES goes straight to the fix round, no other review role first"

# ── AC4: stamps stay bound to the head SHA ───────────────────────────────────
# A stamp at an earlier head is refused (the real check-approval-sha) and the
# merge gate sends it back; the key does not touch either.
git config user.email "test@talos.invalid"
git config user.name "talos-test"
printf 'one\n' > feature.txt; git add feature.txt; git commit -q -m one
SHA_OLD="$(git rev-parse HEAD)"
printf 'two\n' > feature.txt; git add feature.txt; git commit -q -m two
SHA_NEW="$(git rev-parse HEAD)"
rev_cfg "$ON"
_c="[{\"body\":\"approval\\n<!-- talos:approval sha=$SHA_OLD role=qa -->\"}]"
_out="$(STUB_PR_HEAD_SHA="$SHA_NEW" STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]' STUB_PR_COMMENTS_JSON="$_c" \
  bash "$TALOS_ROOT/scripts/pipeline-vcs.sh" check-approval-sha 9 --stale-list 2>&1)"; _rc=$?
assert_eq "1" "$_rc" "AC4 key on: a qa:pass stamped at an earlier head is refused (exit 1)"
assert_contains "$_out" "stale role=qa" "AC4 key on: the stale stamp is named"
_c="[{\"body\":\"approval\\n<!-- talos:approval sha=$SHA_NEW role=qa -->\"}]"
STUB_PR_HEAD_SHA="$SHA_NEW" STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]' STUB_PR_COMMENTS_JSON="$_c" \
  bash "$TALOS_ROOT/scripts/pipeline-vcs.sh" check-approval-sha 9 >/dev/null 2>&1
assert_eq "0" "$?" "AC4 key on: a stamp at the head is accepted"
reset_stubs
rev_cfg "$ON"
printf '{"labels":[{"name":"qa:pass"},{"name":"review:approved"},{"name":"security:approved"},{"name":"adversarial:approved"}]}' > "$STUB_DIR/view-pr.12"
printf 'stale role=qa label=qa:pass' > "$STUB_DIR/check-approval-sha.out"; printf 1 > "$STUB_DIR/check-approval-sha.rc"
_gate="$(bash "$RUN" gate merge 12 9 2>/dev/null | tr '\n' ' ')"
assert_contains "$_gate" "verdict=redispatch" "AC4 key on: gate merge refuses a stale qa:pass"
assert_contains "$_gate" "reason=stale-approvals" "AC4 key on: gate merge names stale-approvals"

# ── AC6: the defaults row and the docs ───────────────────────────────────────
assert_eq "1" "$(grep -c "^roles.fix_on_first_findings$(printf '\t')bool$(printf '\t')false$(printf '\t')-$(printf '\t')-$(printf '\t')any\$" "$TALOS_ROOT/scripts/pipeline-defaults.sh")" \
  "AC6 pipeline-defaults.sh has the row roles.fix_on_first_findings (bool, default false, any)"
assert_contains "$(grep '^| `roles.fix_on_first_findings`' "$TALOS_ROOT/docs/reference.md")" '| bool | `false` | - | any |' \
  "AC6 docs/reference.md config table lists the key (bool, false)"
_sec="$(awk '/^### Draft PRs/{f=1} f&&/fix_on_first_findings/{print} /^### /&&!/Draft PRs/{if(f)exit}' "$TALOS_ROOT/docs/reference.md")"
assert_contains "$_sec" "roles.fix_on_first_findings" "AC6 the stage-order section names the key"
assert_contains "$_sec" "docs, reviewer, security" "AC6 the stage-order section gives the order the key makes"

finish
