#!/usr/bin/env bash
# test-multi-user.sh -- several operators on one repo (#560, #949): the ownership
# filter of `collect`, `next`, `state --summary` and `run`: only issues assigned
# to the operator (and their PRs) route; an unassigned issue is never routed or
# claimed automatically, `talos.sh claim N` is the explicit way to take it.
#
# Two operators, A = alice and B = bob (the stub's current-user is $STUB_ME),
# share one stub repo whose issues and PRs carry assignees:
#   #1 ready, bob's           #2 ready, alice's        #3 ready, unassigned
#   #4 pipeline:dev, bob's    #6 blocked, bob's
#   #7 bob's, with PR 17 (qa next)    #8 bob's, with PR 18 (blocked)
#
#   - A's collect/next/run never routes anything of B's (queued, in flight,
#     blocked, PRs, needs-owner) and B's items show up as `theirs`
#   - an unassigned item is not routed and not claimed by `next`/`run`
#     (`unassigned: #N` in `state --summary`, `next --issue N` answers
#     `wait reason=unassigned`); `claim N` takes it and the next `next` routes it
#   - issues.claim: false, issues.assignee: none, an unresolvable identity and
#     an unsupported provider each give today's unfiltered behaviour exactly
#
# Verb-level provider stub (a copy of scripts/ with its own pipeline-vcs.sh);
# the lease ledger and everything else is real.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

PARENT="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-multiuser.XXXXXX")" || exit 1
trap '_is_trap_owner && rm -rf "$SANDBOX" "$PARENT"' EXIT
FX="$PARENT/fx"
GS="$PARENT/scripts"
export SF_FX="$FX"
unset TALOS_CLAIM_STATE
cp -R "$TALOS_ROOT/scripts" "$GS"

cat > "$GS/pipeline-vcs.sh" <<'TALOS_stubvcsMu560Xk'
#!/usr/bin/env bash
# Verb-level stub; fixtures in $SF_FX. Every call is logged (writes too).
FX="${SF_FX:?}"
verb="${1:-}"; shift
printf '%s %s\n' "$verb" "$*" >> "$FX/calls.log"
rc_of() { if [ -f "$FX/$1" ]; then cat "$FX/$1"; else echo "${2:-0}"; fi; }
case "$verb" in
  current-user)
    [ -n "${STUB_ME:-}" ] || exit 1
    echo "$STUB_ME" ;;
  list-assignees)
    [ -f "$FX/assignees.err" ] && cat "$FX/assignees.err" >&2
    # The bulk view of the per-issue files in $FX/as, read fresh on every call.
    python3 -I -c "
import json, os, sys
d = {}
for n in os.listdir(sys.argv[1]):
    if n.isdigit():
        who = [l for l in open(os.path.join(sys.argv[1], n)).read().split() if l]
        if who:
            d[n] = who
print(json.dumps(d))" "$FX/as"
    exit "$(rc_of assignees.rc 0)" ;;
  issue-assignees)
    cat "$FX/as/$1" 2>/dev/null; exit 0 ;;
  assign-issue)
    mkdir -p "$FX/as"
    [ -f "$FX/as/drop" ] || { grep -qxF "${STUB_ME:-}" "$FX/as/$1" 2>/dev/null || echo "${STUB_ME:-}" >> "$FX/as/$1"; }
    # A racer's write lands at the same moment (one login, used once).
    [ -f "$FX/racer" ] && { grep -qxF "$(cat "$FX/racer")" "$FX/as/$1" 2>/dev/null || cat "$FX/racer" >> "$FX/as/$1"; rm -f "$FX/racer"; }
    echo "assign-issue: #$1 assigned to ${STUB_ME:-}" ;;
  unassign-issue)
    grep -vxF "$2" "$FX/as/$1" > "$FX/as/$1.t"; mv "$FX/as/$1.t" "$FX/as/$1"
    echo "unassign-issue: #$1 unassigned $2" ;;
  list-prs)
    cat "$FX/prs.json" ;;
  list-issues)
    cat "$FX/issues.json" ;;
  view-issue)
    python3 -I -c "
import json, sys
n = int(sys.argv[2])
for i in json.load(open(sys.argv[1])):
    if i['number'] == n:
        i = dict(i); i['state'] = 'open'; print(json.dumps(i)); break
