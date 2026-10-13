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
# #601: hook.<key> is a shell snippet sourced here (hook.merge-pr, hook.worktree):
# it moves the fixture state the way that call would, e.g. a merge closing the PR.
if [ -f "$d/hook.$key" ]; then . "$d/hook.$key"; fi
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
# The identity the run driver hands every dispatch (role:issue:pr; an unset
# variable prints as <unset>), kept apart from the journal the tests count.
printf '%s:%s:%s\n' "$role" "${TALOS_ISSUE-<unset>}" "${TALOS_PR-<unset>}" >> "$d/agent.env"
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
assert_eq "developer:9:" "$(cat "$STUB_DIR/agent.env")" "run identity: the first developer dispatch carries TALOS_ISSUE=9 and no PR"
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
# A failed state read: the collect stub answers 1.
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
assert_eq "1" "$(journal | grep -c '^status-file collect$')" "inflight open PR: one collect -- the list read, which this pass's next reuses (#554)"

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
assert_eq "1" "$(journal | grep -c '^status-file collect$')" "inflight empty: one collect, read for the list and reused by the pass's next (#554), never a second queue walk"
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

# (g6) #524 AC6: an pipeline:epic-decomposed parent is an index, never a
# developer's work. The stubbed inflight list names it on purpose (a real
# collect leaves it out, #524 AC5), so the routing itself is what is pinned.
reset_stubs
LEASE_RESET
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [26], "owners": [], "capped": []}' \
  > "$STUB_DIR/collect.json"
printf '{"number": 26, "title": "t", "labels": [{"name": "pipeline:epic-decomposed"}], "body": "body", "state": "open"}' \
  > "$STUB_DIR/view-issue.26"
printf 'blocked: the fixture has no test route\n' > "$STUB_DIR/message"
TALOS_NOW=10500 rn --max-iterations 3
assert_eq "0" "$RC" "#524 AC6: a drained run over an epic-decomposed parent exits 0"
assert_not_contains "$(journal)" "agent developer" "#524 AC6: no developer is dispatched onto an epic-decomposed parent"

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

# AC8 (#535): pr.ready_gate qa-local. QA already passed on the draft head (the
# resolver answers `ready` only then), so the continuation calls ready-pr once,
# runs the draft guard, and dispatches no QA and makes no pr-checks-required call,
# whatever verify.qa_mode says. The CI wait is the next pass's `ci` stage.
reset_stubs
LEASE_RESET
draft_cfg '"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900' ', "merge": {"required_checks": ["test (ubuntu-latest)"]}, "pr": {"draft": true, "ready_gate": "qa-local"}'
draft_collect ready
draft_ready
printf 'PASS: verified\n' > "$STUB_DIR/message.qa"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "0" "$RC" "AC8 gate on: the continuation exits 0"
assert_eq "1" "$(journal | grep -c 'vcs ready-pr 12')" "AC8 gate on: ready-pr is called exactly once"
assert_contains "$(journal)" "vcs pr-is-draft 12" "AC8 gate on: the draft guard still runs"
assert_not_contains "$(journal)" "agent qa" "AC8 gate on: no QA is dispatched after ready-pr"
assert_not_contains "$(journal)" "pr-checks-required" "AC8 gate on: no pr-checks-required call"
assert_eq "ready-pr 12>pr-is-draft 12" "$(draft_order)" "AC8 gate on: the sequence is ready-pr then the guard, nothing else"

# Gate off, explicitly: the sequence is today's (ready-pr, guard, CI wait, QA).
reset_stubs
LEASE_RESET
draft_cfg '"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900' ', "merge": {"required_checks": ["test (ubuntu-latest)"]}, "pr": {"draft": true, "ready_gate": "off"}'
draft_collect ready
draft_ready
printf 'PASS: verified\n' > "$STUB_DIR/message.qa"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "ready-pr 12>pr-is-draft 12>pr-checks-required 12 --wait 570>agent qa>post_stage qa" "$(draft_order)" \
  "AC8 gate off: ready-pr, the guard, the CI wait under qa_mode ci, then QA (unchanged)"

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
printf 'README.md\n' > "$STUB_DIR/pr-files"
printf 'APPROVED: docs pass\n' > "$STUB_DIR/message.docs"
# #640: docs runs in a worktree of the PR's head branch; the sandbox checkout holds it.
git symbolic-ref -q --short HEAD > "$STUB_DIR/pr-head-ref.12"
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
git symbolic-ref -q --short HEAD > "$STUB_DIR/pr-head-ref.12"
mkdir -p "$SANDBOX/tmp-docs"
TMPDIR="$SANDBOX/tmp-docs" TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_contains "$(journal)" "agent docs" "docs-gate dispatch: a README PR dispatches the docs agent"
assert_contains "$(cat "$STUB_DIR/agent.stdin")" "README.md" "docs-gate dispatch: the prompt carries the filtered paths"
assert_not_contains "$(cat "$STUB_DIR/agent.stdin")" "scripts/talos.sh" "docs-gate dispatch: the prompt carries only the docs-relevant subset"
assert_not_contains "$(journal)" "post-approval 12 docs" "docs-gate dispatch: the run does not stamp, the agent's done does"
assert_eq "0" "$(find "$SANDBOX/tmp-docs" -maxdepth 1 -name 'talos-docs-paths.*' 2>/dev/null | wc -l | tr -d ' ')" "docs-gate dispatch: the paths file is removed after the stage"

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
  # A spec QA can use (#610): the fix round answers a finding on the PR.
  printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "- [ ] AC1 the suite is green (prose: fixture)", "state": "open"}' \
    > "$STUB_DIR/view-issue.9"
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
# The merge closes the PR: the pass after it (#601) finds nothing left.
cat > "$STUB_DIR/hook.merge-pr" <<'HOOK'
printf '%s' '{"prs":[],"pr_total":0,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$d/collect.json"
HOOK
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --max-iterations 5
assert_eq "0" "$RC" "fix round: the run exits 0"
assert_not_contains "$OUT" "iterations-exhausted" "fix round: the run does not loop to --max-iterations"
assert_contains "$OUT" "merged=pr=12" "fix round: a passing QA after the fix reaches the merge arm and merges"
assert_eq "ready-pr 12>agent qa>vcs record-attempt 9 qa --pr 12>label-pr 12 --remove pipeline:blocked>agent developer>ready-pr 12>agent qa>view-pr 12" "$(fix_order)" \
  "fix round: QA FAIL -> gate fix-round (record-attempt, unblock) -> developer -> the normal path (ready-pr, QA) -> the merge arm"
assert_contains "$(cat "$STUB_DIR/developer.prompt" 2>/dev/null)" "Fix round: PR #12 is already open" \
  "fix round: the developer got the fix-round shape of the prompt"
assert_not_contains "$OUT" "qa-fail-unchanged-head" "fix round: a pushed fix is not the backstop"

# (i1b) #647: a fix-round developer whose report was lost to a trailing turn
# (no PR link in the final message). The head evidence decides.
late_fixture() {
  fix_fixture
  printf 'That monitor expiry does not change anything.\n' > "$STUB_DIR/message.developer"
}
# The PR head reads around the dispatch: only the #647 code reads it right
# before and again right after the developer agent.
late_head_reads() { grep -oE 'vcs pr-head 12|agent developer' "$STUB_DIR/journal" | tr '\n' '>' | grep -oE 'vcs pr-head 12>agent developer>(vcs pr-head 12>)?' | tr '\n' ' '; }
late_dev_opened() { grep -c 'hooks post_stage developer.* --verdict PR_OPENED' "$STUB_DIR/journal"; }
late_fixture
cat >> "$STUB_DIR/hook.developer.1" <<'HOOK'
printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"
HOOK
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12100 rn --max-iterations 2
assert_not_contains "$OUT" "stop reason=stage-blocked role=developer" "AC1 a moved head makes a link-less fix-round report PR_OPENED, not stage-blocked"
assert_eq "1" "$(late_dev_opened)" "AC1 done recorded PR_OPENED for the developer"
late_fixture
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12200 rn --max-iterations 2
assert_contains "$OUT" "stop reason=stage-blocked role=developer" "AC2 an unmoved head with no report stays stage-blocked"
assert_eq "0" "$(late_dev_opened)" "AC2 no PR_OPENED is recorded for an unmoved head"
assert_eq "vcs pr-head 12>agent developer>vcs pr-head 12> " "$(late_head_reads)" "AC2 the PR head is read before and after the dispatch"
late_fixture
printf 'BLOCKED: cannot run the tests\n' > "$STUB_DIR/message.developer"
cat >> "$STUB_DIR/hook.developer.1" <<'HOOK'
printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"
HOOK
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12300 rn --max-iterations 2
assert_contains "$OUT" "stop reason=stage-blocked role=developer" "AC3 an explicit BLOCKED: stays blocked even when the head moved"
assert_eq "0" "$(late_dev_opened)" "AC3 no PR_OPENED is recorded over an explicit block"
assert_eq "vcs pr-head 12>agent developer>vcs pr-head 12> " "$(late_head_reads)" "AC3 the PR head is read before and after the dispatch"
late_fixture
cat >> "$STUB_DIR/hook.developer.1" <<'HOOK'
printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"
printf 1 > "$d/pr-head.12.rc"
HOOK
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12400 rn --max-iterations 2
assert_contains "$OUT" "stop reason=stage-blocked role=developer" "AC5 an unreadable head after the dispatch applies no override"
assert_eq "0" "$(late_dev_opened)" "AC5 no PR_OPENED is recorded on an unresolved head"
assert_eq "vcs pr-head 12>agent developer>vcs pr-head 12> " "$(late_head_reads)" "AC5 the PR head is read before and after the dispatch"

