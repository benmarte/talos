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
# #537: the Nth dispatch of a role (1-based, counted off the journal) may carry
# its own final message (message.<role>.<N>) and a hook (hook.<role>.<N>, a
# shell snippet sourced here: it moves the fixture's state the way that stage's
# real work would, e.g. a developer push changing the PR head).
cnt="$(grep -c "^agent $role\$" "$d/journal")"
if [ -f "$d/message.$role.$cnt" ]; then cat "$d/message.$role.$cnt"; fi
if [ -f "$d/hook.$role.$cnt" ]; then . "$d/hook.$role.$cnt"; fi
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
assert_contains "$OUT" "iterations-exhausted max=2" \
  "AC9: a run never reclaims its own live lease mid-loop -- the multi-iteration pass cap completes both passes"
# The lease: a second run on the same issue waits, never double-dispatches.
reset_stubs
LEASE_RESET
TALOS_LEASE_TTL_S=1800 TALOS_NOW=7000 bash "$RUN" next --issue 9 > /dev/null 2>&1
# The same clock as the holder: the run's next sees the live lease (expires
# 8800 > NOW 7000), the acquire answers held, and the run stops on the wait.
# The holder is a LIVE foreign process (#522 re-pin: the one-shot `next` above
# stamps its own pid, which is a dead process by the time the run's `next`
# reads the line -- the dead-holder reclaim would answer a dispatch, so the
# old fixture only stayed green by accident).
sleep 30 & _f_lpid=$!
printf 'issue=9 held=7000 expires=8800 pid=%s\n' "$_f_lpid" > "$LEASE"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=7000 rn --issue 9 --max-iterations 1
case "$OUT" in
  "stop action=wait reason=lease"*) pass "AC9: a run never reclaims a live lease -- the run's next sees it and waits" ;;
  *) fail "AC9: a run never reclaims a live lease -- the run's next sees it and waits" "got: $OUT" ;;
esac
assert_contains "$(cat "$LEASE")" "expires=8800 pid=$_f_lpid" "AC9: the live lease survives the run untouched"
kill "$_f_lpid" 2>/dev/null

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

# ── (h) the draft-window completion (#516) ───────────────────────────────────
# On `action=wait reason=draft pr=<M> issue=<N>` the driver continues the Draft
# stage order itself: the resolver answered `ready` (every enabled draft-window
# approval fresh), so the pass leases the write, calls ready-pr, asks the PR
# (the Draft guard), waits for the one CI run when qa_mode is ci, dispatches QA
# through the one dispatch path, and releases the lease before returning to the
# loop. Every pin runs on the journaling stubs; the resolver is the collect's
# canned stage, so no fixture needs the real resolver.
draft_cfg() {  # $1 = the verify block's members ; $2 = extra top-level members
  printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": true}, "verify": {%s}%s}' \
    "${1:-}" "${2:-}" > "$SANDBOX/talos.pipeline.json"
}
draft_collect() {  # $1 = the PR's collect stage
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"%s"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' \
    "$1" > "$STUB_DIR/collect.json"
}
draft_ready() {  # the guard stub: the ready verb took (rc 1, stdout exactly ready)
  printf ready > "$STUB_DIR/pr-is-draft.12"
  printf 1 > "$STUB_DIR/pr-is-draft.12.rc"
}
draft_order() { grep -oE 'ready-pr 12|pr-is-draft 12|pr-checks-required 12( --wait [0-9]+)?|agent qa|post_stage qa' "$STUB_DIR/journal" | tr '\n' '>' | sed 's/>$//'; }

