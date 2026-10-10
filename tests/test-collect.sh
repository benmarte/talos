#!/usr/bin/env bash
# test-collect.sh -- behavioural tests for `pipeline-status-file.sh collect`
# (#550): the normalised run state as ONE JSON object on stdout,
#   {prs, pr_total, ignored, blocked, queued, held, inflight, owners, capped}.
#
# Contract under test:
#   - read verbs of pipeline-vcs.sh only (a WRITE verb would be logged and fail)
#   - list-prs, list-issues, pr-head, check-approval-sha, list-needs-owner (exit
#     1) failing is a failed read: exit 1 and NOTHING on stdout
#   - list-needs-owner exit 2 (unsupported provider): owners is null
#   - only the lowest-numbered PRs are looked up, plus merge-ready ones past the cap
#   - TALOS_STATUS_READ_DEADLINE bounds the read phase; a signal kills the verb
#   - usage: exactly `collect`, nothing else, one line on stderr, exit 1
#
# The GitHub reads go through a VERB-LEVEL stub: scripts/ is copied into the
# sandbox and its pipeline-vcs.sh replaced (the script resolves it via its own
# directory), because the `gh` stub has one global head SHA and no isDraft
# handler. The real gh stub is used once, for the no-write assertion.
#
# Every collect costs a handful of process spawns, so a table of cases shares
# one run wherever the config is the same (one PR per case, per-PR fixtures).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

SF_REAL="$TALOS_ROOT/scripts/pipeline-status-file.sh"

PARENT="$(mktemp -d "${TMPDIR:-/tmp}/talos-collect.XXXXXX")" || exit 1
{ [ -n "$PARENT" ] && [ -d "$PARENT" ]; } || exit 1
FX="$PARENT/fx"
SCR="$PARENT/scripts"
trap '_is_trap_owner && rm -rf "$SANDBOX" "$PARENT"' EXIT
mkdir -p "$PARENT/tmp"
export TMPDIR="$PARENT/tmp"
export SF_FX="$FX"

# rm_under_parent <path>...: rm -rf that only acts on paths strictly under
# $PARENT (the checked mktemp -d above); anything else is refused (#448).
rm_under_parent() {
  local d
  for d in "$@"; do
    case "$d" in
      "$PARENT"/*) ;;
      *) echo "rm_under_parent: refusing '$d' (not under \$PARENT)" >&2; exit 1 ;;
    esac
    case "$d" in
      */../*|*/..) echo "rm_under_parent: refusing '$d' (.. component)" >&2; exit 1 ;;
    esac
    rm -rf "$d"
  done
}

# ── copied scripts dir with a verb-level pipeline-vcs.sh stub ───────────────
cp -R "$TALOS_ROOT/scripts" "$SCR"
cat > "$SCR/pipeline-vcs.sh" <<'TALOS_stubvcs7Hq2LmZx'
#!/usr/bin/env bash
# Verb-level stub. Fixtures live in $SF_FX; every call is logged. Any verb that
# is not a read verb is logged as WRITE and fails, so a test can see it.
FX="${SF_FX:?}"
verb="${1:-}"; shift
printf '%s %s\n' "$verb" "$*" >> "$FX/calls.log"
rc_of() { if [ -f "$FX/$1" ]; then cat "$FX/$1"; else echo "${2:-0}"; fi; }
[ -f "$FX/sleep.$verb" ] && { echo $$ > "$FX/verbpid.$verb"; sleep "$(cat "$FX/sleep.$verb")"; }
case "$verb" in
  list-prs)
    [ -f "$FX/prs.err" ] && cat "$FX/prs.err" >&2
    [ -f "$FX/prs.json" ] && cat "$FX/prs.json"
    exit "$(rc_of prs.rc 0)" ;;
  list-issues)
    [ -f "$FX/issues.err" ] && cat "$FX/issues.err" >&2
    [ -f "$FX/issues.json" ] && cat "$FX/issues.json"
    exit "$(rc_of issues.rc 0)" ;;
  pr-head)
    [ -f "$FX/head.$1" ] || exit 1
    cat "$FX/head.$1"; exit 0 ;;
  check-approval-sha)
    [ -f "$FX/stale.$1" ] && cat "$FX/stale.$1"
    exit "$(rc_of "stale.$1.rc" 0)" ;;
  pr-checks-required)
    exit "$(rc_of "ci.$1.rc" 0)" ;;
  pr-is-draft)
    rc="$(rc_of "draft.$1.rc" 1)"
    [ "$rc" = 0 ] && echo draft
    [ "$rc" = 1 ] && echo ready
    exit "$rc" ;;
  current-user)
    # #560: the identity read; none here, so collect keeps every issue (claiming off).
    exit 1 ;;
  list-needs-owner)
    [ -f "$FX/owners.err" ] && cat "$FX/owners.err" >&2
    if [ -f "$FX/owners.json" ]; then cat "$FX/owners.json"; else echo '[]'; fi
    exit "$(rc_of owners.rc 0)" ;;
  *)
    printf 'WRITE %s\n' "$verb" >> "$FX/calls.log"
    exit 99 ;;
esac
TALOS_stubvcs7Hq2LmZx
SF="$SCR/pipeline-status-file.sh"