# (i1c) #656: a first-round developer (no PR yet) whose report was lost to a
# trailing turn. The open PRs of the issue, listed before and after the
# dispatch, decide: a PR that did not exist before is the opened one.
first_fixture() {
  reset_stubs
  LEASE_RESET
  printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:dev"}], "body": "body", "state": "open"}' \
    > "$STUB_DIR/view-issue.9"
  cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"developer": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'
  printf 'That monitor expiry does not change anything.\n' > "$STUB_DIR/message"
}
first_opened() { grep -c 'hooks post_stage developer.* --verdict PR_OPENED' "$STUB_DIR/journal"; }
first_finds() { grep -c 'vcs find-pr 9 open' "$STUB_DIR/journal"; }
# The list find-pr answers after the dispatch: two new PRs, highest first.
first_new_prs() {
  printf '%s\n' '{"number": 14, "state": "open", "title": "b", "headRefName": "x"}' \
    '{"number": 13, "state": "open", "title": "a", "headRefName": "y"}' > "$STUB_DIR/new-prs"
  printf 'cp "$d/new-prs" "$d/find-pr.9.out"\n' > "$STUB_DIR/hook.developer.1"
}
first_fixture
first_new_prs
TALOS_LEASE_TTL_S=1 TALOS_NOW=13000 rn --issue 9 --max-iterations 1
assert_not_contains "$OUT" "stop reason=stage-blocked role=developer" "AC1 a new open PR makes a link-less first-round report PR_OPENED, not stage-blocked"
assert_contains "$(journal)" "hooks post_stage developer developer 9 --pr 13 --verdict PR_OPENED" "AC1 done recorded PR_OPENED with the lowest new PR"
first_fixture
TALOS_LEASE_TTL_S=1 TALOS_NOW=13100 rn --issue 9 --max-iterations 1
assert_contains "$OUT" "stop reason=stage-blocked role=developer" "AC2 no new open PR stays stage-blocked"
assert_eq "0" "$(first_opened)" "AC2 no PR_OPENED is recorded without a new PR"
assert_eq "2" "$(first_finds)" "AC2 find-pr is asked before and after the dispatch"
first_fixture
printf 'BLOCKED: cannot run the tests\n' > "$STUB_DIR/message"
first_new_prs
TALOS_LEASE_TTL_S=1 TALOS_NOW=13200 rn --issue 9 --max-iterations 1
assert_contains "$OUT" "stop reason=stage-blocked role=developer" "AC3 an explicit BLOCKED: stays blocked even when a new PR exists"
assert_eq "0" "$(first_opened)" "AC3 no PR_OPENED is recorded over an explicit block"
assert_eq "1" "$(first_finds)" "AC3 an explicit BLOCKED: line is not checked against find-pr after the dispatch"
first_fixture
first_new_prs
cp "$STUB_DIR/new-prs" "$STUB_DIR/find-pr.9"
TALOS_LEASE_TTL_S=1 TALOS_NOW=13300 rn --issue 9 --max-iterations 1
assert_contains "$OUT" "stop reason=stage-blocked role=developer" "AC4 a PR already open before the dispatch never counts"
assert_eq "0" "$(first_opened)" "AC4 no PR_OPENED is recorded for a PR that was already open"
assert_eq "2" "$(first_finds)" "AC4 find-pr is asked before and after the dispatch"
first_fixture
first_new_prs
printf 'printf 1 > "$d/find-pr.9.rc"\n' >> "$STUB_DIR/hook.developer.1"
TALOS_LEASE_TTL_S=1 TALOS_NOW=13400 rn --issue 9 --max-iterations 1
assert_contains "$OUT" "stop reason=stage-blocked role=developer" "AC5 a failing find-pr after the dispatch applies no override"
assert_eq "0" "$(first_opened)" "AC5 no PR_OPENED is recorded when find-pr fails"
assert_eq "2" "$(first_finds)" "AC5 find-pr is asked before and after the dispatch, the failing answer is not used"
first_fixture
printf 'printf "not json\\n" > "$d/find-pr.9.out"\n' > "$STUB_DIR/hook.developer.1"
TALOS_LEASE_TTL_S=1 TALOS_NOW=13500 rn --issue 9 --max-iterations 1
assert_contains "$OUT" "stop reason=stage-blocked role=developer" "AC5 an unparseable find-pr after the dispatch applies no override"
assert_eq "0" "$(first_opened)" "AC5 no PR_OPENED is recorded on an unparseable list"
assert_eq "2" "$(first_finds)" "AC5 find-pr is asked before and after the dispatch, the unparseable answer is not used"
first_fixture
first_new_prs
printf '1\n' > "$STUB_DIR/find-pr.9.rc"
printf 'rm -f "$d/find-pr.9.rc"\n' >> "$STUB_DIR/hook.developer.1"
TALOS_LEASE_TTL_S=1 TALOS_NOW=13550 rn --issue 9 --max-iterations 1
assert_contains "$OUT" "stop reason=stage-blocked role=developer" "AC5 an unreadable find-pr before the dispatch applies no override"
assert_eq "0" "$(first_opened)" "AC5 no PR_OPENED is recorded when the PR cannot be proven new"
assert_eq "1" "$(first_finds)" "AC5 find-pr is not asked after the dispatch when the pre-dispatch list is unreadable"
# AC6: find-pr is asked only for a first-round developer whose verdict is BLOCKED.
first_fixture
printf 'https://github.com/acme/widget/pull/12\nimplemented\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1 TALOS_NOW=13600 rn --issue 9 --max-iterations 1
assert_eq "1" "$(first_finds)" "AC6 a PR_OPENED first-round report asks find-pr only before the dispatch"
late_fixture
TALOS_LEASE_TTL_S=1800 TALOS_NOW=13700 rn --max-iterations 2
assert_eq "0" "$(first_finds)" "AC6 a fix-round developer never asks find-pr"

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
QA_BACKSTOP_OUT="$OUT"  # kept for the #609 pin of the QA round, section (l)

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
QA_CEILING_OUT="$OUT"

# (i4) a spec QA cannot use is not a finding on the PR (#610): QA answers FAIL
# on an issue whose spec has no criteria checklist. The driver asks
# `spec-usable` itself, before the head read and the gate: blocked on the PR
# and the issue, one stop line, exit 0, no attempt recorded, no fix round.
fix_fixture
printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "a body with no checklist", "state": "open"}' \
  > "$STUB_DIR/view-issue.9"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --max-iterations 9
assert_eq "0" "$RC" "AC8 spec fault: the run exits 0"
assert_eq "stop reason=spec-unusable issue=9 pr=12" "$(printf '%s\n' "$OUT" | grep '^stop ')" \
  "AC8 spec fault: exactly one stop line, naming the reason, the issue and the PR"
assert_contains "$(journal)" "vcs label-pr 12 --add pipeline:blocked" "AC8 spec fault: pipeline:blocked on the PR"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "AC8 spec fault: pipeline:blocked on the issue"
assert_eq "0" "$(journal | grep -c 'record-attempt')" "AC8 spec fault: no gate fix-round call (no attempt recorded)"
assert_eq "0" "$(journal | grep -c 'label-pr 12 --remove pipeline:blocked')" "AC8 spec fault: the gate's unblock never ran"
assert_eq "0" "$(journal | grep -c '^agent developer$')" "AC8 spec fault: no developer dispatch"
assert_contains "$(cat "$ERR")" "spec-usable: BLOCKED spec: no criteria checklist" "AC8 spec fault: the verb's line is relayed"
# The one stage of that run was QA: its prompt names the checkout the run was
# started in, with no placeholder left to fill.
assert_eq "Worktree path: $(git -C "$SANDBOX" rev-parse --show-toplevel)" "$(grep '^Worktree path:' "$STUB_DIR/agent.stdin")" \
  "AC12 the QA prompt of a run names the absolute top level of the run's checkout"

# ── (l) a review finding is a developer fix round (#609) ─────────────────────
# After a reviewer CHANGES or a security/adversarial FINDINGS the driver acts on
# `done`'s answer itself, as it does for QA. `next=batch` (pr.draft): the roles
# after the failing one that are enabled and hold no fresh approval run on the
# same head, then `gate fix-round` once, for the first failing role, and one
# developer fix round with every finding. `next=fix-round stage=<role>`: the
# gate and the round for that role. A round that pushed nothing blocks the PR
# and the issue and stops. The collect stub is static, as in (i): the stage it
# names is the one `next` dispatches on every pass, and the developer's hook
# moves the PR head.
rev_fixture() {  # $1 = pr.draft ; $2 = the PR's collect stage ; $3 = extra roles members
  reset_stubs
  LEASE_RESET
  printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true%s}, "pr": {"draft": %s}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
    "${3:-}" "$1" > "$SANDBOX/talos.pipeline.json"
  draft_collect "$2"
  printf '{"labels": [], "state": "open"}' > "$STUB_DIR/view-pr.12"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  printf 'https://github.com/acme/widget/pull/12\nfixed the findings\n' > "$STUB_DIR/message.developer"
  cat > "$STUB_DIR/hook.developer.1" <<'HOOK'
