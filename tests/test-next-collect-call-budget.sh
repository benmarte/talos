#!/usr/bin/env bash
# test-next-collect-call-budget.sh -- a routing pass reads GitHub a bounded number
# of times (#1038). One `talos.sh next` made ~170 serial REST calls in a repo with
# 11 open PRs; under load it overran the read deadline and stopped
# `state-unavailable` with no word on which read failed.
#   AC1 (test) 10 open PRs: one `next` reads each pulls/<n> at most once and /user
#       at most once (a recording `gh` stub counts the REST calls)
#   AC2 (test) `next --issue N` reads only issue N's own PR, plus the list reads:
#       no other PR's pulls/<n>, comments or files endpoint is called
#   AC3 (test) head sha and draft state come from the list-prs payload: no pr-head
#       or pr-is-draft provider call is made during collect
#   AC4 (test) a read that times out or fails ends the pass with a `detail` naming
#       the read, on the stop line and in the run_end event
#   AC5 (same) the action and stage `next --issue N` answers for PRs in each stage
#       (review, qa, docs, merge) are the answers it gave before
# AC6 (docs and changelog) is prose.
#
# The real scripts run in a copy of the scripts dir whose pipeline-vcs.sh is a
# recording wrapper around the real one; `gh` is a small fake GitHub REST API.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs
# A stage session exports the repo and base through the config env column: the
# fixture's own config and git remote must decide, not the caller's.
unset PIPELINE_REPO PIPELINE_BASE_BRANCH

export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "roles": {"adversarial": false}}\n' > "$PIPELINE_CONFIG"

SCR="$SANDBOX/scripts"
BIN="$SANDBOX/bin"
export GH_FX="$SANDBOX/fx.json" GH_CALLS="$SANDBOX/gh.calls" VERB_LOG="$SANDBOX/verbs.log"
mkdir -p "$BIN"
cp -R "$TALOS_ROOT/scripts" "$SCR"
mv "$SCR/pipeline-vcs.sh" "$SCR/pipeline-vcs-real.sh"
cat > "$SCR/pipeline-vcs.sh" <<'TALOS_verbwrapLq8Zx3Vn'
#!/usr/bin/env bash
# Records the provider verb, then runs the real script from the same directory.
printf '%s\n' "${1:-}" >> "${VERB_LOG:?}"
exec bash "$(dirname "$0")/pipeline-vcs-real.sh" "$@"
TALOS_verbwrapLq8Zx3Vn

cat > "$BIN/gh" <<'TALOS_ghstubPy3Qx7Lm'
#!/usr/bin/env python3
# A small fake GitHub REST API behind `gh api -i`: every call is logged.
import json, os, re, sys, time

argv = sys.argv[1:]
if argv[:2] == ['auth', 'token']:
    print('stub-token')
    sys.exit(0)
if argv[:2] != ['api', '-i']:
    sys.exit(1)
method, path, i = 'GET', '', 2
while i < len(argv):
    if argv[i] in ('-X', '-H', '--input'):
        if argv[i] == '-X':
            method = argv[i + 1]
        i += 2
    else:
        path = argv[i]
        i += 1
fx = json.load(open(os.environ['GH_FX']))
with open(os.environ['GH_CALLS'], 'a') as f:
    f.write('%s %s\n' % (method, path))
rest = re.sub(r'^repos/[^/]+/[^/]+/?', '', path)
status, body = 200, None
for key, secs in fx.get('sleep', {}).items():
    if rest.startswith(key):
        time.sleep(secs)
for key, code in fx.get('fail', {}).items():
    if rest.startswith(key):
        status, body = code, {'message': 'stub failure'}
if body is None and method == 'GET':
    m = re.match(r'pulls/(\d+)$', rest)
    c = re.match(r'issues/(\d+)/comments', rest)
    if rest.startswith('pulls?'):
        body = fx['list']
    elif m:
        body = next((p for p in fx['prs'] if p['number'] == int(m.group(1))), None)
    elif re.match(r'pulls/\d+/files', rest):
        body = []
    elif rest.startswith('issues?'):
        body = fx['issues']
    elif c:
        body = fx['comments'].get(c.group(1), [])
    elif re.match(r'issues/\d+$', rest):
        n = int(rest.split('/')[1])
        body = next((x for x in fx['issues'] if x['number'] == n), None)
    elif re.match(r'commits/[0-9a-f]+/check-runs', rest):
        body = {'total_count': 0, 'check_runs': []}
    elif re.match(r'commits/[0-9a-f]+/status', rest):
        body = {'state': 'pending', 'statuses': []}
    elif rest == 'user':
        body = {'login': 'tester'}