# pr.draft is explicit (#435: the draft flow is the default, so a table that
# assumes the ready order must say so). RF_DRAFT=true overrides it.
cfg_rf() {  # $1 = extra top-level JSON members
  printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main", "pr": {"draft": %s}%s}\n' \
    "${RF_DRAFT:-false}" "${1:+, $1}" > talos.pipeline.json
}

# ── fixtures for the verb stub ───────────────────────────────────────────────
PRS=(); ISS=()
fx_reset() { rm_under_parent "$FX"; mkdir -p "$FX"; : > "$FX/calls.log"; PRS=(); ISS=(); }
labels_json() {  # "a,b" -> LJ=[{"name":"a"},{"name":"b"}]  (no subshell: fixtures are big)
  local out="" l
  local IFS=,
  for l in $1; do out="${out:+$out,}{\"name\":\"$l\"}"; done
  LJ="[$out]"
}
sha40() { printf '%040d' "$1"; }
add_pr() {  # number branch labels [isCrossRepository: false|true|absent] [baseRefName]
  local cross="\"isCrossRepository\":${4:-false}," h
  [ "${4:-}" = "absent" ] && cross=""
  labels_json "${3:-}"
  PRS+=("{\"number\":$1,\"title\":\"PR $1\",\"headRefName\":\"$2\",\"baseRefName\":\"${5:-main}\",${cross}\"labels\":$LJ}")
  printf -v h '%040d' "$1"
  printf '%s\n' "$h" > "$FX/head.$1"
}
add_issue() {  # number labels
  labels_json "${2:-}"
  ISS+=("{\"number\":$1,\"title\":\"Issue $1\",\"labels\":$LJ,\"body\":\"\"}")
}
join_json() { local IFS=,; printf '[%s]' "$*"; }
fx_flush() {
  join_json ${PRS[@]+"${PRS[@]}"} > "$FX/prs.json"
  join_json ${ISS[@]+"${ISS[@]}"} > "$FX/issues.json"
}
calls() { cat "$FX/calls.log"; }
count_calls() { grep -c "^$1 " "$FX/calls.log" || true; }

# collect: run the verb against the current fixture; OUT, ERR and RC are set.
OUT=""; ERR=""; RC=0
collect() {
  fx_flush
  OUT="$(bash "$SF" collect 2>"$PARENT/err")"; RC=$?
  ERR="$(cat "$PARENT/err")"
}
# J EXPR: evaluate a python expression over the parsed stdout (as `d`); strings
# print raw, everything else as compact JSON.
J() {
  printf '%s' "$OUT" | python3 -I -c '
import json, os, sys
d = json.load(sys.stdin)
v = eval(sys.argv[1])
print(v if isinstance(v, str) else json.dumps(v, separators=(",", ":")))' "$1"
}
stage_of() { J "[p['stage'] for p in d['prs'] if p['n'] == $1][0]"; }
pr_nums() { J "' '.join(str(p['n']) for p in d['prs'])"; }
assert_failed_read() {  # LABEL: exit 1 and nothing on stdout
  assert_eq "1" "$RC" "$1: exits 1"
  assert_eq "" "$OUT" "$1: nothing on stdout"
}

# A table of stage cases that share one config and one collect run. Each case is
# one PR (number N, issue N); tc attaches the per-PR fixture files through
# $TC_LAST (echo 2 > "$FX/ci.$TC_LAST.rc").
TC_N=10; TC_NS=(); TC_WANTS=(); TC_LABELS=(); TC_LAST=0
tc_reset() { fx_reset; TC_N=10; TC_NS=(); TC_WANTS=(); TC_LABELS=(); }
tc() {  # WANT-STAGE LABEL PR-LABELS [ISSUE-LABELS]
  TC_LAST=$TC_N
  add_pr "$TC_N" "fix/issue-$TC_N-x" "$3"; add_issue "$TC_N" "${4:-}"
  TC_NS+=("$TC_N"); TC_WANTS+=("$1"); TC_LABELS+=("$2"); TC_N=$((TC_N + 1))
}
run_cases() {  # NAME
  local i=0 stages
  collect
  assert_eq_ctx "0" "$RC" "$1: collect exits 0" "$ERR"
  stages="$(J "' '.join('%d=%s' % (p['n'], p['stage']) for p in d['prs'])" 2>/dev/null)"
  while [ "$i" -lt "${#TC_NS[@]}" ]; do
    assert_eq "${TC_WANTS[$i]}" "$(printf '%s\n' "$stages" | tr ' ' '\n' | sed -n "s/^${TC_NS[$i]}=//p")" "${TC_LABELS[$i]}"
    i=$((i + 1))
  done
}

# ── argument grammar ─────────────────────────────────────────────────────────
cfg_rf
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
for args in "collect --print" "collect extra" "" "init" "assemble" "refresh" "refresh --print" "assemble --refresh"; do
  # shellcheck disable=SC2086
  o="$(bash "$SF" $args 2>"$PARENT/err")"; rc=$?
  assert_eq "1" "$rc" "args: '$args' exits 1"
  assert_eq "" "$o" "args: '$args' prints nothing on stdout"
  assert_eq "usage: pipeline-status-file.sh collect" "$(cat "$PARENT/err")" "args: '$args' prints the one-line usage on stderr"
done
assert_eq "" "$(calls)" "args: a usage error reads nothing from GitHub"

