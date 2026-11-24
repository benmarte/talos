#!/usr/bin/env bash
# test-merge-gate-current-base.sh -- the merge gate's stale-base step also brings a PR
# that is merely BEHIND its base (no conflict) up to date before any merge verdict, so
# its required CI is never judged against an older base (#1060). AC ids are the spec's.
#   AC1 merge.queue off, key at its default: a behind, clean PR is synced and the gate
#       answers `wait reason=base-synced`, never `merge`
#   AC2 after the sync the next gate run merges only once pr-checks-required is green
#   AC3 merge.auto_sync false: the PR being merged is still brought up to date, and no
#       sibling sync runs
#   AC4 merge.queue talos or github: the key is ignored, the gate behaves as today
#   AC5 merge.require_current_base false: a behind, clean PR is merged as today
#   AC6 a behind-check that cannot be read answers `wait reason=base-check-unverified`
#   AC7 (same) a PR whose head already contains the base head goes to `merge`
# AC8 is prose (docs/reference.md and the CHANGELOG).
# Part (a) drives `talos.sh gate merge` against a journaling stub provider (as
# tests/test-talos-gate.sh); part (b) runs the real `pr-behind` verb against a local
# bare repo and the curl stub (the compare-API fallback).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
TALOS="$TALOS_ROOT/scripts/talos.sh"
ERR="$SANDBOX/stderr"

GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="${1:-}"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
if [ "$n" = "hooks" ]; then cat > "$d/hooks.stdin"; fi
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-mergebase.sh pipeline-draft-check.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
GATE="$GS/talos.sh"

HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
cfg_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }
set_stub() {  # <key> <rc> [out] [err]
  printf '%s\n' "$2" > "$STUB_DIR/$1.rc"
  printf '%s' "${3:-}" > "$STUB_DIR/$1.out"
  printf '%s' "${4:-}" > "$STUB_DIR/$1.err"
}
labels_json() {
  local out="" n
  for n in "$@"; do out="${out:+$out,}{\"name\":\"$n\"}"; done
  printf '{"labels":[%s]}' "$out"
}
# A PR that clears every gate before the stale-base step: no conflict, CI green.
fixture() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$SANDBOX/talos.pipeline.json"
  set_stub view-pr 0 "$(labels_json qa:pass review:approved security:approved docs:done pipeline:review)"
  set_stub view-issue 0 "$(labels_json pipeline:review)"
  set_stub pr-head 0 "$HEAD_SHA"
  set_stub read-comments 0 '{"comments":[]}'
  set_stub draft-check 0 "false"
  set_stub pr-ci-runs 0 "2"
  set_stub conflict-files 0 ""
  set_stub pr-mergeable 0 "MERGEABLE"
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
called() { journal | grep -c "^$1 \|^vcs $1 "; }
gm() { OUT="$(bash "$GATE" gate merge 9 42 2>"$ERR")"; RC=$?; }
NL=$'\n'

# AC1: behind and clean (merge.queue off, the key at its default).
fixture; set_stub pr-behind 1 "behind"
gm
assert_eq "verdict=wait${NL}reason=base-synced" "$OUT" "AC1 a behind, clean PR is synced and waits, never merges"
assert_eq "1" "$(called mergebase)" "AC1 the PR is brought up to date by pipeline-mergebase.sh"
assert_eq "0" "$(called update-branch)" "AC1 no update-branch while the mechanical sync succeeds"
fixture; set_stub pr-behind 1 "behind"; set_stub mergebase 1
gm
assert_eq "verdict=wait${NL}reason=base-synced" "$OUT" "AC1 a failed mechanical sync falls back to update-branch"
assert_eq "1" "$(called update-branch)" "AC1 update-branch is called once"

# AC2: the sync's head is CI-verified before a merge.
fixture; set_stub pr-behind 0 "current"; set_stub pr-checks-required 2
gm
assert_eq "verdict=wait${NL}reason=ci-pending" "$OUT" "AC2 after the sync a pending required check at the new head waits"
assert_eq "0" "$(called pr-behind)" "AC2 the base check is not reached behind a pending CI"
set_stub pr-checks-required 0
gm
assert_eq "verdict=merge" "$OUT" "AC2 the next run merges once pr-checks-required is green at the new head"

# AC3: merge.auto_sync false still syncs the PR being merged, and no sibling.
fixture; cfg_json '{"merge": {"auto_sync": false}}'; set_stub pr-behind 1 "behind"
gm
assert_eq "verdict=wait${NL}reason=base-synced" "$OUT" "AC3 auto_sync false: the PR being merged is still synced"
assert_eq "1" "$(called mergebase)" "AC3 the PR being merged is brought up to date"
assert_eq "0" "$(called list-prs)" "AC3 no sibling sync (no list-prs)"
assert_eq "1" "$(called conflict-files)" "AC3 only the PR being merged is looked at"
fixture; cfg_json '{"merge": {"auto_sync": false}}'; set_stub pr-behind 1 "behind"; set_stub mergebase 1
gm
assert_eq "verdict=wait${NL}reason=base-synced" "$OUT" "AC3 auto_sync false: update-branch syncs the PR when the mechanical sync cannot"
assert_eq "1" "$(called update-branch)" "AC3 update-branch runs for the PR being merged"