cp "$d/agent.stdin" "$d/developer.prompt"
HOOK
}
rev_push() {  # the fix round pushes a new head
  cat >> "$STUB_DIR/hook.developer.1" <<'HOOK'
printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"
HOOK
}
rev_finding() {  # $1 = role: its first dispatch ends in a finding that names the role
  local _w=FINDINGS
  [ "$1" != reviewer ] || _w=CHANGES
  printf '%s: 1 findings\n1. scripts/x.sh:12 asserts nothing (the-%s-finding)\n' "$_w" "$1" > "$STUB_DIR/message.$1.1"
}
rev_foreign_lease() {  # $1 = a vcs verb: its first call after the reviewer's `done` finds another live run's lease on issue 9
  cat > "$STUB_DIR/hook.$1" <<HOOK
if grep -q 'post_stage reviewer' "\$d/journal"; then printf 'issue=9 held=15000 expires=16800 pid=$_l_lpid\n' > "$LEASE"; fi
HOOK
}
rev_order() { grep -oE 'agent [a-z]+|vcs record-attempt 9 [a-z]+ --pr 12|label-pr 12 --remove pipeline:blocked' "$STUB_DIR/journal" | tr '\n' '>' | sed 's/>$//'; }
rev_count() { journal | grep -c "$1"; }
rev_stop() { printf '%s\n' "$OUT" | grep '^stop '; }
ADV_ON=', "adversarial": true'
UNBLOCK="label-pr 12 --remove pipeline:blocked"

# AC1-AC3: the draft batch. Reviewer CHANGES, security CLEAR, adversarial
# FINDINGS, one fix round that pushes; the second pass reviews the new head.
rev_fixture true reviewer "$ADV_ON"
rev_push
rev_finding reviewer
printf 'CLEAR: nothing exploitable (the-security-clear)\n' > "$STUB_DIR/message.security.1"
rev_finding adversarial
printf 'APPROVED: the new head is fine\n' > "$STUB_DIR/message.reviewer.2"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 2
assert_eq "0" "$RC" "AC1 (#609) the draft batch: the run exits 0"
assert_eq "agent reviewer>agent security>agent adversarial>vcs record-attempt 9 reviewer --pr 12>$UNBLOCK>agent developer" \
  "$(rev_order | sed 's/\(>agent developer\).*/\1/')" \
  "AC1 (#609) the draft batch: reviewer, the remaining reviewers, gate fix-round for the first failing role, the unblock, the developer"