# ── three PRs: 40-char heads, stages, non-pipeline branches skipped ─────────
fx_reset
add_pr 21 fix/issue-7-b "qa:pass"
add_pr 20 feat/issue-6-a ""
add_pr 22 feat/issue-8 ""
add_pr 30 dependabot/npm/x ""
add_pr 31 feature/issue-9-nope ""
add_pr 32 fix/issue-abc-nope ""
add_pr 33 fix/issue-9x ""
add_issue 6 "pipeline:ready"; add_issue 7 ""; add_issue 8 ""
collect
assert_eq "0" "$RC" "three PRs: exits 0"
assert_eq "" "$ERR" "three PRs: nothing on stderr on a clean run"
assert_eq '["blocked","capped","held","ignored","inflight","owners","pr_total","prs","queued"]' "$(J 'sorted(d)')" "shape: exactly the nine documented keys"
assert_eq "0" "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" "shape: a single line of JSON"
assert_eq '[]' "$(J "d['capped']")" "shape: capped is empty on a clean run"
assert_eq '[]' "$(J "d['owners']")" "shape: owners is an empty list when nobody is waiting"
assert_eq "20 21 22" "$(pr_nums)" "three PRs: only the pipeline branches, ascending by PR number"
assert_eq "3" "$(J "d['pr_total']")" "three PRs: pr_total counts the pipeline PRs"
assert_eq "0" "$(J "d['ignored']")" "three PRs: non-pipeline branches are skipped, not 'ignored'"
assert_eq "$(sha40 20)" "$(J "d['prs'][0]['head']")" "three PRs: #20 carries the full 40-char head"
assert_eq "6" "$(J "d['prs'][0]['issue']")" "three PRs: #20 maps to issue 6 (feat/ prefix)"
assert_eq "qa" "$(stage_of 20)" "three PRs: #20 is at qa"
assert_eq "docs" "$(stage_of 21)" "three PRs: #21 (qa:pass) is at docs"
assert_eq "8" "$(J "d['prs'][2]['issue']")" "three PRs: #22 maps to issue 8 (branch with no slug)"
assert_eq "$(sha40 22)" "$(J "d['prs'][2]['head']")" "three PRs: #22 head"
assert_eq "false" "$(J "str(d['prs'][0]['owner']).lower()")" "three PRs: owner is false without a needs-owner label"
assert_eq '[6]' "$(J "d['queued']")" "three PRs: queued lists the pipeline:ready issue"
assert_not_contains "$(calls)" "pr-head 30" "three PRs: a non-pipeline branch is never looked up"
assert_not_contains "$(calls)" "pr-head 33" "three PRs: digits followed by a letter is never looked up"

# ── next-stage table: one fixture per result ────────────────────────────────
ALL="qa:pass,docs:done,review:approved,security:approved"
cfg_rf
tc_reset
tc blocked "table: PR label pipeline:blocked -> blocked" "pipeline:blocked"
BLOCKED_PR=$TC_LAST
tc blocked "table: issue label pipeline:blocked -> blocked" "" "pipeline:blocked"
tc qa "table: no labels -> qa" ""
tc docs "table: qa:pass -> docs" "qa:pass"
tc reviewer "table: qa+docs -> reviewer" "qa:pass,docs:done"
tc security "table: qa+docs+review -> security" "qa:pass,docs:done,review:approved"
tc merge "table: roles.adversarial unset (default false) skips adversarial -> merge" "$ALL"
tc merge "table: pr.draft false never asks pr-is-draft" "$ALL"; DRAFT_PR=$TC_LAST; echo 0 > "$FX/draft.$TC_LAST.rc"
tc qa "table: present but stale qa:pass -> qa" "$ALL"
printf 'stale role=qa label=qa:pass\n' > "$FX/stale.$TC_LAST"; echo 1 > "$FX/stale.$TC_LAST.rc"
tc reviewer "table: stale review:approved with a marker-authors line before it -> reviewer" "$ALL"
printf 'talos:marker-authors-unverified reader=check-approval-sha\nstale role=reviewer label=review:approved\n' > "$FX/stale.$TC_LAST"; echo 1 > "$FX/stale.$TC_LAST.rc"
tc merge "table: a non-stale line is not an answer -> merge" "$ALL"
printf 'talos:marker-authors-unverified reader=check-approval-sha\n' > "$FX/stale.$TC_LAST"; echo 0 > "$FX/stale.$TC_LAST.rc"
tc merge "needs-owner: a PR label leaves the PR listed at its stage" "$ALL,pipeline:needs-owner"; OWN_PR=$TC_LAST
tc merge "needs-owner: an issue label leaves the PR listed at its stage" "$ALL" "pipeline:needs-owner"; OWN_ISSUE=$TC_LAST
tc blocked "table: a blocked PR short-circuits" "pipeline:blocked,qa:pass"; BLOCKED_QA=$TC_LAST
run_cases "table"
assert_contains "$(calls)" "check-approval-sha $((DRAFT_PR + 1)) --stale-list" "table: stale check uses --stale-list"
assert_not_contains "$(calls)" "check-approval-sha $BLOCKED_QA" "table: a blocked PR needs no approval read"
assert_not_contains "$(calls)" "pr-is-draft" "table: pr.draft false makes no pr-is-draft call"
assert_not_contains "$OUT" "stale" "table: no stale text in the JSON"
assert_eq "true true false" "$(J "' '.join(str([p['owner'] for p in d['prs'] if p['n'] == n][0]).lower() for n in ($OWN_PR, $OWN_ISSUE, $BLOCKED_PR))")" "needs-owner: owner is true for a PR or issue label, false without"

