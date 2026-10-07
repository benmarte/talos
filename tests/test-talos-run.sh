#!/usr/bin/env bash
# test-talos-run.sh -- `scripts/talos.sh run` (#472, slice 8 of epic #422).
#
# `run` IS the loop of Step 2 (`next` -> act -> `done`), one bash process with
# no orchestrator LLM. This file pins, against stubs:
#   (a) the loop: one pass per action, the dispatch through
#       pipeline-agent.sh `<role> -` with the rendered prompt on stdin, the
#       bookkeeping through `done` (the journal is the order pin)
#   (b) the verdict reading: the first `<WORD>:` of the agent's final message
#       against the role's done verdict list; the developer's PR URL ->
#       PR_OPENED --pr <N>, none -> BLOCKED; pm/planner carry no verdict
#   (c) a merge action runs `gate merge`, on verdict=merge runs `merge-pr`
#       and then `post-merge` with the captured `ci_runs=`
#   (d) wait/ask-owner stop clean (exit 0, `stop action=...` printed); every
#       gate verdict that is not merge stops clean; `next`'s own stop
#       (a failed state read) exits 1
#   (e) a provider 75/69 is the relayed contract: no verdict, nothing
#       recorded, exit 1; a dispatch failure (unknown verdict word, missing
#       prompt) records nothing and exits 1
#   (f) --max-iterations caps the passes; the lease keeps two callers from
#       the same dispatch
#   (g) the in-flight fallback (#519): a queue-drained wait works the
#       collect's `inflight` list -- an open-PR issue is never re-dispatched,
#       an empty list stops at the first wait with no second ready-queue
#       walk, an unreadable state read is said (never silently inert), and a
#       waiting in-flight issue moves to the next one
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
TALOS="$TALOS_ROOT/scripts/talos.sh"
ERR="$SANDBOX/stderr"

# ── fixture: a copied scripts dir with stubbed providers ──────────────────────
# A journaling stub set, as test-talos-gate.sh builds one: <key> is the verb
# of pipeline-vcs.sh, else the script's name; $STUB_DIR/<key>.{out,err,rc} is
# what it answers (rc 0 by default). Two verbs are special:
#   prompt/next/next-issue/done*: the run verb re-invokes talos.sh itself, so
#   the stub never intercepts talos.sh -- the copy is real.
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
mkdir -p "$SANDBOX/templates"
mkdir -p "$SANDBOX/templates/prompts"
cp -R "$TALOS_ROOT/templates/prompts/." "$SANDBOX/templates/prompts/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="$1"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
# list-prs / list-issues / list-needs-owner: the reads of the collect. LIST_PRS
# is the open-PR array (default empty); the issue list has canned answers.
if [ "$key" = "list-prs" ]; then printf '%s' "${LIST_PRS:-[]}"; exit 0; fi
if [ "$key" = "list-needs-owner" ]; then printf '%s' "${LIST_OWNERS:-[]}"; exit 0; fi
if [ "$key" = "list-issues" ]; then printf '%s' "${LIST_ISSUES:-[]}"; exit 0; fi
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then { printf "[%s]\n" "$*"; cat "$a"; } >> "$d/bodies"; fi
  prev="$a"