assert_eq "1" "$(rev_count '^agent developer$')" "AC1 (#609) the draft batch: one developer fix round for every finding"
assert_not_contains "$OUT" "action=wait reason=blocked" "AC1 (#609) the draft batch: the run does not end on the blocked wait"
REV_PROMPT="$(cat "$STUB_DIR/developer.prompt" 2>/dev/null)"
assert_contains "$REV_PROMPT" "Fix round: PR #12 is already open" "AC2 (#609) the batch's developer got the fix-round shape of the prompt"
assert_contains "$REV_PROMPT" "reviewer findings:
CHANGES: 1 findings
1. scripts/x.sh:12 asserts nothing (the-reviewer-finding)" "AC2 (#609) the prompt carries the reviewer's final message under its role's name"
assert_contains "$REV_PROMPT" "adversarial findings:
FINDINGS: 1 findings
1. scripts/x.sh:12 asserts nothing (the-adversarial-finding)" "AC2 (#609) the prompt carries the adversarial final message under its role's name"
assert_not_contains "$REV_PROMPT" "the-security-clear" "AC2 (#609) the prompt does not carry the security CLEAR message"
assert_not_contains "$REV_PROMPT" "security findings:" "AC2 (#609) a role with no finding is not named in the prompt"
assert_eq "agent reviewer>agent security>agent adversarial>vcs record-attempt 9 reviewer --pr 12>$UNBLOCK>agent developer>agent reviewer" "$(rev_order)" \
  "AC3 (#609) after the push the next pass dispatches the review stage next names for the new head"
assert_eq "2" "$(rev_count '^agent reviewer$')" "AC3 (#609) the reviewer ran once per head"
assert_not_contains "$OUT" "fix-round-unchanged-head" "AC3 (#609) a round that pushed is not the backstop"
assert_eq "stop reason=iterations-exhausted max=2" "$(rev_stop)" "AC3 (#609) the run went on to the pass cap, its only stop line"

# AC4: a batch skips a disabled role and a role whose approval is fresh.
rev_fixture true security
rev_push
rev_finding security
printf '{"labels": [{"name": "review:approved"}], "state": "open"}' > "$STUB_DIR/view-pr.12"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 1
assert_eq "agent security>vcs record-attempt 9 security --pr 12>$UNBLOCK>agent developer" "$(rev_order)" \
  "AC4 (#609) a security FINDINGS with review:approved fresh and adversarial off: no reviewer, no adversarial, record-attempt for security"
rev_fixture true reviewer
rev_push
rev_finding reviewer
printf '{"labels": [{"name": "security:approved"}], "state": "open"}' > "$STUB_DIR/view-pr.12"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 1
assert_eq "agent reviewer>vcs record-attempt 9 reviewer --pr 12>$UNBLOCK>agent developer" "$(rev_order)" \
  "AC4 (#609) a reviewer CHANGES with security:approved fresh and adversarial off: the batch dispatches no other role"

# AC5: pr.draft off is the single-role round, for each review role.
for _l_role in reviewer security adversarial; do
  rev_fixture false "$_l_role" "$ADV_ON"
  rev_push
  rev_finding "$_l_role"
  TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 1
  assert_eq "agent $_l_role>vcs record-attempt 9 $_l_role --pr 12>$UNBLOCK>agent developer" "$(rev_order)" \
    "AC5 (#609) pr.draft off, $_l_role: gate fix-round for the role, then the developer, no other review role in between"
  REV_PROMPT="$(cat "$STUB_DIR/developer.prompt" 2>/dev/null)"
  assert_contains "$REV_PROMPT" "Fix round: PR #12 is already open" "AC5 (#609) pr.draft off, $_l_role: the developer got the fix-round shape"
  assert_contains "$REV_PROMPT" "(the-$_l_role-finding)" "AC5 (#609) pr.draft off, $_l_role: the role's final message is the prior summary"
done

# AC6: the gate's ceiling ends the run, for the batch and the single-role round.
for _l_draft in true false; do
  rev_fixture "$_l_draft" reviewer
  rev_finding reviewer
  printf 'CLEAR: nothing exploitable\n' > "$STUB_DIR/message.security.1"
  printf 'pipeline-vcs: record-attempt: max_fix_attempts (3) reached for reviewer\n' > "$STUB_DIR/record-attempt.err"
  printf 1 > "$STUB_DIR/record-attempt.rc"
  TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 9
  assert_eq "0" "$RC" "AC6 (#609) pr.draft $_l_draft: a ceiling after a review finding ends the run clean"
  assert_eq "stop verdict=block reason=max-fix-attempts" "$(rev_stop)" "AC6 (#609) pr.draft $_l_draft: the stop names the gate's verdict and reason"
  assert_eq "0" "$(rev_count '^agent developer$')" "AC6 (#609) pr.draft $_l_draft: no developer dispatch past the ceiling"
done

# AC7: two findings comments of the role on one file are an owner question.
rev_fixture false reviewer
rev_finding reviewer
python3 -I -c 'import json
body = "**Agent:** reviewer (talos)\n\n**Blocked**\n\n1. scripts/x.sh:%d asserts nothing."
print(json.dumps({"comments": [{"author": {"login": "bot"}, "body": body % n} for n in (12, 30)]}))' > "$STUB_DIR/read-comments.12"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 9
assert_eq "0" "$RC" "AC7 (#609) ask-owner ends the run clean"
assert_eq "stop verdict=ask-owner reason=design-decision stage=reviewer rounds=2 area=scripts/x.sh" "$(rev_stop)" \
  "AC7 (#609) the stop line is the gate's ask-owner answer with its detail lines"
assert_eq "0" "$(rev_count '^agent developer$')" "AC7 (#609) ask-owner dispatches no developer"
assert_eq "0" "$(rev_count 'vcs record-attempt')" "AC7 (#609) ask-owner records no attempt"

# AC8: a fix round that pushed nothing stops the run, once.
for _l_draft in true false; do
  rev_fixture "$_l_draft" reviewer
  rev_finding reviewer
  printf 'CLEAR: nothing exploitable\n' > "$STUB_DIR/message.security.1"
  TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 9
  assert_eq "0" "$RC" "AC8 (#609) pr.draft $_l_draft: the unchanged-head stop exits 0"
  assert_eq "stop reason=fix-round-unchanged-head pr=12 issue=9" "$(rev_stop)" \
    "AC8 (#609) pr.draft $_l_draft: exactly one stop line, naming the reason, the PR and the issue"
  assert_contains "$(journal)" "vcs label-pr 12 --add pipeline:blocked" "AC8 (#609) pr.draft $_l_draft: pipeline:blocked on the PR"
  assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "AC8 (#609) pr.draft $_l_draft: pipeline:blocked on the issue"
  assert_eq "1" "$(rev_count '^agent developer$')" "AC8 (#609) pr.draft $_l_draft: exactly one developer dispatch"
  assert_eq "agent developer" "$(journal | grep '^agent ' | tail -n 1)" "AC8 (#609) pr.draft $_l_draft: no review stage is dispatched on that head again"
  assert_not_contains "$OUT" "iterations-exhausted" "AC8 (#609) pr.draft $_l_draft: never a loop to --max-iterations"
done

# AC3 (#639): a run that starts on a PR already blocked by a review finding
# takes it to the fix round, as the run that saw the verdict does. The collect
# stage is `blocked`, so `next` only waits; the newest stage verdict on the PR
# says which role's finding it is.
blocked_fixture() {  # $1 = the PR's comments: the newest stage comment's verdict line
  rev_fixture false blocked
  printf '{"number": 9, "title": "t", "labels": [], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9"
  python3 -I -c 'import json, sys
print(json.dumps({"comments": [{"author": {"login": "bot"}, "body": "**Agent:** reviewer (talos)\n\n**Review:** " + sys.argv[1] + " scripts/x.sh:12 asserts nothing."}]}))' "$1" > "$STUB_DIR/read-comments.12"
}
blocked_fixture "CHANGES —"
rev_push
TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --issue 9 --max-iterations 1
assert_eq "0" "$RC" "AC3 (#639) run --issue on a PR blocked by a review finding: exits 0"
assert_eq "vcs record-attempt 9 reviewer --pr 12>label-pr 12 --remove pipeline:blocked>agent developer" "$(rev_order)" \
  "AC3 (#639) the gate fix-round for the finding's role, the unblock, then the developer"
REV_PROMPT="$(cat "$STUB_DIR/developer.prompt" 2>/dev/null)"
assert_contains "$REV_PROMPT" "Fix round: PR #12 is already open" "AC3 (#639) the developer got the fix-round shape of the prompt"
assert_not_contains "$OUT" "action=wait reason=blocked" "AC3 (#639) the run does not end on the blocked wait"
blocked_fixture "APPROVED —"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --issue 9 --max-iterations 1
assert_eq "0" "$(rev_count '^agent developer$')" "AC3 (#639) a PR whose newest verdict is no finding is not taken to the fix round"
assert_contains "$OUT" "action=wait reason=blocked" "AC3 (#639) that PR still ends on the blocked wait"

# AC9: BLOCKED: is for a person, as the first failing stage and inside a batch.
rev_fixture true reviewer
printf 'BLOCKED: the diff cannot be read\n' > "$STUB_DIR/message.reviewer.1"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 9
assert_eq "0" "$RC" "AC9 (#609) a blocked reviewer ends the run clean"
assert_eq "stop reason=stage-blocked role=reviewer" "$(rev_stop)" "AC9 (#609) a reviewer BLOCKED: stops for a person"
assert_eq "0" "$(rev_count 'vcs record-attempt')" "AC9 (#609) a reviewer BLOCKED: records no attempt"
assert_eq "0" "$(rev_count '^agent developer$')" "AC9 (#609) a reviewer BLOCKED: dispatches no developer"
rev_fixture true reviewer
rev_finding reviewer
printf 'BLOCKED: the advisory feed cannot be read\n' > "$STUB_DIR/message.security.1"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 9
assert_eq "0" "$RC" "AC9 (#609) a role blocked inside a batch ends the run clean"
assert_eq "stop reason=stage-blocked role=security" "$(rev_stop)" "AC9 (#609) a security BLOCKED: inside a batch stops for a person"
assert_eq "0" "$(rev_count 'vcs record-attempt')" "AC9 (#609) a BLOCKED: inside a batch records no attempt"
assert_eq "0" "$(rev_count '^agent developer$')" "AC9 (#609) a BLOCKED: inside a batch dispatches no developer"

# AC10: the driver's own dispatches are leased. Another live run takes the
# issue's lease after the reviewer's `done` freed it: before the batch's next
# role (the PR label read is the call in between), and before the fix-round
# developer (the gate's record-attempt is).
sleep 30 & _l_lpid=$!
rev_fixture true reviewer
rev_finding reviewer
rev_foreign_lease view-pr
TALOS_LEASE_TTL_S=1800 TALOS_NOW=15000 rn --max-iterations 9
assert_eq "0" "$RC" "AC10 (#609) a held lease before a batch role ends the run clean"
assert_eq "stop action=wait reason=lease retry_after_s=1800" "$(rev_stop)" "AC10 (#609) a held lease before a batch role is the lease wait"
assert_eq "0" "$(rev_count '^agent security$')" "AC10 (#609) the batch role is not dispatched under another run's lease"
rev_fixture false reviewer
rev_finding reviewer
rev_foreign_lease record-attempt
TALOS_LEASE_TTL_S=1800 TALOS_NOW=15000 rn --max-iterations 9
assert_eq "0" "$RC" "AC10 (#609) a held lease before the fix-round developer ends the run clean"
assert_eq "stop action=wait reason=lease retry_after_s=1800" "$(rev_stop)" "AC10 (#609) a held lease before the fix-round developer is the lease wait"
assert_eq "0" "$(rev_count '^agent developer$')" "AC10 (#609) the developer is not dispatched under another run's lease"
kill "$_l_lpid" 2>/dev/null

# AC11: the QA round of (i) keeps its stop lines (its pins above are unchanged).
assert_contains "$QA_BACKSTOP_OUT" "stop reason=qa-fail-unchanged-head pr=12 issue=9" "AC11 (#609) the QA backstop keeps its stop line"
assert_contains "$QA_CEILING_OUT" "stop verdict=block reason=max-fix-attempts" "AC11 (#609) the QA round's ceiling keeps its stop line"

# ── (k) the merge arm takes every multi-line gate answer (#543) ───────────────
# `gate merge` prints `verdict=<v>` and then one line per detail (`reason=`,
# `missing=`, `stale=`). The merge arm matched wait/handoff/redispatch exactly,
# so any real answer with a detail line died as `stop reason=state-unavailable`
# (exit 1). Each of these drives the REAL gate over the stubbed vcs verbs and
# must end the run clean (exit 0) with the gate's verdict and reasons relayed.
merge_fixture() {  # $1 = the PR's labels (JSON array members) ; $2 = extra top-level config members
  reset_stubs
  LEASE_RESET
  draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900' "${2:-}"
  draft_collect merge
  printf '{"labels": [%s], "state": "open"}' "$1" > "$STUB_DIR/view-pr.12"
}
ALL_APPROVALS='{"name": "qa:pass"}, {"name": "docs:done"}, {"name": "review:approved"}, {"name": "security:approved"}'

merge_fixture '{"name": "docs:done"}, {"name": "review:approved"}, {"name": "security:approved"}'
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --max-iterations 5
assert_eq "0" "$RC" "merge arm wait: a gate wait answer ends the run clean (exit 0)"
assert_contains "$OUT" "stop verdict=wait reason=approvals-missing missing=qa:pass" "merge arm wait: the stop names the verdict, the reason and the missing label"
assert_not_contains "$OUT" "state-unavailable" "merge arm wait: never state-unavailable"
assert_not_contains "$(journal)" "merge-pr" "merge arm wait: nothing is merged"

merge_fixture "$ALL_APPROVALS"
printf 1 > "$STUB_DIR/check-approval-sha.rc"
printf 'stale role=qa label=qa:pass\n' > "$STUB_DIR/check-approval-sha.out"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --max-iterations 5
assert_eq "0" "$RC" "merge arm redispatch: a gate redispatch answer ends the run clean (exit 0)"
assert_contains "$OUT" "stop verdict=redispatch reason=stale-approvals stale=qa" "merge arm redispatch: the stop names the verdict, the reason and the stale roles"
assert_not_contains "$OUT" "state-unavailable" "merge arm redispatch: never state-unavailable"
assert_not_contains "$(journal)" "merge-pr" "merge arm redispatch: nothing is merged"

merge_fixture "$ALL_APPROVALS" ', "merge": {"auto": false}'
draft_ready  # draft_cfg turns pr.draft on: the gate asks pr-is-draft, which says ready
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --max-iterations 5
assert_eq "0" "$RC" "merge arm handoff: a gate handoff answer ends the run clean (exit 0)"
assert_contains "$OUT" "stop verdict=handoff" "merge arm handoff: the stop names the verdict"
assert_not_contains "$OUT" "state-unavailable" "merge arm handoff: never state-unavailable"
assert_not_contains "$(journal)" "merge-pr" "merge arm handoff: nothing is merged"

# A gate block keeps its reason too (the arm used to print the first line only).
merge_fixture "$ALL_APPROVALS"
printf 'infra/prod.tf\n' > "$STUB_DIR/check-pr-files.out"
printf 1 > "$STUB_DIR/check-pr-files.rc"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --max-iterations 5
assert_eq "0" "$RC" "merge arm block: a gate block answer ends the run clean (exit 0)"
assert_contains "$OUT" "stop verdict=block reason=forbidden-files" "merge arm block: the reason is relayed"

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

# ── (k) the collected state is read once per state (#554) ─────────────────────
# Inside one `run` the collect is cached (TALOS_COLLECT_CACHE, a file in the run's
# private dir): the in-flight list read and the first `next` share one read, and
# later ones reuse it until something writes. Any writing verb empties it.
CC="$SANDBOX/collect.cache"
collects() { journal | grep -c '^status-file collect$'; }
EMPTY_STATE='{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}'
reset_stubs; LEASE_RESET; rm -f "$CC"
export TALOS_COLLECT_CACHE="$CC"
# a hit: the cached state, not the stub's, answers (and no collect is paid)
printf '%s' "$EMPTY_STATE" > "$CC"
OUT="$(TALOS_NOW=14000 bash "$RUN" next 2>/dev/null)"
assert_contains "$OUT" "action=wait reason=none" "collect cache: a fresh cache answers next (its empty queue, not the stub's queued [9])"
assert_eq "0" "$(collects)" "collect cache: a hit pays no collect"
# a miss: read once, kept
reset_stubs; LEASE_RESET; rm -f "$CC"
TALOS_NOW=14000 bash "$RUN" next --issue 9 >/dev/null 2>&1
TALOS_NOW=14000 bash "$RUN" next --issue 9 >/dev/null 2>&1
assert_eq "1" "$(collects)" "collect cache: a miss reads once, the second next reuses it"
assert_contains "$(cat "$CC")" '"queued": [9]' "collect cache: the miss stored what collect printed"
# expired: ignored
touch -t 202001010000 "$CC"
TALOS_NOW=14000 bash "$RUN" next --issue 9 >/dev/null 2>&1
assert_eq "2" "$(collects)" "collect cache: a cache older than two minutes is read again"
# a failed or non-JSON read is never kept
reset_stubs; LEASE_RESET; rm -f "$CC"
printf '1' > "$STUB_DIR/collect.rc"
TALOS_NOW=14000 bash "$RUN" next --issue 9 >/dev/null 2>&1
assert_file_absent "$CC" "collect cache: a failed collect is not kept"
rm -f "$STUB_DIR/collect.rc"; printf 'not json' > "$STUB_DIR/collect.json"
TALOS_NOW=14000 bash "$RUN" next --issue 9 >/dev/null 2>&1
assert_file_absent "$CC" "collect cache: a read that is not a JSON object is not kept"
# every verb that writes empties it
for v in done gate docs-gate post-merge sweep claim; do
  printf '%s' "$EMPTY_STATE" > "$CC"
  bash "$RUN" "$v" >/dev/null 2>&1
  assert_file_absent "$CC" "collect cache: '$v' empties the cache before it writes"
done
printf '%s' "$EMPTY_STATE" > "$CC"
bash "$RUN" summary >/dev/null 2>&1
assert_file_exists "$CC" "collect cache: a read-only verb leaves it"
unset TALOS_COLLECT_CACHE

# In a run: the list read and the first next share one collect; a dispatch's
# done empties the cache, so the pass after it reads the state the stage left.
reset_stubs; LEASE_RESET
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [9], "held": [], "inflight": [], "owners": [], "capped": []}' > "$STUB_DIR/collect.json"
printf 'CONFIRMED: real\n' > "$STUB_DIR/message"
printf '%s' "$EMPTY_STATE" > "$STUB_DIR/collect.after"
cat > "$STUB_DIR/hook.validator.1" <<'HOOK'
cp "$d/collect.after" "$d/collect.json"
HOOK
TALOS_LEASE_TTL_S=1 TALOS_NOW=15000 rn --max-iterations 5
assert_contains "$(journal)" "agent validator" "run cache: the queued issue was dispatched on the first read"
assert_eq "2" "$(collects)" "run cache: list read + first next share one collect; the pass after the dispatch reads again"
assert_contains "$OUT" "action=wait reason=none" "run cache: the pass after the dispatch saw the state the stage left (queue empty), not the cached one"

# (k2) #582: `run --issue N` continues through N's open PR although N carries no
# pipeline label (the developer removed it), on the run's cached collect; and
# never works another issue's PR.
reset_stubs; LEASE_RESET
cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"qa": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'
printf '{"number": 9, "title": "t", "labels": [], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9"
# PR 11 belongs to issue 8 and is the lower number; PR 12 is issue 9's, at $1.
pr_state() {
  printf '{"prs": [{"n": 11, "issue": 8, "head": "%040d", "owner": false, "stage": "reviewer"}, {"n": 12, "issue": 9, "head": "%040d", "owner": false, "stage": "%s"}], "pr_total": 2, "ignored": 0, "blocked": [], "queued": [], "held": [], "inflight": [], "owners": [], "capped": []}' 11 12 "$1"
}
pr_state qa > "$STUB_DIR/collect.json"
pr_state human-merge > "$STUB_DIR/collect.after"
printf 'PASS: criteria met\n' > "$STUB_DIR/message"
cat > "$STUB_DIR/hook.qa.1" <<'HOOK'
cp "$d/collect.after" "$d/collect.json"
HOOK
TALOS_LEASE_TTL_S=1 TALOS_NOW=15500 rn --issue 9 --max-iterations 4
assert_eq "1" "$(journal | grep -c '^agent qa$')" "run --issue (#582): the unlabeled issue's PR is dispatched at qa"
assert_contains "$(journal)" "hooks post_stage qa qa 9" "run --issue (#582): done ran for the PR's stage on issue 9"
assert_contains "$OUT" "action=wait reason=human-merge" "run --issue (#582): the run continued to the PR's next stage and stopped there"
assert_not_contains "$(journal)" "agent reviewer" "run --issue (#582): another issue's PR is never worked"
assert_eq "2" "$(collects)" "run --issue (#582): one collect before the dispatch, one after it (done empties the cache)"
# The dispatch carries the issue and PR identity pipeline-agent records on its
# stage_complete event (without it the event has issue null).
assert_eq "qa:9:12" "$(cat "$STUB_DIR/agent.env")" "run identity: a PR stage is dispatched with TALOS_ISSUE=9 and TALOS_PR=12"

# ── (h) BLOCKED: <reason> is a blocked outcome for ANY role (#580) ────────────
# A headless stage that cannot do its job ends "BLOCKED: <why>" (the validator on
# testrun#3 could not read the issue). That is not a verdict word for the role,
# and used to stop the run dispatch-failed verdict-unreadable. Now: the role's
# done runs with --verdict BLOCKED, pipeline:blocked is set on the issue (and the
# PR), the reason is relayed, and the run stops clean with the stage-blocked line.
reset_stubs
LEASE_RESET
printf 'BLOCKED: every pipeline-vcs.sh call was refused by the permission mode\nsecond line\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1 TALOS_NOW=16000 rn --issue 9 --max-iterations 3
assert_eq "0" "$RC" "blocked: a validator BLOCKED: ends the run clean (exit 0)"
assert_contains "$OUT" "stop reason=stage-blocked role=validator" "blocked: the documented stop line"
assert_not_contains "$OUT" "dispatch-failed" "blocked: never dispatch-failed"
assert_not_contains "$OUT" "verdict-unreadable" "blocked: never verdict-unreadable"
assert_contains "$(journal)" "hooks post_stage validator validator 9 --verdict BLOCKED" "blocked: done recorded the verdict BLOCKED for the validator"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "blocked: the issue is labelled pipeline:blocked"
assert_contains "$(cat "$STUB_DIR/hooks.stdin" 2>/dev/null)$(cat "$STUB_DIR/bodies" 2>/dev/null)$(cat "$ERR")" "refused by the permission mode" "blocked: the reason is relayed"
# a leading blank line does not hide it; a verdict word later in the text does not rescue it
reset_stubs
LEASE_RESET
printf '\nBLOCKED: no access\nCONFIRMED: but really\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1 TALOS_NOW=16100 rn --issue 9 --max-iterations 3
assert_contains "$OUT" "stop reason=stage-blocked role=validator" "blocked: BLOCKED: on the first non-blank line wins over a later verdict word"
# only the FIRST line counts: BLOCKED: later in the text is not a block
reset_stubs
LEASE_RESET
printf 'CONFIRMED: real\nBLOCKED: only a note\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1 TALOS_NOW=16200 rn --issue 9 --max-iterations 1
assert_not_contains "$OUT" "stage-blocked" "blocked: BLOCKED: on a later line is not a block"
assert_contains "$(journal)" "hooks post_stage validator validator 9 --verdict CONFIRMED" "blocked: the first-line verdict stands"
# the developer with a PR URL in its message: BLOCKED: first still blocks
reset_stubs
LEASE_RESET
printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:dev"}], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9"
cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"developer": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'
printf 'BLOCKED: tests need a secret (see https://github.com/acme/widget/pull/12)\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1 TALOS_NOW=16300 rn --issue 9 --max-iterations 1
assert_contains "$OUT" "stop reason=stage-blocked role=developer" "blocked: a developer BLOCKED: line wins over a PR URL in the text"
assert_contains "$(journal)" "hooks post_stage developer developer 9 --verdict BLOCKED" "blocked: developer recorded as BLOCKED"
# a PR-side stage (qa): the PR is labelled too, and no fix round follows
reset_stubs
LEASE_RESET
draft_cfg '"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900' ', "merge": {"required_checks": ["test (ubuntu-latest)"]}'
draft_collect ready
draft_ready
printf 'BLOCKED: the verify command needs approval\n' > "$STUB_DIR/message.qa"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=16400 rn --max-iterations 1
assert_eq "0" "$RC" "blocked: a qa BLOCKED: ends the run clean"
assert_contains "$OUT" "stop reason=stage-blocked role=qa" "blocked: qa stop line"
assert_contains "$(journal)" "hooks post_stage qa qa 9 --pr 12 --verdict BLOCKED" "blocked: qa recorded as BLOCKED"
assert_contains "$(journal)" "vcs label-pr 12 --add pipeline:blocked" "blocked: the PR is labelled pipeline:blocked"
assert_not_contains "$(journal)" "gate fix-round" "blocked: a qa BLOCKED: starts no developer fix round"

# AC6 (#645): a QA `BLOCKED: spec:` is a spec fault, not a stage that needs a
# person: the documented spec-unusable stop, blocked as for any BLOCKED.
reset_stubs
LEASE_RESET
draft_cfg '"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900' ', "merge": {"required_checks": ["test (ubuntu-latest)"]}'
draft_collect ready
draft_ready
printf '\nBLOCKED: spec: no criteria checklist\nsecond line\n' > "$STUB_DIR/message.qa"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=16500 rn --max-iterations 1
assert_eq "0" "$RC" "AC6 a qa BLOCKED: spec: ends the run clean"
assert_eq "stop reason=spec-unusable issue=9 pr=12" "$(printf '%s\n' "$OUT" | grep '^stop ')" \
  "AC6 a qa BLOCKED: spec: is the spec-unusable stop, not stage-blocked"
assert_contains "$(journal)" "vcs label-pr 12 --add pipeline:blocked" "AC6 the PR is labelled pipeline:blocked"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "AC6 the issue is labelled pipeline:blocked"
assert_not_contains "$(journal)" "gate fix-round" "AC6 no developer fix round follows"
# only QA's first line counts, and only QA's
printf 'BLOCKED: the verify command needs approval\nBLOCKED: spec: later line\n' > "$STUB_DIR/message.qa"
LEASE_RESET
TALOS_LEASE_TTL_S=1800 TALOS_NOW=16600 rn --max-iterations 1
assert_contains "$OUT" "stop reason=stage-blocked role=qa" "AC6 a qa BLOCKED: not about the spec stays stage-blocked"
reset_stubs
LEASE_RESET
printf 'BLOCKED: spec: not a QA stage\n' > "$STUB_DIR/message"
TALOS_LEASE_TTL_S=1 TALOS_NOW=16700 rn --issue 9 --max-iterations 1
assert_contains "$OUT" "stop reason=stage-blocked role=validator" "AC6 BLOCKED: spec: from another role stays stage-blocked"

# ── (m) one run drains the queue (#601) ───────────────────────────────────────
# After a merge an untargeted run goes on: post-merge returns the checkout
# (`pipeline-worktree.sh to-base`), the run flushes, runs its exit hooks and
# execs $SCRIPT_DIR/talos.sh for the next pass (same PID, the merged code).
# pipeline-worktree.sh is a journaling stub from here on (the real verb is
# pinned in tests/test-worktree.sh): `to-base` answers $STUB_DIR/worktree.out,
# and hook.worktree / hook.merge-pr move the fixture the way the call would.
printf '%s' "$STUB_BODY" > "$GS/pipeline-worktree.sh"
export GS_DIR="$GS" LEASE_FILE="$LEASE"
STOPF="$SANDBOX/.git/talos/run.stop"
last_line() { printf '%s\n' "$OUT" | tail -n 1; }
vi() {  # $1 = issue ; $2 = its labels (JSON array members)
  printf '{"number": %s, "title": "t", "labels": [%s], "body": "body", "state": "open"}' "$1" "$2" > "$STUB_DIR/view-issue.$1"
}
st_pr() {  # PR 12 (issue 9) at the merge stage ; $1 = the queued issues
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"merge"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[%s],"held":[],"inflight":[],"owners":[],"capped":[],"priority":{}}' "$1"
}
st_q() {  # no PR ; $1 = queued ; $2 = in flight ; $3 = the priority object (default: none)
  local _prio="${3:-}"
  [ -n "$_prio" ] || _prio='{}'
  printf '{"prs":[],"pr_total":0,"ignored":0,"blocked":[],"queued":[%s],"held":[],"inflight":[%s],"owners":[],"capped":[],"priority":%s}' "$1" "${2:-}" "$_prio"
}
drain_fixture() {  # PR 12 passes every merge gate ; $1 = what to-base answers
  merge_fixture "$ALL_APPROVALS"
  draft_ready
  rm -f "$STOPF"
  printf 'talos:checkout state=%s\n' "${1:-returned}" > "$STUB_DIR/worktree.out"
  printf 'CONFIRMED: real\n' > "$STUB_DIR/message.validator"
}
drain_order() { grep -oE 'merge-pr 12|worktree to-base 9|worktree remove 9|agent [a-z]+' "$STUB_DIR/journal" | tr '\n' '>' | sed 's/>$//'; }