# The primary flow: ci mode, the ready verb took, QA dispatched, the whole
# continuation inside one pass (AC2 trigger, AC4 once, AC6 guard-pass, AC7 one
# CI wait, AC9 dispatch, AC12 max-iterations 1).
reset_stubs
LEASE_RESET
draft_cfg '"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900' ', "merge": {"required_checks": ["test (ubuntu-latest)"]}'
draft_collect ready
draft_ready
printf 'PASS: verified\n' > "$STUB_DIR/message.qa"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "0" "$RC" "AC2: the key-carrying draft wait triggers the continuation; the run exits 0"
assert_contains "$OUT" "reason=iterations-exhausted max=1" "AC12: the capped run's last stop names the max"
assert_contains "$(journal)" "vcs ready-pr 12" "AC2: the pass continued (ready-pr called)"
assert_eq "1" "$(journal | grep -c 'vcs ready-pr 12')" "AC4: ready-pr is called exactly once for that PR"
assert_contains "$(journal)" "vcs pr-is-draft 12" "AC6: the Draft guard asked the PR, never memory"
assert_contains "$(journal)" "vcs pr-checks-required 12 --wait 570" "AC7: the one CI wait uses B=570 (min(900, 600000/1000-30))"
assert_eq "1" "$(journal | grep -c 'vcs pr-checks-required 12')" "AC7: exactly one CI wait before QA"
assert_contains "$(journal)" "agent qa" "AC9: QA dispatched through the driver's one dispatch path"
grep -q "You are QA" "$STUB_DIR/agent.stdin"
assert_eq "0" "$?" "AC9: the agent received prompt qa's render on stdin, never argv"
assert_contains "$(journal)" "post_stage qa" "AC12: the journal holds the full continuation"
assert_eq "ready-pr 12>pr-is-draft 12>pr-checks-required 12 --wait 570>agent qa>post_stage qa" "$(draft_order)" \
  "AC12: the continuation's order is the Draft stage order (ready-pr, the guard, the CI wait, QA, its post_stage)"

# AC8: qa_mode local -- the continuation calls no pr-checks-required at all;
# the QA dispatch follows ready-pr and the guard directly.
reset_stubs
LEASE_RESET
draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
draft_collect ready
draft_ready
printf 'PASS: verified\n' > "$STUB_DIR/message.qa"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "0" "$RC" "AC8: the local-mode run exits 0"
assert_contains "$(journal)" "agent qa" "AC8: the QA dispatch follows ready-pr and the guard directly (no CI wait in local mode)"
assert_not_contains "$(journal)" "pr-checks-required" "the local-mode continuation calls no pr-checks-required at all"

# AC5: a non-zero ready-pr is a stop, never a QA dispatch.
reset_stubs
LEASE_RESET
draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
draft_collect ready
printf 2 > "$STUB_DIR/ready-pr.12.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "1" "$RC" "AC5: a non-zero ready-pr is a stop (exit 1)"
assert_eq "stop reason=ready-pr-failed" "$OUT" "AC5: the stdout is exactly the stop line (the emit buffer wiped)"
assert_not_contains "$(journal)" "pr-is-draft" "AC5: the guard never ran"
assert_not_contains "$(journal)" "pr-checks-required" "AC5: no CI wait"
assert_not_contains "$(journal)" "agent qa" "AC5: never a QA dispatch"

# AC6: the guard's draft answer (the ready never took) stops ready-pr-failed.
reset_stubs
LEASE_RESET
draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
draft_collect ready
printf draft > "$STUB_DIR/pr-is-draft.12"
printf 0 > "$STUB_DIR/pr-is-draft.12.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "1" "$RC" "AC6: a draft answer after ready-pr stops ready-pr-failed (exit 1)"
assert_eq "stop reason=ready-pr-failed" "$OUT" "AC6: the stop line"
assert_not_contains "$(journal)" "agent qa" "AC6: 0 agent qa"

# AC6: pr.draft false never reaches the arm (the resolver answers false); a
# fixture that forces stage ready with pr-is-draft rc 0 must still stop.
reset_stubs
LEASE_RESET
cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'
draft_collect ready
printf draft > "$STUB_DIR/pr-is-draft.12"
printf 0 > "$STUB_DIR/pr-is-draft.12.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "1" "$RC" "AC6: pr.draft false with a forced ready stage still stops ready-pr-failed"
assert_contains "$OUT" "stop reason=ready-pr-failed" "AC6: the stop line"
assert_not_contains "$(journal)" "agent qa" "AC6: 0 agent qa"

