#!/usr/bin/env bash
# test-merge-queue-retry-950.sh -- merge.queue_retry (#950): before `talos.sh queue
# run` ejects a PR for a red candidate it re-runs the failed required checks of
# the SAME candidate sha, up to merge.queue_retry times (int 0-3, default 1), and
# merges when they go green. Tests are named by the spec's criterion id.
#
# The fixture is tests/test-merge-queue-timeout-946.sh's: tests/talos-run-sections.sh
# sourced with TALOS_RUN_PART=930 TALOS_RUN_EMBED=1, a local bare `origin`,
# journaling stubs and TALOS_RETRY_SLEEP_SCALE=0. No network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=930 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TALOS_RETRY_SLEEP_SCALE=0
MARK='<!-- talos:queue -->'

# ── fixtures (as tests/test-merge-queue-946.sh) ──────────────────────────────
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
  cat > "$ORIGIN/hooks/update" <<TALOS_updhook950Zq4Lm8Rt
#!/bin/sh
printf '%s %s %s\n' "\$1" "\$2" "\$3" >> "$UPD"
TALOS_updhook950Zq4Lm8Rt
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

# red_until <n>: ref-checks-required is red for the first <n> calls, then green.
red_until() {
  printf '[ "$(grep -c "^vcs ref-checks-required " "$d/journal")" -gt %s ] && exit 0\n' "$1" > "$STUB_DIR/hook.ref-checks-required"
  red_always >> "$STUB_DIR/hook.ref-checks-required"
}
red_always() { printf '%s\n' 'printf "unit\tfail\t1m\thttps://ci.example/1\n"; exit 1'; }
cand_sha() { printf '%s\n' "$OUT" | sed -n 's/^candidate=[^ ]* sha=\([0-9a-f]*\) .*/\1/p' | head -n 1; }
# pushes: the creations of a talos/queue/ ref on origin (old sha all zeros).
pushes() { awk '$1 ~ /^refs\/heads\/talos\/queue\// && $2 ~ /^0+$/ { n++ } END { print n + 0 }' "$UPD"; }
check_shas() { journal | grep '^vcs ref-checks-required ' | sed 's/.* //'; }

# ── AC1: the default (1): red once, green on the re-run -> merged, not ejected ─
q_reset; q_three; red_until 1
qr
assert_eq "verdict=merged" "$(line1)" "AC1 red once, green on the re-run: verdict=merged"
assert_eq "3" "$(jc '^vcs merge-pr ')" "AC1 the 3 PRs merge"
assert_eq "0|0" "$(jc '^vcs upsert-pr-comment')|$(jc '^hooks post_stage queue_eject ')" "AC1 no PR is ejected"
assert_eq "1" "$(jc '^vcs rerun-ci ')" "AC1 exactly one re-run"
assert_eq "2" "$(jc '^vcs ref-checks-required ')" "AC1 two check reads: the first red, the re-run green"

# ── AC4: the re-run is of the same candidate sha, and nothing else moves ──────
SHA="$(cand_sha)"
assert_eq "vcs rerun-ci --sha $SHA" "$(journal | grep '^vcs rerun-ci ')" "AC4 rerun-ci names the candidate sha and no PR"
assert_eq "1" "$(pushes)" "AC4 one candidate was cut: the re-run cut no new one"
assert_eq "0" "$(jc '^vcs (label-pr|approve-pr|comment-pr|upsert-pr-comment|post-approval|check-approval-sha)')" "AC4 no approval or label of a PR changes"
assert_eq "$SHA|$SHA" "$(check_shas | sed -n 1p)|$(check_shas | sed -n 2p)" "AC4 both check reads are of the candidate sha"