# roles.adversarial true: the default order, one PR per step (the order collect walks)
cfg_rf '"roles": {"adversarial": true}'
tc_reset
tc qa "order: no labels" ""
tc docs "order: qa" "qa:pass"
tc reviewer "order: qa docs" "qa:pass,docs:done"
tc security "order: qa docs reviewer" "qa:pass,docs:done,review:approved"
tc adversarial "order: roles.adversarial true, no adversarial:approved -> adversarial" "$ALL"
tc merge "order: adversarial approved -> merge" "$ALL,adversarial:approved"
run_cases "order"
assert_eq "qa docs reviewer security adversarial merge" "$(J "' '.join(p['stage'] for p in d['prs'])")" "order: the default stage order"

cfg_rf '"merge": {"required_checks": ["build"]}'
tc_reset
tc ci "table: required check pending (exit 2) -> ci" "$ALL"; echo 2 > "$FX/ci.$TC_LAST.rc"
tc ci "table: required check failed (exit 1) -> ci" "$ALL"; echo 1 > "$FX/ci.$TC_LAST.rc"
tc merge "table: required check passing -> merge" "$ALL"; echo 0 > "$FX/ci.$TC_LAST.rc"
run_cases "checks"

cfg_rf '"merge": {"auto": false}'
tc_reset
tc human-merge "table: merge.auto false -> human-merge" "$ALL"
tc human-merge "table: merge.auto false -> human-merge, every approved PR" "$ALL"
run_cases "human-merge"

cfg_rf '"roles": {"docs": false, "qa": false}'
tc_reset
tc reviewer "table: disabled roles qa and docs are skipped -> reviewer" ""
run_cases "roles off"

# pr.draft true, adversarial on: the draft order (QA comes after ready-pr)
RF_DRAFT=true cfg_rf '"roles": {"adversarial": true}'
tc_reset
tc docs "draft order: draft PR skips qa -> docs" ""; echo 0 > "$FX/draft.$TC_LAST.rc"
tc reviewer "draft order: docs -> reviewer" "docs:done"; echo 0 > "$FX/draft.$TC_LAST.rc"
tc security "draft order: docs reviewer -> security" "docs:done,review:approved"; echo 0 > "$FX/draft.$TC_LAST.rc"
tc adversarial "draft order: docs reviewer security -> adversarial" "docs:done,review:approved,security:approved"; echo 0 > "$FX/draft.$TC_LAST.rc"
tc ready "draft order: everything but qa done -> ready" "docs:done,review:approved,security:approved,adversarial:approved"; echo 0 > "$FX/draft.$TC_LAST.rc"
tc unverified "draft order: pr-is-draft exit 2 -> unverified" ""; echo 2 > "$FX/draft.$TC_LAST.rc"
tc qa "draft order: pr.draft true but PR is ready (exit 1) -> default order, qa" ""; echo 1 > "$FX/draft.$TC_LAST.rc"
run_cases "draft order"
assert_eq "docs reviewer security adversarial ready" "$(J "' '.join(p['stage'] for p in d['prs'][:5])")" "draft order: the draft stage order"
cfg_rf

# pr.draft unset (#435): the default is the draft flow on github, and the ready
# flow on github-api (it cannot open draft PRs, so pr-is-draft would exit 2 and
# every PR would read `unverified`).
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main"}\n' > talos.pipeline.json
tc_reset
tc docs "default: pr.draft unset on github is the draft flow (draft PR skips qa -> docs)" ""; echo 0 > "$FX/draft.$TC_LAST.rc"
run_cases "default github"
assert_contains "$(calls)" "pr-is-draft $TC_LAST" "default: pr.draft unset on github asks pr-is-draft"
printf '{"vcs": {"provider": "github-api", "repo": "acme/widget"}, "base_branch": "main"}\n' > talos.pipeline.json
tc_reset
tc qa "default: pr.draft unset on github-api is the ready flow, never unverified (qa)" ""; echo 2 > "$FX/draft.$TC_LAST.rc"
run_cases "default github-api"
assert_not_contains "$(calls)" "pr-is-draft" "default: pr.draft unset on github-api makes no pr-is-draft call"
cfg_rf

# ── check-approval-sha: exit 1 with no stale line is a failed read ──────────
fx_reset; add_pr 10 fix/issue-5-x "qa:pass"; add_issue 5 ""; echo 1 > "$FX/stale.10.rc"
collect
assert_failed_read "fail-closed: check-approval-sha exit 1 with no stale line"