done
if [ "$n" = "hooks" ]; then cat > "$d/hooks.stdin"; fi
if [ "$n" = "notify" ] && [ "${3:-}" = "-" ]; then cat > "$d/notify.stdin"; fi
a1="${2:-}"
if [ -f "$d/$key.$a1.err" ]; then cat "$d/$key.$a1.err" >&2; elif [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
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

# The agent stub: echoes a scripted final message (the verdict word or the PR
# URL) and journals the prompt it received on stdin.
cat > "$GS/pipeline-agent.sh" <<'TALOS_stubagentR8kWq2Xn'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
role="$1"
cat > "$d/agent.stdin"
printf "agent %s\n" "$role" >> "$d/journal"
if [ -f "$d/message" ]; then cat "$d/message"; fi
if [ -f "$d/message.$role" ]; then cat "$d/message.$role"; fi
if [ -f "$d/agerr" ]; then cat "$d/agerr" >&2; fi
rc=0
if [ -f "$d/agrc" ]; then rc="$(cat "$d/agrc")"; fi
exit "$rc"
TALOS_stubagentR8kWq2Xn

# The collect stub: $STUB_DIR/collect.json is the state; the issue-side route
# is exercised via run --issue.
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusJ3mVx7Bq'
#!/usr/bin/env bash
# The collect stub: $STUB_DIR/collect.json is the state; the issue-side route
# is exercised via run --issue. Every call is journalled so a test can count
# the collects the run loop pays for (#519).
# With $STUB_DIR/collect.garbage present the FIRST call answers non-JSON and
# removes the marker, so a test can pin the in-flight list read failing while
# the passes' own state reads work.
d="${STUB_DIR:?}"
printf 'status-file collect\n' >> "$d/journal"
if [ -f "$d/collect.garbage" ]; then rm -f "$d/collect.garbage"; printf 'not json at all'; exit 0; fi
printf '%s' "$(cat "$d/collect.json" 2>/dev/null || echo '{}')"
if [ -f "$d/collect.rc" ]; then exit "$(cat "$d/collect.rc")"; fi
exit 0
TALOS_stubstatusJ3mVx7Bq

RUN="$GS/talos.sh"

# cfg <extra JSON members>: github provider, validator on, no PM.
cfg_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
base_cfg() {
  printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}%s}' \
    "${1:-}" > "$SANDBOX/talos.pipeline.json"
}
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  base_cfg
  printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [9], "held": [], "owners": [], "capped": []}' \
    > "$STUB_DIR/collect.json"
  printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "body", "state": "open"}' \
    > "$STUB_DIR/view-issue.9"
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
LEASE="$SANDBOX/.git/talos-lease.ledger"
LEASE_RESET() { rm -f "$LEASE" "${LEASE:?}.lock.d"; }
rn() { OUT="$(bash "$RUN" run "$@" 2>"$ERR")"; RC=$?; }

# issue 9 is view-issue's canned answer.
reset_stubs
printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "body", "state": "open"}' \
  > "$STUB_DIR/view-issue.9"

# ── (a) the loop: dispatch -> agent on stdin -> done ──────────────────────────
reset_stubs
LEASE_RESET
printf 'CONFIRMED: real, reproducible, in scope\nnote two\n' > "$STUB_DIR/message"
printf 'PASS: validator confirmed #9\n' > "$STUB_DIR/summary"
TALOS_LEASE_TTL_S=1 TALOS_NOW=1000 rn --issue 9 --max-iterations 1
assert_eq "0" "$RC" "loop: the run exits 0"
assert_eq "reason=iterations-exhausted max=1" "$(printf '%s\n' "$OUT" | sed -n 's/^stop //p' | head -n 1)" \
  "loop: the capped run's last stop names the cap and the max"
# Wait: max-iterations 1 means ONE dispatched pass: pass 1 dispatched validator
# (done released the lease, #470), pass 2's `next` answered a second dispatch,
# and the dispatch cap answered iterations-exhausted before executing it.
# The order pin: prompt, then the agent with the prompt on stdin, then done.
grep -q "^notify validator #9 - 9$" "$(dirname "$STUB_DIR")" 2>/dev/null || true
assert_contains "$(journal)" "agent validator" "loop: the dispatch went through pipeline-agent.sh with the role"
assert_contains "$(journal)" "vcs view-issue 9" "loop: next read the issue it routed"
grep -q "You are the Validator" "$STUB_DIR/agent.stdin"
assert_eq "0" "$?" "loop: the agent received the rendered prompt on stdin, never argv"
# The bookkeeping is done's: board, relay, post_stage, spend in journal order.
assert_contains "$(journal)" "hooks post_stage validator validator 9 --verdict CONFIRMED" \
  "loop: done wrote the validator's post_stage with the verdict"