" "$FX/issues.json" "$1" ;;
  pr-head)
    cat "$FX/head.$1" || exit 1 ;;
  check-approval-sha|pr-checks-required) exit 0 ;;
  pr-is-draft) exit 1 ;;
  list-needs-owner)
    if [ -f "$FX/owners.json" ]; then cat "$FX/owners.json"; else echo '[]'; fi ;;
  has-spec|check-attempt) exit 1 ;;
  *) echo "pipeline-vcs: $verb: not implemented for provider 'stub'" >&2; exit 1 ;;
esac
TALOS_stubvcsMu560Xk

cat > "$GS/pipeline-agent.sh" <<'TALOS_stubagentMu560Xk'
#!/usr/bin/env bash
# Any stage dispatch through `run` lands here: it must never happen for B's work.
echo "AGENT $*" >> "${SF_FX:?}/agent.log"
exit 1
TALOS_stubagentMu560Xk
TN="$GS/talos.sh"
SF="$GS/pipeline-status-file.sh"

cfg_p() {  # [extra top-level JSON members]
  printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main", "pr": {"draft": false}%s}\n' "${1:+, $1}" > talos.pipeline.json
}

# ── the shared repo ──────────────────────────────────────────────────────────
reset_repo() {
  rm -rf "$FX"; mkdir -p "$FX/as"; : > "$FX/calls.log"
  unset TALOS_CLAIM_STATE
  cat > "$FX/issues.json" <<'EOF'
[{"number":1,"title":"one","labels":[{"name":"pipeline:ready"}],"body":""},
 {"number":2,"title":"two","labels":[{"name":"pipeline:ready"}],"body":""},
 {"number":3,"title":"three","labels":[{"name":"pipeline:ready"}],"body":""},
 {"number":4,"title":"four","labels":[{"name":"pipeline:dev"}],"body":""},
 {"number":6,"title":"six","labels":[{"name":"pipeline:blocked"}],"body":""},
 {"number":7,"title":"seven","labels":[{"name":"pipeline:dev"}],"body":""},
 {"number":8,"title":"eight","labels":[{"name":"pipeline:dev"}],"body":""}]
EOF
  cat > "$FX/prs.json" <<'EOF'
[{"number":17,"title":"PR 17","headRefName":"fix/issue-7-x","baseRefName":"main","isCrossRepository":false,"labels":[{"name":"pipeline:dev"}]},
 {"number":18,"title":"PR 18","headRefName":"fix/issue-8-x","baseRefName":"main","isCrossRepository":false,"labels":[{"name":"pipeline:blocked"}]}]
EOF
  printf '%040d\n' 17 > "$FX/head.17"; printf '%040d\n' 18 > "$FX/head.18"
  printf 'bob\n' > "$FX/as/1"; printf 'alice\n' > "$FX/as/2"; : > "$FX/as/3"
  printf 'bob\n' > "$FX/as/4"; printf 'bob\n' > "$FX/as/6"; printf 'bob\n' > "$FX/as/7"; printf 'bob\n' > "$FX/as/8"
}
LEASE="$SANDBOX/.git/talos-lease.ledger"
as_state() { sort "$FX/as/$1" 2>/dev/null | paste -sd, -; }
calls() { cat "$FX/calls.log"; }
count_calls() { grep -c "^$1 " "$FX/calls.log" || true; }

# me <login> <verb args...> : run talos.sh as that operator; OUT / RC set.
me() {
  local who="$1"; shift
  rm -f "$LEASE" "${LEASE:?}.lock.d"
  OUT="$(STUB_ME="$who" bash "$TN" "$@" 2>"$PARENT/err")"; RC=$?
  ERR="$(cat "$PARENT/err")"
}
J() {  # python expression over the collect JSON in $OUT as d
  printf '%s' "$OUT" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
v = eval(sys.argv[1])
print(v if isinstance(v, str) else json.dumps(v, separators=(",", ":")))' "$1"
}
collect_as() {  # <login>
  OUT="$(STUB_ME="$1" bash "$SF" collect 2>"$PARENT/err")"; RC=$?
  ERR="$(cat "$PARENT/err")"
}

