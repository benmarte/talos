#!/usr/bin/env bash
# test-qa-draft-ready.sh -- QA is never dispatched for a draft PR whose CI cannot
# run (#1002): under pr.draft and verify.qa_mode ci, a `dispatch stage=qa` for a
# PR that is still a draft marks it ready first (when its approvals are current)
# or routes it to the stage that is stale.
#   AC1  a draft PR with current approvals is marked ready, then QA's prompt is rendered
#   AC2  a draft PR with a stale approval goes to that stage, not to QA
#   AC3  a failed ready-pr stops the run with ready-pr-failed and no QA
#   AC4  (same) a PR that is already ready goes straight to QA with no ready-pr
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
ERR="$SANDBOX/stderr"

# A copied scripts dir with a journaling provider stub: <key> is the verb of
# pipeline-vcs.sh, else the script's name; $STUB_DIR/<key>.{out,err,rc} is what
# it answers (rc 0 by default) and hook.<key> is a snippet sourced on the call.
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR" "$SANDBOX/templates/prompts"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cp -R "$TALOS_ROOT/templates/prompts/." "$SANDBOX/templates/prompts/"
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
if [ -f "$d/$key.$a1.out" ]; then cat "$d/$key.$a1.out"
elif [ -f "$d/$key.$a1" ]; then cat "$d/$key.$a1"
elif [ -f "$d/$key.out" ]; then cat "$d/$key.out"
elif [ -f "$d/$key" ]; then cat "$d/$key"; fi
rc=0
if [ -f "$d/$key.$a1.rc" ]; then rc="$(cat "$d/$key.$a1.rc")"; elif [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
cat > "$GS/pipeline-agent.sh" <<'TALOS_stubagentQf7Hx2Lm'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
role="$1"
cat > "$d/agent.stdin"
printf "agent %s\n" "$role" >> "$d/journal"
if [ -f "$d/message.$role" ]; then cat "$d/message.$role"; fi
exit 0
TALOS_stubagentQf7Hx2Lm
# collect.json is the state `next` reads; once the QA-dispatch guard has asked for
# the PR's draft state (hook.pr-is-draft touches $d/live) a collect answers
# collect.live.json, the state the resolver computes for the PR as it is now.
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusBw3Nk9Rc'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
printf 'status-file collect\n' >> "$d/journal"
f="$d/collect.json"
if [ -f "$d/live" ] && [ -f "$d/collect.live.json" ]; then f="$d/collect.live.json"; fi
printf '%s' "$(cat "$f" 2>/dev/null || echo '{}')"
TALOS_stubstatusBw3Nk9Rc

RUN="$GS/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
LEASE="$SANDBOX/.git/talos-lease.ledger"
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
rn() { OUT="$(bash "$RUN" run "$@" 2>"$ERR")"; RC=$?; }
qa_count() { journal | grep -c '^agent qa$'; }

# fixture <is-draft 1|0>: PR 12 / issue 9 whose collected stage says `qa` (the
# state `next` read); a draft PR answers pr-is-draft rc 0 and the ready verb
# flips the answer. The live collect says every approval is current (`ready`).
fixture() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$LEASE" "${LEASE:?}.lock.d"
  printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": true}, "verify": {"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900}, "merge": {"required_checks": ["test (ubuntu-latest)"]}, "ci": {"parallel_with_qa": false}}' \
    > "$SANDBOX/talos.pipeline.json"
  printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:review"}], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9"
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"qa"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' \
    > "$STUB_DIR/collect.json"
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"ready"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' \
    > "$STUB_DIR/collect.live.json"
  printf 'PASS: verified\n' > "$STUB_DIR/message.qa"
  printf 'APPROVED\n' > "$STUB_DIR/message.reviewer"
  printf '{"labels": [{"name": "docs:done"}, {"name": "review:approved"}, {"name": "security:approved"}], "state": "open"}' > "$STUB_DIR/view-pr.12"
  printf 0 > "$STUB_DIR/check-approval-sha.rc"
  if [ "$1" -eq 1 ]; then
    printf draft > "$STUB_DIR/pr-is-draft.12"
    printf 0 > "$STUB_DIR/pr-is-draft.12.rc"
    printf 'printf ready > "$d/pr-is-draft.12"; printf 1 > "$d/pr-is-draft.12.rc"\n' > "$STUB_DIR/hook.ready-pr"
  else
    printf ready > "$STUB_DIR/pr-is-draft.12"
    printf 1 > "$STUB_DIR/pr-is-draft.12.rc"
  fi
  printf 'touch "$d/live"\n' > "$STUB_DIR/hook.pr-is-draft"
}
# The journal line number of the first line matching <pattern>, 0 when none.
pos() { journal | grep -nE -m1 "$1" | cut -d: -f1 | grep . || echo 0; }

# ── AC1: a draft PR with current approvals is marked ready, then QA runs ─────
fixture 1
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_contains "$(journal)" "vcs ready-pr 12" "AC1 the draft PR is marked ready"
assert_eq "1" "$(qa_count)" "AC1 QA is dispatched once"
RP="$(pos '^vcs ready-pr 12')"; QA="$(pos '^agent qa$')"
assert_eq "yes" "$([ "$RP" -gt 0 ] && [ "$QA" -gt "$RP" ] && echo yes || echo no)" "AC1 ready-pr comes before the QA dispatch"
assert_contains "$(cat "$STUB_DIR/agent.stdin" 2>/dev/null)" "qa" "AC1 QA's prompt is rendered after ready-pr (the agent received it)"
assert_eq "yes" "$([ "$(pos '^vcs pr-checks-required 12')" -gt "$RP" ] && echo yes || echo no)" "AC1 the CI wait follows ready-pr"

# ── AC2: a stale approval routes to that stage, not to QA ────────────────────
fixture 1
printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"reviewer"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' \
  > "$STUB_DIR/collect.live.json"
printf 1 > "$STUB_DIR/check-approval-sha.rc"
printf 'stale role=reviewer label=review:approved approved=aaaaaaa head=bbbbbbb\n' > "$STUB_DIR/check-approval-sha.out"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 2
assert_eq "0" "$(qa_count)" "AC2 QA is not dispatched on a draft with a stale approval"
assert_eq "1" "$(journal | grep -c '^agent reviewer$')" "AC2 the stale reviewer stage is dispatched instead"
assert_not_contains "$(journal)" "vcs ready-pr" "AC2 a draft with a stale approval is not marked ready"

# ── AC3: a failed ready-pr stops the run, no QA ──────────────────────────────
fixture 1
printf 1 > "$STUB_DIR/ready-pr.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 2
assert_contains "$OUT" "stop reason=ready-pr-failed" "AC3 a ready-pr failure stops with ready-pr-failed"
assert_eq "0" "$(qa_count)" "AC3 QA is not dispatched after a ready-pr failure"

# ── AC4 (same): a ready PR dispatches QA with no ready-pr ────────────────────
fixture 0
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "1" "$(qa_count)" "AC4 a PR that is already ready is dispatched to QA"
assert_not_contains "$(journal)" "vcs ready-pr" "AC4 a ready PR gets no ready-pr call"

finish