assert_contains "$(journal)" "events cost --issue 9 --line" "loop: the spend block ran"

# ── (b) the verdict reading ────────────────────────────────────────────────────
# An unknown verdict word is a dispatch failure: nothing is recorded.
reset_stubs
LEASE_RESET
printf 'MAYBE: sounds fine\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1 TALOS_NOW=2000 rn --issue 9 --max-iterations 1
assert_eq "1" "$RC" "verdict: an unknown word is not a verdict (exit 1)"
assert_contains "$OUT" "run=stopped" "verdict: the failure says run=stopped"
assert_contains "$OUT" "reason=dispatch-failed" "verdict: the failure names dispatch-failed"
assert_not_contains "$(journal)" "hooks post_stage" "verdict: nothing was recorded"
# An empty final message: no verdict word, same treatment.
reset_stubs
LEASE_RESET
printf '' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1 TALOS_NOW=2000 rn --issue 9 --max-iterations 1
assert_eq "1" "$RC" "verdict: no verdict word in the final message is a dispatch failure"

# ── (b2) the developer: PR URL -> PR_OPENED --pr <N> ───────────────────────────
reset_stubs
LEASE_RESET
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [9], "held": [], "owners": [], "capped": []}' \
  > "$STUB_DIR/collect.json"
printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:dev"}], "body": "body", "state": "open"}' \
  > "$STUB_DIR/view-issue.9"
cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"developer": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'
printf 'https://github.com/acme/widget/pull/12\nimplemented the thing\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1 TALOS_NOW=3000 rn --issue 9 --max-iterations 1
assert_eq "0" "$RC" "developer PR_OPENED: the run exits 0"
assert_contains "$(journal)" "hooks post_stage developer developer 9 --pr 12 --verdict PR_OPENED" \
  "developer PR_OPENED: the PR URL became verdict PR_OPENED with --pr 12"
# No PR URL: BLOCKED.
reset_stubs
LEASE_RESET
printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:dev"}], "body": "body", "state": "open"}' \
  > "$STUB_DIR/view-issue.9"
printf 'blocked: the build needs a secret\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1 TALOS_NOW=3000 rn --issue 9 --max-iterations 1
assert_contains "$(journal)" "hooks post_stage developer developer 9 --verdict BLOCKED" \
  "developer BLOCKED: no PR URL is verdict BLOCKED"

# ── (d) wait / ask-owner / a failed state read ─────────────────────────────────
reset_stubs
LEASE_RESET
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [], "capped": []}' \
  > "$STUB_DIR/collect.json"
rn --issue 9 --max-iterations 3
assert_eq "0" "$RC" "wait: an empty queue answers clean"
assert_contains "$OUT" "action=wait" "wait: the wait action is relayed on the stop line"
reset_stubs
LEASE_RESET
TALOS_NOW=4000 bash "$GS/pipeline-vcs.sh" collect > /dev/null 2>&1 || true
# A failed state read: collect exits 1 ->
printf 'not json' > "$STUB_DIR/collect.json"
printf '' > "$STUB_DIR/collect.rc" && printf 1 > "$STUB_DIR/collect.rc"
rm -f "$STUB_DIR/collect.rc"; : > /dev/null
rn --issue 9 --max-iterations 3 2>/dev/null || true
# Build the failed-read case directly: collect stub answers 1.
reset_stubs
LEASE_RESET
printf 1 > "$STUB_DIR/collect.rc"
rn --issue 9 --max-iterations 3
assert_eq "1" "$RC" "stop: a failed state read exits 1 (not clean)"
assert_contains "$OUT" "stop reason=" "stop: the failed read names its reason"
rm -f "$STUB_DIR/collect.rc"

