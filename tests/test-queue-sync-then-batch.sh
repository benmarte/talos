#!/usr/bin/env bash
# test-queue-sync-then-batch.sh -- merge queue, sync then batch (#1042): under
# `merge.queue: talos` on a base whose protection does not require status checks,
# two PRs that each add a CHANGELOG line share one candidate. The one that does
# not apply plainly is applied with a union merge of merge.union_paths inside the
# candidate, and once the candidate is green it is synced mechanically
# (pipeline-mergebase.sh, exit 0) just before its merge: its marker is rebound to
# the synced head (eligible kept), and it merges at that head (merge-pr --sha),
# with no CI run of its own. A protected, or unreadable, base keeps today's
# behaviour: a PR that does not apply is left out, with one note naming
# `merge.queue: github`. Tests are named by the spec's criterion id.
#
# The fixture is tests/test-merge-queue-drain.sh's: a local bare `origin`,
# journaling stubs and TALOS_RETRY_SLEEP_SCALE=0, with the real
# pipeline-mergebase.sh. No network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=930 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TALOS_RETRY_SLEEP_SCALE=0
MARK='<!-- talos:queue -->'

# ── fixtures ─────────────────────────────────────────────────────────────────
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
export Q_ORIGIN="$ORIGIN" Q_SEED="$SEED"
git remote set-url origin "$ORIGIN"

# GQ: the run fixture's scripts with the real pipeline-mergebase.sh behind a shim
# that journals its calls; the worktree and board scripts are stubs (post-merge
# runs for real over them).
GQ="$SANDBOX/gq"
mkdir -p "$GQ"
cp "$GS"/* "$GQ/"
for s in pipeline-worktree.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GQ/$s"
done
cp "$TALOS_ROOT/scripts/pipeline-mergebase.sh" "$GQ/mergebase-real.sh"
cat > "$GQ/pipeline-mergebase.sh" <<'TALOS_mbshimQ7vN2xKd4'
#!/usr/bin/env bash
printf 'mergebase %s\n' "$*" >> "${STUB_DIR:?}/journal"
exec bash "$(dirname "$0")/mergebase-real.sh" "$@"
TALOS_mbshimQ7vN2xKd4

sg() { git -C "$SEED" "$@"; }
origin_reset() {
  rm -rf "${ORIGIN:?}" "${SEED:?}"
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
main_commit() {  # <file> <line>: a new commit on origin's main (the base moves)
  sg checkout -q main
  printf '%s\n' "$2" >> "$SEED/$1"
  sg add -A
  sg commit -q -m "main: $1"
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
elig() { printf '2026-11-01T00:00:%02dZ' "$1"; }
q_pr() {  # <pr> <issue> <file> <line>: one queued PR on feat/issue-<issue>-q, eligible in call order
  local _pr="$1" _n="$2" _br="feat/issue-$2-q" _h
  sg checkout -q -B "$_br" main
  printf '%s\n' "$4" >> "$SEED/$3"
  sg add -A
  sg commit -q -m "pr$_pr: $3"
  sg push -q -f origin "$_br"
  _h="$(sg rev-parse HEAD)"
  sg checkout -q main
  Q_SEQ=$((Q_SEQ + 1))
  printf '%s' "$_br" > "$STUB_DIR/branch.$_pr"
  printf '%s' "$_h" > "$STUB_DIR/pr-head.$_pr"
  comments_json "owner|$(qbody main "$_h" "$(elig "$Q_SEQ")")" > "$STUB_DIR/read-comments.$_pr"
  printf '{"number": %s, "headRefName": "%s", "baseRefName": "main", "labels": [], "state": "open"}' "$_pr" "$_br" > "$STUB_DIR/view-pr.$_pr"
  Q_LIST="$Q_LIST${Q_LIST:+,}{\"number\":$_pr,\"baseRefName\":\"main\",\"headRefName\":\"$_br\",\"isCrossRepository\":false}"
  export LIST_PRS="[$Q_LIST]"
}
q_cfg() {  # [extra merge members]
  printf '{"vcs": {"provider": "github"}, "base_branch": "main", "merge": {"queue": "talos", "method": "squash"%s}}' \
    "${1:-}" > "$SANDBOX/talos.pipeline.json"
}
# The stubs move origin the way the provider would: pr-head answers the branch's
# real head on origin (a sync moves it), merge-pr squashes the head it is bound to
# into main; a merge that cannot be made is written to merge.fail.
HEAD_HOOK='printf "%s" "$(git --git-dir="$Q_ORIGIN" rev-parse "refs/heads/$(cat "$d/branch.$2")")" > "$d/pr-head.$2"'
MERGE_HOOK='if [ "$1" = merge-pr ]; then
  { git -C "$Q_SEED" fetch -q origin && git -C "$Q_SEED" checkout -q main && git -C "$Q_SEED" reset -q --hard origin/main \
    && git -C "$Q_SEED" merge -q --squash "$4" && git -C "$Q_SEED" -c commit.gpgsign=false commit -q -m "squash #$2" \
    && git -C "$Q_SEED" push -q origin main; } >/dev/null 2>&1 || echo "$2" >> "$d/merge.fail"
fi'
q_reset() {  # [open|checks|unreadable]: the base's protection (default open)
  reset_stubs
  LEASE_RESET
  Q_LIST=""; Q_SEQ=0
  export LIST_PRS="[]" LIST_ISSUES="[]"
  printf 'owner' > "$STUB_DIR/current-user"
  printf 'talos:checkout state=kept' > "$STUB_DIR/worktree.out"
  printf '.github/workflows/*\n' > "$STUB_DIR/forbidden-files-patterns.out"
  printf '%s' "$HEAD_HOOK" > "$STUB_DIR/hook.pr-head"
  printf '%s' "$MERGE_HOOK" > "$STUB_DIR/hook.merge-pr"
  case "${1:-open}" in
    open) printf 'open\n' > "$STUB_DIR/base-protection.out" ;;
    checks) printf 'checks\n' > "$STUB_DIR/base-protection.out"; printf 1 > "$STUB_DIR/base-protection.rc" ;;
    unreadable) printf 2 > "$STUB_DIR/base-protection.rc" ;;
  esac
  q_cfg
  origin_reset
}
qr() { OUT="$(bash "$GQ/talos.sh" queue run </dev/null 2>"$ERR")"; RC=$?; }
jc() { journal | grep -c -E "$1"; }
line1() { printf '%s\n' "$OUT" | sed -n 1p; }
has_line() { grep -qx -- "$1" <<< "$OUT"; }
assert_line() { if has_line "$2"; then pass "$1"; else fail "$1" "no line '$2' in: $(printf '%s' "$OUT" | tr '\n' '|')"; fi; }
merged_prs() { journal | sed -n 's/^vcs merge-pr \([0-9]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//'; }
origin_head() { git -C "$ORIGIN" rev-parse "refs/heads/feat/issue-$1-q"; }
first_cand() { printf '%s\n' "$OUT" | sed -n 's/^candidate=.* prs=//p' | head -n 1; }
notes() { printf '%s\n' "$OUT" | grep -c '^note .*merge\.queue: github'; }
# the queue marker bodies written for a PR, in order
marker_bodies() { awk -v pr="$1" '/^\[/ { on = index($0, "upsert-pr-comment " pr " --marker queue ") > 0 } on' "$STUB_DIR/bodies" 2>/dev/null; }
marker_writes() { grep -c -E "^\[upsert-pr-comment $1 --marker queue " "$STUB_DIR/bodies" 2>/dev/null; }
merge_sha() { journal | sed -n "s/^vcs merge-pr $1 --sha \([0-9a-f]*\).*/\1/p"; }
merge_failed() { cat "$STUB_DIR/merge.fail" 2>/dev/null; }