# ═════ collect: the ownership filter ════════════════════════════════════════
cfg_p; reset_repo
collect_as alice
assert_eq "0" "$RC" "collect as alice: exits 0"
assert_eq '[2]' "$(J "d['queued']")" "AC3 A: only the issues assigned to A are queued (not bob's #1, not the unassigned #3)"
assert_eq '[]' "$(J "d['inflight']")" "A: bob's pipeline:dev issue #4 is not in flight for A"
assert_eq '[]' "$(J "d['blocked']")" "A: bob's blocked issue and blocked PR are not A's to report"
assert_eq '[]' "$(J "d['prs']")" "A: bob's pipeline PRs are not A's"
assert_eq '[3]' "$(J "d['unassigned']")" "AC1 A: the unassigned ready issue is listed as unassigned, not queued"
assert_eq 'False' "$(J "'unclaimed' in d")" "AC1 A: nothing is left for next to claim"
assert_eq 'alice' "$(J "d['me']")" "A: the state names the operator"
assert_eq '[[1,"bob"],[4,"bob"],[6,"bob"],[7,"bob"],[8,"bob"]]' "$(J "[[t['issue'], t['owner']] for t in d['theirs'] if t['kind'] == 'issue']")" "A: bob's issues are listed as theirs, with the owner"
assert_eq '[[17,7,"bob"],[18,8,"bob"]]' "$(J "[[t['n'], t['issue'], t['owner']] for t in d['theirs'] if t['kind'] == 'PR']")" "A: bob's PRs are listed as theirs, with the issue and owner"
assert_eq "1" "$(count_calls list-assignees)" "A: one bulk read of the assignees, not one per issue"
assert_eq "0" "$(count_calls pr-head)" "A: no per-PR read is spent on bob's PRs"

collect_as bob
assert_eq '[1]' "$(J "d['queued']")" "B: queued is B's #1 only (the unassigned #3 is nobody's yet)"
assert_eq '[4]' "$(J "d['inflight']")" "B: B's in-flight issue without a PR (7 and 8 have PRs)"
assert_eq '[17,18]' "$(J "[p['n'] for p in d['prs']]")" "B: B's PRs are B's"
assert_eq '[["issue",6],["PR",18]]' "$(J "d['blocked']")" "B: B's blocked items are B's"
assert_eq '[[2,"alice"]]' "$(J "[[t['issue'], t['owner']] for t in d['theirs']]")" "B: A's #2 is theirs"

# needs-owner items of someone else stay out of A's way
cfg_p; reset_repo
printf '%s' '[{"number":1,"title":"one","labels":[{"name":"pipeline:ready"},{"name":"pipeline:needs-owner"}],"body":""},{"number":2,"title":"two","labels":[{"name":"pipeline:ready"}],"body":""}]' > "$FX/issues.json"
printf '%s' '[{"n":1,"answered":"no","question":"which way?"}]' > "$FX/owners.json"
collect_as alice
assert_eq '[]' "$(J "d['held']")" "A: bob's needs-owner issue is not held for A"
assert_eq '[]' "$(J "d['owners']")" "A: bob's owner question is not A's to answer"
assert_eq '[2]' "$(J "d['queued']")" "A: only A's own issue is queued"

# ═════ next: A never routes B's work ═══════════════════════════════════════
cfg_p; reset_repo
me alice next
assert_eq "0|action=dispatch stage=validator issue=2" "$RC|$OUT" "A's next dispatches A's own #2, not bob's #1 (lower number)"
assert_eq "0" "$(count_calls assign-issue)" "A's next on its own issue needs no claim write"
assert_eq "" "$ERR" "A's next says nothing on stderr"

me bob next
assert_eq "0|action=dispatch stage=qa pr=17 issue=7" "$RC|$OUT" "B's next dispatches B's PR 17 at qa"
me alice next
assert_eq "0|action=dispatch stage=validator issue=2" "$RC|$OUT" "A's next never dispatches a stage on B's PR 17"

for n in 1 4 6 7 8; do
  me alice next --issue "$n"
  assert_eq "0|action=wait reason=theirs" "$RC|$OUT" "A's next --issue $n (bob's) is a wait, never a dispatch"