# ── queued ordering, blocked, held, owners ──────────────────────────────────
fx_reset
add_issue 9 "pipeline:ready"; add_issue 4 "pipeline:ready,p2"; add_issue 8 "pipeline:ready,p1"
add_issue 3 "pipeline:ready,p0"; add_issue 7 "pipeline:ready,p1"; add_issue 2 "p0"; add_issue 12 "pipeline:ready"
add_issue 20 "pipeline:blocked"; add_issue 13 "pipeline:ready,pipeline:needs-owner,p2"
add_pr 40 fix/issue-30-x "pipeline:blocked"
python3 -I -c '
import json
print(json.dumps([
  {"n": 21, "kind": "issue", "answered": "yes", "question": "Ship now?"},
  {"n": 20, "kind": "issue", "answered": "no", "question": "Pick A or B?"},
]))' > "$FX/owners.json"
collect
assert_eq "0" "$RC" "queued: exits 0"
assert_eq '[3,7,8,4,13,9,12]' "$(J "d['queued']")" "queued: p0, p1, p2, unlabelled, then by number (a not-ready p0 is absent)"
assert_eq '[13]' "$(J "d['held']")" "held: the queued issue that also carries needs-owner"
assert_eq '[["issue",20],["PR",40]]' "$(J "d['blocked']")" "blocked: issue and PR, ordered by number"
assert_eq '[{"n":20,"status":"unanswered","question":"Pick A or B?"},{"n":21,"status":"answered","question":"Ship now?"}]' "$(J "d['owners']")" "owners: sorted by number, status separate from the question"
assert_eq "blocked" "$(stage_of 40)" "blocked: the blocked PR is listed with stage blocked"
assert_contains "$(calls)" "list-needs-owner --json" "owners: read through --json"
assert_not_contains "$(calls)" "--clear-answered" "owners: never --clear-answered"
# unverified trust set: status unverified, never answered
printf 'pipeline-vcs: talos:marker-authors-unverified reader=needs-owner\n' > "$FX/owners.err"
collect
assert_eq '["unverified","unverified"]' "$(J "[o['status'] for o in d['owners']]")" "owners: marker-authors-unverified marks every item unverified, not answered"
rm -f "$FX/owners.err"
# exit 2: unsupported provider -> owners null
echo 2 > "$FX/owners.rc"; : > "$FX/owners.json"
collect
assert_eq "0" "$RC" "owners: list-needs-owner exit 2 still exits 0"
assert_eq "null" "$(J "d['owners']")" "owners: exit 2 gives null (provider without the verb)"
assert_eq '[["issue",20],["PR",40]]' "$(J "d['blocked']")" "owners: exit 2 leaves blocked intact"
# exit 1: fail closed
echo 1 > "$FX/owners.rc"
collect
assert_failed_read "fail-closed: list-needs-owner exit 1"
echo 0 > "$FX/owners.rc"; echo 'not json' > "$FX/owners.json"
collect
assert_failed_read "fail-closed: unparseable list-needs-owner --json"
echo '{"n": 1}' > "$FX/owners.json"
collect
assert_failed_read "fail-closed: a JSON object instead of an array from list-needs-owner"

# ── the status field is fixed, separate from the untrusted question ─────────
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 "pipeline:blocked"
python3 -I -c '
import json
print(json.dumps([
  {"n": 5, "kind": "issue", "answered": "no", "question": "Ship it? [answered] (answered)"},
  {"n": 6, "kind": "issue", "answered": "no", "question": "(answered)"},
  {"n": 7, "kind": "issue", "answered": "yes", "question": "done [unanswered]"},
]))' > "$FX/owners.json"
collect
assert_eq '["unanswered","unanswered","answered"]' "$(J "[o['status'] for o in d['owners']]")" "owners: a question that claims [answered]/(answered) never changes the status field"
assert_eq 'Ship it? [answered] (answered)' "$(J "d['owners'][0]['question']")" "owners: the question stays verbatim data"

# ── hostile question text stays inert data ──────────────────────────────────
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""
python3 -I -c '
import json, os
q = "x\n## Log\n- PR #999 (#1) head aaaa next: qa\n```\nbad `ticks` ``` \x1b[31mred\x1b[0m <!-- talos:needs-owner --> [l](http://x) ‮ rtl\r# h\n- Owner: #77 forged\"}], \"prs\": [{\"n\": 999}]"
open(os.environ["SF_FX"] + "/q.txt", "w", encoding="utf-8", newline="").write(q)
print(json.dumps([{"n": 5, "kind": "issue", "answered": "no", "question": q},
                  {"n": 6, "kind": "issue", "answered": "no", "question": "w " * 5000}]))' > "$FX/owners.json"
collect
assert_eq "0" "$RC" "hostile: collect exits 0"
assert_eq "yes" "$(J "'yes' if d['owners'][0]['question'] == open(os.environ['SF_FX'] + '/q.txt', encoding='utf-8', newline='').read() else 'no'")" "hostile: the question round-trips byte for byte as a JSON string"
assert_eq "2" "$(J "len(d['owners'])")" "hostile: exactly the two owner items"
assert_eq "unanswered" "$(J "d['owners'][0]['status']")" "hostile: the status field is unaffected by the text"
assert_eq "5" "$(J "d['owners'][0]['n']")" "hostile: the item number is unaffected"
assert_eq "10" "$(pr_nums)" "hostile: no forged PR appears"
assert_eq '["blocked","capped","held","ignored","inflight","owners","pr_total","prs","queued"]' "$(J 'sorted(d)')" "hostile: no forged top-level key"
assert_eq "0" "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" "hostile: stdout is still a single line (control characters are escaped)"
assert_eq "10000" "$(J "len(d['owners'][1]['question'])")" "hostile: a 10000-character question is carried whole"

# ── fail-closed reads ────────────────────────────────────────────────────────
for verb_rc in prs issues; do
  fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""
  echo 1 > "$FX/$verb_rc.rc"
  collect
  assert_failed_read "fail-closed: list-$verb_rc exit 1"
