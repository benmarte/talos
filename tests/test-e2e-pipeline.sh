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

VCS="$HOME/.talos/scripts/pipeline-vcs.sh"
NOTIFY="$HOME/.talos/scripts/pipeline-notify.sh"
STATUS="$HOME/.talos/scripts/pipeline-status.sh"
export PIPELINE_THREAD_STATE="$SANDBOX/threads.json"
export SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C0TEST
export STUB_ISSUE_TITLE="Fix login crash" STUB_PR_TITLE="fix: guard null session"
export PIPELINE_ISSUE_TITLE="$STUB_ISSUE_TITLE"

cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF

N=42

# ── Stage 0: bootstrap + dispatch ────────────────────────────────────────────
bash "$HOME/.talos/scripts/bootstrap-labels.sh" acme/widget >/dev/null
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

# ── Step 1.6: epic auto-close sweep gate (#168) ──────────────────────────────
# An epic whose children have all closed must NOT auto-close while its own
# `- [ ]` acceptance boxes are still unticked; it gets pipeline:epic-children-done
# and a comment instead, and stays open. An epic with all boxes ticked (or no
# checkboxes) still closes exactly as before.

# Epic #100: all sub-issues closed, but the epic's own body has an unticked box.
: > "$GH_LOG"
export STUB_EPIC_BODY='Epic description.

- [ ] Bring the full stack up and prove it communicates'
bash "$VCS" check-epic-acceptance 100 >/dev/null 2>&1
sweep_rc=$?
if [ "$sweep_rc" -ne 0 ]; then
  bash "$VCS" label-issue 100 --add pipeline:epic-children-done >/dev/null 2>&1
  bash "$VCS" comment-issue 100 "All sub-issues are closed, but this epic's own acceptance criteria still have unticked boxes -- needs human review:
- Bring the full stack up and prove it communicates" >/dev/null 2>&1
fi
sweep_log="$(cat "$GH_LOG")"
assert_contains "$sweep_log" "issue edit 100 --add-label pipeline:epic-children-done" \
  "e2e: epic with unticked boxes gets pipeline:epic-children-done"
assert_contains "$sweep_log" "issue comment 100" \
  "e2e: epic with unticked boxes gets a comment naming what's outstanding"
assert_not_contains "$sweep_log" "issue close 100" \
  "e2e: epic with unticked boxes is NOT closed"

# Epic #200: all sub-issues closed, and every acceptance box is ticked.
: > "$GH_LOG"
export STUB_EPIC_BODY='Epic description.

- [x] Bring the full stack up and prove it communicates'
bash "$VCS" check-epic-acceptance 200 >/dev/null 2>&1
sweep_rc=$?
if [ "$sweep_rc" -eq 0 ]; then
  bash "$VCS" close-issue 200 "All sub-issues resolved." >/dev/null 2>&1
fi
sweep_log="$(cat "$GH_LOG")"
assert_contains "$sweep_log" "issue close 200" \
  "e2e: epic with all boxes ticked still closes"
assert_not_contains "$sweep_log" "epic-children-done" \
  "e2e: epic with all boxes ticked does not get pipeline:epic-children-done"

# Epic #300: all sub-issues closed, and the epic has no checkboxes at all.
: > "$GH_LOG"
export STUB_EPIC_BODY='Epic description with no checklist at all.'
bash "$VCS" check-epic-acceptance 300 >/dev/null 2>&1
sweep_rc=$?
if [ "$sweep_rc" -eq 0 ]; then
  bash "$VCS" close-issue 300 "All sub-issues resolved." >/dev/null 2>&1
fi
sweep_log="$(cat "$GH_LOG")"
assert_contains "$sweep_log" "issue close 300" \
  "e2e: epic with no checkboxes still closes"

# ── Idempotency across repeated sweeps (PR #190 reviewer finding) ───────────
# The label+comment action must fire exactly once per epic, not on every
# sweep, while check-epic-acceptance keeps running every sweep so an epic
# whose boxes get ticked later still auto-closes -- and the flag label gets
# removed on that close (mirrors the "does NOT yet carry pipeline:ready"
# guard idiom Step 1.7 already uses).
epic400_labeled=false

