#!/usr/bin/env bash
# test-merge-queue-solo.sh -- merge.queue_solo_labels and merge.queue_solo_paths
# (#1082): under `merge.queue: talos` a queued PR that carries a solo label, or
# changes a path matching a solo glob, is batched alone: the batch stops before it
# and it heads the next pass's batch; a PR whose changed files cannot be read is
# solo too; with both keys unset the batching is unchanged. Tests are named by the
# spec's criterion id.
#
# The fixture is tests/test-merge-queue-drain.sh's: a local bare `origin`,
# journaling stubs and TALOS_RETRY_SLEEP_SCALE=0. No network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=930 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TALOS_RETRY_SLEEP_SCALE=0
MARK='<!-- talos:queue -->'

# ── fixtures (as tests/test-merge-queue-drain.sh) ────────────────────────────
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
has_line() { grep -qx -- "$1" <<< "$OUT"; }
assert_line() { if has_line "$2"; then pass "$1"; else fail "$1" "no line '$2' in: $(printf '%s' "$OUT" | tr '\n' '|')"; fi; }
# The PRs of each candidate, in order, passes separated by a space; the solo=
# lines, likewise.
cand_prs() { printf '%s\n' "$OUT" | sed -n 's/^candidate=[^ ]* sha=[0-9a-f]* prs=//p' | paste -sd' ' -; }
solos() { printf '%s\n' "$OUT" | sed -n 's/^solo=//p' | paste -sd' ' -; }
merged_prs() { journal | sed -n 's/^vcs merge-pr \([0-9]*\) .*/\1/p' | paste -sd' ' -; }
# three [<changed file of PR 12>]: PRs 11, 12, 13, each adding its own file, and
# the changed files the stub provider reports for each.
three() {
  q_pr 11 41 a11.txt x11; q_pr 12 42 a12.txt x12; q_pr 13 43 a13.txt x13
  printf 'a11.txt\n' > "$STUB_DIR/pr-files.11.out"
  printf '%s\n' "${1:-a12.txt}" > "$STUB_DIR/pr-files.12.out"
  printf 'a13.txt\n' > "$STUB_DIR/pr-files.13.out"
}

# ── AC1: a PR that changes a solo path is batched alone ──────────────────────
q_reset; three db/migrations/001.sql
q_cfg talos ', "queue_batch": 3, "queue_solo_paths": ["db/migrations/**"]'
qr
assert_eq "11 12 13" "$(cand_prs)" "AC1 the candidates hold A, then B (the migration) alone, then C"
assert_eq "12 12" "$(solos)" "AC1 solo=12 is printed when B is held back and when it runs alone"
assert_eq "11 12 13" "$(merged_prs)" "AC1 the PRs merge in queue order"

# ── AC2: a PR that carries a solo label is batched alone ─────────────────────
q_reset; three
printf '{"number": 12, "headRefName": "feat/issue-42-q", "baseRefName": "main", "labels": [{"name": "solo-merge"}], "state": "open"}' > "$STUB_DIR/view-pr.12"
q_cfg talos ', "queue_batch": 3, "queue_solo_labels": ["solo-merge"]'
qr
assert_eq "11 12 13" "$(cand_prs)" "AC2 the candidates hold A, then the labelled B alone, then C"
assert_eq "12 12" "$(solos)" "AC2 solo=12 is printed"
assert_eq "0" "$(jc '^vcs pr-files')" "AC2 with only labels set, no changed-files read is made"
q_reset; three
q_cfg talos ', "queue_batch": 3, "queue_solo_labels": ["solo-merge"]'
qr
assert_eq "11,12,13" "$(cand_prs)" "AC2 no PR carries the label: one candidate holds all three"

# ── AC3: an unreadable changed-files list makes the PR solo ──────────────────
q_reset; three
printf '1' > "$STUB_DIR/pr-files.12.rc"; : > "$STUB_DIR/pr-files.12.out"
q_cfg talos ', "queue_batch": 3, "queue_solo_paths": ["db/migrations/**"]'
qr
assert_eq "11 12 13" "$(cand_prs)" "AC3 the PR whose changed-files read fails is batched alone"
assert_line "AC3 the line solo=12 is printed" "solo=12"

# ── AC4: both keys unset keeps today's batching ──────────────────────────────
q_reset; three db/migrations/001.sql
q_cfg talos ', "queue_batch": 3'
qr
assert_eq "11,12,13" "$(cand_prs)" "AC4 no solo keys: three queued PRs share one candidate"
assert_eq "0|" "$(jc '^vcs (pr-files|view-pr) ')|$(solos)" "AC4 no solo key: no extra provider read, no solo= line"

finish
