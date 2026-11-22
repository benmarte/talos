#!/usr/bin/env bash
# test-merge-queue-drain.sh -- the lock holder drains the queue (#981): after a
# `talos.sh queue run` pass that merged or ejected, the same invocation reads the
# queue again under the same lock and runs another pass for the PRs that were not
# part of the batch just handled, so a PR queued by a queue-busy lane is not
# stranded. It stops at an empty queue, at any wait/block verdict, and after
# merge.queue_batch * 4 PRs handled. Tests are named by the spec's criterion id.
#
# The fixture is tests/test-merge-queue-runner-lock.sh's: a local bare `origin`,
# journaling stubs and TALOS_RETRY_SLEEP_SCALE=0. No network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=930 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TALOS_RETRY_SLEEP_SCALE=0
MARK='<!-- talos:queue -->'

# ── fixtures (as tests/test-merge-queue-runner-lock.sh) ──────────────────────
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
UPD="$SANDBOX/origin-updates.log"
export Q_ORIGIN="$ORIGIN" Q_SEED="$SEED"
git remote set-url origin "$ORIGIN"

GQ="$SANDBOX/gq"
mkdir -p "$GQ"
cp "$GS"/* "$GQ/"
for s in pipeline-mergebase.sh pipeline-worktree.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GQ/$s"
done

sg() { git -C "$SEED" "$@"; }
origin_reset() {
  rm -rf "${ORIGIN:?}" "${SEED:?}"
  : > "$UPD"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git init -q "$SEED"
  sg symbolic-ref HEAD refs/heads/main
  sg config user.name talos-test
  sg config user.email test@talos.invalid
  sg config commit.gpgsign false
  printf 'base\n' > "$SEED/base.txt"
  printf '# Changelog\n\n## [Unreleased]\n\n' > "$SEED/CHANGELOG.md"
  sg add -A
  sg commit -q -m base
  sg remote add origin "$ORIGIN"
  sg push -q origin main
}
comments_json() {
  python3 -I -c '
import json, sys
out = []
for a in sys.argv[1:]:
    login, body = a.split("|", 1)
    out.append({"author": {"login": login}, "body": body.replace("\\n", "\n")})
print(json.dumps({"comments": out}))' "$@"
}
qbody() { printf '**Merge queue:**\\n\\nqueue: base=%s head=%s eligible=%s\\n\\n%s' "$1" "$2" "$3" "$MARK"; }
Q_LIST=""
Q_SEQ=0
q_pr() {  # <pr> <issue> <file> <line>: one queued PR on feat/issue-<issue>-q
  local _pr="$1" _n="$2" _br="feat/issue-$2-q" _h
  sg checkout -q -B "$_br" main
  printf '%s\n' "$4" >> "$SEED/$3"
  sg add -A
  sg commit -q -m "pr$_pr: $3"
  sg push -q -f origin "$_br"
  _h="$(sg rev-parse HEAD)"
  sg checkout -q main
  Q_SEQ=$((Q_SEQ + 1))
  printf '%s' "$_h" > "$STUB_DIR/pr-head.$_pr"
  comments_json "owner|$(qbody main "$_h" "$(printf '2026-11-01T00:00:%02dZ' "$Q_SEQ")")" > "$STUB_DIR/read-comments.$_pr"
  printf '{"number": %s, "headRefName": "%s", "baseRefName": "main", "labels": [], "state": "open"}' "$_pr" "$_br" > "$STUB_DIR/view-pr.$_pr"
  Q_LIST="$Q_LIST${Q_LIST:+,}{\"number\":$_pr,\"baseRefName\":\"main\",\"headRefName\":\"$_br\",\"isCrossRepository\":false}"
  export LIST_PRS="[$Q_LIST]"
}
q_cfg() {  # <merge.queue or -> [extra merge members]
  local _q=""
  [ "$1" = "-" ] || _q="\"queue\": \"$1\", "
  printf '{"vcs": {"provider": "github"}, "base_branch": "main", "merge": {%s"method": "squash"%s}}' \
    "$_q" "${2:-}" > "$SANDBOX/talos.pipeline.json"
}
q_reset() {
  reset_stubs
  LEASE_RESET
  Q_LIST=""; Q_SEQ=0
  export LIST_PRS="[]" LIST_ISSUES="[]"
  printf 'owner' > "$STUB_DIR/current-user"
  printf 'talos:checkout state=kept' > "$STUB_DIR/worktree.out"
  q_cfg talos
  origin_reset
}
qr() { OUT="$(bash "$GQ/talos.sh" queue run </dev/null 2>"$ERR")"; RC=$?; }
jc() { journal | grep -c -E "$1"; }
queue_left() { git -C "$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads/talos/queue/ | grep -c .; }
line1() { printf '%s\n' "$OUT" | sed -n 1p; }
has_line() { grep -qx -- "$1" <<< "$OUT"; }
assert_line() { if has_line "$2"; then pass "$1"; else fail "$1" "no line '$2' in: $(printf '%s' "$OUT" | tr '\n' '|')"; fi; }

# ── the runner lock: <git common dir>/talos-queue-<base>.lock.d ──────────────
QLOCK="$(git rev-parse --git-common-dir)/talos-queue-main.lock.d"
HOLDER=""
hold_lock() {  # <pid>: a lock held by <pid>
  rm -rf "${QLOCK:?}"; mkdir "$QLOCK"; printf '%s:1\n' "$1" > "$QLOCK/pid"
}
stop_holder() {
  [ -z "$HOLDER" ] || { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; }
  HOLDER=""; rm -rf "${QLOCK:?}"
}
cands() { grep -c '^candidate=' <<< "$OUT"; }
verdicts() { grep -c '^verdict=' <<< "$OUT"; }
locked() { if [ -e "$QLOCK" ]; then echo yes; else echo no; fi; }
merged_prs() { journal | sed -n 's/^vcs merge-pr \([0-9]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//'; }
trap stop_holder EXIT

# late_pr <pr> <issue> <file> <line>: a PR queued while the first pass waits on its
# candidate: it is on origin with its marker, but list-prs shows it only once the
# first check call has been made.
late_pr() {
  local _first="$LIST_PRS"
  q_pr "$@"
  printf '%s' "$LIST_PRS" > "$STUB_DIR/list-prs.full"
  export LIST_PRS="$_first"
  printf '%s\n' ': > "$d/shown"' > "$STUB_DIR/hook.ref-checks-required"
  printf '%s\n' '[ ! -f "$d/shown" ] || LIST_PRS="$(cat "$d/list-prs.full")"' > "$STUB_DIR/hook.list-prs"
}

# ── AC1: a PR queued during a pass is merged by the same invocation ──────────
q_reset; q_pr 11 41 a11.txt x11; late_pr 12 42 a12.txt x12
qr
assert_eq "verdict=merged" "$(line1)" "AC1 the drain ends merged"
assert_eq "11 12" "$(merged_prs)" "AC1 PR B queued during the pass merges after A, in the same invocation"
assert_eq "2" "$(cands)" "AC1 a second pass cuts a second candidate"
assert_eq "2" "$(verdicts)" "AC1 each pass prints its own verdict"
assert_eq "0|no" "$(queue_left)|$(locked)" "AC1 no candidate left on origin, the lock released"

# ── AC2: a pass that ends wait does not start another ────────────────────────
q_reset; q_pr 11 41 a11.txt x11; late_pr 12 42 a12.txt x12; printf 2 > "$STUB_DIR/ref-checks-required.rc"
qr
assert_eq "verdict=wait" "$(line1)" "AC2 a timed-out pass: verdict=wait"
assert_line "AC2 reason=candidate-timeout" "reason=candidate-timeout"
assert_eq "1|0" "$(cands)|$(jc '^vcs merge-pr ')" "AC2 candidate-timeout: no second pass, nothing merged"
q_reset; q_pr 11 41 a11.txt x11; q_pr 13 43 a13.txt x13; late_pr 12 42 a12.txt x12
printf '%s' 'cccccccccccccccccccccccccccccccccccccccc' > "$STUB_DIR/head-after"
printf '%s\n' '[ "$1" != merge-pr ] || [ "$2" != 11 ] || cp "$d/head-after" "$d/pr-head.13"' > "$STUB_DIR/hook.merge-pr"
qr
assert_eq "verdict=wait" "$(line1)" "AC2 a wait after a merge: verdict=wait"
assert_line "AC2 reason=head-moved" "reason=head-moved"
assert_eq "1|11" "$(cands)|$(merged_prs)" "AC2 head-moved after PR 11 merged: no second pass for the late PR"
assert_eq "no" "$(locked)" "AC2 the lock is released after the wait"

# ── AC3: the drain stops after merge.queue_batch * 4 PRs ─────────────────────
q_reset; q_cfg talos ', "queue_batch": 1'
q_pr 11 41 a11.txt x11; q_pr 12 42 a12.txt x12; q_pr 13 43 a13.txt x13
q_pr 14 44 a14.txt x14; q_pr 15 45 a15.txt x15; q_pr 16 46 a16.txt x16
qr
assert_eq "verdict=merged" "$(line1)" "AC3 the bounded drain ends merged"
assert_eq "11 12 13 14" "$(merged_prs)" "AC3 merge.queue_batch 1 * 4: four PRs merge, two stay queued"
assert_eq "4|no" "$(cands)|$(locked)" "AC3 four passes, the lock released"

# ── AC4: an empty queue after the first pass ends with its verdict ───────────
q_reset; q_pr 11 41 a11.txt x11
qr
assert_eq "verdict=merged" "$(line1)" "AC4 nothing else queued: the first pass's verdict"
assert_eq "1|1|1" "$(cands)|$(verdicts)|$(jc '^vcs merge-pr ')" "AC4 one pass, one candidate, one merge"
assert_eq "0|no" "$(queue_left)|$(locked)" "AC4 no candidate left, the lock is released"

# ── AC5 (same): the queue-busy answer is unchanged ───────────────────────────
q_reset; q_pr 11 41 a11.txt x11
sleep 300 & HOLDER=$!
hold_lock "$HOLDER"
qr
assert_eq "verdict=wait" "$(line1)" "AC5 a held lock: verdict=wait"
assert_line "AC5 reason=queue-busy" "reason=queue-busy"
assert_eq "0|0" "$(cands)|$(jc '^vcs merge-pr')" "AC5 no candidate cut, nothing merged"
stop_holder

finish