# ── AC1: two CHANGELOG-adding PRs share one candidate, one CI run ────────────
q_reset
q_pr 11 41 CHANGELOG.md '- pr11 entry'
q_pr 12 42 CHANGELOG.md '- pr12 entry'
OLD12="$(origin_head 42)"
qr
assert_eq "verdict=merged" "$(line1)" "AC1 two CHANGELOG-adding PRs: verdict=merged"
assert_eq "11,12" "$(first_cand)" "AC1 both PRs are in the one candidate"
assert_eq "1" "$(jc '^vcs ref-checks-required')" "AC1 one candidate, one check call"
assert_eq "0" "$(jc '^vcs pr-checks-required')" "AC1 no PR has its own CI wait"
assert_eq "11 12" "$(merged_prs)" "AC1 both merge, in queue order"
assert_eq "1" "$(jc '^mergebase 12$')" "AC1 the second PR is synced mechanically, once"
assert_eq "0" "$(jc '^mergebase 11$')" "AC1 the first PR needs no sync"
assert_eq "1|0" "$(jc '^vcs base-protection main')|$(notes)" "AC1 the protection is read once, and an open base prints no note"
assert_eq "" "$(merge_failed)" "AC1 every merge-pr was made against a head that merges"
NEW12="$(origin_head 42)"
assert_eq "different" "$([ -n "$NEW12" ] && [ "$NEW12" != "$OLD12" ] && echo different || echo same)" "AC1 the synced head is a new head"
assert_eq "$NEW12" "$(merge_sha 12)" "AC1 the second PR merges at its synced head"
CL="$(git -C "$ORIGIN" show main:CHANGELOG.md 2>/dev/null)"
assert_contains "$CL" "- pr11 entry" "AC1 main holds the first entry"
assert_contains "$CL" "- pr12 entry" "AC1 main holds the second entry"