sweep_epic_400() {
  local items rc
  items="$(bash "$VCS" check-epic-acceptance 400 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    bash "$VCS" close-issue 400 "All sub-issues resolved." >/dev/null 2>&1
    if [ "$epic400_labeled" = "true" ]; then
      bash "$VCS" label-issue 400 --remove pipeline:epic-children-done >/dev/null 2>&1
      epic400_labeled=false
    fi
  else
    if [ "$epic400_labeled" != "true" ]; then
      bash "$VCS" label-issue 400 --add pipeline:epic-children-done >/dev/null 2>&1
      bash "$VCS" comment-issue 400 "All sub-issues are closed, but this epic's own acceptance criteria still have unticked boxes -- needs human review:
- Bring the full stack up and prove it communicates" >/dev/null 2>&1
      epic400_labeled=true
    fi
  fi
}

: > "$GH_LOG"
export STUB_EPIC_BODY='Epic description.

- [ ] Bring the full stack up and prove it communicates'
sweep_epic_400   # sweep 1: unticked -> labels + comments
sweep_epic_400   # sweep 2: still unticked, already labeled -> must not repeat

sweep_log="$(cat "$GH_LOG")"
label_calls="$(grep -c "issue edit 400 --add-label pipeline:epic-children-done" <<<"$sweep_log")"
comment_calls="$(grep -c "issue comment 400" <<<"$sweep_log")"
assert_eq "1" "$label_calls" \
  "e2e: two sweeps of a still-unticked epic add pipeline:epic-children-done exactly once"
assert_eq "1" "$comment_calls" \
  "e2e: two sweeps of a still-unticked epic comment exactly once"

# Sweep 3: a human ticks the box since the last sweep -> the epic auto-closes
# and the flag label added earlier is removed.
: > "$GH_LOG"
export STUB_EPIC_BODY='Epic description.

- [x] Bring the full stack up and prove it communicates'
sweep_epic_400
sweep_log="$(cat "$GH_LOG")"
assert_contains "$sweep_log" "issue close 400" \
  "e2e: epic closes once its boxes are ticked on a later sweep"
assert_contains "$sweep_log" "issue edit 400 --remove-label pipeline:epic-children-done" \
  "e2e: pipeline:epic-children-done is removed once the epic closes"

# ── Untrusted checklist text must never reach a shell command literal ───────
# (PR #190 security finding, HIGH). check-epic-acceptance's stdout is
# unescaped text taken straight from the epic body -- reporter-controlled.
# The sweep must capture it into a variable and render it through the
# templates/comments recipe, then pass the fully-rendered variable to
# comment-issue -- never splice the item text into a command string.
: > "$GH_LOG"
rm -f INJECTED_MARKER
export STUB_EPIC_BODY='Epic description.

- [ ] " ; touch INJECTED_MARKER #'
items="$(bash "$VCS" check-epic-acceptance 500 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  TMPL="$HOME/.talos/templates/comments/epic-acceptance-pending.md"
  comment_body="$(
    HEADER='**Agent:** orchestrator (talos)' DETAILS="$items" \
    python3 -c "
import os, string, sys
with open(sys.argv[1]) as f:
    t = string.Template(f.read())
print(t.safe_substitute(os.environ).strip())
" "$TMPL"
  )"
  bash "$VCS" comment-issue 500 "$comment_body" >/dev/null 2>&1
fi
sweep_log="$(cat "$GH_LOG")"
assert_contains "$sweep_log" '" ; touch INJECTED_MARKER #' \
  "e2e: malicious checklist text is rendered verbatim in the posted comment"
if [ -f INJECTED_MARKER ]; then
  fail "e2e: checklist metacharacters must never execute during the sweep"
else
  pass "e2e: checklist metacharacters do not execute during the sweep"
fi

unset STUB_EPIC_BODY

finish
