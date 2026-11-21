#!/usr/bin/env bash
# test-merge-queue-runner-lock.sh -- one queue runner per base branch (#965):
# `talos.sh queue run` takes a runner lock in the git common dir, keyed by the
# base branch, from before it cleans up and cuts until it ends. A second runner
# answers `verdict=wait reason=queue-busy` and cuts, pushes and deletes nothing;
# a lock whose holder pid is gone is reclaimed; a candidate gone stale while its
# checks are pending (the base moved, a PR of it merged or closed) is deleted and
# re-cut from the current queue in the same pass. Tests are named by the spec's
# criterion id.
#
# The fixture is tests/test-merge-queue-timeout-946.sh's: a local bare `origin`,
# journaling stubs and TALOS_RETRY_SLEEP_SCALE=0. No network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=930 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TALOS_RETRY_SLEEP_SCALE=0
MARK='<!-- talos:queue -->'

# ── fixtures (as tests/test-merge-queue-timeout-946.sh) ──────────────────────
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
  cat > "$ORIGIN/hooks/update" <<TALOS_updhook965Lk3Rw8Tz
#!/bin/sh
printf '%s %s %s\n' "\$1" "\$2" "\$3" >> "$UPD"
TALOS_updhook965Lk3Rw8Tz
  chmod +x "$ORIGIN/hooks/update"
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
q_three() { q_pr 11 41 a11.txt x11; q_pr 12 42 a12.txt x12; q_pr 13 43 a13.txt x13; }
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
stop_holder() { [ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null; HOLDER=""; rm -rf "${QLOCK:?}"; }
cands() { grep -c '^candidate=' <<< "$OUT"; }
locked() { if [ -e "$QLOCK" ]; then echo yes; else echo no; fi; }
merged_prs() { journal | sed -n 's/^vcs merge-pr \([0-9]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//'; }
trap stop_holder EXIT

# ── AC1: a live holder -> queue-busy, nothing cut, pushed or deleted ─────────
q_reset; q_three
sleep 300 & HOLDER=$!
hold_lock "$HOLDER"
sg push -q origin "main:refs/heads/talos/queue/main-1700000000"
: > "$UPD"
qr
assert_eq "verdict=wait" "$(line1)" "AC1 a held lock: verdict=wait"
assert_line "AC1 reason=queue-busy" "reason=queue-busy"
assert_eq "0" "$RC" "AC1 exit 0"
assert_eq "0|0" "$(cands)|$(jc '^vcs ref-checks-required')" "AC1 no candidate cut, no check call"
assert_eq "0|0" "$(jc '^vcs merge-pr')|$(grep -c . "$UPD")" "AC1 no merge-pr, nothing pushed or deleted on origin"
assert_eq "1" "$(queue_left)" "AC1 the holder's candidate is left alone"
assert_eq "$HOLDER:1" "$(cat "$QLOCK/pid")" "AC1 the lock is still the holder's"
stop_holder

# ── AC2: a lock whose holder pid is gone is reclaimed ────────────────────────
q_reset; q_three
true & DEAD=$!
wait "$DEAD" 2>/dev/null
hold_lock "$DEAD"
qr
assert_eq "verdict=merged" "$(line1)" "AC2 a dead holder's lock is reclaimed: verdict=merged"
assert_eq "3" "$(jc '^vcs merge-pr ')" "AC2 the pass merges the 3 PRs"
assert_eq "no" "$(locked)" "AC2 the lock is released at the end"

# ── AC3: a PR of the candidate merged meanwhile -> re-cut, no CI wait ────────
q_reset; q_three
printf '%s' "$LIST_PRS" | python3 -I -c 'import json,sys; print(json.dumps([p for p in json.load(sys.stdin) if p["number"] != 11]))' \
  > "$STUB_DIR/list-prs.after"
printf '%s\n' 'if [ "$(grep -c "^vcs ref-checks-required " "$d/journal")" -le 1 ]; then : > "$d/dropped"; exit 2; fi' \
  > "$STUB_DIR/hook.ref-checks-required"
printf '%s\n' '[ ! -f "$d/dropped" ] || LIST_PRS="$(cat "$d/list-prs.after")"' > "$STUB_DIR/hook.list-prs"
qr
assert_eq "verdict=merged" "$(line1)" "AC3 a merged PR in the candidate: the pass re-cuts and merges"
assert_eq "2" "$(cands)" "AC3 a second candidate is cut in the same pass"
assert_eq "2" "$(jc '^vcs ref-checks-required ')" "AC3 the stale candidate is not waited on: 2 check calls"
assert_eq "12 13" "$(merged_prs)" "AC3 only the PRs still queued merge"
assert_eq "0" "$(queue_left)" "AC3 no candidate is left on origin"

# ── AC3: the base moved meanwhile -> re-cut on the new base ──────────────────
q_reset; q_three
printf '%s\n' 'if [ "$(grep -c "^vcs ref-checks-required " "$d/journal")" -le 1 ]; then git -C "$Q_SEED" commit -q --allow-empty -m moved && git -C "$Q_SEED" push -q origin main; exit 2; fi' \
  > "$STUB_DIR/hook.ref-checks-required"
qr
assert_eq "verdict=merged" "$(line1)" "AC3 the base moved: the pass re-cuts and merges"
assert_eq "2" "$(cands)" "AC3 the base moved: a second candidate is cut in the same pass"
assert_eq "2" "$(jc '^vcs ref-checks-required ')" "AC3 the base moved: the stale candidate is not waited on"
assert_eq "3|0" "$(jc '^vcs merge-pr ')|$(queue_left)" "AC3 the base moved: all 3 merge, no candidate left"

# ── AC4 (same): a lone run cuts, checks and merges as before ─────────────────
q_reset; q_three
qr
assert_eq "verdict=merged" "$(line1)" "AC4 a lone run: verdict=merged"
assert_eq "1|3|1" "$(cands)|$(jc '^vcs merge-pr ')|$(jc '^vcs ref-checks-required ')" "AC4 one candidate, 3 merges, one check call"
assert_eq "no" "$(locked)" "AC4 the lock is released after a merged pass"
q_reset; q_three; printf 2 > "$STUB_DIR/ref-checks-required.rc"
qr
assert_eq "verdict=wait" "$(line1)" "AC4 a timed-out pass: verdict=wait"
assert_eq "no" "$(locked)" "AC4 the lock is released after a wait"

finish