# ── AC2: a head that predates the last merge keeps its position ──────────────
q_reset; q_cfg ', "queue_batch": 1'
q_pr 11 41 CHANGELOG.md '- pr11 entry'
q_pr 12 42 CHANGELOG.md '- pr12 entry'
q_pr 13 43 a13.txt x13
qr
assert_eq "verdict=merged" "$(line1)" "AC2 the drain ends merged"
assert_eq "11 12 13" "$(merged_prs)" "AC2 the PR synced after PR 11 merged keeps its place before PR 13"
assert_eq "3" "$(jc '^vcs ref-checks-required')" "AC2 one candidate per pass, the synced head has no CI of its own"
assert_eq "0" "$(jc '^vcs pr-checks-required')" "AC2 no PR waits for its own CI"
NEW12="$(origin_head 42)"
assert_eq "1" "$(marker_writes 12)" "AC2 the marker is written once, at the sync"
assert_contains "$(marker_bodies 12)" "queue: base=main head=$NEW12 eligible=$(elig 2)" "AC2 rebound to the synced head with its original eligible time"
assert_eq "$NEW12" "$(merge_sha 12)" "AC2 merged at the synced head"
assert_eq "0" "$(jc '^vcs (label-pr|label-issue) ')" "AC2 not enqueued again, no label moved"

# behind <protection>: PRs 11 and 13 add a CHANGELOG line, PR 12 a file; then the
# base moves with a CHANGELOG line of its own, so 11 and 13 conflict with the new
# base only in CHANGELOG.md.
behind() {
  q_reset "$1"
  q_pr 11 41 CHANGELOG.md '- pr11 entry'
  q_pr 12 42 a12.txt x12
  q_pr 13 43 CHANGELOG.md '- pr13 entry'
  main_commit CHANGELOG.md '- main entry'
}

# ── AC3: a base that requires checks keeps today's behaviour ─────────────────
behind checks
qr
assert_eq "verdict=merged" "$(line1)" "AC3 protected base: the PR that applies merges"
assert_eq "12" "$(first_cand)" "AC3 protected base: the candidate holds the PR that applies"
assert_line "AC3 protected base: PR 11 goes to the merge-base task" "conflict=11 action=mergebase"
assert_line "AC3 protected base: PR 13 goes to the merge-base task" "conflict=13 action=mergebase"
assert_eq "12" "$(merged_prs)" "AC3 protected base: the synced PRs wait for their own CI, they are not merged"
assert_eq "1|1" "$(jc '^mergebase 11$')|$(jc '^mergebase 13$')" "AC3 protected base: each PR is synced once, in the cut, as before"
assert_eq "0|0" "$(marker_writes 11)|$(marker_writes 13)" "AC3 protected base: no marker is rebound (the PRs are enqueued again after their CI)"
assert_eq "1" "$(notes)" "AC3 protected base: one note names merge.queue: github"
assert_eq "1" "$(jc '^vcs base-protection main')" "AC3 the protection is read once per queue run"

# ── AC4: an unreadable protection answer is protected ────────────────────────
behind unreadable
qr
assert_line "AC4 unreadable protection: PR 11 is left out as on a protected base" "conflict=11 action=mergebase"
assert_eq "12" "$(merged_prs)" "AC4 unreadable protection: only the PR that applies merges"
assert_eq "1" "$(notes)" "AC4 unreadable protection: one note names merge.queue: github"
behind open; printf 1 > "$STUB_DIR/base-protection.rc"; : > "$STUB_DIR/base-protection.out"
qr
assert_eq "12" "$(merged_prs)" "AC4 a failed read with no answer: only the PR that applies merges"
behind open; printf 3 > "$STUB_DIR/base-protection.rc"
qr
assert_eq "12" "$(merged_prs)" "AC4 an answer that came with a failed read is not trusted: only the PR that applies merges"

# ── AC5: a real conflict still goes to the developer ─────────────────────────
q_reset
q_pr 11 41 a11.txt x11
q_pr 12 42 base.txt pr12-line
main_commit base.txt main-line
q_pr 13 43 a13.txt x13
qr
assert_line "AC5 a real conflict: conflict=12 action=developer" "conflict=12 action=developer"
assert_eq "11,13" "$(first_cand)" "AC5 PR 12 is left out of the candidate"
assert_eq "11 13" "$(merged_prs)" "AC5 PR 12 is not merged"
assert_eq "0" "$(marker_writes 12)" "AC5 PR 12's marker is not rebound"