# AC6: any other rc/output is draft-unverified (the gate's existing enum).
reset_stubs
LEASE_RESET
draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
draft_collect ready
printf 2 > "$STUB_DIR/pr-is-draft.12.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "1" "$RC" "AC6: any other rc/output stops draft-unverified"
assert_contains "$OUT" "stop reason=draft-unverified" "AC6: the stop line"
assert_not_contains "$(journal)" "agent qa" "AC6: 0 agent qa"

# AC7: a red required check is scheduling -- the qa-ci-red warn, then the ci
# wait stop, no QA, no merge gate, exit 0.
reset_stubs
LEASE_RESET
draft_cfg '"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900' ', "merge": {"required_checks": ["test (ubuntu-latest)"]}'
draft_collect ready
draft_ready
printf 'pr-checks-required: failed: test (ubuntu-latest)\n' > "$STUB_DIR/pr-checks-required.12.err"
printf 1 > "$STUB_DIR/pr-checks-required.12.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "0" "$RC" "AC7: a red required check is scheduling (exit 0)"
assert_contains "$OUT" "warn reason=qa-ci-red pr=12 issue=9" "AC7: the warn line names the reason and the PR"
assert_contains "$OUT" "stop action=wait reason=ci pr=12 issue=9" "AC7: the stop carries the ci wait shape"
assert_not_contains "$(journal)" "agent qa" "AC7: no QA dispatch"

# AC7: rc 1 without the failed: line still dispatches QA; rc 2 (pending at the
# deadline) dispatches QA too.
reset_stubs
LEASE_RESET
draft_cfg '"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900' ', "merge": {"required_checks": ["test (ubuntu-latest)"]}'
draft_collect ready
draft_ready
printf 'something unrelated\n' > "$STUB_DIR/pr-checks-required.12.err"
printf 1 > "$STUB_DIR/pr-checks-required.12.rc"
printf 'PASS: verified\n' > "$STUB_DIR/message.qa"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_contains "$(journal)" "agent qa" "AC7: rc 1 without the failed: line still dispatches QA"

reset_stubs
LEASE_RESET
draft_cfg '"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900' ', "merge": {"required_checks": ["test (ubuntu-latest)"]}'
draft_collect ready
draft_ready
printf 2 > "$STUB_DIR/pr-checks-required.12.rc"
printf 'PASS: verified\n' > "$STUB_DIR/message.qa"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_contains "$(journal)" "agent qa" "AC7: rc 2 (pending at the deadline) dispatches QA"

# AC7: the wait bound clamps at 3600, and a non-positive B omits the flag
# entirely.
reset_stubs
LEASE_RESET
draft_cfg '"qa_mode": "ci", "timeout_ms": 6000000, "ci_wait_s": 4000' ', "merge": {"required_checks": ["x"]}'
draft_collect ready
draft_ready
printf 'PASS: verified\n' > "$STUB_DIR/message.qa"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_contains "$(journal)" "vcs pr-checks-required 12 --wait 3600" "AC7: the wait bound clamps at 3600"

reset_stubs
LEASE_RESET
draft_cfg '"qa_mode": "ci", "timeout_ms": 1000, "ci_wait_s": 900' ', "merge": {"required_checks": ["x"]}'
draft_collect ready
draft_ready
printf 'PASS: verified\n' > "$STUB_DIR/message.qa"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_contains "$(journal)" "vcs pr-checks-required 12" "AC7: the CI-wait call happens even when B is not a positive integer"
assert_not_contains "$(journal)" "pr-checks-required 12 --wait" "AC7: a non-positive B omits the --wait flag entirely"

# AC9: qa off -- no dispatch, return to the loop.
reset_stubs
LEASE_RESET
cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": false, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'
draft_collect ready
draft_ready
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "0" "$RC" "AC9-adjacent: the qa-off run exits 0"
assert_contains "$(journal)" "vcs ready-pr 12" "AC9-adjacent: ready-pr ran"
assert_not_contains "$(journal)" "agent qa" "AC9-adjacent: qa off means no QA dispatch"

