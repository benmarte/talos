#!/usr/bin/env bash
# test-branch-prefix-adoption.sh -- a PR on any conventional branch prefix is
# adopted as its issue's PR, and two open PRs for one issue stop routing (#1073).
# `scripts/pipeline-next.py` mapped a PR to its issue only by `fix/` or `feat/`;
# a `refactor/issue-1020-...` PR was never adopted and a second PR was opened.
#   AC1 (test) an open PR on `refactor/issue-7-x` (and each other listed prefix)
#       is adopted as issue 7's PR: `next --issue 7` routes it like a fix/ PR
#   AC2 (test) a branch with an unlisted prefix (`wip/issue-7-x`) is not adopted
#   AC3 (test) two open PRs for one issue make `next --issue <n>` answer
#       `stop reason=duplicate-pr issue=<n> prs=<a,b>` (exit 0), dispatching nothing
#   AC4 (test) every `<prefix>/issue-N` parser in scripts/ reads the one shared
#       prefix list: no other hard-coded `fix|feat` alternation remains
#   AC5 (same) `fix/issue-7-x` and `feat/issue-7-x` PRs are adopted as before
# AC6 (docs and changelog) is prose.
#
# The real scripts run against `gh`, a small fake GitHub REST API (the stub provider).
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

BIN="$SANDBOX/bin"
export GH_FX="$SANDBOX/fx.json"
mkdir -p "$BIN"

cat > "$BIN/gh" <<'TALOS_ghstubBp4Wn8Ze'
#!/usr/bin/env python3
# A small fake GitHub REST API behind `gh api -i`.
import json, os, re, sys

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
rest = re.sub(r'^repos/[^/]+/[^/]+/?', '', path)
status, body = 200, None
if method == 'GET':
    m = re.match(r'pulls/(\d+)$', rest)
    if rest.startswith('pulls?'):
        body = fx['prs']
    elif m:
        body = next((p for p in fx['prs'] if p['number'] == int(m.group(1))), None)
    elif re.match(r'pulls/\d+/files', rest):
        body = []
    elif rest.startswith('issues?'):
        body = fx['issues']
    elif re.match(r'issues/\d+/comments', rest):
        body = []
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
    status, body = 404, {'message': 'Not Found'}
sys.stdout.write('HTTP/2.0 %d X\r\nContent-Type: application/json\r\n\r\n%s' % (status, json.dumps(body)))
if status >= 400:
    sys.stderr.write('gh: stub (HTTP %d)\n' % status)
    sys.exit(1)
TALOS_ghstubBp4Wn8Ze
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# fixture <pr:branch>...: one open PR per argument, each closing issue 7 (the
# number before the `:` is the PR number); issue 7 is queued for the operator.
fixture() {
  python3 -I - "$GH_FX" "$@" <<'TALOS_fxbuildBp6Rj3Hd'
import json, sys
prs = []
for spec in sys.argv[2:]:
    n, branch = spec.split(':', 1)
    n = int(n)
    prs.append({'number': n, 'title': 'PR %d' % n, 'draft': False,
                'head': {'ref': branch, 'sha': '%040x' % n, 'repo': {'full_name': 'acme/widget'}},
                'base': {'ref': 'main', 'repo': {'full_name': 'acme/widget'}},
                'labels': [], 'body': 'Closes #7'})
issues = [{'number': 7, 'title': 'issue 7', 'body': 'b', 'labels': [{'name': 'pipeline:ready'}],
           'user': {'login': 'tester'}, 'assignees': [{'login': 'tester'}]}]
json.dump({'prs': prs, 'issues': issues}, open(sys.argv[1], 'w'))
TALOS_fxbuildBp6Rj3Hd
}

TALOS="$TALOS_ROOT/scripts/talos.sh"
# nxt <args...>: sets OUT (stdout) and RC, with every lease cleared first.
nxt() { reset_leases; OUT="$(bash "$TALOS" next "$@" 2>"$SANDBOX/err")"; RC=$?; }
LIST="fix feat refactor chore docs test perf ci build style"

# ── AC5 ─────────────────────────────────────────────────────────────────────
for P in fix feat; do
  fixture "107:$P/issue-7-x"
  nxt --issue 7
  assert_eq "action=dispatch stage=qa pr=107 issue=7" "$OUT" "AC5 a $P/issue-7-x PR is adopted as before" "$(cat "$SANDBOX/err")"
done

# ── AC1 ─────────────────────────────────────────────────────────────────────
for P in $LIST; do
  fixture "107:$P/issue-7-x"
  nxt --issue 7
  assert_eq "action=dispatch stage=qa pr=107 issue=7" "$OUT" "AC1 a $P/issue-7-x PR is adopted as issue 7's PR" "$(cat "$SANDBOX/err")"
done
fixture "107:refactor/issue-7-x"
nxt
assert_eq "action=dispatch stage=qa pr=107 issue=7" "$OUT" "AC1 the unscoped next adopts the refactor/ PR too" "$(cat "$SANDBOX/err")"

# ── AC2 ─────────────────────────────────────────────────────────────────────
fixture "107:wip/issue-7-x"
nxt --issue 7
assert_not_contains "$OUT" "pr=107" "AC2 a wip/issue-7-x PR is not adopted"
assert_eq "action=dispatch stage=validator issue=7" "$OUT" "AC2 control: issue 7 is routed as a PR-less issue" "$(cat "$SANDBOX/err")"

# ── AC3 ─────────────────────────────────────────────────────────────────────
fixture "107:fix/issue-7-x" "108:refactor/issue-7-y"
nxt --issue 7
assert_eq "stop reason=duplicate-pr issue=7 prs=107,108" "$OUT" "AC3 two open PRs for issue 7 stop the routing" "$(cat "$SANDBOX/err")"
assert_eq "0" "$RC" "AC3 the duplicate-pr stop exits 0"
assert_eq "" "$(ls "$SANDBOX"/.git/talos-lease* 2>/dev/null)" "AC3 nothing is dispatched, so no lease is taken"
nxt
assert_eq "stop reason=duplicate-pr issue=7 prs=107,108" "$OUT" "AC3 the unscoped next stops the same way" "$(cat "$SANDBOX/err")"
fixture "107:fix/issue-7-x" "108:wip/issue-7-y"
nxt --issue 7
assert_eq "action=dispatch stage=qa pr=107 issue=7" "$OUT" "AC3 control: a second PR on an unlisted prefix is no duplicate" "$(cat "$SANDBOX/err")"

# ── AC4 ─────────────────────────────────────────────────────────────────────
# hardcoded <dir>: the lines of <dir> (but the contract, where the list lives)
# that spell a `fix|feat` alternation; nothing printed means every parser reads the list.
hardcoded() { grep -rEn '(fix\|feat|\(\?:fix|fix,feat)' "$1" --exclude=pipeline-contract.sh || true; }
assert_eq "" "$(hardcoded "$TALOS_ROOT/scripts")" "AC4 no hard-coded fix|feat alternation is left in scripts/"
assert_contains "$(cat "$TALOS_ROOT/scripts/pipeline-contract.sh")" "TALOS_BRANCH_PREFIXES=(fix feat refactor chore docs test perf ci build style)" "AC4 the shared list lives in pipeline-contract.sh"
mkdir -p "$SANDBOX/plant"
printf 'rx = re.compile(r"^(?:fix|feat)/issue-([0-9]+)")\n' > "$SANDBOX/plant/p.py"
assert_contains "$(hardcoded "$SANDBOX/plant")" "fix|feat" "AC4 control: the check finds a planted hard-coded alternation"

finish