if body is None:
    status, body = (status if status != 200 else 404), {'message': 'Not Found'}
sys.stdout.write('HTTP/2.0 %d X\r\nContent-Type: application/json\r\n\r\n%s' % (status, json.dumps(body)))
if status >= 400:
    sys.stderr.write('gh: stub (HTTP %d)\n' % status)
    sys.exit(1)
TALOS_ghstubPy3Qx7Lm
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# The fixture: ten open PRs, PR 100+k closing issue k, each at a different stage.
#   101 no approval (qa)   102 qa:pass (docs)   103 qa+docs (reviewer)
#   104 qa+docs+review (security)   105 all four (merge)   106 a draft (docs)
#   107-110 no approval (qa)
python3 -I - "$GH_FX" <<'TALOS_fxbuildBn5Rw2Kd'
import json, sys
ROLES = [('qa', 'qa:pass'), ('docs', 'docs:done'), ('reviewer', 'review:approved'), ('security', 'security:approved')]
HELD = {102: 1, 103: 2, 104: 3, 105: 4}
prs, comments = [], {}
for n in range(101, 111):
    sha = '%040x' % n
    labels = [ROLES[i][1] for i in range(HELD.get(n, 0))]
    prs.append({'number': n, 'title': 'PR %d' % n, 'draft': n == 106,
                'head': {'ref': 'fix/issue-%d-x' % (n - 100), 'sha': sha, 'repo': {'full_name': 'acme/widget'}},
                'base': {'ref': 'main', 'repo': {'full_name': 'acme/widget'}},
                'labels': [{'name': l} for l in labels], 'body': 'Closes #%d' % (n - 100)})
    comments[str(n)] = [{'id': n * 10 + i, 'body': 'ok\n<!-- talos:approval sha=%s role=%s -->' % (sha, ROLES[i][0]),
                         'user': {'login': 'tester'}, 'created_at': '2026-11-01T00:00:00Z'}
                        for i in range(HELD.get(n, 0))]
issues = [{'number': k, 'title': 'issue %d' % k, 'body': 'b', 'labels': [], 'user': {'login': 'tester'},
           'assignees': [{'login': 'tester'}]} for k in range(1, 11)]
json.dump({'prs': prs, 'list': prs, 'issues': issues, 'comments': comments}, open(sys.argv[1], 'w'))
TALOS_fxbuildBn5Rw2Kd

TALOS="$SCR/talos.sh"
reset_calls() { : > "$GH_CALLS"; : > "$VERB_LOG"; rm -f "$SANDBOX"/.git/talos/lease* 2>/dev/null; }
# dup_max <regex>: the most times one REST path matching <regex> was read in a pass.
dup_max() { grep -E "$1" "$GH_CALLS" | sort | uniq -c | sort -rn | awk 'NR==1 { print $1 }' | grep . || echo 0; }

# ── AC1 ─────────────────────────────────────────────────────────────────────
reset_calls
OUT="$(bash "$TALOS" next 2>"$SANDBOX/err")"
printf '  info  one next over 10 open PRs made %s REST calls\n' "$(wc -l < "$GH_CALLS" | tr -d ' ')"
assert_eq "action=dispatch stage=qa pr=101 issue=1" "$OUT" "AC1 the unscoped next answers" "$(cat "$SANDBOX/err")"
assert_eq "1" "$(dup_max '^GET repos/acme/widget/pulls/[0-9]+$')" "AC1 each pulls/<n> is read at most once in one next over 10 PRs"
assert_eq "1" "$(dup_max '^GET user$')" "AC1 /user is read at most once in one next"
reset_calls
OUT="$(bash "$TALOS" next --issue 3 2>"$SANDBOX/err")"
printf '  info  one next --issue over 10 open PRs made %s REST calls\n' "$(wc -l < "$GH_CALLS" | tr -d ' ')"
assert_eq "1" "$(dup_max '^GET repos/acme/widget/pulls/[0-9]+$')" "AC1 each pulls/<n> is read at most once in one next --issue"
assert_eq "1" "$(dup_max '^GET user$')" "AC1 /user is read at most once in one next --issue"