# AC9: a QA FAIL converts the PR back -- --draft keeps its existing meaning.
reset_stubs
LEASE_RESET
draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
draft_collect ready
draft_ready
printf 'FAIL: the suite broke\n' > "$STUB_DIR/message.qa"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_contains "$(journal)" "agent qa" "AC9: the QA FAIL dispatch ran"
assert_contains "$(journal)" "vcs draft-pr 12" "AC9: --draft keeps its existing meaning: a QA FAIL converts the PR back"
assert_contains "$(journal)" "vcs label-pr 12 --remove qa:pass" "AC9: the failed QA drops qa:pass"

# AC10: a held lease ends the pass with the lease wait, zero ready-pr, exit 0.
reset_stubs
LEASE_RESET
draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
draft_collect ready
draft_ready
sleep 30 & _f_lpid=$!
printf 'issue=9 held=7000 expires=8800 pid=%s\n' "$_f_lpid" > "$LEASE"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=7000 rn --max-iterations 1
case "$OUT" in
  "stop action=wait reason=lease retry_after_s="*) pass "AC10: a held lease ends the pass with the lease wait" ;;
  *) fail "AC10: a held lease ends the pass with the lease wait" "got: $OUT" ;;
esac
assert_eq "0" "$RC" "AC10: the lease wait exits 0"
assert_not_contains "$(journal)" "vcs ready-pr 12" "AC10: zero ready-pr on a held lease"
kill "$_f_lpid" 2>/dev/null

# AC10: a lock that could not be held answers the same shape with the lock's
# own seconds, never a takeover.
reset_stubs
LEASE_RESET
draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
draft_collect ready
draft_ready
mkdir "$LEASE.lock.d"
sleep 30 & _lock_lpid=$!
printf '%s:1\n' "$_lock_lpid" > "$LEASE.lock.d/pid"
TALOS_LEASE_LOCK_S=1 TALOS_LEASE_TTL_S=1800 TALOS_NOW=7000 rn --max-iterations 1
assert_contains "$OUT" "stop action=wait reason=lease retry_after_s=1" "AC10: a lock timeout answers the lock's own seconds"
assert_not_contains "$(journal)" "vcs ready-pr 12" "AC10: zero ready-pr on a lock timeout"
kill "$_lock_lpid" 2>/dev/null
rm -rf "${LEASE:?}.lock.d"

# AC11: no second merge path -- pin structurally: the loop has exactly one
# merge-pr and one gate merge call; the continuation has none of the three.
_loop_src="$(sed -n '/^_talos_run_loop()/,/^}$/p' "$GS/talos.sh")"
_comp_src="$(sed -n '/^_talos_run_draft_complete()/,/^}$/p' "$GS/talos.sh")"
assert_contains "$_comp_src" "_talos_run_draft_complete()" "AC11: the continuation exists next to _talos_run_dispatch"
assert_eq "0" "$(printf '%s' "$_comp_src" | grep -c 'merge-pr\\|gate merge \\|post-merge')" "AC11: the continuation calls no merge path at all"
assert_eq "1" "$(printf '%s' "$_loop_src" | grep -c '_vcs merge-pr')" "the loop has exactly one merge-pr call"
assert_eq "1" "$(printf '%s' "$_loop_src" | grep -c 'gate merge ')" "the loop has exactly one gate merge call"
# AC3 (the structural half of the contract): ready-pr is reachable only from
# the resolver's ready stage -- the run loop's single ready-pr call site is the
# continuation's, behind the resolver's ready answer. At the red commit the
# continuation does not exist, so the pin fails for the right reason; the
# behavioral half (the approval-stage pass dispatches and calls it zero times)
# is the pin above, whose id label lands with the implementation commit.
assert_contains "$_comp_src" "_talos_cap _vcs ready-pr" "AC3: ready-pr is reachable only from the resolver's ready stage (the run loop's single ready-pr call site is the continuation's, through AC4's _talos_cap call form)"
assert_eq "0" "$(printf '%s' "$_loop_src" | grep -c '_talos_cap _vcs ready-pr')" "the run loop's body outside the continuation calls ready-pr zero times (through AC4's _talos_cap call form)"