# ── AC2: the default, red again on the re-run -> ejected as today ────────────
q_reset; q_pr 11 41 a11.txt x11
red_always > "$STUB_DIR/hook.ref-checks-required"
qr
assert_eq "verdict=ejected" "$(line1)" "AC2 red twice: verdict=ejected"
assert_line "AC2 ejected=11 issue=41" "ejected=11 issue=41"
assert_eq "1|2|0" "$(jc '^vcs rerun-ci ')|$(jc '^vcs ref-checks-required ')|$(jc '^vcs merge-pr ')" "AC2 one re-run, two check reads, no merge"
assert_eq "1" "$(jc '^hooks post_stage queue_eject ')" "AC2 the PR is ejected"

# AC2: a batch of two red twice: the retry comes first, the bisection after it.
q_reset; q_pr 11 41 a11.txt x11; q_pr 12 42 a12.txt x12
red_always > "$STUB_DIR/hook.ref-checks-required"
qr
SHA="$(cand_sha)"
assert_eq "$SHA|$SHA" "$(check_shas | sed -n 1p)|$(check_shas | sed -n 2p)" \
  "AC2 a batch of 2: the first two check reads are both of the whole candidate (retry before bisecting)"
# Two re-runs: the whole candidate, and the re-cut of the PR left after the eject
# (a new candidate, its own retry); the bisection step in between has none.
assert_eq "2" "$(jc '^vcs rerun-ci ')" "AC2 a batch of 2: a re-run per candidate, none per bisection step"
assert_eq "5" "$(jc '^vcs ref-checks-required ')" "AC2 a batch of 2 red twice: 2 reads of the whole candidate, 1 bisection read, 2 of the re-cut"

# ── AC3: merge.queue_retry 0 -> ejected at once, no re-run ───────────────────
q_reset; q_pr 11 41 a11.txt x11; q_cfg talos ', "queue_retry": 0'; red_until 1
qr
assert_eq "verdict=ejected" "$(line1)" "AC3 queue_retry 0, red once: verdict=ejected"
assert_eq "0|1|0" "$(jc '^vcs rerun-ci ')|$(jc '^vcs ref-checks-required ')|$(jc '^vcs merge-pr ')" "AC3 no re-run, one check read, no merge"

# ── the number of retries is the key: 3 re-runs, 2 re-runs ───────────────────
q_reset; q_pr 11 41 a11.txt x11; q_cfg talos ', "queue_retry": 3'; red_until 3
qr
assert_eq "verdict=merged" "$(line1)" "AC1 queue_retry 3, red three times then green: verdict=merged"
assert_eq "3" "$(jc '^vcs rerun-ci ')" "AC1 queue_retry 3: three re-runs"
q_reset; q_pr 11 41 a11.txt x11; q_cfg talos ', "queue_retry": 2'; red_until 9
qr
assert_eq "verdict=ejected" "$(line1)" "AC2 queue_retry 2, always red: verdict=ejected"
assert_eq "2|3" "$(jc '^vcs rerun-ci ')|$(jc '^vcs ref-checks-required ')" "AC2 queue_retry 2: two re-runs, three check reads"

# A re-run with nothing to re-run YET (rerun-ci answers 2: the candidate's other
# jobs are still in progress, so no run has a failed conclusion) is not a re-run:
# the queue waits and asks again, and the retry is spent only by a re-run that
# started. A re-run the provider refuses (1) still ejects, below.
rerun_busy() { printf '[ "$(grep -c "^vcs rerun-ci " "$d/journal")" -gt %s ] || exit 2\n' "$1" > "$STUB_DIR/hook.rerun-ci"; }
q_reset; q_pr 11 41 a11.txt x11; red_until 1; rerun_busy 2
qr
assert_eq "verdict=merged" "$(line1)" "AC1 red while jobs run, re-run once they settle: verdict=merged"
assert_eq "3|2" "$(jc '^vcs rerun-ci ')|$(jc '^vcs ref-checks-required ')" "AC1 two waits then one started re-run: three rerun-ci calls, two check reads"
assert_eq "0" "$(jc '^hooks post_stage queue_eject ')" "AC1 a pending candidate is not ejected"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c '^rerun=')" "AC1 one rerun= line: a wait is not a re-run"