done
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; rm -f "$FX/head.10"
collect
assert_failed_read "fail-closed: an unresolvable pr-head"
echo 'not-a-sha' > "$FX/head.10"
collect
assert_failed_read "fail-closed: a pr-head that is not a SHA"

# ── cap warnings ─────────────────────────────────────────────────────────────
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""
printf 'pipeline-vcs: list-prs: WARNING result capped at 100 (az repos pr list --top ceiling) -- some PRs may be missing\n' > "$FX/prs.err"
collect
assert_eq "0" "$RC" "capped: a cap warning still exits 0"
assert_eq '["list-prs"]' "$(J "d['capped']")" "capped: list-prs named when its listing was capped"
printf 'pipeline-vcs: list-issues: WARNING result capped at 100 (x) -- some issues may be missing\n' > "$FX/issues.err"
collect
assert_eq '["list-prs","list-issues"]' "$(J "d['capped']")" "capped: both named when both were capped, list-prs first"
rm -f "$FX/prs.err" "$FX/issues.err"
printf 'pipeline-vcs: some other warning\n' > "$FX/prs.err"
collect
assert_eq '[]' "$(J "d['capped']")" "capped: an unrelated stderr line is not a cap"
rm -f "$FX/prs.err"

# ── no write verb is ever called ─────────────────────────────────────────────
fx_reset; add_pr 10 fix/issue-5-x ""; add_pr 11 fix/issue-6-x "qa:pass"; add_issue 5 "pipeline:ready"; add_issue 6 ""
add_issue 7 "pipeline:dev"
printf '[{"n": 5, "kind": "issue", "answered": "no", "question": "q"}]\n' > "$FX/owners.json"
before_status="$(git status --porcelain)"
collect
assert_eq "0" "$RC" "read-only: exits 0"
assert_not_contains "$(calls)" "WRITE" "read-only: the verb stub saw only read verbs"
assert_eq "" "$(awk '{print $1}' "$FX/calls.log" | sort -u | grep -v -x -e list-prs -e list-issues -e pr-head -e check-approval-sha -e pr-checks-required -e pr-is-draft -e list-needs-owner -e current-user)" "read-only: only the documented read verbs were called"
assert_eq "$before_status" "$(git status --porcelain)" "read-only: the caller's checkout is untouched"

# the real gh stub: no POST/PATCH/PUT/DELETE and no label or comment call
STUB_PR_HEAD_SHA="$(sha40 9)"
export STUB_PR_HEAD_SHA
export STUB_GH_PRS_RAW='[{"number":9,"title":"fix: guard null session","head":{"ref":"fix/issue-42-guard","repo":{"full_name":"acme/widget"}},"base":{"ref":"main","repo":{"full_name":"acme/widget"}},"labels":[]}]'
: > "$GH_LOG"
OUT="$(bash "$SF_REAL" collect 2>"$PARENT/err")"; RC=$?
assert_eq "0" "$RC" "gh stub: collect exits 0 against the real pipeline-vcs.sh (stderr: $(head -c 200 "$PARENT/err"))"
assert_eq "9 42 $(sha40 9) qa" "$(J "' '.join(str(d['prs'][0][k]) for k in ('n', 'issue', 'head', 'stage'))")" "gh stub: the stubbed PR is listed with the stubbed 40-char head"
log="$(cat "$GH_LOG")"
assert_not_contains "$log" "POST" "gh stub: no POST"
assert_not_contains "$log" "PATCH" "gh stub: no PATCH"
assert_not_contains "$log" "PUT" "gh stub: no PUT"
assert_not_contains "$log" "DELETE" "gh stub: no DELETE"
assert_not_contains "$log" "--add-label" "gh stub: no label add"
assert_not_contains "$log" "--remove-label" "gh stub: no label remove"
assert_not_contains "$log" "--method" "gh stub: no explicit write method"
assert_not_contains "$log" "comment " "gh stub: no comment-writing call"
assert_not_contains "$log" "--edit" "gh stub: no edit call"
unset STUB_PR_HEAD_SHA STUB_GH_PRS_RAW

# ── F1: a pipeline-style branch name alone does not make a pipeline PR ──────
fx_reset
add_pr 77 fix/issue-3-evil "" true            # the security repro: unlabelled fork PR
add_pr 20 fix/issue-3-a "" false              # same repo, no label: a fix round in flight
add_pr 21 fix/issue-4-b "qa:pass" true        # fork PR a maintainer labelled
add_pr 22 fix/issue-5-c "pipeline:review" true
add_pr 23 fix/issue-6-d "" absent             # field absent, no label: excluded
add_pr 24 fix/issue-7-e "docs:done" absent    # field absent, label: listed
add_pr 25 fix/issue-8-f "pipeline:review" false other   # wrong base: excluded
add_pr 26 fix/issue-9-g "" true
add_pr 30 fix/issue-3-x "bug" true            # an unrelated label is not a Talos label
# a fork PR counts as the pipeline's only with an exact contract label
add_pr 40 fix/issue-3-x "pipeline:bogus" true; add_pr 41 fix/issue-3-x "pipeline:review" true
add_pr 42 fix/issue-3-x "pipeline:epic-children-done" true; add_pr 43 fix/issue-3-x "review:approved" true
add_pr 44 fix/issue-3-x "Pipeline:review" true
add_issue 3 "pipeline:ready"
collect
assert_eq "20 21 22 24 41 42 43" "$(pr_nums)" "fork: same-repo unlabelled, labelled fork and field-absent labelled PRs are listed; fork or field-absent unlabelled, unrelated-label and wrong-base PRs are not; only exact contract labels admit a fork PR"
assert_eq "7" "$(J "d['pr_total']")" "fork: pr_total counts the listed PRs"
assert_eq "6" "$(J "d['ignored']")" "fork: ignored counts 77, 23, 26, 30, 40 and 44, not the wrong-base 25"
assert_eq '[3]' "$(J "d['queued']")" "fork: the queue is unaffected by the fork PRs"
assert_not_contains "$OUT" "evil" "fork: no attacker-chosen text in the JSON"
for n in 77 23 26 30 40 44 25; do
  assert_not_contains "$(calls)" "pr-head $n" "fork: the excluded PR #$n is not looked up"
  assert_not_contains "$(calls)" "check-approval-sha $n" "fork: the excluded PR #$n has no approval read"