# ── AC6 (same): approvals are judged as before ───────────────────────────────
# (a) a synced head whose approvals are stale is not merged and not rebound
q_reset
q_pr 11 41 CHANGELOG.md '- pr11 entry'
q_pr 12 42 CHANGELOG.md '- pr12 entry'
printf 1 > "$STUB_DIR/check-approval-sha.12.rc"
printf 'STALE qa:pass (qa): non-waivable files changed since abc\n' > "$STUB_DIR/check-approval-sha.12.out"
qr
assert_eq "verdict=wait" "$(line1)" "AC6 stale approvals after the sync: verdict=wait"
assert_line "AC6 stale approvals after the sync: reason=approvals-stale" "reason=approvals-stale"
assert_eq "11" "$(merged_prs)" "AC6 the PR with stale approvals is not merged"
assert_eq "0" "$(marker_writes 12)" "AC6 the stale PR's marker is not rebound: it leaves the queue until re-stamped"
# (b) the rule itself: a change to a non-waivable file since the stamp is STALE
CHK="$(
  VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
  cfg() { bash "$TALOS_ROOT/scripts/pipeline-config.sh" "$@"; }
  _TALOS_CFG=""
  _src="$(awk '/^_github\(\) \{/{exit} /^_vcs_shared_read_attempt\(\) \{/{flag=1} flag{print}' "$VCS")"
  eval "$_src"
  G="$SANDBOX/approval-graph"
  rm -rf "${G:?}"; git init -q "$G"
  gg() { git -C "$G" -c user.name=t -c user.email=t@t.invalid -c commit.gpgsign=false "$@"; }
  printf 'a\n' > "$G/f.txt"; gg add -A; gg commit -q -m a
  STAMP="$(gg rev-parse HEAD)"
  mkdir -p "$G/scripts"; printf 'x\n' > "$G/scripts/s.sh"; gg add -A; gg commit -q -m sync
  HEAD1="$(gg rev-parse HEAD)"
  printf 'doc\n' > "$G/NOTES.md"; gg add -A; gg commit -q -m doc
  HEAD2="$(gg rev-parse HEAD)"
  chk() {
    ( cd "$G" && printf '{"headRefOid":"%s","baseRefName":""}' "$1" \
      | MARKER_ENTRIES="{\"entries\":[{\"label\":\"qa:pass\",\"role\":\"qa\",\"sha\":\"$STAMP\",\"reason\":null}]}" STALE_LIST=false \
        _vcs_shared_check_approval_sha 2>&1 )
    echo "rc=$?"
  }
  chk "$HEAD1"
  chk "$HEAD2"
)"
assert_contains "$CHK" "STALE qa:pass (qa)" "AC6 a sync that changes a non-waivable file: check-approval-sha answers STALE"
assert_eq "2" "$(printf '%s\n' "$CHK" | grep -c '^rc=1$')" "AC6 STALE is exit 1 for the synced head and for a later docs-only commit"

# ── AC3/AC4: the verb behind the queue's protection read, on both transports ─
# `pipeline-vcs.sh base-protection <branch>`: exit 0 `open` (no required status
# checks), exit 1 `checks` (a required check on the classic protection or a
# ruleset), exit 2 unreadable. use_stubs: the gh and curl stubs answer from a queue.
use_stubs
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
bp() {  # <leg> <canned answers, one per line>
  github_leg "$1"
  printf '%s\n' "$2" > "$CURL_QUEUE"
  : > "$CURL_LOG"
  OUT="$(bash "$VCS" base-protection main 2>"$ERR")"; RC=$?
}
for leg in gh curl; do
  bp "$leg" '{"name":"main","protected":false}
[]'
  assert_eq "open|0" "$OUT|$RC" "AC3 $leg: no protection and no ruleset is open"
  bp "$leg" '{"name":"main","protected":true}
{"strict":true,"contexts":["ci"],"checks":[{"context":"ci"}]}'
  assert_eq "checks|1" "$OUT|$RC" "AC3 $leg: classic protection with a required check"
  bp "$leg" '{"name":"main","protected":true}
{"strict":false,"contexts":[],"checks":[]}
[]'
  assert_eq "open|0" "$OUT|$RC" "AC3 $leg: classic protection with no required check is open"
  bp "$leg" '{"name":"main","protected":false}
[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"ci"}]}}]'
  assert_eq "checks|1" "$OUT|$RC" "AC3 $leg: a ruleset with a required check"
  bp "$leg" '{"name":"main","protected":false}
[{"type":"pull_request","parameters":{}}]'
  assert_eq "open|0" "$OUT|$RC" "AC3 $leg: a ruleset with no required check is open"
  bp "$leg" 'not json'
  assert_eq "|2" "$OUT|$RC" "AC4 $leg: an unreadable branch answer is exit 2, nothing on stdout"
  bp "$leg" '{"name":"main","protected":true}
not json'
  assert_eq "|2" "$OUT|$RC" "AC4 $leg: protected but the checks unreadable is exit 2"
  bp "$leg" '{"name":"main","protected":false}
not json'
  assert_eq "|2" "$OUT|$RC" "AC4 $leg: the rulesets unreadable is exit 2"
done

finish
