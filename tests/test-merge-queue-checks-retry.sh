#!/usr/bin/env bash
# test-merge-queue-checks-retry.sh -- a failed check read in `talos.sh queue run`
# step 7 (ref-checks-required exit outside 0/1/2) counts as pending: the pass asks
# again at the next tick, prints `warn reason=checks-read-failed sha=<sha>
# attempt=<n>`, and only 3 failed reads in a row end it with
# `wait reason=checks-unverified`. Tests are named by the spec's criterion id.
#
# The fixture is tests/test-merge-queue-retry-950.sh's: tests/talos-run-sections.sh
# sourced with TALOS_RUN_PART=930 TALOS_RUN_EMBED=1, a local bare `origin`,
# journaling stubs and TALOS_RETRY_SLEEP_SCALE=0. No network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=930 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TALOS_RETRY_SLEEP_SCALE=0
MARK='<!-- talos:queue -->'

# ── fixtures (as tests/test-merge-queue-retry-950.sh) ────────────────────────
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
  cat > "$ORIGIN/hooks/update" <<TALOS_updhook982Wn7Qd3Vk
#!/bin/sh
printf '%s %s %s\n' "\$1" "\$2" "\$3" >> "$UPD"
TALOS_updhook982Wn7Qd3Vk
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
line1() { printf '%s\n' "$OUT" | sed -n 1p; }
has_line() { grep -qx -- "$1" <<< "$OUT"; }
assert_line() { if has_line "$2"; then pass "$1"; else fail "$1" "no line '$2' in: $(printf '%s' "$OUT" | tr '\n' '|')"; fi; }

# reads "<rc rc ...>": the n-th ref-checks-required call answers the n-th exit
# code (the last repeats); 1 prints a red row, 22 is a failed lookup.
reads() {
  {
    printf 'n="$(grep -c "^vcs ref-checks-required " "$d/journal")"\n'
    printf 'set -- %s\n' "$1"
    printf 'rc=$1; [ "$n" -gt "$#" ] && n=$#; i=1; for v in "$@"; do [ "$i" -eq "$n" ] && rc=$v; i=$((i + 1)); done\n'
    printf '%s\n' '[ "$rc" -ne 1 ] || printf "unit\tfail\t1m\thttps://ci.example/1\n"'
    printf '%s\n' 'exit "$rc"'
  } > "$STUB_DIR/hook.ref-checks-required"
}
cand_sha() { printf '%s\n' "$OUT" | sed -n 's/^candidate=[^ ]* sha=\([0-9a-f]*\) .*/\1/p' | head -n 1; }
warns() { printf '%s\n' "$OUT" | grep -c '^warn reason=checks-read-failed sha=[0-9a-f]\{40\} attempt=[0-9]*$'; }
cands_left() { git -C "$ORIGIN" for-each-ref --format='%(refname)' 'refs/heads/talos/queue/' | grep -c .; }

# ── AC1: one failed lookup, then green -> merged in the same pass ────────────
q_reset; q_three; reads "22 0"
qr
assert_eq "verdict=merged" "$(line1)" "AC1 a lookup that fails once then answers green: verdict=merged"
assert_eq "3" "$(jc '^vcs merge-pr ')" "AC1 the 3 PRs merge in the same pass"
assert_eq "1" "$(warns)" "AC1 exactly one warn reason=checks-read-failed line"
assert_line "AC1 the warn line names the candidate sha and attempt 1" "warn reason=checks-read-failed sha=$(cand_sha) attempt=1"
assert_eq "2" "$(jc '^vcs ref-checks-required ')" "AC1 two check reads"

# ── AC2: 3 failed lookups in a row end the pass ──────────────────────────────
q_reset; q_three; reads "22"
qr
assert_eq "verdict=wait" "$(line1)" "AC2 3 failed lookups in a row: verdict=wait"
assert_line "AC2 reason=checks-unverified" "reason=checks-unverified"
assert_eq "3|0|0" "$(jc '^vcs ref-checks-required ')|$(jc '^vcs merge-pr ')|$(jc '^hooks post_stage queue_eject ')" "AC2 three reads, nothing merged, nothing ejected"
assert_eq "3" "$(warns)" "AC2 one warn line per failed read"
assert_line "AC2 the third warn is attempt=3" "warn reason=checks-read-failed sha=$(cand_sha) attempt=3"
assert_eq "0" "$(cands_left)" "AC2 the candidate is deleted"
# a success in between resets the count: 22 22 pending 22 22 green
q_reset; q_three; reads "22 22 2 22 22 0"
qr
assert_eq "verdict=merged" "$(line1)" "AC2 a pending answer resets the count: verdict=merged"
assert_eq "4" "$(warns)" "AC2 four failed reads, never 3 in a row"

# ── AC3: failed lookups alternating with pending never reach the limit ───────
q_reset; q_pr 11 41 a11.txt x11; q_cfg talos ', "queue_timeout_s": 150'; reads "22 2 22 2 22"
qr
assert_eq "verdict=wait" "$(line1)" "AC3 alternating failed and pending reads: verdict=wait"
assert_line "AC3 the pass ends at the budget: reason=candidate-timeout" "reason=candidate-timeout"
assert_eq "5|0" "$(jc '^vcs ref-checks-required ')|$(jc '^vcs merge-pr ')" "AC3 five reads (150 / 30), no merge"
assert_eq "0" "$(cands_left)" "AC3 the candidate is deleted"

# ── AC4: a failed lookup during the red retry or the bisection is retried ────
# the retry: red, re-run, one failed read, green
q_reset; q_pr 11 41 a11.txt x11; reads "1 22 0"
qr
assert_eq "verdict=merged" "$(line1)" "AC4 a failed read after the re-run is retried: verdict=merged"
assert_eq "0|1" "$(jc '^hooks post_stage queue_eject ')|$(jc '^vcs rerun-ci ')" "AC4 no PR is ejected, one re-run"
# the bisection: red whole candidate (no retry), the first bisection read fails
q_reset; q_pr 11 41 a11.txt x11; q_pr 12 42 a12.txt x12; q_cfg talos ', "queue_retry": 0'; reads "1 22 0 0"
qr
assert_line "AC4 bisection: only the culprit is ejected" "ejected=12 issue=42"
assert_line "AC4 bisection: the other PR merges" "merged=11 issue=41"
assert_eq "1" "$(jc '^hooks post_stage queue_eject ')" "AC4 bisection: one PR ejected, not both"
assert_eq "1" "$(warns)" "AC4 bisection: one warn line"
# the bisection with 3 failed reads in a row: nothing ejected
q_reset; q_pr 11 41 a11.txt x11; q_pr 12 42 a12.txt x12; q_cfg talos ', "queue_retry": 0'; reads "1 22"
qr
assert_line "AC4 bisection: 3 failed reads: reason=checks-unverified" "reason=checks-unverified"
assert_eq "0|0" "$(jc '^hooks post_stage queue_eject ')|$(jc '^vcs merge-pr ')" "AC4 bisection: nothing ejected, nothing merged"

# ── AC5 (same): red is still handled as today ────────────────────────────────
q_reset; q_pr 11 41 a11.txt x11; q_cfg talos ', "queue_retry": 0'; reads "1"
qr
assert_eq "verdict=ejected" "$(line1)" "AC5 red with queue_retry 0: verdict=ejected at once"
assert_eq "1|1|0|0" "$(jc '^vcs ref-checks-required ')|$(jc '^hooks post_stage queue_eject ')|$(jc '^vcs merge-pr ')|$(warns)" "AC5 one read, one eject, no merge, no warn"

finish