# ── AC2 ─────────────────────────────────────────────────────────────────────
reset_calls
bash "$TALOS" next --issue 3 >/dev/null 2>&1
OTHERS="$(grep -E 'pulls/[0-9]+|issues/[0-9]+/comments' "$GH_CALLS" | grep -vE 'pulls/103|issues/103/comments|issues/3/comments' || true)"
assert_eq "" "$OTHERS" "AC2 next --issue 3 touches no other PR's pulls, comments or files endpoint"
assert_contains "$(cat "$GH_CALLS")" "pulls/103" "AC2 next --issue 3 reads its own PR 103"
assert_contains "$(cat "$GH_CALLS")" "/pulls?" "AC2 the list-prs read is made"
assert_contains "$(cat "$GH_CALLS")" "/issues?" "AC2 the list-issues read is made"

# ── AC3 ─────────────────────────────────────────────────────────────────────
reset_calls
bash "$TALOS" next >/dev/null 2>&1
assert_eq "0" "$(grep -cx 'pr-head' "$VERB_LOG")" "AC3 no pr-head provider call during collect"
assert_eq "0" "$(grep -cx 'pr-is-draft' "$VERB_LOG")" "AC3 no pr-is-draft provider call during collect"
assert_contains "$(cat "$VERB_LOG")" "list-prs" "AC3 control: the verb log records the list-prs read"

# ── AC4 ─────────────────────────────────────────────────────────────────────
reset_calls
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["sleep"]={"pulls?": 4}; json.dump(d, open(sys.argv[1], "w"))' "$GH_FX"
OUT="$(TALOS_STATUS_READ_DEADLINE=1 bash "$TALOS" next --issue 3 2>/dev/null)"
assert_eq "stop reason=state-unavailable detail=list-prs:deadline" "$OUT" "AC4 a list-prs read past the deadline names itself on the stop line"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["sleep"]={}; d["fail"]={"issues?": 500}; json.dump(d, open(sys.argv[1], "w"))' "$GH_FX"
OUT="$(bash "$TALOS" next --issue 3 2>/dev/null)"
assert_eq "stop reason=state-unavailable detail=list-issues:failed" "$OUT" "AC4 a failed list-issues read names itself on the stop line"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["fail"]={"pulls?": 401}; json.dump(d, open(sys.argv[1], "w"))' "$GH_FX"
OUT="$(bash "$TALOS" next --issue 3 2>/dev/null)"
assert_eq "stop reason=state-unavailable detail=list-prs:auth" "$OUT" "AC4 an auth failure is told from a deadline"

# the run_end event carries the same detail
LOG="$SANDBOX/.git/talos/events.jsonl"
rm -f "$LOG"
bash "$TALOS" run --issue 3 >"$SANDBOX/run.out" 2>"$SANDBOX/run.err"
assert_contains "$(cat "$SANDBOX/run.out")" "detail=list-prs:auth" "AC4 the run's stop line carries the detail"
DETAIL="$(python3 -I -c '
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d.get("event") == "run_end":
        print(d.get("detail"))' "$LOG" 2>/dev/null)"
assert_eq "list-prs:auth" "$DETAIL" "AC4 the run_end event carries the detail" "$(cat "$SANDBOX/run.err")"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["fail"]={}; json.dump(d, open(sys.argv[1], "w"))' "$GH_FX"

# ── AC5 ─────────────────────────────────────────────────────────────────────
for CASE in "1 dispatch stage=qa pr=101" "2 dispatch stage=docs pr=102" "3 dispatch stage=reviewer pr=103" \
            "4 dispatch stage=security pr=104" "5 merge pr=105" "6 dispatch stage=docs pr=106"; do
  set -- $CASE
  N="$1"; shift
  reset_calls
  OUT="$(bash "$TALOS" next --issue "$N" 2>"$SANDBOX/err")"
  assert_eq "action=$* issue=$N" "$OUT" "AC5 next --issue $N answers $*" "$(cat "$SANDBOX/err")"
done

finish