done

# ── cost: only the lowest-numbered PRs are looked up ────────────────────────
# 44 unready PRs, then one merge-ready PR and two it must not look up. The line
# cap (MAX_PR_LINES 40) looks up the lowest 37; the merge-ready one past it is
# looked up too (#454), a needs-owner one and a blocked one are not.
fx_reset; add_issue 5 ""
for i in $(seq 100 143); do add_pr "$i" "fix/issue-5-x" ""; done
add_pr 150 fix/issue-5-x "$ALL"
add_pr 151 fix/issue-5-x "$ALL,pipeline:needs-owner"
add_pr 152 fix/issue-5-x "$ALL,pipeline:blocked"
collect
assert_eq "0" "$RC" "cost: 47 matching PRs: exits 0"
assert_eq "38" "$(count_calls pr-head)" "cost: 37 pr-head calls (the cap) plus one merge-ready PR past it"
assert_eq "38" "$(J "len(d['prs'])")" "cost: 38 PRs are returned"
assert_eq "47" "$(J "d['pr_total']")" "cost: pr_total still counts every pipeline PR"
assert_eq "100 101 102" "$(pr_nums | cut -d' ' -f1-3)" "cost: the lowest-numbered PRs are the ones looked up"
assert_eq "136" "$(J "d['prs'][36]['n']")" "cost: the 37th looked-up PR is the 37th lowest"
assert_eq "150" "$(J "d['prs'][37]['n']")" "cap-next: the merge-ready PR past the cap is looked up"
assert_eq "merge" "$(stage_of 150)" "cap-next: ... and reports stage merge"
assert_not_contains "$(calls)" "pr-head 143" "cap-next: an unready PR past the cap is not looked up"
assert_not_contains "$(calls)" "pr-head 151" "cap-next: a needs-owner PR past the cap is not looked up"
assert_not_contains "$(calls)" "pr-head 152" "cap-next: a blocked PR past the cap is not looked up"
assert_eq '[["PR",152]]' "$(J "d['blocked']")" "cap-next: the blocked PR past the cap is still reported as blocked"
assert_eq "1" "$(count_calls check-approval-sha)" "cost: only the merge-ready PR needed an approval read"

# with no role enabled every PR qualifies as merge-ready: the extra lookups past
# the cap are bounded by the number of PRs the cap shows (37), not by the PR count
cfg_rf '"roles": {"qa": false, "docs": false, "reviewer": false, "security": false}'
fx_reset; add_issue 5 ""
for i in $(seq 100 179); do add_pr "$i" fix/issue-5-x ""; done
collect
assert_eq "74" "$(count_calls pr-head)" "cap-next: no roles enabled, 80 PRs: 37 shown + at most 37 extra lookups"
assert_eq "74" "$(J "len(d['prs'])")" "cap-next: no roles enabled: 74 PRs returned"
assert_eq "80" "$(J "d['pr_total']")" "cap-next: no roles enabled: pr_total counts all 80"
assert_eq "merge" "$(stage_of 100)" "cap-next: no roles enabled: the lowest PR is at merge"
cfg_rf

# ── inflight (#519) ──────────────────────────────────────────────────────────
# Issues in the mid-states (confirmed/dev/epic-decomposed), not queued, not
# blocked or needs-owner, ascending -- and NEVER an issue whose pipeline work
# is already up as an open PR against the base (the PR side owns that work).
# A fork PR with no Talos label is not the pipeline's, so it keeps no issue out.
fx_reset
add_pr 12 "fix/issue-9-stale" "pipeline:review"     # labelled: owns issue 9
add_pr 18 "fix/issue-10-other" "" false              # unlabelled same-repo: owns issue 10
add_pr 17 "fix/issue-20-fork" "" true                # unlabelled fork: owns nothing
add_issue 9 "pipeline:dev"
add_issue 10 "pipeline:dev"
add_issue 11 "pipeline:confirmed"
add_issue 16 "pipeline:epic-decomposed"
add_issue 20 "pipeline:dev"
add_issue 13 "pipeline:ready"
add_issue 14 "pipeline:blocked,pipeline:dev"
add_issue 15 "pipeline:needs-owner,pipeline:dev"
add_issue 19 "pipeline:ready,pipeline:dev"
collect
assert_eq "[11,16,20]" "$(J "d['inflight']")" "inflight: the mid-state issues with no open pipeline PR, ascending; not queued, blocked or needs-owner ones"