done

# only B's work left in the repo: A has nothing to do
cfg_p; reset_repo
rm -f "$FX/as/2" "$FX/as/3"; printf 'bob\n' > "$FX/as/2"; printf 'bob\n' > "$FX/as/3"
me alice next
assert_eq "0|action=wait reason=none" "$RC|$OUT" "A's next with only bob's work left is wait reason=none"
assert_eq "0" "$(count_calls assign-issue)" "A claims nothing of bob's"

# ═════ an unassigned issue: never routed, never claimed by next/run (#949) ═══
# AC1: #3 is the only free issue; A's next does not take it and does not assign it
cfg_p; reset_repo
printf 'bob\n' > "$FX/as/2"
me alice next
assert_eq "0|action=wait reason=none" "$RC|$OUT" "AC1 A's next does not dispatch the unassigned #3"
assert_eq "0" "$(count_calls assign-issue)" "AC1 A's next does not assign the unassigned #3"
assert_eq "" "$(as_state 3)" "AC1 #3 stays unassigned after next"
rm -f "$FX/agent.log"
me alice run
assert_contains "$OUT" "stop action=wait reason=none" "AC1 A's run ends idle: the unassigned #3 is not dispatched"
assert_eq "0" "$(count_calls assign-issue)" "AC1 A's run does not assign the unassigned #3"
assert_eq "" "$(cat "$FX/agent.log" 2>/dev/null)" "AC1 A's run dispatches no agent on the unassigned #3"
me alice state --summary
assert_contains "$OUT" "where=unassigned: #3" "AC1 state --summary lists the unassigned #3 on its own line"
assert_contains "$OUT" "where=next: nothing queued" "AC1 state --summary: the unassigned #3 is not A's next"

# AC2: a pin on an unassigned issue answers wait reason=unassigned and writes nothing
me alice next --issue 3
assert_eq "0|action=wait reason=unassigned" "$RC|$OUT" "AC2 next --issue 3 (unassigned) answers wait reason=unassigned"
assert_eq "" "$(as_state 3)" "AC2 the pinned issue stays unassigned"
assert_eq "0" "$(count_calls assign-issue)" "AC2 a pin writes no assignee"

# an unassigned in-flight issue is not continued either
cfg_p; reset_repo
: > "$FX/as/4"; printf 'bob\n' > "$FX/as/2"; printf 'bob\n' > "$FX/as/3"
me alice next --issue 4
assert_eq "0|action=wait reason=unassigned" "$RC|$OUT" "AC2 an unassigned in-flight issue is not continued"
me alice next
assert_eq "0|action=wait reason=none" "$RC|$OUT" "AC2 the untargeted walk passes the unassigned in-flight issue over"

# AC3: an issue assigned to A with others routes as today
cfg_p; reset_repo
printf 'bob\nalice\n' > "$FX/as/1"; printf 'bob\n' > "$FX/as/3"
me alice next --issue 1
assert_eq "0|action=dispatch stage=validator issue=1" "$RC|$OUT" "AC3 an issue assigned to A and bob routes to A"
assert_eq "0" "$(count_calls assign-issue)" "AC3 a held issue needs no write"

# AC4: claim N takes the unassigned issue, then next routes it
cfg_p; reset_repo
printf 'bob\n' > "$FX/as/2"
me alice claim 3
assert_eq "0|claim=taken owner=alice" "$RC|$OUT" "AC4 claim 3 takes the unassigned issue"
assert_eq "alice" "$(as_state 3)" "AC4 #3 is assigned to A"
me alice next
assert_eq "0|action=dispatch stage=validator issue=3" "$RC|$OUT" "AC4 the next next routes the claimed #3"

# a lost tie on claim: the lower login keeps the issue
cfg_p; reset_repo
printf 'bob\n' > "$FX/as/2"
printf 'amy\n' > "$FX/racer"
me zed claim 3
assert_eq "0|claim=lost owner=amy" "$RC|$OUT" "AC4 claim 3 lost to a lower login that claimed at once"
assert_eq "amy" "$(as_state 3)" "AC4 exactly one owner of #3: the lower login"