# ── (e) the provider contract (AC7) ───────────────────────────────────────────
reset_stubs
LEASE_RESET
printf 'CONFIRMED: would be fine\n' > "$STUB_DIR/message"
printf 75 > "$STUB_DIR/agrc"
TALOS_LEASE_TTL_S=1 TALOS_NOW=5000 rn --issue 9 --max-iterations 1
assert_eq "1" "$RC" "provider: 75 from the agent is the provider contract, exit 1"
assert_not_contains "$(journal)" "hooks post_stage" "provider: 75 records nothing"
printf 69 > "$STUB_DIR/agrc"
TALOS_LEASE_TTL_S=1 TALOS_NOW=5000 rn --issue 9 --max-iterations 1
assert_not_contains "$(journal)" "hooks post_stage" "provider: 69 records nothing"

# ── (f) the pass cap and the lease ────────────────────────────────────────────
reset_stubs
LEASE_RESET
printf 'CONFIRMED: ok\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1 TALOS_NOW=6000 rn --issue 9 --max-iterations 2
assert_contains "$OUT" "iterations-exhausted max=2" "cap: two passes end in the cap stop, the max named"
# The lease: a second run on the same issue waits, never double-dispatches.
reset_stubs
LEASE_RESET
TALOS_LEASE_TTL_S=1800 TALOS_NOW=7000 bash "$RUN" next --issue 9 > /dev/null 2>&1
# The same clock as the holder: the run's next sees the live lease (expires
# 8800 > NOW 7000), the acquire answers held, and the run stops on the wait.
TALOS_LEASE_TTL_S=1800 TALOS_NOW=7000 rn --issue 9 --max-iterations 1
case "$OUT" in
  "stop action=wait reason=lease"*) pass "lease: a held lease is a stop with the wait action" ;;
  "stop action=wait reason=cap"*) pass "lease: a held lease is a stop (cap shape), never a double dispatch" ;;
  *) fail "lease: a held lease is a stop, never a double dispatch" "got: $OUT" ;;
esac

# ── (g) the in-flight fallback (#519) ────────────────────────────────────────
# A queue-drained wait works the collect's `inflight` list; the journalled
# collect stub counts the reads, so the pins name the collects a drained run
# pays for: the one list read plus its own passes, never a second
# ready-queue walk.

# (g1) an in-flight issue with no open PR becomes a dispatch.
reset_stubs
LEASE_RESET
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [7], "owners": [], "capped": []}' \
  > "$STUB_DIR/collect.json"
printf '{"number": 7, "title": "t", "labels": [{"name": "pipeline:confirmed"}], "body": "body", "state": "open"}' \
  > "$STUB_DIR/view-issue.7"
printf 'blocked: the fixture has no test route\n' > "$STUB_DIR/message"
cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "developer": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'
TALOS_LEASE_TTL_S=1 TALOS_NOW=8000 rn --max-iterations 5
assert_eq "0" "$RC" "inflight: the untargeted run ends clean on the stage's BLOCKED"
assert_contains "$OUT" "stop reason=stage-blocked role=developer" "inflight: the in-flight developer stage ran through done"
assert_contains "$(journal)" "vcs view-issue 7" "inflight: the drained wait fell through to next --issue"
assert_contains "$(journal)" "agent developer" "inflight: a confirmed issue with no open PR becomes a dispatch, not the first wait"
assert_contains "$(journal)" "hooks post_stage developer developer 7 --verdict BLOCKED" "inflight: done's bookkeeping ran for the fallback dispatch"

# (g2) a stale pipeline:dev with an OPEN PR must not manufacture a developer
# fix round -- not even when the state lists it as in-flight (#519 review,
# finding 1: `next --issue` on a not-queued issue skips adoption).
reset_stubs
LEASE_RESET
printf '{"prs": [{"n": 12, "issue": 9, "head": "0000000000000000000000000000000000000012", "owner": false, "stage": "ci"}], "pr_total": 1, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [9], "owners": [], "capped": []}' \
  > "$STUB_DIR/collect.json"
printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:dev"}], "body": "body", "state": "open"}' \
  > "$STUB_DIR/view-issue.9"
TALOS_LEASE_TTL_S=1 TALOS_NOW=8500 rn --max-iterations 3
assert_eq "0" "$RC" "inflight open PR: the run ends clean on the PR-side wait"
assert_contains "$OUT" "action=wait reason=ci" "inflight open PR: the open PR's CI wait is the run's answer"
assert_not_contains "$(journal)" "vcs view-issue 9" "inflight open PR: the gated issue is never even routed"
assert_not_contains "$(journal)" "agent developer" "inflight open PR: no developer fix round is manufactured"
assert_eq "2" "$(journal | grep -c '^status-file collect$')" "inflight open PR: the gate costs no extra collect (the list read plus this pass's next)"

# (g3) an empty inflight list stops at the first wait: never the second
# collect and ready-queue walk the old empty-list sentinel paid (#519 review,
# finding 2).
reset_stubs
LEASE_RESET
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}' \
  > "$STUB_DIR/collect.json"
TALOS_NOW=9000 rn --max-iterations 3
assert_eq "0" "$RC" "inflight empty: the drained run exits clean"
assert_contains "$OUT" "stop action=wait reason=none" "inflight empty: the run stops at its first wait"
assert_eq "2" "$(journal | grep -c '^status-file collect$')" "inflight empty: the list read plus the pass's next, never a second queue walk"
assert_not_contains "$(journal)" "vcs view-issue" "inflight empty: the ready queue is not re-walked"

# (g4) an unreadable state read is said: the fallback is never silently inert
# (the emit-cap truncation this replaced did nothing at all; #519 review,
# finding 3).
reset_stubs
LEASE_RESET
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}' \
  > "$STUB_DIR/collect.json"
printf 'not json at all' > "$STUB_DIR/collect.garbage"
TALOS_NOW=9500 rn --max-iterations 3
assert_contains "$OUT" "warn reason=inflight-unreadable" "inflight unreadable: the failed list read names itself on the run's output, never silently inert"
assert_contains "$OUT" "stop action=wait reason=none" "inflight unreadable: the unreadable list leaves the fallback unused; the first wait still ends the run clean"
assert_eq "0" "$RC" "inflight unreadable: the run is clean -- a fallback read is not a state-read failure"

# (g5) a waiting in-flight issue (here: another run holds its lease) moves to
# the NEXT in-flight issue instead of ending the whole run (#519 review,
# non-blocking note).
reset_stubs
LEASE_RESET
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [7, 8], "owners": [], "capped": []}' \
  > "$STUB_DIR/collect.json"
printf '{"number": 7, "title": "t", "labels": [{"name": "pipeline:dev"}], "body": "body", "state": "open"}' \
  > "$STUB_DIR/view-issue.7"
printf '{"number": 8, "title": "t", "labels": [{"name": "pipeline:dev"}], "body": "body", "state": "open"}' \
  > "$STUB_DIR/view-issue.8"
printf 'blocked: the fixture has no test route\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=10000 bash "$RUN" next --issue 7 > /dev/null 2>&1
TALOS_LEASE_TTL_S=1800 TALOS_NOW=10000 rn --max-iterations 3
assert_eq "0" "$RC" "inflight lease: the run ends clean on the second issue's stage"
assert_contains "$(journal)" "vcs view-issue 8" "inflight lease: the lease-held issue did not end the pass; the next in-flight issue was routed"
assert_not_contains "$(journal)" "hooks post_stage developer developer 7" "inflight lease: the lease-held issue was not dispatched"
assert_contains "$OUT" "stop reason=stage-blocked role=developer" "inflight lease: the second in-flight issue dispatched"

finish