# Never settling is the candidate timeout (merge.queue_timeout_s / 30 asks), not an eject.
q_reset; q_pr 11 41 a11.txt x11; q_cfg talos ', "queue_timeout_s": 90'; red_always > "$STUB_DIR/hook.ref-checks-required"; rerun_busy 99
qr
assert_eq "wait reason=candidate-timeout" "$(line1)" "AC1 jobs that never settle: wait reason=candidate-timeout"
assert_eq "3|0|0" "$(jc '^vcs rerun-ci ')|$(jc '^hooks post_stage queue_eject ')|$(jc '^vcs merge-pr ')" "AC1 the timeout bounds the asks: three, no eject, no merge"

# The provider needs a moment to reset the re-run jobs: the next read is after a pause.
mkdir -p "$SANDBOX/sleepbin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/sleeps"\n' "$STUB_DIR" > "$SANDBOX/sleepbin/sleep"
chmod +x "$SANDBOX/sleepbin/sleep"
q_reset; q_pr 11 41 a11.txt x11; red_until 1; : > "$STUB_DIR/sleeps"
OUT="$(PATH="$SANDBOX/sleepbin:$PATH" TALOS_RETRY_SLEEP_SCALE=1 bash "$GQ/talos.sh" queue run </dev/null 2>"$ERR")"; RC=$?
assert_eq "verdict=merged" "$(line1)" "AC1 with real pauses: verdict=merged"
assert_eq "30" "$(cat "$STUB_DIR/sleeps")" "AC1 one pause of 30 s after the re-run, before the check is read again"

# A re-run the provider cannot start ejects as today.
q_reset; q_pr 11 41 a11.txt x11; red_until 1; printf 1 > "$STUB_DIR/rerun-ci.rc"
qr
assert_eq "verdict=ejected" "$(line1)" "AC2 a re-run that cannot start: verdict=ejected as today"

# ── AC5: a value outside 0-3 is stop reason=config-unreadable ────────────────
for v in 4 -1 '"abc"' 1.5 '""' 100; do
  q_reset; q_three; q_cfg talos ", \"queue_retry\": $v"; : > "$UPD"
  qr
  assert_eq "stop reason=config-unreadable" "$(line1)" "AC5 queue_retry=$v: stop reason=config-unreadable"
  assert_contains "$(cat "$ERR")" "merge.queue_retry must be an integer from 0 to 3 -- got: ${v//\"/}" \
    "AC5 queue_retry=$v: stderr names merge.queue_retry, the value and the range"
  assert_eq "0|0|0" "$(jc '^vcs ref-checks-required')|$(jc '^vcs merge-pr')|$(jc '^vcs rerun-ci')" "AC5 queue_retry=$v: no check call, no merge, no re-run"
  assert_eq "0" "$(grep -c . "$UPD")" "AC5 queue_retry=$v: nothing pushed to origin"
done
for v in 0 1 2 3 '"2"'; do
  q_reset; q_three; q_cfg talos ", \"queue_retry\": $v"
  qr
  assert_eq "verdict=merged" "$(line1)" "AC5 queue_retry=$v is accepted"
done
# off ignores a bad value, as merge.queue_timeout_s does
q_reset; q_three; q_cfg off ', "queue_retry": 9'
qr
assert_eq "0|verdict=off" "$RC|$OUT" "AC5 merge.queue=off ignores a bad queue_retry"

# ── the default is 1 and the row is int ──────────────────────────────────────
EMPTY="$SANDBOX/no-config"
mkdir -p "$EMPTY" && git init -q "$EMPTY"
assert_eq "1" "$(cd "$EMPTY" && env -u PIPELINE_CONFIG TALOS_HOME="$EMPTY/home" \
  bash "$TALOS_ROOT/scripts/pipeline-config.sh" merge.queue_retry 2>/dev/null)" \
  "AC1 with no config file pipeline-config.sh prints 1"
assert_eq "int 1" "$(awk -F'\t' '$1 == "merge.queue_retry" { print $2, $3 }' "$TALOS_ROOT/scripts/pipeline-defaults.sh")" \
  "AC1 the defaults row is int with default 1"

finish