# AC6: the rule is the same whichever provider the config names (the verb stub
# stands in for each provider's list-assignees / assign-issue)
for P in github github-api gitlab azure; do
  printf '{"vcs": {"provider": "%s", "repo": "acme/widget"}, "base_branch": "main", "pr": {"draft": false}}\n' "$P" > talos.pipeline.json
  reset_repo
  printf 'bob\n' > "$FX/as/2"
  me alice next
  assert_eq "0|action=wait reason=none" "$RC|$OUT" "AC6 $P: the unassigned #3 is not dispatched"
  me alice next --issue 3
  assert_eq "0|action=wait reason=unassigned" "$RC|$OUT" "AC6 $P: next --issue 3 answers wait reason=unassigned"
  assert_eq "0" "$(count_calls assign-issue)" "AC6 $P: nothing assigned by next"
  me alice claim 3
  assert_eq "0|claim=taken owner=alice" "$RC|$OUT" "AC6 $P: claim 3 takes it"
  me alice next
  assert_eq "0|action=dispatch stage=validator issue=3" "$RC|$OUT" "AC6 $P: the next next routes it"
done

# #582: a pinned next routes the pinned issue's own PR -- the issue carries no
# pipeline label once its PR is open -- once the issue is the operator's
cfg_p; reset_repo
printf '%s' '[{"number":9,"title":"nine","labels":[],"body":""},{"number":10,"title":"ten","labels":[],"body":""}]' > "$FX/issues.json"
printf '%s' '[{"number":19,"title":"PR 19","headRefName":"fix/issue-9-x","baseRefName":"main","isCrossRepository":false,"labels":[{"name":"pipeline:review"}]}]' > "$FX/prs.json"
printf '%040d\n' 19 > "$FX/head.19"
rm -f "$FX"/as/[0-9]*; : > "$FX/as/9"; : > "$FX/as/10"
me alice next --issue 10
assert_eq "0|action=wait reason=none" "$RC|$OUT" "#582: A's pin on an issue without a PR never routes another issue's PR"
me alice next --issue 9
assert_eq "0|action=wait reason=unassigned" "$RC|$OUT" "AC2 #582: the PR of an unassigned issue is not routed by A's pin"
me alice next
assert_eq "0|action=wait reason=none" "$RC|$OUT" "AC2 #582: the unpinned next does not route the PR of an unassigned issue"
assert_eq "0" "$(count_calls assign-issue)" "AC2 #582: nothing was claimed"
printf 'alice\n' > "$FX/as/9"
me alice next --issue 9
assert_eq "0|action=dispatch stage=qa pr=19 issue=9" "$RC|$OUT" "#582: A's pin on #9 routes #9's own PR once it is A's"
me alice next
assert_eq "0|action=dispatch stage=qa pr=19 issue=9" "$RC|$OUT" "#582: the unpinned next answers the same PR"
printf 'bob\n' > "$FX/as/9"
me alice next --issue 9
assert_eq "0|action=wait reason=theirs" "$RC|$OUT" "#582: the PR of bob's issue is not routed by A's pin"

# ═════ state --summary ═════════════════════════════════════════════════════
cfg_p; reset_repo
me alice state --summary
assert_contains "$OUT" "where=theirs: #1 (@bob), #4 (@bob), #6 (@bob), #7 (@bob), #8 (@bob)" "state --summary lists bob's items as theirs"
assert_contains "$OUT" "where=next: start issue #2" "state --summary: A's next is A's own issue"
assert_not_contains "$OUT" "PR #17" "state --summary: bob's PR is not in A's in-flight list"
me bob state --summary
assert_contains "$OUT" "where=theirs: #2 (@alice)" "state --summary as bob lists alice's #2 as theirs"
assert_contains "$OUT" "PR #17 (#7) at qa" "state --summary as bob lists bob's PR"

# ═════ run: no stage is ever dispatched on B's work ════════════════════════
cfg_p; reset_repo
rm -f "$FX/agent.log"
me alice run --issue 1
assert_contains "$OUT" "reason=theirs" "A's run --issue 1 (bob's) stops on theirs"
assert_eq "0" "$(count_calls assign-issue)" "A's run on bob's issue claims nothing"
assert_eq "" "$(cat "$FX/agent.log" 2>/dev/null)" "A's run never dispatches an agent on bob's issue"
for n in 4 7 8; do
  me alice run --issue "$n"
  assert_contains "$OUT" "reason=theirs" "A's run --issue $n (bob's in-flight work) stops on theirs"