# AC1: the merge is not the end. PR 12 merges, the checkout is returned, and
# the same command dispatches the next queued issue; the run ends on the next
# terminal answer.
drain_fixture returned
st_pr 21 > "$STUB_DIR/collect.json"
st_q 21 > "$STUB_DIR/collect.merged"
st_q "" > "$STUB_DIR/collect.drained"
vi 21 '{"name": "pipeline:ready"}'
printf 'cp "$d/collect.merged" "$d/collect.json"\n' > "$STUB_DIR/hook.merge-pr"
printf 'cp "$d/collect.drained" "$d/collect.json"\n' > "$STUB_DIR/hook.validator.1"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=17000 rn --max-iterations 6
assert_eq "0" "$RC" "AC1 (#601): the run that merged and went on exits 0"
assert_contains "$OUT" "merged=pr=12" "AC1 (#601): the merge is reported as merged=pr=<M>"
assert_not_contains "$OUT" "stop merged" "AC1 (#601): an untargeted run prints no stop merged line"
assert_eq "merge-pr 12>worktree to-base 9>worktree remove 9>agent validator" "$(drain_order)" \
  "AC1 (#601): the same command performs the next pass: the second queued issue gets its dispatch after the merge"
assert_eq "stop action=wait reason=none" "$(last_line)" "AC1 (#601): the run ends on the next terminal answer"
# checkout=synced and checkout=kept go on the same way.
for _s in synced kept; do
  drain_fixture "$_s"
  st_pr 21 > "$STUB_DIR/collect.json"
  st_q 21 > "$STUB_DIR/collect.merged"
  st_q "" > "$STUB_DIR/collect.drained"
  vi 21 '{"name": "pipeline:ready"}'
  printf 'cp "$d/collect.merged" "$d/collect.json"\n' > "$STUB_DIR/hook.merge-pr"
  printf 'cp "$d/collect.drained" "$d/collect.json"\n' > "$STUB_DIR/hook.validator.1"
  TALOS_LEASE_TTL_S=1800 TALOS_NOW=17000 rn --max-iterations 6
  assert_contains "$(journal)" "agent validator" "AC1 (#601): checkout=$_s goes on to the next pass"