# AC12: a second pass is never stopped by the run's own leftover lease.
reset_stubs
LEASE_RESET
draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
draft_collect ready
draft_ready
printf 'PASS: verified\n' > "$STUB_DIR/message.qa"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 2
assert_eq "0" "$RC" "AC12: two passes end in the cap stop"
assert_contains "$OUT" "reason=iterations-exhausted max=2" "AC12: the cap names the max"
assert_not_contains "$OUT" "reason=lease" "AC12: never stopped by its own reason=lease"
assert_eq "2" "$(journal | grep -c 'vcs ready-pr 12')" "AC12: the second pass ran the continuation again (the lease was released)"

# The other wait reasons keep today's terminal stop (AC2's contract; unlabeled:
# the behavior holds at the red commit too, so an id label there would read as
# vacuous to the criteria report).
reset_stubs
LEASE_RESET
cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true}, "pr": {"draft": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'
draft_collect ci
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "0" "$RC" "the ci-stage wait ends the run clean"
assert_contains "$OUT" "stop action=wait reason=ci" "the ci wait keeps the bare terminal form"
assert_not_contains "$(journal)" "vcs ready-pr 12" "the ci wait calls ready-pr zero times"

# The approval stages still come first (AC3's contract; the AC3 label lands
# with the implementation commit -- the behavior holds at the red commit, so an
# AC3 label there would read as vacuous to the criteria report).
reset_stubs
LEASE_RESET
draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
draft_collect docs
printf 'APPROVED: docs pass\n' > "$STUB_DIR/message.docs"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "0" "$RC" "the approval-stage pass exits 0"
assert_contains "$(journal)" "agent docs" "the approval-stage pass dispatches agent docs"
assert_eq "0" "$(journal | grep -c 'vcs ready-pr 12')" "AC3: the approval-stage pass calls ready-pr zero times"

# The docs stage goes through `docs-gate` (#546): a PR with no docs-relevant
# change is stamped by code (no docs agent), a docs-relevant one dispatches the
# agent with the filtered paths in its prompt.
reset_stubs
LEASE_RESET
draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
draft_collect docs
printf 'scripts/talos.sh\ntests/t.sh\nCHANGELOG.md\n' > "$STUB_DIR/pr-files"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "0" "$RC" "docs-gate skip: the pass exits 0"
assert_not_contains "$(journal)" "agent docs" "docs-gate skip: no docs agent is dispatched"
assert_contains "$(journal)" "vcs post-approval 12 docs --body-file" "docs-gate skip: docs:done is stamped by code"
assert_contains "$(journal)" "hooks " "docs-gate skip: done docs ran"

reset_stubs
LEASE_RESET
draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
draft_collect docs
printf 'README.md\nscripts/talos.sh\n' > "$STUB_DIR/pr-files"
printf 'docs updated\n' > "$STUB_DIR/message.docs"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_contains "$(journal)" "agent docs" "docs-gate dispatch: a README PR dispatches the docs agent"
assert_contains "$(cat "$STUB_DIR/agent.stdin")" "README.md" "docs-gate dispatch: the prompt carries the filtered paths"
assert_not_contains "$(cat "$STUB_DIR/agent.stdin")" "scripts/talos.sh" "docs-gate dispatch: the prompt carries only the docs-relevant subset"
assert_not_contains "$(journal)" "post-approval 12 docs" "docs-gate dispatch: the run does not stamp, the agent's done does"
assert_eq "0" "$(ls "${TMPDIR:-/tmp}"/talos-docs-paths.* 2>/dev/null | wc -l | tr -d ' ')" "docs-gate dispatch: the paths file is removed after the stage"

# AC13: docs and pins move with the contract.
grep -q 'run-reasons: .*ready-pr-failed' "$GS/talos.sh"
assert_eq "0" "$?" "AC13: run-reasons names ready-pr-failed"
grep -q 'warn: .*qa-ci-red' "$GS/talos.sh"
assert_eq "0" "$?" "AC13: run-reasons names qa-ci-red"
grep -qF 'action=wait reason=draft pr=<M> issue=<N>' "$GS/talos.sh"
assert_eq "0" "$?" "AC13: the next schema describes the key-carrying draft wait"
grep -q '_talos_run_draft_complete' "$GS/talos.sh"
assert_eq "0" "$?" "AC13: the run block describes the draft continuation"
grep -q 'finishes the draft window by itself' "$TALOS_ROOT/CHANGELOG.md"
assert_eq "0" "$?" "AC13: CHANGELOG has the draft-window entry under [Unreleased] (anchored to the #516 entry's own text, not a generic draft-window match which would satisfy the pre-existing #332 entry too)"
assert_not_contains "$(cat "$TALOS_ROOT/skills/pipeline/SKILL.md")" "ready-pr-failed" "AC13-adjacent: SKILL.md is not edited"
assert_not_contains "$(cat "$TALOS_ROOT/skills/pipeline/SKILL.md")" "qa-ci-red" "AC13-adjacent: SKILL.md is not edited"

# ── (i) a QA FAIL is a developer fix round, never a QA re-run (#537) ──────────
# After a QA FAIL the driver runs the playbook's flow: `gate fix-round <N> qa
# --pr <M>` (record-attempt, then the unblock) and the developer in the
# fix-round shape; the next pass resumes the normal path (ready-pr, QA). A
# second QA FAIL at the head of the first (the fix round pushed nothing) is the
# backstop: pipeline:blocked on the PR and the issue, stop
# reason=qa-fail-unchanged-head, exit 0 -- never a loop to --max-iterations.
# The collect stub is static (stage ready), as in (h); the stubs' hooks move
# the state the way the real stage would: the developer's push changes the PR
# head, a passing QA moves the PR to the merge stage.
fix_fixture() {
  reset_stubs
  LEASE_RESET
  draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
  draft_collect ready
  draft_ready
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  printf 'https://github.com/acme/widget/pull/12\nfixed the failing test\n' > "$STUB_DIR/message.developer"
  printf 'FAIL: the suite broke\n' > "$STUB_DIR/message.qa.1"
  # The developer's real work, as the stub plays it: the fix round's prompt is
  # kept for the shape pin (the push, when there is one, is added per test).
  cat > "$STUB_DIR/hook.developer.1" <<'HOOK'
cp "$d/agent.stdin" "$d/developer.prompt"
HOOK
}
fix_order() { grep -oE 'ready-pr 12|agent qa|vcs record-attempt 9 qa --pr 12|label-pr 12 --remove pipeline:blocked|agent developer|view-pr 12' "$STUB_DIR/journal" | tr '\n' '>' | sed 's/>$//'; }

# (i1) QA FAIL -> fix round (the developer pushes a new head) -> QA PASS ->
# the merge arm.
fix_fixture
cat >> "$STUB_DIR/hook.developer.1" <<'HOOK'
printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"
HOOK
printf 'PASS: verified\n' > "$STUB_DIR/message.qa.2"
printf '{"labels": [{"name": "qa:pass"}, {"name": "docs:done"}, {"name": "review:approved"}, {"name": "security:approved"}], "state": "open"}' > "$STUB_DIR/view-pr.12"
cat > "$STUB_DIR/hook.qa.2" <<'HOOK'
printf '%s' '{"prs":[{"n":12,"issue":9,"head":"bbbb","owner":false,"stage":"merge"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$d/collect.json"
HOOK
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --max-iterations 5
assert_eq "0" "$RC" "fix round: the run exits 0"
assert_not_contains "$OUT" "iterations-exhausted" "fix round: the run does not loop to --max-iterations"
assert_contains "$OUT" "stop merged pr=12" "fix round: a passing QA after the fix reaches the merge arm and merges"
assert_eq "ready-pr 12>agent qa>vcs record-attempt 9 qa --pr 12>label-pr 12 --remove pipeline:blocked>agent developer>ready-pr 12>agent qa>view-pr 12" "$(fix_order)" \
  "fix round: QA FAIL -> gate fix-round (record-attempt, unblock) -> developer -> the normal path (ready-pr, QA) -> the merge arm"
assert_contains "$(cat "$STUB_DIR/developer.prompt" 2>/dev/null)" "Fix round: PR #12 is already open" \
  "fix round: the developer got the fix-round shape of the prompt"
assert_not_contains "$OUT" "qa-fail-unchanged-head" "fix round: a pushed fix is not the backstop"

# (i2) the backstop: the fix round pushes nothing, the second QA FAIL is at the
# same head -> blocked on PR and issue, stop, exit 0, ready-pr exactly twice.
fix_fixture
printf 'FAIL: still broken\n' > "$STUB_DIR/message.qa.2"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --max-iterations 9
assert_eq "0" "$RC" "backstop: the stop exits 0"
assert_contains "$OUT" "stop reason=qa-fail-unchanged-head pr=12 issue=9" "backstop: the stop line names the reason, the PR and the issue"
assert_not_contains "$OUT" "iterations-exhausted" "backstop: never a loop to --max-iterations"
assert_contains "$(journal)" "vcs label-pr 12 --add pipeline:blocked" "backstop: pipeline:blocked on the PR"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "backstop: pipeline:blocked on the issue"
assert_eq "2" "$(journal | grep -c 'vcs ready-pr 12')" "backstop: ready-pr ran exactly twice"
assert_eq "2" "$(journal | grep -c '^agent qa$')" "backstop: QA ran exactly twice"
assert_eq "1" "$(journal | grep -c '^agent developer$')" "backstop: exactly one fix round ran"

# (i3) the gate's own refusal (a ceiling) ends the run clean and its reason is
# relayed, not lost: no fix round, no unchanged-head stop.
fix_fixture
printf 'pipeline-vcs: record-attempt: max_fix_attempts (3) reached for qa\n' > "$STUB_DIR/record-attempt.err"
printf 1 > "$STUB_DIR/record-attempt.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --max-iterations 9
assert_eq "0" "$RC" "gate block: a ceiling ends the run clean"
assert_contains "$OUT" "stop verdict=block reason=max-fix-attempts" "gate block: the stop names the gate's verdict and reason"
assert_contains "$(cat "$ERR")" "max_fix_attempts" "gate block: the gate's stderr is relayed to the run's stderr"
assert_eq "0" "$(journal | grep -c '^agent developer$')" "gate block: no developer fix round past the ceiling"

# ── (j) the developer's `pr=<N>` word, on the host's own text tools (#537) ────
# A final message with no PR URL but a standalone `pr=<N>` is PR_OPENED <N>; the
# word must not be part of a longer one (xpr=12, my_pr=3, pr=12a, PR=4). The
# reading used a GNU-only `\b` in sed: BSD sed (macOS) matched nothing, so
# `pr=12` alone was misread as BLOCKED.
dev_pr_word() {  # $1 = the final message ; $2 = the expected PR (digits) or none ; $3 = label
  reset_stubs
  LEASE_RESET
  printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:dev"}], "body": "body", "state": "open"}' \
    > "$STUB_DIR/view-issue.9"
  cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"developer": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'
  printf '%b' "$1" > "$STUB_DIR/message"
  TALOS_LEASE_TTL_S=1 TALOS_NOW=13000 rn --issue 9 --max-iterations 1
  if [ "$2" = none ]; then
    assert_contains "$(journal)" "hooks post_stage developer developer 9 --verdict BLOCKED" "pr word: $3 is no PR (BLOCKED)"
  else
    assert_contains "$(journal)" "hooks post_stage developer developer 9 --pr $2 --verdict PR_OPENED" "pr word: $3 is PR $2"
  fi
}
dev_pr_word 'pr=12\n' 12 "a bare pr=12"
dev_pr_word 'opened pr=7 today\n' 7 "pr=7 inside a sentence (only the digits, not the text before)"
dev_pr_word 'see (pr=34).\n' 34 "pr=34 in parentheses"
dev_pr_word 'pr=5 then pr=6\n' 5 "the first of two pr= words"
dev_pr_word 'implemented the thing\nopened pr=8\n' 8 "a pr= word on the second line"
dev_pr_word 'xpr=12\n' none "xpr=12"
dev_pr_word 'pr=12a\n' none "pr=12a"
dev_pr_word 'my_pr=3\n' none "my_pr=3"
dev_pr_word 'PR=4\n' none "PR=4 (case-sensitive)"

finish