#!/usr/bin/env bash
# test-run-closed-issue-stop.sh -- `talos.sh run` re-reads the issue right before
# it dispatches a stage (#1057): another lane's merge queue can close the issue
# and merge its PR between the pass's `next` and the dispatch.
#   AC1 a CLOSED issue: `stop reason=issue-closed issue=<n>`, exit 0, no stage, no blocked label
#   AC2 a MERGED PR: the same stop
#   AC3 the run's lease is released on that stop
#   AC6 a run started on an already-CLOSED issue: no state change, no label
#   AC4 (same) an open issue with an open PR is dispatched as before
#   (no id) an unreadable pre-dispatch read keeps today's behaviour, with one warn line
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=none
. "$(dirname "$0")/talos-run-sections.sh"

OPEN9='{"number": 9, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "body", "state": "open"}'
CLOSED9='{"number": 9, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "body", "state": "closed"}'

# flip_after <n>: the Nth and later `view-issue 9` calls answer CLOSED (the stub
# sources hook.view-issue on every call, before it reads its answer file).
flip_after() {
  printf '%s' "$CLOSED9" > "$STUB_DIR/view-issue.9.closed"
  cat > "$STUB_DIR/hook.view-issue" <<TALOS_hookFlipR5nB8vLc
if [ "\$(grep -c '^vcs view-issue 9' "\$d/journal")" -ge $1 ]; then cp "\$d/view-issue.9.closed" "\$d/view-issue.9"; fi
TALOS_hookFlipR5nB8vLc
}

# ── AC1 ─────────────────────────────────────────────────────────────────────
reset_stubs; LEASE_RESET
printf 'CONFIRMED: ok\n' > "$STUB_DIR/message"
flip_after 2
TALOS_LEASE_TTL_S=1800 TALOS_NOW=1000 rn --issue 9 --max-iterations 3
assert_eq "0" "$RC" "AC1 a closed issue at the pre-dispatch check exits 0"
assert_contains "$OUT" "stop reason=issue-closed issue=9" "AC1 the stop line names the reason and the issue"
assert_not_contains "$(journal)" "agent validator" "AC1 no stage is dispatched"
assert_not_contains "$(journal)" "label-issue 9 --add pipeline:blocked" "AC1 no pipeline:blocked label is added"
assert_not_contains "$(journal)" "record-attempt" "AC1 no attempt is recorded"
assert_not_contains "$(journal)" "hooks post_stage" "AC1 nothing is recorded as a stage"

# ── AC2 ─────────────────────────────────────────────────────────────────────
# A QA dispatch on PR 12 whose PR reads merged while the issue still reads open.
reset_stubs; LEASE_RESET
printf '{"prs": [{"n": 12, "issue": 9, "head": "0000000000000000000000000000000000000012", "owner": false, "stage": "qa"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [], "capped": []}' \
  > "$STUB_DIR/collect.json"
printf '%s' "$OPEN9" > "$STUB_DIR/view-issue.9"
printf 'merged\n' > "$STUB_DIR/pr-state.12"
printf 'PASS: ok\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=2000 rn --issue 9 --max-iterations 3
assert_eq "0" "$RC" "AC2 a merged PR at the pre-dispatch check exits 0"
assert_contains "$OUT" "stop reason=issue-closed issue=9" "AC2 the same stop line"
assert_not_contains "$(journal)" "agent qa" "AC2 no stage is dispatched"
assert_not_contains "$(journal)" "label-issue 9 --add pipeline:blocked" "AC2 no pipeline:blocked label is added"
assert_contains "$(journal)" "vcs pr-state 12" "AC2 the PR was read"

# ── AC3 ─────────────────────────────────────────────────────────────────────
reset_stubs; LEASE_RESET
printf 'CONFIRMED: ok\n' > "$STUB_DIR/message"
flip_after 2
TALOS_LEASE_TTL_S=1800 TALOS_NOW=3000 rn --issue 9 --max-iterations 3
assert_contains "$OUT" "stop reason=issue-closed issue=9" "AC3 the run stopped on the closed issue"
assert_not_contains "$(cat "$LEASE" 2>/dev/null)" "issue=9 " "AC3 the run's lease on the issue is released"

# ── AC6 ─────────────────────────────────────────────────────────────────────
# The issue reads CLOSED from the very first read, so the run is started on it.
reset_stubs; LEASE_RESET
printf '%s' "$CLOSED9" > "$STUB_DIR/view-issue.9"
printf 'CONFIRMED: ok\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=3500 rn --issue 9 --max-iterations 3
assert_eq "0" "$RC" "AC6 a run started on a closed issue exits 0"
assert_contains "$OUT" "stop reason=issue-closed issue=9" "AC6 the run stops on the closed issue"
assert_not_contains "$(journal)" "agent " "AC6 no stage is dispatched"
assert_not_contains "$(journal)" "label-issue" "AC6 no label is added or removed"
assert_not_contains "$(journal)" "close-issue" "AC6 the issue's state is never written (close)"
assert_not_contains "$(journal)" "reopen" "AC6 the issue's state is never written (reopen)"
assert_not_contains "$(journal)" "record-attempt" "AC6 no attempt is recorded"
assert_not_contains "$(journal)" "post-verdict" "AC6 no verdict is posted on the closed issue"
assert_not_contains "$(journal)" "comment-issue" "AC6 no comment is posted on the closed issue"

# ── AC4 (same) ──────────────────────────────────────────────────────────────
reset_stubs; LEASE_RESET
printf 'CONFIRMED: ok\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1 TALOS_NOW=4000 rn --issue 9 --max-iterations 1
assert_eq "0" "$RC" "AC4 an open issue: the run exits 0 as before"
assert_contains "$(journal)" "agent validator" "AC4 an open issue is dispatched to the routed stage"
assert_not_contains "$OUT" "issue-closed" "AC4 an open issue is not stopped"
assert_not_contains "$OUT" "pre-dispatch-unread" "AC4 a clean read prints no warn"
reset_stubs; LEASE_RESET
printf '{"prs": [{"n": 12, "issue": 9, "head": "0000000000000000000000000000000000000012", "owner": false, "stage": "qa"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [], "capped": []}' \
  > "$STUB_DIR/collect.json"
printf 'open\n' > "$STUB_DIR/pr-state.12"
printf '{"labels": [], "state": "open"}' > "$STUB_DIR/view-pr.12"
printf 'PASS: ok\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=4500 rn --issue 9 --max-iterations 1
assert_not_contains "$OUT" "issue-closed" "AC4 an open issue with an open PR is not stopped"
assert_contains "$(journal)" "agent qa" "AC4 an open issue with an open PR is dispatched to the routed stage"

# ── unreadable read ─────────────────────────────────────────────────────────
# The pre-dispatch read fails (the 2nd and later view-issue calls exit 1).
reset_stubs; LEASE_RESET
printf 'CONFIRMED: ok\n' > "$STUB_DIR/message"
cat > "$STUB_DIR/hook.view-issue" <<'TALOS_hookFailK3dZ9wQe'
if [ "$(grep -c '^vcs view-issue 9' "$d/journal")" -ge 2 ]; then exit 1; fi
TALOS_hookFailK3dZ9wQe
TALOS_LEASE_TTL_S=1 TALOS_NOW=5000 rn --issue 9 --max-iterations 1
assert_contains "$(journal)" "agent validator" "unread: a failed read keeps today's behaviour, the stage is dispatched"
assert_contains "$OUT" "warn reason=pre-dispatch-unread" "unread: the failed read says so"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'pre-dispatch-unread')" "unread: with exactly one warn line"

finish