done
assert_eq "" "$(cat "$FX/agent.log" 2>/dev/null)" "A's runs never dispatch an agent on bob's in-flight work or PRs"

# only B's work in the repo: an untargeted run ends clean and idle
cfg_p; reset_repo
printf 'bob\n' > "$FX/as/2"; printf 'bob\n' > "$FX/as/3"
me alice run
assert_contains "$OUT" "stop action=wait reason=none" "A's untargeted run with only bob's work ends on wait reason=none"
assert_eq "" "$(cat "$FX/agent.log" 2>/dev/null)" "A's untargeted run dispatches nothing of bob's"
assert_eq "0" "$(count_calls assign-issue)" "A's untargeted run claims nothing of bob's"
assert_eq "1" "$(count_calls current-user)" "a run resolves the operator's identity once, however many next and collect calls it makes"

# ═════ the opt-outs give today's behaviour exactly ═════════════════════════
for variant in 'claim-false|"issues": {"claim": false}' 'assignee-none|"issues": {"assignee": "none"}'; do
  name="${variant%%|*}"; extra="${variant#*|}"
  cfg_p "$extra"; reset_repo
  collect_as alice
  assert_eq '["blocked","capped","held","ignored","inflight","owners","pr_total","priority","prs","queued"]' "$(J 'sorted(d)')" "$name: the state has the ten documented keys, nothing added"
  assert_eq '[1,2,3]' "$(J "d['queued']")" "$name: every ready issue is queued, bob's too"
  assert_eq '[4]' "$(J "d['inflight']")" "$name: every in-flight issue is routed"
  assert_eq '[17,18]' "$(J "[p['n'] for p in d['prs']]")" "$name: every pipeline PR is routed"
  assert_eq "0" "$(count_calls list-assignees)" "$name: no assignee read"
  assert_eq "0" "$(count_calls current-user)" "$name: no identity lookup"
  me alice next
  assert_eq "0|action=dispatch stage=qa pr=17 issue=7" "$RC|$OUT" "$name: A's next takes the lowest PR whoever's it is"
  assert_eq "0" "$(count_calls assign-issue)" "$name: no claim write"
done

# no identity (an Actions token, file mode): unfiltered, quiet
cfg_p; reset_repo
OUT="$(STUB_ME="" bash "$SF" collect 2>"$PARENT/err")"; RC=$?
assert_eq "0" "$RC" "no identity: collect still works"
assert_eq '[1,2,3]' "$(J "d['queued']")" "no identity: nothing is filtered"
assert_eq "" "$(cat "$PARENT/err")" "no identity: nothing on stderr"
assert_eq "0" "$(count_calls list-assignees)" "no identity: the assignees are not read"

# identity.name stands in for the login
cfg_p '"identity": {"name": "bob"}'; reset_repo
collect_as alice
assert_eq '[1,3]' "$(J "d['queued']")" "identity.name: the operator is bob whoever is logged in"
assert_eq "0" "$(count_calls current-user)" "identity.name: no identity lookup"

# a provider with no assignees (file mode answers 2): unfiltered
cfg_p; reset_repo
printf '2\n' > "$FX/assignees.rc"
collect_as alice
assert_eq "0" "$RC" "unsupported list-assignees: collect works"
assert_eq '[1,2,3]' "$(J "d['queued']")" "unsupported list-assignees: nothing is filtered"
assert_eq '["blocked","capped","held","ignored","inflight","owners","pr_total","priority","prs","queued"]' "$(J 'sorted(d)')" "unsupported list-assignees: the ten documented keys"

# a failed read of the assignees fails closed: never route on a guess
cfg_p; reset_repo
printf '1\n' > "$FX/assignees.rc"
collect_as alice
assert_eq "1|" "$RC|$OUT" "a failed list-assignees: exit 1, nothing on stdout"
me alice next
assert_contains "$OUT" "stop reason=state-unavailable" "a failed list-assignees: next stops, it does not dispatch"

finish
