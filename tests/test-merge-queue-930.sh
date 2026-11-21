#!/usr/bin/env bash
# test-merge-queue-930.sh -- merge queue 3/5 (#930): under `merge.queue: talos`
# `talos.sh queue run` cuts a candidate branch (base + the next queued PRs),
# waits on its required checks and merges the PRs in queue order only when
# green and nothing moved; post-merge skips the sibling sweep under the queue;
# `run` drives a pass on a gate `reason=queued`. Tests are named by the spec's
# criterion id.
#
# The fixture is tests/talos-run-sections.sh (sourced with TALOS_RUN_PART=930
# TALOS_RUN_EMBED=1, as tests/test-talos-run-merge-conflict-850.sh does): its
# sandbox, journaling stubs (hook.<key> snippets, LIST_PRS) and merge_fixture.
# `origin` is a local bare repo (an `update` hook logs every ref change); the
# PR branches are real commits pushed to it. No network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=930 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TALOS_RETRY_SLEEP_SCALE=0
OTHER_SHA="fedcba9876543210fedcba9876543210fedcba98"
MARK='<!-- talos:queue -->'

# ── fixtures ─────────────────────────────────────────────────────────────────
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
UPD="$SANDBOX/origin-updates.log"
export Q_ORIGIN="$ORIGIN" Q_SEED="$SEED"
git remote set-url origin "$ORIGIN"

# GQ: the run fixture's scripts, with the merge-base, worktree and board scripts
# stubbed too (post-merge runs for real over them).
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
  cat > "$ORIGIN/hooks/update" <<TALOS_updhookQ4n8Wm2Zk