done

# AC2: the next pass is a new image of $SCRIPT_DIR/talos.sh reached by exec.
# The file is replaced while post-merge returns the checkout (that is when a
# merge of Talos's own scripts lands on disk); the replacement records its PID,
# its arguments, the pass count it was handed, the run's leases still in the
# ledger and the scratch directories still on disk, then ends the run.
drain_fixture returned
st_pr "" > "$STUB_DIR/collect.json"
mkdir -p "$SANDBOX/tmp-601"
cp "$GS/talos.sh" "$GS/talos.orig"
cat > "$STUB_DIR/talos.new" <<'TALOS_newimageQ4xNv8Lr'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
leases="$(grep -c "pid=$$\$" "${LEASE_FILE:?}" 2>/dev/null)"
{
  printf 'pid=%s args=%s passes=%s\n' "$$" "$*" "${TALOS_RUN_PASSES-<unset>}"
  printf 'leases=%s\n' "${leases:-0}"
  printf 'scratch=%s\n' "$(find "${TMPDIR:?}" -maxdepth 1 -name 'talos-cfg-cache.*' | wc -l | tr -d ' ')"
} > "$d/new-image"
printf 'new-image\n'
TALOS_newimageQ4xNv8Lr
cat > "$STUB_DIR/hook.worktree" <<'TALOS_hookwtB7mKq3Zs'
if [ "$1" = to-base ]; then
  # A lease of this run that only the run's exit hook can free.
  printf 'issue=77 held=17000 expires=18800 pid=%s\n' "${TALOS_RUN_PID:?}" >> "${LEASE_FILE:?}"
  cp "$d/talos.new" "${GS_DIR:?}/talos.sh.new" && mv "$GS_DIR/talos.sh.new" "$GS_DIR/talos.sh"