# ── the read deadline: a verb that outlasts it fails the read phase ─────────
run_wd() {  # SECONDS cmd...: stdout to stdout, stderr to $WD_ERR, exit code (124 after SECONDS)
  python3 -I -c '
import os, subprocess, sys
try:
    with open(os.environ["WD_ERR"], "wb") as e:
        p = subprocess.run(sys.argv[2:], stdout=subprocess.PIPE, stderr=e, timeout=int(sys.argv[1]))
except subprocess.TimeoutExpired:
    sys.stdout.write("WATCHDOG: still running\n")
    sys.exit(124)
sys.stdout.buffer.write(p.stdout)
sys.exit(p.returncode)' "$@"
}
export WD_ERR="$PARENT/wd.err"
fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
echo 20 > "$FX/sleep.pr-head"
# four ASCII digits are accepted (0002 is 2 s): the 20 s verb is cut off
OUT="$(TALOS_STATUS_READ_DEADLINE=0002 run_wd 40 bash "$SF" collect)"; RC=$?
assert_eq "1" "$RC" "deadline: collect exits 1 when a read verb outlasts the deadline (stderr: $(head -c 200 "$WD_ERR"))"
assert_contains "$(cat "$WD_ERR")" "deadline" "deadline: stderr names the deadline"
assert_eq "" "$OUT" "deadline: nothing on stdout"

# TALOS_STATUS_READ_DEADLINE takes 1 to 4 ASCII digits only (#454): `²` is a
# digit to str.isdigit() and crashed int(); 5000 digits crashed it too; five
# digits (here 00001, which is 1) are over the limit, so the default applies and
# the 2 s verb below is NOT cut off.
rm -f "$FX/sleep.pr-head"
for dl in '²' "$(python3 -I -c 'print("9" * 5000)')"; do
  OUT="$(TALOS_STATUS_READ_DEADLINE="$dl" run_wd 60 bash "$SF" collect)"; RC=$?
  assert_eq_ctx "0" "$RC" "deadline: a ${#dl}-char value starting '$(printf '%s' "$dl" | head -c 4)' falls back to the default" "$(head -c 160 "$WD_ERR")"
  assert_not_contains "$(cat "$WD_ERR")" "Traceback" "deadline: a bad deadline value never raises"
done
assert_eq "10" "$(J "d['prs'][0]['n']")" "deadline: ... and the result is intact"
echo 2 > "$FX/sleep.pr-head"
OUT="$(TALOS_STATUS_READ_DEADLINE=00001 run_wd 60 bash "$SF" collect)"; RC=$?
assert_eq_ctx "0" "$RC" "deadline: a five-digit value (00001) is not accepted; the default applies and a 2 s verb is not cut off" "$(head -c 160 "$WD_ERR")"
rm -f "$FX/sleep.pr-head"
unset WD_ERR

# ── a signal during the read phase stops the running read verb (#454) ───────
# The verb runs in its own session, so the signal sent to the script's process
# group (a terminal's Ctrl-C) never reached it and it outlived the script.
run_sig() {  # SIG pidfile cmd...: run cmd in a new session, signal its group once the verb wrote pidfile, print the exit code
  python3 -I -c '
import os, signal, subprocess, sys, time
sig = getattr(signal, "SIG" + sys.argv[1])
def dfl():
    for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGHUP, signal.SIGTERM):
        signal.signal(s, signal.SIG_DFL)
p = subprocess.Popen(sys.argv[3:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     stdin=subprocess.DEVNULL, start_new_session=True, preexec_fn=dfl)
end = time.time() + 20
while time.time() < end and not os.path.exists(sys.argv[2]):
    time.sleep(0.05)
time.sleep(0.2)
os.killpg(p.pid, sig)
try:
    print(p.wait(timeout=15))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    print("WATCHDOG")' "$@"
}
for sig in TERM INT; do
  fx_reset; add_pr 10 fix/issue-5-x ""; add_issue 5 ""; fx_flush
  echo 30 > "$FX/sleep.pr-head"
  rc="$(run_sig "$sig" "$FX/verbpid.pr-head" bash "$SF" collect)"
  case "$sig" in TERM) want=143 ;; INT) want=130 ;; esac
  assert_eq "$want" "$rc" "signal: SIG$sig during a read exits $want"
  vpid="$(cat "$FX/verbpid.pr-head" 2>/dev/null)"
  if [ -n "$vpid" ] && kill -0 "$vpid" 2>/dev/null; then
    kill "$vpid" 2>/dev/null
    alive=yes
  else
    alive=no
  fi
  assert_eq "no" "$alive" "signal: SIG$sig during a read kills the running read verb"
done

# ── no temp directory left behind ────────────────────────────────────────────
leftover="$(ls -A "$PARENT/tmp")"
assert_eq_ctx "" "$leftover" "leak: nothing left in the test's TMPDIR after the whole file" "$(ls -A "$PARENT/tmp" | sed 's/\.[A-Za-z0-9]*$//' | sort | uniq -c | tr '\n' ';')"

echo "test-collect.sh: $_PASS passed, $_FAIL failed"
[ "$_FAIL" -eq 0 ]