#!/bin/sh
printf '%s %s %s\n' "\$1" "\$2" "\$3" >> "$UPD"
TALOS_updhookQ4n8Wm2Zk
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
# main_commit <file> <line>: a new commit on origin's main (the base moves).
main_commit() {
  sg checkout -q main
  printf '%s\n' "$2" >> "$SEED/$1"
  sg add -A
  sg commit -q -m "main: $1"
  sg push -q origin main
}
# comments_json 'login|body' ... (\n in a body is a newline)
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
# q_pr <pr> <issue> <file> <line> [<file> <line>...]: branch feat/issue-<issue>-q
# off main, one commit per pair, pushed; queued (a trusted marker at its head),
# eligible in call order.
Q_LIST=""
Q_SEQ=0
q_pr() {
  local _pr="$1" _n="$2" _br="feat/issue-$2-q" _h
  shift 2
  sg checkout -q -B "$_br" main
  while [ "$#" -ge 2 ]; do
    printf '%s\n' "$2" >> "$SEED/$1"
    sg add -A
    sg commit -q -m "pr$_pr: $1"
    shift 2
  done
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
# q_cfg <merge.queue or -> [extra merge members]
q_cfg() {
  local _q=""
  [ "$1" = "-" ] || _q="\"queue\": \"$1\", "
  printf '{"vcs": {"provider": "github"}, "base_branch": "main", "merge": {%s"method": "%s"%s}}' \
    "$_q" "${Q_METHOD:-squash}" "${2:-}" > "$SANDBOX/talos.pipeline.json"
}
# The default check hook records what origin holds when the checks are asked.
CHECK_HOOK='git -C "$Q_ORIGIN" for-each-ref --format="%(refname:short) %(objectname)" refs/heads/talos/queue/ > "$d/cand.refs"
git -C "$Q_ORIGIN" ls-tree -r --name-only "$2" | tr "\n" " " > "$d/cand.tree"
git -C "$Q_ORIGIN" rev-list --count main.."$2" > "$d/cand.count"
git -C "$Q_ORIGIN" rev-list --count --merges main.."$2" > "$d/cand.merges"
git -C "$Q_ORIGIN" rev-list --count --first-parent main.."$2" > "$d/cand.fp"
git -C "$Q_ORIGIN" log --format=%s --reverse --no-merges main.."$2" | tr "\n" "|" > "$d/cand.subjects"
git -C "$Q_ORIGIN" rev-parse main > "$d/cand.main"
'
q_reset() {
  reset_stubs
  LEASE_RESET
  Q_LIST=""; Q_SEQ=0
  export LIST_PRS="[]" LIST_ISSUES="[]"
  printf 'owner' > "$STUB_DIR/current-user"
  printf 'talos:checkout state=kept' > "$STUB_DIR/worktree.out"
  printf '%s' "$CHECK_HOOK" > "$STUB_DIR/hook.ref-checks-required"
  Q_METHOD=squash
  q_cfg talos
  origin_reset
}
# q_three: PRs 11, 12, 13 (issues 41-43), each adding its own file.
q_three() { q_pr 11 41 a11.txt x11; q_pr 12 42 a12.txt x12; q_pr 13 43 a13.txt x13; }
qr() { OUT="$(bash "${QG:-$GQ}/talos.sh" queue run </dev/null 2>"$ERR")"; RC=$?; }
jc() { journal | grep -c -E "$1"; }
cand_pushes() { grep -c -E '^refs/heads/talos/queue/main-[0-9]+ 0{40} ' "$UPD"; }
queue_left() { git -C "$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads/talos/queue/ | grep -c .; }
line1() { printf '%s\n' "$OUT" | sed -n 1p; }
has_line() { grep -qx -- "$1" <<< "$OUT"; }
assert_line() { if has_line "$2"; then pass "$1"; else fail "$1" "no line '$2' in: $(printf '%s' "$OUT" | tr '\n' '|')"; fi; }
merge_order() { journal | grep -oE '^vcs merge-pr [0-9]+|^worktree to-base [0-9]+' | tr '\n' '>' | sed 's/>$//'; }

# ── AC1 (same), AC2: post-merge's sibling sync, without and under the queue ──
pm_fixture() {
  q_reset
  q_cfg "$1"
  export LIST_PRS='[{"number":13,"baseRefName":"main","headRefName":"feat/issue-43-x","isCrossRepository":false}]'
  export LIST_ISSUES='[{"number":41}]'
  printf 'CHANGELOG.md\n' > "$STUB_DIR/conflict-files.out"
  printf 'closes' > "$STUB_DIR/pr-closes-issue.out"
}
pm() { rm -f "$STUB_DIR/journal"; OUT="$(bash "$GQ/talos.sh" post-merge 11 41 </dev/null 2>"$ERR")"; RC=$?; }
for q in - off; do
  pm_fixture "$q"; pm
  assert_contains "$OUT" "sibling=13 action=" "AC1 merge.queue=$q: post-merge syncs the conflicting sibling (sibling= line)"
  assert_eq "1" "$(jc '^vcs list-prs')" "AC1 merge.queue=$q: post-merge lists the PRs"
done
for q in talos github; do
  pm_fixture "$q"; pm
  assert_eq "0" "$RC" "AC2 merge.queue=$q: post-merge exits 0"
  assert_eq "0" "$(jc '^vcs (list-prs|conflict-files|pr-mergeable|update-branch)|^mergebase ')" \
    "AC2 merge.queue=$q: no list-prs, conflict-files, pr-mergeable, update-branch or pipeline-mergebase.sh call"
  assert_not_contains "$OUT" "sibling=" "AC2 merge.queue=$q: no sibling= line"
  assert_eq "1" "$(jc '^vcs close-issue 41 ')" "AC2 merge.queue=$q: the issue is still closed"
  assert_contains "$OUT" "checkout=kept" "AC2 merge.queue=$q: checkout= still runs"
done

# ── AC3: unset, off, github -> verdict=off, no provider call, no push ────────
for q in - off github; do
  q_reset; q_three; q_cfg "$q"; : > "$UPD"
  qr
  assert_eq "0|verdict=off" "$RC|$OUT" "AC3 merge.queue=$q: queue run answers verdict=off, exit 0"
  assert_eq "0" "$(jc '^vcs ')" "AC3 merge.queue=$q: no pipeline-vcs.sh call"
  assert_eq "0" "$(grep -c . "$UPD")" "AC3 merge.queue=$q: nothing pushed to origin"
  assert_eq "0" "$(queue_left)" "AC3 merge.queue=$q: no queue branch on origin"
done

# ── AC4: 3 queued, batch 3, all apply, checks green -> 3 merges in order ─────
q_reset; q_three; q_cfg talos ', "queue_batch": 3'
qr
assert_eq "0" "$RC" "AC4 queue run exits 0"
assert_eq "verdict=merged" "$(line1)" "AC4 the first line is verdict=merged"
assert_eq "1" "$(cand_pushes)" "AC4 exactly one talos/queue/main-<n> candidate was pushed"
CAND="$(cut -d' ' -f1 "$STUB_DIR/cand.refs" 2>/dev/null)"
CSHA="$(cut -d' ' -f2 "$STUB_DIR/cand.refs" 2>/dev/null)"
grep -Eqx 'talos/queue/main-[0-9]+' <<< "$CAND" \
  && pass "AC4 the candidate is named ^talos/queue/main-[0-9]+\$" || fail "AC4 the candidate is named ^talos/queue/main-[0-9]+\$" "$CAND"
assert_eq "CHANGELOG.md a11.txt a12.txt a13.txt base.txt " "$(cat "$STUB_DIR/cand.tree" 2>/dev/null)" "AC4 the candidate tree is the base plus the 3 PRs"
assert_eq "3" "$(cat "$STUB_DIR/cand.count" 2>/dev/null)" "AC4 the candidate is 3 commits on the base head"
assert_eq "1" "$(jc '^vcs ref-checks-required ')" "AC4 ref-checks-required was called exactly once"
assert_eq "1" "$(jc "^vcs ref-checks-required $CSHA\$")" "AC4 the check call names the candidate sha"
assert_eq "vcs merge-pr 11>worktree to-base 41>vcs merge-pr 12>worktree to-base 42>vcs merge-pr 13>worktree to-base 43" \
  "$(merge_order)" "AC4 merge-pr then post-merge for each PR, in queue order"
assert_line "AC4 one candidate= line names the branch, sha and PRs" "candidate=$CAND sha=$CSHA prs=11,12,13"
assert_eq "merged=11 issue=41
merged=12 issue=42
merged=13 issue=43" "$(printf '%s\n' "$OUT" | grep '^merged=')" "AC4 three merged= lines in queue order"
assert_eq "0" "$(queue_left)" "AC4 no talos/queue/ branch is left on origin"
assert_eq "0" "$(jc 'update-branch')" "AC4 no update-branch call"

# ── AC5: 4 queued, batch 3 -> only the first 3 ───────────────────────────────
q_reset; q_three; q_pr 14 44 a14.txt x14; q_cfg talos ', "queue_batch": 3'
qr
assert_eq "verdict=merged" "$(line1)" "AC5 the batch merges"
assert_eq "CHANGELOG.md a11.txt a12.txt a13.txt base.txt " "$(cat "$STUB_DIR/cand.tree" 2>/dev/null)" "AC5 only the first 3 PRs are in the candidate"
assert_eq "3|0" "$(jc '^vcs merge-pr ')|$(jc '^vcs merge-pr 14')" "AC5 3 merge-pr calls, none for the 4th"
assert_eq "0" "$(jc '^vcs upsert-pr-comment')" "AC5 no queue marker is rewritten"
assert_contains "$OUT" "prs=11,12,13" "AC5 the candidate line lists the first 3"

# ── AC6: merge.method shapes the candidate ───────────────────────────────────
q6() {
  q_reset; Q_METHOD="$1"; q_cfg talos
  q_pr 11 41 a11.txt x11 b11.txt y11
  q_pr 12 42 a12.txt x12 b12.txt y12
  q_pr 13 43 a13.txt x13 b13.txt y13
  qr
}
q6 squash
assert_eq "3|0|3" "$(cat "$STUB_DIR/cand.count")|$(cat "$STUB_DIR/cand.merges")|$(cat "$STUB_DIR/cand.fp")" \
  "AC6 squash: 3 linear non-merge commits on the base head"
assert_eq "verdict=merged" "$(line1)" "AC6 squash: merged"
q6 merge
assert_eq "3|3" "$(cat "$STUB_DIR/cand.merges")|$(cat "$STUB_DIR/cand.fp")" "AC6 merge: 3 merge commits on the base head"
q6 rebase
assert_eq "6|0" "$(cat "$STUB_DIR/cand.count")|$(cat "$STUB_DIR/cand.merges")" "AC6 rebase: the PRs' 6 own commits, no merge commit"
assert_eq "pr11: a11.txt|pr11: b11.txt|pr12: a12.txt|pr12: b12.txt|pr13: a13.txt|pr13: b13.txt|" \
  "$(cat "$STUB_DIR/cand.subjects")" "AC6 rebase: the PRs' own commits, in queue order"

# ── AC7: the base moves between the cut and the merge ────────────────────────
q_reset; q_three
printf '%s%s' "$CHECK_HOOK" 'if [ ! -f "$d/moved" ]; then : > "$d/moved"; printf "moved\n" >> "$Q_SEED/base.txt"; git -C "$Q_SEED" commit -q -am move; git -C "$Q_SEED" push -q origin main; fi
' > "$STUB_DIR/hook.ref-checks-required"
qr
assert_eq "verdict=wait" "$(line1)" "AC7 a moved base waits"
assert_line "AC7 reason=base-moved" "reason=base-moved"
assert_eq "0" "$(jc '^vcs merge-pr')" "AC7 no merge-pr"
assert_eq "0" "$(queue_left)" "AC7 the candidate is deleted"
NEW_MAIN="$(git -C "$ORIGIN" rev-parse main)"
qr
assert_eq "verdict=merged" "$(line1)" "AC7 a second pass merges"
assert_eq "$NEW_MAIN" "$(cat "$STUB_DIR/cand.main")" "AC7 the second pass checked a candidate while main was the new head"
assert_eq "3" "$(cat "$STUB_DIR/cand.count")" "AC7 the second candidate is cut on the new main head"
assert_eq "3" "$(jc '^vcs merge-pr ')" "AC7 the second pass merges the 3 PRs"

# ── AC8: a PR head moves before the merge ────────────────────────────────────
q_reset; q_three
printf '%s%s' "$CHECK_HOOK" "printf '$OTHER_SHA' > \"\$d/pr-head.12\"
" > "$STUB_DIR/hook.ref-checks-required"
qr
assert_eq "verdict=wait" "$(line1)" "AC8 a moved PR head waits"
assert_line "AC8 reason=head-moved" "reason=head-moved"
assert_eq "0" "$(jc '^vcs merge-pr')" "AC8 no merge-pr for any PR"
assert_eq "0" "$(queue_left)" "AC8 the candidate is deleted"
# A push to PR 12 while PR 11 merges: its head is read again right before its
# merge-pr, so the untested head is never merged.
q_reset; q_three
printf '[ "$2" != 11 ] || printf %%s %s > "$d/pr-head.12"\n' "$OTHER_SHA" > "$STUB_DIR/hook.merge-pr"
qr
assert_eq "verdict=wait" "$(line1)" "AC8 a head moved mid-merge waits"
assert_line "AC8 mid-merge reason=head-moved" "reason=head-moved"
assert_line "AC8 mid-merge names the moved PR" "pr=12"
assert_eq "vcs merge-pr 11>worktree to-base 41" "$(merge_order)" "AC8 a head moved mid-merge gets no merge-pr, nor do the PRs after it"
assert_line "AC8 mid-merge the merged PR is reported" "merged=11 issue=41"
assert_eq "0" "$(queue_left)" "AC8 mid-merge the candidate is deleted"

# ── AC9: a PR that does not apply goes to the merge-base task ────────────────
q9() {  # <mergebase rc>: PR 12 edits base.txt, then main does too
  q_reset
  q_pr 11 41 a11.txt x11
  q_pr 12 42 base.txt pr12-line
  main_commit base.txt main-line
  q_pr 13 43 a13.txt x13
  printf '%s' "$1" > "$STUB_DIR/mergebase.rc"
  qr
}
q9 0
assert_line "AC9 mergebase exit 0: conflict=12 action=mergebase" "conflict=12 action=mergebase"
assert_eq "1" "$(jc '^mergebase 12')" "AC9 pipeline-mergebase.sh 12 is called once"
assert_eq "CHANGELOG.md a11.txt a13.txt base.txt " "$(cat "$STUB_DIR/cand.tree" 2>/dev/null)" "AC9 the candidate holds PRs 1 and 3"
assert_eq "2" "$(cat "$STUB_DIR/cand.count" 2>/dev/null)" "AC9 the candidate is 2 commits on the base"
assert_eq "verdict=merged" "$(line1)" "AC9 PRs 1 and 3 merge"
assert_eq "1|1|0" "$(jc '^vcs merge-pr 11')|$(jc '^vcs merge-pr 13')|$(jc '^vcs merge-pr 12')" "AC9 PRs 1 and 3 merge, PR 2 gets no merge-pr"
assert_contains "$OUT" "prs=11,13" "AC9 the candidate line lists PRs 1 and 3"
q9 3
assert_line "AC9 mergebase exit 3: conflict=12 action=developer" "conflict=12 action=developer"
q9 1
assert_line "AC9 mergebase exit 1: conflict=12 action=unverified" "conflict=12 action=unverified"
q_reset
q_pr 11 41 base.txt l11; q_pr 12 42 base.txt l12; q_pr 13 43 base.txt l13
main_commit base.txt main-line
: > "$UPD"
qr
assert_eq "verdict=wait" "$(line1)" "AC9 none apply: verdict=wait"
assert_line "AC9 none apply: reason=no-candidate" "reason=no-candidate"
assert_eq "0|0" "$(cand_pushes)|$(jc '^vcs ref-checks-required')" "AC9 none apply: no push, no check call"
assert_eq "3" "$(jc '^mergebase ')" "AC9 none apply: each PR goes to the merge-base task"

# ── AC10: the real pipeline-mergebase.sh unions a CHANGELOG-only conflict ────
GQ3="$SANDBOX/gq3"
mkdir -p "$GQ3"
cp "$GQ"/* "$GQ3/"
cp "$TALOS_ROOT/scripts/pipeline-mergebase.sh" "$GQ3/"
q_reset
q_pr 11 41 CHANGELOG.md "- pr11 entry"
main_commit CHANGELOG.md "- main entry"
printf '.github/workflows/*\n' > "$STUB_DIR/forbidden-files-patterns.out"
QG="$GQ3" qr
assert_eq_ctx "conflict=11 action=mergebase" "$(printf '%s\n' "$OUT" | grep '^conflict=')" \
  "AC10 a CHANGELOG-only conflict: conflict=11 action=mergebase" "$(grep mergebase "$ERR" | head -n 5)"
CL="$(git -C "$ORIGIN" show feat/issue-41-q:CHANGELOG.md 2>/dev/null)"
assert_contains "$CL" "- pr11 entry" "AC10 the PR branch keeps its own line"
assert_contains "$CL" "- main entry" "AC10 the PR branch gained the base's line (union merge)"
assert_eq "2" "$(git -C "$ORIGIN" rev-list --parents -n 1 feat/issue-41-q | wc -w | tr -d ' ' | awk '{print $1 - 1}')" "AC10 the PR branch tip is a merge commit"

# ── AC11: a red candidate merges nothing ─────────────────────────────────────
q_reset; q_three
printf 1 > "$STUB_DIR/ref-checks-required.rc"
qr
assert_eq "verdict=block" "$(line1)" "AC11 a red candidate blocks"
assert_line "AC11 reason=candidate-red" "reason=candidate-red"
assert_eq "0|0" "$(jc '^vcs merge-pr')|$(jc '^vcs upsert-pr-comment')" "AC11 no merge-pr, no marker rewritten"
assert_eq "1|0" "$(cand_pushes)|$(queue_left)" "AC11 the candidate was pushed and is deleted"

# ── AC12: pending checks: 120 calls, then a timeout ──────────────────────────
q_reset; q_three
printf 2 > "$STUB_DIR/ref-checks-required.rc"
rm -f "$STUB_DIR/hook.ref-checks-required"
qr
assert_eq "120" "$(jc '^vcs ref-checks-required ')" "AC12 always pending: exactly 120 check calls"
assert_eq "verdict=wait" "$(line1)" "AC12 always pending: verdict=wait"
assert_line "AC12 always pending: reason=candidate-timeout" "reason=candidate-timeout"
assert_eq "0|0" "$(jc '^vcs merge-pr')|$(queue_left)" "AC12 always pending: no merge-pr, the candidate is deleted"
q_reset; q_three
printf '%s%s' "$CHECK_HOOK" '[ "$(grep -c "^vcs ref-checks-required " "$d/journal")" -ge 3 ] || exit 2
' > "$STUB_DIR/hook.ref-checks-required"
qr
assert_eq "3" "$(jc '^vcs ref-checks-required ')" "AC12 pending, pending, green: 3 check calls"
assert_eq "1" "$(journal | sed -n 's/^vcs ref-checks-required //p' | sort -u | grep -c .)" "AC12 pending, pending, green: every call on one sha"
assert_eq "verdict=merged" "$(line1)" "AC12 pending, pending, green: merged"

# ── AC13: a check lookup that fails is never a merge ─────────────────────────
for rc in 3 5; do
  q_reset; q_three
  printf '%s' "$rc" > "$STUB_DIR/ref-checks-required.rc"
  qr
  assert_eq "verdict=wait" "$(line1)" "AC13 checks exit $rc: verdict=wait"
  assert_line "AC13 checks exit $rc: reason=checks-unverified" "reason=checks-unverified"
  assert_eq "0|0" "$(jc '^vcs merge-pr')|$(queue_left)" "AC13 checks exit $rc: no merge-pr, the candidate is deleted"
done

# ── AC14: origin refuses the candidate push ──────────────────────────────────
q_reset; q_three
cat > "$ORIGIN/hooks/pre-receive" <<'TALOS_prercvH6t3Lp9Vx'
#!/bin/sh
while read -r o n r; do
  case "$r" in refs/heads/talos/queue/*) echo "refused" >&2; exit 1 ;; esac
done
exit 0
TALOS_prercvH6t3Lp9Vx
chmod +x "$ORIGIN/hooks/pre-receive"
qr
assert_eq "verdict=wait" "$(line1)" "AC14 a refused push: verdict=wait"
assert_line "AC14 a refused push: reason=candidate-unverified" "reason=candidate-unverified"
assert_eq "0|0" "$(jc '^vcs ref-checks-required')|$(jc '^vcs merge-pr')" "AC14 a refused push: no check call, no merge-pr"

# ── AC15: stale candidates of this base are deleted, nothing else ────────────
q_reset
for b in talos/queue/main-1 talos/queue/main-2 talos/queue/develop-1 talos/queue-x feature/x; do
  sg push -q origin "main:refs/heads/$b"
done
qr
assert_eq "verdict=empty" "$(line1)" "AC15 an empty queue: verdict=empty"
assert_eq "cleanup=talos/queue/main-1
cleanup=talos/queue/main-2" "$(printf '%s\n' "$OUT" | grep '^cleanup=' | LC_ALL=C sort)" "AC15 two cleanup= lines, the main- branches"
assert_eq "feature/x main talos/queue-x talos/queue/develop-1" \
  "$(git -C "$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads/ | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" \
  "AC15 only the two main- branches are deleted"

# ── AC16: an unreadable queue never cuts a candidate ─────────────────────────
for c in list-prs pr-head read-comments corrupt; do
  q_reset; q_three
  case "$c" in
    list-prs) printf 'exit 1\n' > "$STUB_DIR/hook.list-prs" ;;
    pr-head) printf 1 > "$STUB_DIR/pr-head.12.rc" ;;
    read-comments) printf 1 > "$STUB_DIR/read-comments.12.rc" ;;
    corrupt) comments_json "owner|**Merge queue:**\n\nno data here\n\n$MARK" > "$STUB_DIR/read-comments.12" ;;
  esac
  : > "$UPD"
  qr
  assert_eq "verdict=wait" "$(line1)" "AC16 a failed $c: verdict=wait"
  assert_line "AC16 a failed $c: reason=queue-state-unverified" "reason=queue-state-unverified"
  assert_eq "0|0" "$(cand_pushes)|$(jc '^vcs merge-pr')" "AC16 a failed $c: no push, no merge-pr"
done

# ── AC17: the three events reach events.jsonl through the real hooks ────────
GQ2="$SANDBOX/gq2"
mkdir -p "$GQ2"
cp "$GQ"/* "$GQ2/"
cp "$TALOS_ROOT/scripts/pipeline-hooks.sh" "$TALOS_ROOT/scripts/pipeline-events.sh" "$GQ2/"
EVENTS="$SANDBOX/.git/talos/events.jsonl"
ev_check() {  # <expected kind list>: the queue_* events, checked
  python3 -I -c '
import json, sys
want = sys.argv[2].split(",")
heads = sys.argv[3].split(",")
evs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
evs = [e for e in evs if e.get("event", "").startswith("queue_batch") or e.get("event") == "queue_merge"]
got = [e["event"] for e in evs]
if got != want:
    sys.exit("events: %s" % got)
for e in evs:
    if e.get("batch_size") != 3 or not isinstance(e.get("duration_s"), int):
        sys.exit("batch_size/duration_s: %r" % e)
    if list(e).index("batch_size") != len(e) - 2:
        sys.exit("batch_size is not right before ts: %r" % list(e))
if evs[0]["duration_s"] != 0:
    sys.exit("queue_batch_start duration_s is %r" % evs[0]["duration_s"])
m = [e for e in evs if e["event"] == "queue_merge"]
if [(e["pr"], e["sha"]) for e in m] != list(zip([11, 12, 13], heads))[:len(m)]:
    sys.exit("queue_merge pr/sha: %r" % [(e["pr"], e["sha"]) for e in m])
' "$EVENTS" "$1" "$(cat "$STUB_DIR/pr-head.11"),$(cat "$STUB_DIR/pr-head.12"),$(cat "$STUB_DIR/pr-head.13")"
}
q_reset; q_three; rm -f "$EVENTS"
QG="$GQ2" qr
if r="$(ev_check queue_batch_start,queue_batch_pass,queue_merge,queue_merge,queue_merge 2>&1)"; then
  pass "AC17 a merged batch logs queue_batch_start (duration_s 0), queue_batch_pass and 3 queue_merge (pr, head sha), batch_size 3"
else fail "AC17 a merged batch logs queue_batch_start (duration_s 0), queue_batch_pass and 3 queue_merge (pr, head sha), batch_size 3" "$r"; fi
q_reset; q_three; rm -f "$EVENTS"
printf 1 > "$STUB_DIR/ref-checks-required.rc"
QG="$GQ2" qr
if r="$(ev_check queue_batch_start 2>&1)"; then
  pass "AC17 a red candidate logs queue_batch_start only"
else fail "AC17 a red candidate logs queue_batch_start only" "$r"; fi

# ── AC18: post_stage --batch-size ────────────────────────────────────────────
HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
q_reset; rm -f "$EVENTS"
last_keys() { tail -n 1 "$EVENTS" | python3 -I -c 'import json, sys; e = json.load(sys.stdin); print(" ".join(e)); print(e.get("batch_size"))'; }
bash "$HOOKS" post_stage queue_batch_pass orchestrator 41 --batch-size 3 </dev/null 2>"$ERR"
assert_eq "event role issue pr repo sha verdict summary details attempt model runner duration_s tokens tool_uses batch_size ts
3" "$(last_keys)" "AC18 --batch-size 3 adds \"batch_size\": 3 before ts"
bash "$HOOKS" post_stage queue_batch_pass orchestrator 41 --batch-size x </dev/null 2>"$ERR"
assert_eq "event role issue pr repo sha verdict summary details attempt model runner duration_s tokens tool_uses ts
None" "$(last_keys)" "AC18 --batch-size x adds no key"
assert_eq "1" "$(grep -c . "$ERR")" "AC18 --batch-size x prints one stderr note"
bash "$HOOKS" post_stage queue_batch_pass orchestrator 41 </dev/null 2>"$ERR"
assert_eq "event role issue pr repo sha verdict summary details attempt model runner duration_s tokens tool_uses ts
None" "$(last_keys)" "AC18 without the flag the payload keys are main's"

# ── AC19: run drives one queue pass on a gate reason=queued ──────────────────
after_gate_lists() { journal | sed -n '/^vcs upsert-pr-comment /,$p' | grep -c '^vcs list-prs'; }
q19() {  # <labels> <merge.queue>
  origin_reset
  merge_fixture "$1" ", \"merge\": {\"queue\": \"$2\"}"
  draft_ready
  printf 'owner' > "$STUB_DIR/current-user"
  printf '{"comments":[]}' > "$STUB_DIR/read-comments.12"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  printf 'upserted pr=12 comment=created' > "$STUB_DIR/upsert-pr-comment.out"
  export LIST_PRS="[]"
  TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 5
}
q19 "$ALL_APPROVALS" talos
assert_eq "0" "$RC" "AC19 a queued gate wait: run exits 0"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c '^stop ')" "AC19 a queued gate wait: one stop line"
assert_eq_ctx "stop queue verdict=empty" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC19 a queued gate wait ends stop queue verdict=..." \
  "$(bash "$RUN" gate merge 12 9 2>&1 | head -n 5)"
assert_eq "1" "$(after_gate_lists)" "AC19 queue run ran exactly once"
q19 '{"name": "docs:done"}, {"name": "review:approved"}, {"name": "security:approved"}' off
off_lists="$(jc '^vcs list-prs')"
q19 '{"name": "docs:done"}, {"name": "review:approved"}, {"name": "security:approved"}' talos
assert_contains "$OUT" "stop verdict=wait reason=approvals-missing missing=qa:pass" "AC19 another wait reason ends as on main"
assert_not_contains "$OUT" "stop queue" "AC19 another wait reason: no stop queue line"
assert_eq "$off_lists" "$(jc '^vcs list-prs')" "AC19 another wait reason: no queue run (the same list-prs reads as without the queue)"

finish
