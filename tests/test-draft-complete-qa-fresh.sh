#!/usr/bin/env bash
# test-draft-complete-qa-fresh.sh -- the draft completion skips QA when qa:pass
# is fresh at the head (#689).
#   AC1  fresh qa:pass: ready-pr and the guard run, then no QA, no CI wait, lease released
#   AC2  the same PR reaches the merge arm on the next pass with zero QA dispatches
#   AC3  a qa:pass stamped at an older sha still dispatches QA, after the CI wait under qa_mode ci
#   AC4  no qa:pass label still dispatches QA
#   AC5  a failed check-approval-sha read dispatches QA
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
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusBw3Nk9Rc'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
printf 'status-file collect\n' >> "$d/journal"
printf '%s' "$(cat "$d/collect.json" 2>/dev/null || echo '{}')"
TALOS_stubstatusBw3Nk9Rc

RUN="$GS/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
LEASE="$SANDBOX/.git/talos-lease.ledger"
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
rn() { OUT="$(bash "$RUN" run "$@" 2>"$ERR")"; RC=$?; }

# fixture <labels JSON members>: PR 12 / issue 9 at the resolver's `ready`; the
# ready verb takes (the guard answers ready); qa_mode ci, so a QA path shows its CI wait.
fixture() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$LEASE" "${LEASE:?}.lock.d"
  printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": true}, "verify": {"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900}, "merge": {"required_checks": ["test (ubuntu-latest)"]}}' \
    > "$SANDBOX/talos.pipeline.json"
  printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:review"}], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9"
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"ready"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' \
    > "$STUB_DIR/collect.json"
  printf ready > "$STUB_DIR/pr-is-draft.12"
  printf 1 > "$STUB_DIR/pr-is-draft.12.rc"
  printf 'PASS: verified\n' > "$STUB_DIR/message.qa"
  printf '{"labels": [%s], "state": "open"}' "$1" > "$STUB_DIR/view-pr.12"
}
ALL='{"name": "qa:pass"}, {"name": "docs:done"}, {"name": "review:approved"}, {"name": "security:approved"}'
qa_count() { journal | grep -c '^agent qa$'; }
lease_lines() { grep -c '^issue=9 ' "$LEASE" 2>/dev/null; }

# ── AC1: fresh qa:pass -> no QA, no CI wait, the lease released ──────────────
fixture "$ALL"
printf 0 > "$STUB_DIR/check-approval-sha.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "0" "$RC" "AC1 the completion with a fresh qa:pass exits 0"
assert_contains "$(journal)" "vcs ready-pr 12" "AC1 the PR is marked ready"
assert_contains "$(journal)" "vcs pr-is-draft 12" "AC1 the draft guard still runs"
assert_eq "0" "$(qa_count)" "AC1 no QA is dispatched on a fresh qa:pass"
assert_not_contains "$(journal)" "pr-checks-required" "AC1 no CI wait runs on a fresh qa:pass"
assert_eq "0" "$(lease_lines)" "AC1 the lease line for the issue is gone"

# ── AC2: the next pass is the merge arm, zero QA in the whole run ────────────
fixture "$ALL"
printf 0 > "$STUB_DIR/check-approval-sha.rc"
printf '%s' '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"merge"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.merge"
printf 'cp "$d/collect.merge" "$d/collect.json"\n' > "$STUB_DIR/hook.ready-pr"
printf '%s' '{"prs":[],"pr_total":0,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.done"
printf 'cp "$d/collect.done" "$d/collect.json"\n' > "$STUB_DIR/hook.merge-pr"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 5
assert_contains "$OUT" "merged=pr=12" "AC2 a draft PR with a fresh qa:pass reaches the merge stage and merges"
assert_eq "0" "$(qa_count)" "AC2 zero QA dispatches in the whole run"

# ── AC3: a stale qa:pass still dispatches QA, after the CI wait ──────────────
fixture "$ALL"
printf 1 > "$STUB_DIR/check-approval-sha.rc"
printf 'stale role=qa approved=aaaaaaa head=bbbbbbb\n' > "$STUB_DIR/check-approval-sha.out"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "1" "$(qa_count)" "AC3 a stale qa:pass dispatches QA"
assert_eq "pr-checks-required 12 --wait 570>agent qa" \
  "$(journal | grep -oE 'pr-checks-required 12 --wait [0-9]+|^agent qa$' | tr '\n' '>' | sed 's/>$//')" "AC3 the CI wait comes before QA"

# ── AC4: no qa:pass label dispatches QA ──────────────────────────────────────
fixture '{"name": "docs:done"}'
printf 0 > "$STUB_DIR/check-approval-sha.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "1" "$(qa_count)" "AC4 no qa:pass label dispatches QA"

# ── AC5: an unreadable check-approval-sha dispatches QA ──────────────────────
fixture "$ALL"
printf 1 > "$STUB_DIR/check-approval-sha.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "1" "$(qa_count)" "AC5 a failed check-approval-sha read (exit 1, no stale line) dispatches QA"
fixture "$ALL"
printf 2 > "$STUB_DIR/check-approval-sha.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "1" "$(qa_count)" "AC5 any other failure of the read dispatches QA"

finish
