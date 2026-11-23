#!/usr/bin/env bash
# test-repo-derive-no-api.sh -- with vcs.repo unset, pipeline-vcs.sh derives
# owner/repo from the `origin` remote before it asks the API (#1037). The
# `gh api repos/{owner}/{repo} --jq .full_name` lookup cost one REST call per
# verb process, 35% of a routing pass, so it is now the fallback for a remote
# that does not parse.
#
#   AC1  a github.com or gitlab.com remote resolves with no repo lookup
#   AC2  a remote that does not parse (an SSH alias) makes the one lookup
#   AC3  a collect pass (the reads `next` routes on) makes at most one lookup
#   AC4  vcs.repo in config and PIPELINE_REPO in the environment beat the remote
#
# The `gh` stub (tests/stubs/gh) logs every call; a lookup is the line
# `api repos/{owner}/{repo} --jq .full_name`. No network, no sleeps.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
SF="$TALOS_ROOT/scripts/pipeline-status-file.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
unset PIPELINE_REPO
write_cfg() {  # <vcs members after provider>
  printf '%s\n' "{\"vcs\": {\"provider\": \"github\"$1},"' "roles": {"qa": true}, "pr": {"draft": false}}' > "$PIPELINE_CONFIG"
}
write_cfg ""

# lookups: how many repo lookups the gh stub has logged since the log was cleared.
lookups() { grep -c -x 'api repos/{owner}/{repo} --jq .full_name' "$GH_LOG" || true; }
# resolve <remote-url>: the repo `resolve-repo` prints for that origin, the log cleared first.
resolve() {
  git remote set-url origin "$1"
  : > "$GH_LOG"
  bash "$VCS" resolve-repo 2>/dev/null
}

# ── AC1: a parseable remote needs no lookup ──────────────────────────────────
for url in 'https://github.com/acme/widget.git' 'git@github.com:acme/widget.git' \
           'https://github.com/acme/widget' 'ssh://git@github.com/acme/widget.git'; do
  assert_eq "acme/widget" "$(resolve "$url")" "AC1 $url resolves acme/widget"
  assert_eq "0" "$(lookups)" "AC1 $url makes no repo lookup"
done
write_cfg ', "repo": ""'
assert_eq "grp/sub/proj" "$(resolve 'https://gitlab.com/grp/sub/proj.git')" "AC1 a gitlab.com remote keeps its subgroup path"
assert_eq "0" "$(lookups)" "AC1 a gitlab.com remote makes no repo lookup"
assert_eq "grp/proj" "$(resolve 'git@gitlab.com:grp/proj.git')" "AC1 a gitlab.com ssh remote resolves"
write_cfg ""

# ── AC2: a remote that does not parse falls back to the one lookup ───────────
assert_eq "acme/widget" "$(resolve 'git@gh-work:widget')" "AC2 an SSH alias resolves through the API"
assert_eq "1" "$(lookups)" "AC2 an SSH alias makes exactly one repo lookup"
assert_eq "other/name" "$(STUB_REPO=other/name resolve 'git@gh-work:widget')" "AC2 the lookup's answer is the repo, not the remote"

# ── AC3: one pass, at most one lookup ────────────────────────────────────────
export STUB_ISSUE_LIST='[]'
export STUB_PR_LIST='[{"number": 11, "state": "OPEN", "title": "a", "headRefName": "fix/issue-1-a", "baseRefName": "main", "isCrossRepository": false, "labels": []},
  {"number": 12, "state": "OPEN", "title": "b", "headRefName": "fix/issue-2-b", "baseRefName": "main", "isCrossRepository": false, "labels": []},
  {"number": 13, "state": "OPEN", "title": "c", "headRefName": "fix/issue-3-c", "baseRefName": "main", "isCrossRepository": false, "labels": []}]'
export STUB_PR_LABELS_JSON='[]'
export STUB_PR_HEAD_SHA="1111111111111111111111111111111111111111"
for url in 'git@gh-work:widget' 'git@github.com:acme/widget.git'; do
  git remote set-url origin "$url"
  : > "$GH_LOG"
  OUT="$(bash "$SF" collect 2>"$SANDBOX/collect.err")"; RC=$?
  assert_eq "0" "$RC" "AC3 collect on $url exits 0"
  assert_contains "$OUT" '"n": 13' "AC3 collect on $url read all three PRs"
  n="$(lookups)"
  if [ "$n" -le 1 ]; then pass "AC3 collect on $url makes at most one repo lookup"
  else fail "AC3 collect on $url makes at most one repo lookup" "lookups: $n"; fi
done
assert_eq "0" "$(lookups)" "AC3 a parseable remote makes no lookup in the whole pass"

# ── AC4: an explicit vcs.repo or PIPELINE_REPO still wins ────────────────────
write_cfg ', "repo": "cfg/repo"'
assert_eq "cfg/repo" "$(resolve 'git@github.com:acme/widget.git')" "AC4 vcs.repo beats a parseable remote"
assert_eq "0" "$(lookups)" "AC4 vcs.repo makes no repo lookup"
assert_eq "cfg/repo" "$(resolve 'git@gh-work:widget')" "AC4 vcs.repo beats an unparseable remote"
assert_eq "0" "$(lookups)" "AC4 vcs.repo with an alias remote makes no repo lookup"
write_cfg ""
git remote set-url origin 'git@github.com:acme/widget.git'
: > "$GH_LOG"
assert_eq "env/repo" "$(PIPELINE_REPO=env/repo bash "$VCS" resolve-repo 2>/dev/null)" "AC4 PIPELINE_REPO beats the remote"
assert_eq "0" "$(lookups)" "AC4 PIPELINE_REPO makes no repo lookup"
write_cfg ', "repo": "cfg/repo"'
assert_eq "env/repo" "$(PIPELINE_REPO=env/repo bash "$VCS" resolve-repo 2>/dev/null)" "AC4 PIPELINE_REPO is the highest layer, over vcs.repo in config"

echo "test-repo-derive-no-api.sh: $_PASS passed, $_FAIL failed"
[ "$_FAIL" -eq 0 ]
