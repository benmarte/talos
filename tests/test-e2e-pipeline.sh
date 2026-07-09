#!/usr/bin/env bash
# E2E pipeline simulation: install Talos into a fresh repo, then drive one
# issue through the full lifecycle the orchestrator skill prescribes —
# labels → validator → pm → developer/PR → qa → reviewer → security → docs →
# merge → close — using the INSTALLED scripts against stubbed gh/curl.
# Asserts the externally visible protocol: gh calls, chat payloads, threading.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

VCS=".claude/talos/scripts/pipeline-vcs.sh"
NOTIFY=".claude/talos/scripts/pipeline-notify.sh"
STATUS=".claude/talos/scripts/pipeline-status.sh"
export PIPELINE_THREAD_STATE="$SANDBOX/threads.json"
export SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C0TEST
export STUB_ISSUE_TITLE="Fix login crash" STUB_PR_TITLE="fix: guard null session"
export PIPELINE_ISSUE_TITLE="$STUB_ISSUE_TITLE"

cat > .claude-pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF

N=42

# ── Stage 0: bootstrap + dispatch ────────────────────────────────────────────
bash .claude/talos/scripts/bootstrap-labels.sh acme/widget >/dev/null
bash "$NOTIFY" dispatched "#$N" "kickoff" "$N" >/dev/null 2>&1

# ── Stage 1: validator confirms ──────────────────────────────────────────────
bash "$VCS" label-issue "$N" --add pipeline:confirmed --remove pipeline:ready >/dev/null 2>&1
bash "$VCS" comment-issue "$N" "**Agent:** validator — CONFIRMED: crash reproducible" >/dev/null 2>&1
bash "$STATUS" "$N" "In progress" >/dev/null 2>&1
bash "$NOTIFY" validator "#$N" "CONFIRMED: crash reproducible in auth.js:88" "$N" >/dev/null 2>&1

# ── Stage 2: pm spec, developer opens PR ─────────────────────────────────────
bash "$VCS" comment-issue "$N" "spec: guard null session in auth.js" >/dev/null 2>&1
bash "$VCS" label-issue "$N" --add pipeline:dev --remove pipeline:confirmed >/dev/null 2>&1
echo "Closes #$N" > pr-body.md
bash "$VCS" create-pr "fix/issue-$N" "fix: guard null session" pr-body.md >/dev/null 2>&1
PIPELINE_PR=9 PIPELINE_PR_TITLE="$STUB_PR_TITLE" \
  bash "$NOTIFY" pr-opened "#$N" "PR https://github.com/acme/widget/pull/9 opened" "$N" >/dev/null 2>&1

# ── Stage 3: qa / reviewer / security / docs sign off on the PR ──────────────
bash "$VCS" comment-pr 9 "QA: PASS — all acceptance criteria verified" >/dev/null 2>&1
bash "$VCS" label-pr 9 --add qa:pass >/dev/null 2>&1
bash "$VCS" approve-pr 9 "LGTM" >/dev/null 2>&1
bash "$VCS" label-pr 9 --add review:approved --add security:approved --add docs:done >/dev/null 2>&1
bash "$NOTIFY" qa "#$N" "PASS: criteria verified" "$N" >/dev/null 2>&1

# ── Stage 4: merge gates, then merge + close ─────────────────────────────────
# Reconciliation verb: a fresh session must be able to find the PR for #42
adopt="$(bash "$VCS" find-pr "$N")"
assert_contains "$adopt" '"headRefName": "fix/issue-42-guard"' \
  "e2e: find-pr locates the in-flight PR for adoption"

# Forbidden-files gate passes for a clean PR, blocks a secret-touching one
bash "$VCS" check-pr-files 9 >/dev/null 2>&1 \
  && pass "e2e: forbidden-files gate passes clean PR" \
  || fail "e2e: forbidden-files gate passes clean PR"
STUB_PR_FILES=".env" bash "$VCS" check-pr-files 9 >/dev/null 2>&1 \
  && fail "e2e: forbidden-files gate blocks .env" \
  || pass "e2e: forbidden-files gate blocks .env"

bash "$VCS" merge-pr 9 >/dev/null 2>&1
bash "$VCS" close-issue "$N" "resolved by PR #9" >/dev/null 2>&1
bash "$STATUS" "$N" "Done" >/dev/null 2>&1
PIPELINE_PR=9 bash "$NOTIFY" merged "#$N" "PR #9 merged" "$N" >/dev/null 2>&1
bash "$NOTIFY" issue-closed "#$N" "item resolved" "$N" >/dev/null 2>&1

# ── Assertions: VCS side ─────────────────────────────────────────────────────
log="$(cat "$GH_LOG")"
# NB: real-run label-issue goes through eval, so the shell strips the quotes
assert_contains "$log" "issue edit $N --add-label pipeline:confirmed --remove-label pipeline:ready" \
  "e2e: label state machine ready→confirmed"
assert_contains "$log" "issue comment $N --body **Agent:** validator — CONFIRMED: crash reproducible" \
  "e2e: validator findings comment lands on the issue"
assert_contains "$log" "pr create --base main --head fix/issue-$N" "e2e: PR opened against base branch"
assert_contains "$log" "issue comment 9 --body QA: PASS" "e2e: QA verdict lands on the PR"
assert_contains "$log" "pr review 9 --approve" "e2e: reviewer approval posted"
assert_contains "$log" "pr merge 9 --squash --delete-branch" "e2e: PR squash-merged"
assert_contains "$log" "issue close $N" "e2e: issue closed at the end"
assert_contains "$log" "project item-edit --id ITEM_42" "e2e: board status updated"

# ── Assertions: chat side — one thread, links, complete conversation ─────────
payloads="$(cut -f2 "$CURL_LOG")"
roots="$(grep -c -v thread_ts "$CURL_LOG" || true)"
assert_eq "1" "$roots" "e2e: exactly one root post — all later events threaded"
assert_contains "$payloads" '"thread_ts": "1111.2222"' "e2e: replies reference the dispatch anchor"
assert_contains "$payloads" "New comment by validator agent on #$N: $STUB_ISSUE_TITLE" \
  "e2e: validator relay rendered from template"
assert_contains "$payloads" "<https://github.com/acme/widget/issues/$N|" "e2e: issue link present in thread"
assert_contains "$payloads" "<https://github.com/acme/widget/pull/9|" "e2e: PR link present in thread"
assert_contains "$payloads" "merged, work complete" "e2e: merged template rendered"
assert_contains "$payloads" "closed" "e2e: issue-closed event announced"

# Message count: dispatched, validator, pr-opened, qa, merged, issue-closed = 6
assert_eq "6" "$(wc -l < "$CURL_LOG" | tr -d ' ')" "e2e: six chat messages, no dupes or drops"

finish