fi
TALOS_hookwtB7mKq3Zs
TMPDIR="$SANDBOX/tmp-601" TALOS_LEASE_TTL_S=1800 TALOS_NOW=17000 bash "$RUN" run --max-iterations 4 > "$SANDBOX/out.601" 2>"$ERR" &
_run_pid=$!
wait "$_run_pid"; RC=$?
OUT="$(cat "$SANDBOX/out.601")"
cp "$GS/talos.orig" "$GS/talos.sh"
assert_eq "0" "$RC" "AC2 (#601): the continued run exits with the new image's status"
assert_eq "merged=pr=12
new-image" "$OUT" "AC2 (#601): the run flushed its output before the exec, and the replaced talos.sh ran the next pass"
assert_eq "pid=$_run_pid args=run --max-iterations 4 passes=$_run_pid:1" "$(sed -n 1p "$STUB_DIR/new-image" 2>/dev/null)" \
  "AC2 (#601): the new image has the run's PID (exec, not a child) and its arguments"
assert_eq "leases=0" "$(sed -n 2p "$STUB_DIR/new-image" 2>/dev/null)" "AC2 (#601): the exit hooks ran before the exec: no lease of the run is left in the ledger"
assert_eq "scratch=0" "$(sed -n 3p "$STUB_DIR/new-image" 2>/dev/null)" "AC2 (#601): the exit hooks ran before the exec: the run's scratch directory is gone"
# An unreadable $SCRIPT_DIR/talos.sh: there is nothing to exec.
drain_fixture returned
st_pr "" > "$STUB_DIR/collect.json"
printf '[ "$1" != to-base ] || mv "${GS_DIR:?}/talos.sh" "$GS_DIR/talos.gone"\n' > "$STUB_DIR/hook.worktree"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=17000 rn --max-iterations 4
[ ! -f "$GS/talos.gone" ] || mv "$GS/talos.gone" "$GS/talos.sh"
assert_eq "1" "$RC" "AC2 (#601): an unreadable talos.sh after the merge exits 1"
assert_eq "stop reason=scripts-missing" "$(last_line)" "AC2 (#601): an unreadable talos.sh after the merge is stop reason=scripts-missing"

# AC3: --max-iterations caps the passes of the whole command, the merge pass
# included. Pass 1 validates #21, pass 2 merges PR 12, pass 3 validates #22.
drain_fixture returned
st_q 21 > "$STUB_DIR/collect.json"
st_pr 22 > "$STUB_DIR/collect.pr"
st_q 22 > "$STUB_DIR/collect.merged"
vi 21 '{"name": "pipeline:ready"}'
vi 22 '{"name": "pipeline:ready"}'
printf 'cp "$d/collect.pr" "$d/collect.json"\n' > "$STUB_DIR/hook.validator.1"
printf 'cp "$d/collect.merged" "$d/collect.json"\n' > "$STUB_DIR/hook.merge-pr"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=17000 rn --max-iterations 3
assert_eq "0" "$RC" "AC3 (#601): the capped drain exits 0"
assert_eq "agent validator>merge-pr 12>worktree to-base 9>worktree remove 9>agent validator" "$(drain_order)" \
  "AC3 (#601): --max-iterations 3 with a merge on pass 2 runs exactly one more pass"
assert_eq "stop reason=iterations-exhausted max=3" "$(last_line)" "AC3 (#601): the passes of the whole command are capped, the merge pass included"
# The count crosses the exec in TALOS_RUN_PASSES=<pid>:<passes>, honoured only
# by the process it names.
reset_stubs; LEASE_RESET
printf 'CONFIRMED: real\n' > "$STUB_DIR/message"
OUT="$(TALOS_LEASE_TTL_S=1 TALOS_NOW=17100 bash -c 'export TALOS_RUN_PASSES="$$:3"; exec bash "$0" run --max-iterations 3' "$RUN" 2>"$ERR")"
assert_eq "stop reason=iterations-exhausted max=3" "$OUT" "AC3 (#601): the pass count naming the current PID is honoured: no pass is left"
assert_not_contains "$(journal)" "agent validator" "AC3 (#601): a run whose passes are used up dispatches nothing"
reset_stubs; LEASE_RESET
printf 'CONFIRMED: real\n' > "$STUB_DIR/message"
OUT="$(TALOS_LEASE_TTL_S=1 TALOS_NOW=17100 bash -c 'export TALOS_RUN_PASSES="$$:2"; exec bash "$0" run --max-iterations 3' "$RUN" 2>"$ERR")"
assert_eq "1" "$(journal | grep -c '^agent validator$')" "AC3 (#601): two passes used of three leaves exactly one"
reset_stubs; LEASE_RESET
printf 'CONFIRMED: real\n' > "$STUB_DIR/message"
TALOS_RUN_PASSES="1:3" TALOS_LEASE_TTL_S=1 TALOS_NOW=17100 rn --max-iterations 3
assert_eq "3" "$(journal | grep -c '^agent validator$')" "AC3 (#601): the same value seen by any other process is ignored: all three passes run"
reset_stubs; LEASE_RESET
printf 'CONFIRMED: real\n' > "$STUB_DIR/message"
OUT="$(TALOS_LEASE_TTL_S=1 TALOS_NOW=17100 bash -c 'export TALOS_RUN_PASSES="$$:x"; exec bash "$0" run --max-iterations 2' "$RUN" 2>"$ERR")"
assert_eq "2" "$(journal | grep -c '^agent validator$')" "AC3 (#601): a pass count that is not a number is ignored"

# AC4: a targeted run ends after its merge. The collect keeps PR 12 at the
# merge stage, so a further pass would merge again.
drain_fixture returned
TALOS_LEASE_TTL_S=1800 TALOS_NOW=17200 rn --issue 9 --max-iterations 5
assert_eq "0" "$RC" "AC4 (#601): run --issue exits 0 after its merge"
assert_eq "merge-pr 12>worktree to-base 9>worktree remove 9" "$(drain_order)" "AC4 (#601): run --issue merges once, post-merge returns the checkout, and no further pass runs"
assert_eq "merged=pr=12
stop merged pr=12" "$OUT" "AC4 (#601): run --issue ends with stop merged pr=<M>"

# AC5 (#644): QA ran detached (the fallback) and the merge ends the run: to-base
# returns the driver's checkout (it answers returned) and the run ends merged.
drain_fixture returned
TALOS_LEASE_TTL_S=1800 TALOS_NOW=17210 rn --issue 9 --max-iterations 5
assert_eq "stop merged pr=12" "$(last_line)" "AC5 (#644): a merged run whose checkout was detached ends stop merged, checkout back"
assert_not_contains "$OUT" "checkout-return-failed" "AC5 (#644): and no failed return is reported"

# AC8 (the run half): post-merge did not say the checkout is back (no
# checkout=returned|synced|kept line): the run ends there, untargeted and
# --issue alike.
drain_fixture "failed reason=dirty"
st_pr 21 > "$STUB_DIR/collect.json"
st_q 21 > "$STUB_DIR/collect.merged"
vi 21 '{"name": "pipeline:ready"}'
printf 'cp "$d/collect.merged" "$d/collect.json"\n' > "$STUB_DIR/hook.merge-pr"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=17300 rn --max-iterations 5
assert_eq "0" "$RC" "AC8 (#601): a failed checkout return ends the run with exit 0"
assert_eq "stop merged pr=12 reason=checkout-return-failed" "$(last_line)" "AC8 (#601): a failed checkout return is stop merged pr=<M> reason=checkout-return-failed"
assert_not_contains "$(journal)" "agent validator" "AC8 (#601): no further pass after a failed checkout return"
drain_fixture returned
: > "$STUB_DIR/worktree.out"
printf 1 > "$STUB_DIR/worktree.rc"
st_pr 21 > "$STUB_DIR/collect.json"
st_q 21 > "$STUB_DIR/collect.merged"
vi 21 '{"name": "pipeline:ready"}'
printf 'cp "$d/collect.merged" "$d/collect.json"\n' > "$STUB_DIR/hook.merge-pr"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=17300 rn --max-iterations 5
assert_eq "stop merged pr=12 reason=checkout-return-failed" "$(last_line)" "AC8 (#601): a to-base that printed no state ends the run the same way"
assert_not_contains "$(journal)" "agent validator" "AC8 (#601): no further pass when to-base printed no state"
drain_fixture "failed reason=pull-failed"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=17300 rn --issue 9 --max-iterations 5
assert_eq "0" "$RC" "AC8 (#601): run --issue with a failed checkout return exits 0"
assert_eq "stop merged pr=12 reason=checkout-return-failed" "$(last_line)" "AC8 (#601): run --issue names the failed checkout return too"
assert_eq "1" "$(journal | grep -c 'vcs merge-pr 12')" "AC8 (#601): run --issue runs no further pass after a failed checkout return"

# AC11: priority holds across validation and development. A ready p0 (#5) and
# a ready p2 (#6): once the validator confirms #5, the next pass is its PM, and
# #6 gets no validator before that.
reset_stubs; LEASE_RESET; rm -f "$STOPF"
cfg_json '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "pm": true, "pm_skip_when_spec_present": false}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}'
st_q "5, 6" "" '{"5": 0, "6": 2}' > "$STUB_DIR/collect.json"
st_q 6 5 '{"5": 0, "6": 2}' > "$STUB_DIR/collect.confirmed"
vi 5 '{"name": "pipeline:ready"}, {"name": "p0"}'
vi 6 '{"name": "pipeline:ready"}, {"name": "p2"}'
printf '{"number": 5, "title": "t", "labels": [{"name": "pipeline:confirmed"}, {"name": "p0"}], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.5.confirmed"
printf 'CONFIRMED: real\n' > "$STUB_DIR/message.validator"
printf 'spec posted\n' > "$STUB_DIR/message.pm"
cat > "$STUB_DIR/hook.validator.1" <<'TALOS_hookvalD2rYw9Jc'
cp "$d/collect.confirmed" "$d/collect.json"
cp "$d/view-issue.5.confirmed" "$d/view-issue.5"
TALOS_hookvalD2rYw9Jc
TALOS_LEASE_TTL_S=1 TALOS_NOW=17400 rn --max-iterations 2
assert_eq "validator:5:
pm:5:" "$(cat "$STUB_DIR/agent.env" 2>/dev/null)" "AC11 (#601): the confirmed p0 gets its PM on the next pass; the ready p2 gets no validator before that"

# AC13: run --stop writes the request and does nothing else.
reset_stubs; LEASE_RESET; rm -f "$STOPF"
rn --stop
assert_eq "0" "$RC" "AC13 (#601): run --stop exits 0"
assert_eq "stop=requested" "$OUT" "AC13 (#601): run --stop prints stop=requested"
assert_file_exists "$STOPF" "AC13 (#601): run --stop writes run.stop in the run-state directory"
assert_eq "" "$(journal)" "AC13 (#601): run --stop calls no next and no agent"
rm -f "$STOPF"
for _a in "--stop --issue 9" "--issue 9 --stop" "--stop --max-iterations 3" "--max-iterations 3 --stop" "--stop --stop"; do
  # shellcheck disable=SC2086
  rn $_a
  assert_eq "2 stop reason=usage" "$RC $OUT" "AC13 (#601): run $_a is a usage error"
  assert_file_absent "$STOPF" "AC13 (#601): run $_a writes no request"
done

# AC14: the request is read at the top of every pass, before next. Here it is
# written while the validator of pass 1 runs: that stage finishes (its done
# included), and pass 2 stops before it reads the state or takes a lease.
reset_stubs; LEASE_RESET; rm -f "$STOPF"
printf 'CONFIRMED: real\n' > "$STUB_DIR/message"
printf 'bash "${GS_DIR:?}/talos.sh" run --stop > "$d/stop.out" 2>&1\n' > "$STUB_DIR/hook.validator.1"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=17500 rn --max-iterations 5
assert_eq "0" "$RC" "AC14 (#601): a requested stop exits 0"
assert_eq "stop reason=stop-requested" "$(last_line)" "AC14 (#601): the run stops at the stage boundary with stop reason=stop-requested"
assert_contains "$(journal)" "hooks post_stage validator validator 9 --verdict CONFIRMED" "AC14 (#601): the stage that was running finished, its done included"
assert_eq "1" "$(journal | grep -c '^agent validator$')" "AC14 (#601): no stage starts after the request"
assert_eq "1" "$(journal | grep -c '^status-file collect$')" "AC14 (#601): the request is read before next (no second state read)"
assert_eq "" "$(cat "$LEASE" 2>/dev/null)" "AC14 (#601): the stopped pass took no lease"
assert_file_absent "$STOPF" "AC14 (#601): the run deletes the request it honoured"
# A run started fresh deletes a leftover request before its first pass.
reset_stubs; LEASE_RESET; rm -f "$STOPF"
printf 'CONFIRMED: real\n' > "$STUB_DIR/message"
rn --stop
TALOS_LEASE_TTL_S=1 TALOS_NOW=17600 rn --max-iterations 1
assert_not_contains "$OUT" "stop-requested" "AC14 (#601): a fresh run is not stopped by a leftover request"
assert_eq "1" "$(journal | grep -c '^agent validator$')" "AC14 (#601): a fresh run runs its first pass past a leftover request"
assert_file_absent "$STOPF" "AC14 (#601): a fresh run deletes the leftover request"
# The first pass after a merge's exec reads the request too (the continuation
# is not a fresh start): written while post-merge returns the checkout.
drain_fixture returned
st_pr 21 > "$STUB_DIR/collect.json"
st_q 21 > "$STUB_DIR/collect.merged"
vi 21 '{"name": "pipeline:ready"}'
printf 'cp "$d/collect.merged" "$d/collect.json"\n' > "$STUB_DIR/hook.merge-pr"
printf '[ "$1" != to-base ] || bash "${GS_DIR:?}/talos.sh" run --stop > "$d/stop.out" 2>&1\n' > "$STUB_DIR/hook.worktree"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=17700 rn --max-iterations 5
assert_eq "0" "$RC" "AC14 (#601): a stop requested during the merge pass exits 0"
assert_eq "merged=pr=12
stop reason=stop-requested" "$OUT" "AC14 (#601): the first pass after a merge's exec honours the request"
assert_not_contains "$(journal)" "agent validator" "AC14 (#601): no stage starts after a merge when a stop was requested"
assert_file_absent "$STOPF" "AC14 (#601): the continuation deletes the request it honoured"

# ── (n) the docs delta re-stamp (#590) ───────────────────────────────────────
# `docs-gate` answers `shape=restamp restamp-file=<F>` when docs:done is on the
# PR and stale: the docs agent then gets the re-stamp prompt with <F> in it, and
# its RESTAMP_PASS / RESTAMP_FAIL line is the verdict `done docs` records. The
# history is the sandbox's own repo (last in this file: no other test sees it).
git config user.name "talos-test"
git config user.email "test@talos.invalid"
printf 'readme at the approval\n' > README.md
git add README.md
git commit -q -m "the approved head"
RS_S="$(git rev-parse HEAD)"
printf 'readme after the fix round\n' > README.md
git add README.md
git commit -q -m "fix round: the readme"
RS_H="$(git rev-parse HEAD)"
mkdir -p "$SANDBOX/tmp-rs"
restamp_fixture() {  # $1 = the docs agent's final message
  reset_stubs; LEASE_RESET
  draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
  draft_collect docs
  printf 'README.md\nscripts/talos.sh\n' > "$STUB_DIR/pr-files"
  printf '{"labels": [{"name": "docs:done"}], "state": "open"}' > "$STUB_DIR/view-pr.12"
  printf 'stale role=docs label=docs:done sha=%s\n' "$RS_S" > "$STUB_DIR/check-approval-sha"
  printf 1 > "$STUB_DIR/check-approval-sha.rc"
  printf '%s\n' "$RS_H" > "$STUB_DIR/pr-head"
  printf '%s\n' "$1" > "$STUB_DIR/message.docs"
  # #640: the (stubbed) pr-worktree answers the sandbox checkout for issue 9.
  printf '%s\n' "$SANDBOX" > "$STUB_DIR/worktree.9"
}
rs_files() { find "$SANDBOX/tmp-rs" -maxdepth 1 -name 'talos-docs-*' 2>/dev/null | wc -l | tr -d ' '; }

restamp_fixture 'RESTAMP_PASS: the README delta matches the code'
TMPDIR="$SANDBOX/tmp-rs" TALOS_LEASE_TTL_S=1800 TALOS_NOW=18000 rn --max-iterations 1
RS_PROMPT="$(cat "$STUB_DIR/agent.stdin" 2>/dev/null)"
assert_eq "0" "$RC" "AC7 a docs RESTAMP_PASS: the run exits 0"
assert_contains "$(journal)" "agent docs" "AC7 the docs re-stamp dispatches the docs agent"
assert_contains "$RS_PROMPT" "Comment header: **Agent:** docs (talos) — re-stamp" "AC7 the docs agent gets the re-stamp render"
assert_contains "$RS_PROMPT" "approved_sha=$RS_S
head_sha=$RS_H
README.md" "AC7 the re-stamp render carries the re-stamp file"
assert_contains "$RS_PROMPT" "+readme after the fix round" "AC7 the re-stamp render carries the delta's diff"
assert_not_contains "$RS_PROMPT" "Read diff:" "AC7 the re-stamp render is not the first-shape prompt (no --docs-paths-file)"
assert_not_contains "$(journal)" "vcs diff-pr 12" "AC7 the re-stamp render fetches no PR diff (no --embed-change)"
assert_eq "0" "$(rs_files)" "AC7 the re-stamp file is removed after the render"
assert_contains "$(journal)" "hooks post_stage docs docs 9 --pr 12 --verdict RESTAMP_PASS" "AC7 a RESTAMP_PASS line reaches done docs as --verdict RESTAMP_PASS"
assert_eq "stop reason=iterations-exhausted max=1" "$(last_line)" "AC7 after a docs RESTAMP_PASS the run goes on to the next pass"

restamp_fixture 'RESTAMP_FAIL: the README still names the old flag'
TMPDIR="$SANDBOX/tmp-rs" TALOS_LEASE_TTL_S=1800 TALOS_NOW=18100 rn --max-iterations 1
assert_eq "0" "$RC" "AC7 a docs RESTAMP_FAIL: the run exits 0"
assert_contains "$(journal)" "hooks post_stage docs docs 9 --pr 12 --verdict RESTAMP_FAIL" "AC7 a RESTAMP_FAIL line reaches done docs as --verdict RESTAMP_FAIL"
assert_contains "$(journal)" "vcs label-pr 12 --remove docs:done" "AC7 a docs RESTAMP_FAIL: done drops the stale docs:done"
assert_eq "0" "$(journal | grep -c '^agent developer$')" "AC7 a docs RESTAMP_FAIL starts no developer fix round"
assert_eq "stop reason=iterations-exhausted max=1" "$(last_line)" "AC7 after a docs RESTAMP_FAIL the run goes on to the next pass"

restamp_fixture 'docs posted: nothing to change'
TMPDIR="$SANDBOX/tmp-rs" TALOS_LEASE_TTL_S=1800 TALOS_NOW=18200 rn --max-iterations 1
assert_eq "1" "$RC" "AC7 a docs re-stamp answer with neither word: exit 1"
assert_contains "$OUT" "reason=dispatch-failed role=docs" "AC7 a docs re-stamp answer with neither word is a dispatch failure"
assert_contains "$(cat "$ERR")" "reason=verdict-unreadable" "AC7 a docs re-stamp answer with neither word: verdict-unreadable"
assert_not_contains "$(journal)" "hooks post_stage" "AC7 a docs re-stamp answer with neither word: nothing recorded"

finish