# AC4: merge.queue talos or github ignores the key.
for q in talos github; do
  fixture; cfg_json "{\"merge\": {\"queue\": \"$q\"}}"; set_stub pr-behind 1 "behind"
  gm
  assert_not_contains "$OUT" "base-synced" "AC4 merge.queue $q: no base-synced wait"
  assert_not_contains "$OUT" "base-check-unverified" "AC4 merge.queue $q: no base-check-unverified wait"
  assert_eq "0" "$(called pr-behind)" "AC4 merge.queue $q: the behind-check is never read"
  assert_eq "0" "$(called mergebase)" "AC4 merge.queue $q: the PR is not synced by the gate"
done

# AC5: the key off is today's behaviour.
fixture; cfg_json '{"merge": {"require_current_base": false}}'; set_stub pr-behind 1 "behind"
gm
assert_eq "verdict=merge" "$OUT" "AC5 require_current_base false: a behind, clean PR is merged as today"
assert_eq "0" "$(called pr-behind)" "AC5 the behind-check is not read with the key off"

# AC6: an unreadable behind-check fails closed.
fixture; set_stub pr-behind 2 "" "pipeline-vcs: pr-behind: could not determine"
gm
assert_eq "verdict=wait${NL}reason=base-check-unverified" "$OUT" "AC6 an unreadable behind-check waits, never merges"
assert_eq "0" "$(called merge-pr)" "AC6 nothing is merged"
fixture; set_stub pr-behind 1 "behind"; set_stub mergebase 1; set_stub update-branch 1
gm
assert_eq "verdict=wait${NL}reason=base-check-unverified" "$OUT" "AC6 a sync that cannot run never ends in a merge"

# AC7 (same): an up-to-date PR merges as before.
fixture; set_stub pr-behind 0 "current"
gm
assert_eq "verdict=merge" "$OUT" "AC7 an up-to-date PR goes to merge exactly as today"
assert_eq "1" "$(called pr-behind)" "AC7 the behind-check ran once"
assert_eq "0" "$(called mergebase)" "AC7 an up-to-date PR is not synced"

# (b) the real pr-behind verb: local bare repo, github-api transport on the curl stub.
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
git config user.email "test@talos.invalid"; git config user.name "talos-test"
UP_PARENT="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-cb-origin.XXXXXX")" || exit 1
UP="$UP_PARENT/upstream.git"
git init -q --bare "$UP"
trap '_is_trap_owner && rm -rf "$SANDBOX" "$UP_PARENT"' EXIT
git remote set-url origin "$UP"
echo seed > seed.txt; git add seed.txt; git commit -q -m seed
git branch -M main; git push -q origin main
git checkout -q -b pr-51; echo a > a.txt; git add a.txt; git commit -q -m "pr 51"
git push -q origin pr-51:refs/pull/51/head
git checkout -q main; echo b > b.txt; git add b.txt; git commit -q -m "base moves"
git push -q origin main
git checkout -q -b pr-52; echo c > c.txt; git add c.txt; git commit -q -m "pr 52"
git push -q origin pr-52:refs/pull/52/head
git checkout -q main
github_leg curl ', "base_branch": "main"'

out="$(bash "$VCS" pr-behind 51 2>&1)"; rc=$?
assert_eq "1" "$rc" "pr-behind: a head without the base head is behind (exit 1)"
assert_eq "behind" "$out" "pr-behind: prints behind"
out="$(bash "$VCS" pr-behind 52 2>&1)"; rc=$?
assert_eq "0" "$rc" "pr-behind: a head containing the base head is current (exit 0)"
assert_eq "current" "$out" "pr-behind: prints current"
# No refs/pull/53/head: git cannot answer, the compare API does.
printf '%s\n' '{"head":{"sha":"'"$HEAD_SHA"'"}}' '{"behind_by":3}' > "$CURL_QUEUE"
out="$(bash "$VCS" pr-behind 53 2>&1)"; rc=$?
assert_eq "1" "$rc" "pr-behind: the compare fallback reads behind_by > 0 as behind"
printf '%s\n' '{"head":{"sha":"'"$HEAD_SHA"'"}}' '{"behind_by":0}' > "$CURL_QUEUE"
out="$(bash "$VCS" pr-behind 53 2>&1)"; rc=$?
assert_eq "0" "$rc" "pr-behind: the compare fallback reads behind_by 0 as current"
printf '%s\n' '{"head":{"sha":"'"$HEAD_SHA"'"}}' '{"message":"nope"}' > "$CURL_QUEUE"
out="$(bash "$VCS" pr-behind 53 2>&1)"; rc=$?
assert_eq "2" "$rc" "pr-behind: an unreadable compare answer is exit 2, never current"
finish
