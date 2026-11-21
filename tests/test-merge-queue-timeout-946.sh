#!/usr/bin/env bash
# test-merge-queue-timeout-946.sh -- merge.queue_timeout_s (#946): `talos.sh
# queue run` waits up to merge.queue_timeout_s seconds (default 3600) for a
# candidate's required checks, one ref-checks-required call per 30 s, so
# timeout / 30 calls before reason=candidate-timeout; a bad value stops the pass
# with reason=config-unreadable before anything is pushed. Tests are named by
# the spec's criterion id.
#
# The fixture is tests/test-merge-queue-930.sh's: tests/talos-run-sections.sh
# sourced with TALOS_RUN_PART=930 TALOS_RUN_EMBED=1, a local bare `origin`,
# journaling stubs and TALOS_RETRY_SLEEP_SCALE=0. No network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=930 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TALOS_RETRY_SLEEP_SCALE=0
MARK='<!-- talos:queue -->'

# ── fixtures (as tests/test-merge-queue-930.sh) ──────────────────────────────
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
  cat > "$ORIGIN/hooks/update" <<TALOS_updhook946Rk7Vq2Nw
#!/bin/sh
printf '%s %s %s\n' "\$1" "\$2" "\$3" >> "$UPD"
TALOS_updhook946Rk7Vq2Nw
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
# pending [<extra merge members>]: three queued PRs whose checks stay pending.
pending() { q_reset; q_three; q_cfg talos "${1:-}"; printf 2 > "$STUB_DIR/ref-checks-required.rc"; qr; }
# timed_out <id> <calls>: the pass waited <calls> pending answers, then gave up.
timed_out() {
  assert_eq "$2" "$(jc '^vcs ref-checks-required ')" "$1 exactly $2 ref-checks-required calls"
  assert_eq "verdict=wait" "$(line1)" "$1 verdict=wait"
  assert_line "$1 reason=candidate-timeout" "reason=candidate-timeout"
  assert_eq "0|0" "$(jc '^vcs merge-pr')|$(queue_left)" "$1 no merge-pr, no candidate left on origin"
}

# ── AC1 (same): unset -> 120 calls, then candidate-timeout ───────────────────
pending
timed_out "AC1 unset:" 120

# ── AC2: 7200 s -> 240 calls, then candidate-timeout ─────────────────────────
pending ', "queue_timeout_s": 7200'
timed_out "AC2 queue_timeout_s=7200:" 240

# ── AC3: 7200 s, pending 199 times then green -> merged at call 200 ──────────
q_reset; q_three; q_cfg talos ', "queue_timeout_s": 7200'
printf '[ "$(grep -c "^vcs ref-checks-required " "$d/journal")" -ge 200 ] || exit 2\n' \
  > "$STUB_DIR/hook.ref-checks-required"
qr
assert_eq "200" "$(jc '^vcs ref-checks-required ')" "AC3 exactly 200 ref-checks-required calls"
assert_eq "verdict=merged" "$(line1)" "AC3 green on call 200: verdict=merged"
assert_eq "3" "$(jc '^vcs merge-pr ')" "AC3 the 3 PRs merge"

# ── AC4: the boundaries 30 and 59 -> 1 call ──────────────────────────────────
for t in 30 59; do
  pending ", \"queue_timeout_s\": $t"
  timed_out "AC4 queue_timeout_s=$t:" 1
done

# ── AC5: a bad value stops the pass before anything is read or pushed ────────
for v in '"abc"' 1.5 0 -30 29 86401; do
  q_reset; q_three; q_cfg talos ", \"queue_timeout_s\": $v"; : > "$UPD"
  qr
  assert_eq "stop reason=config-unreadable" "$(line1)" "AC5 queue_timeout_s=$v: stop reason=config-unreadable"
  assert_contains "$(cat "$ERR")" "merge.queue_timeout_s must be an integer from 30 to 86400 (seconds) -- got: ${v//\"/}" \
    "AC5 queue_timeout_s=$v: stderr names merge.queue_timeout_s, the value and the range"
  assert_eq "0|0" "$(jc '^vcs ref-checks-required')|$(jc '^vcs merge-pr')" "AC5 queue_timeout_s=$v: no check call, no merge-pr"
  assert_eq "0" "$(grep -c . "$UPD")" "AC5 queue_timeout_s=$v: nothing pushed to origin"
done

# ── AC6: a timeout during bisection uses the configured limit ────────────────
q_reset; q_three; q_cfg talos ', "queue_timeout_s": 60'
printf '%s\n' 'if [ "$(grep -c "^vcs ref-checks-required " "$d/journal")" -le 1 ]; then printf "unit\tfail\t1m\thttps://ci.example/1\n"; exit 1; fi; exit 2' \
  > "$STUB_DIR/hook.ref-checks-required"
qr
timed_out "AC6 a red batch, then a pending sub-candidate:" 3
assert_eq "0|0" "$(jc '^vcs upsert-pr-comment')|$(jc '^hooks post_stage queue_eject ')" "AC6 nothing ejected"

# ── AC7: the default is 3600 and the row is int ──────────────────────────────
EMPTY="$SANDBOX/no-config"
mkdir -p "$EMPTY" && git init -q "$EMPTY"
assert_eq "3600" "$(cd "$EMPTY" && env -u PIPELINE_CONFIG TALOS_HOME="$EMPTY/home" \
  bash "$TALOS_ROOT/scripts/pipeline-config.sh" merge.queue_timeout_s 2>/dev/null)" \
  "AC7 with no config file pipeline-config.sh prints 3600"
assert_eq "int 3600" "$(awk -F'\t' '$1 == "merge.queue_timeout_s" { print $2, $3 }' "$TALOS_ROOT/scripts/pipeline-defaults.sh")" \
  "AC7 the defaults row is int with default 3600"

# ── AC8 (same): unset or off ignores a bad value ─────────────────────────────
for q in - off; do
  q_reset; q_three; q_cfg "$q" ', "queue_timeout_s": "abc"'; : > "$UPD"
  qr
  assert_eq "0|verdict=off" "$RC|$OUT" "AC8 merge.queue=$q, queue_timeout_s=abc: verdict=off, exit 0"
  assert_eq "0" "$(jc '^vcs ')" "AC8 merge.queue=$q: no pipeline-vcs.sh call"
done

finish
