#!/usr/bin/env bash
# test-merge-queue-generated.sh -- merge queue, generated files (#1083): with
# merge.generated_paths and merge.generate_command both set, a queued PR whose only
# conflicts with the candidate are generated files (plus merge.union_paths files) is
# applied anyway: the candidate's side is kept for the generated files, everything else
# is merged, the generator runs in the candidate worktree and its output is committed as
# the PR's part of the candidate (`regenerated=<pr>`). The PR is synced the same way
# (pipeline-mergebase.sh) just before its merge. A generator that fails, leaves a
# conflict marker or touches a file outside merge.generated_paths leaves the PR out with
# `conflict=<pr> action=generate-failed`. The command is repo config only. Tests are
# named by the spec's criterion id.
#
# The fixture is tests/test-queue-sync-then-batch.sh's: a local bare `origin`, journaling
# stubs and TALOS_RETRY_SLEEP_SCALE=0, with the real pipeline-mergebase.sh. The
# generator is `cat gen/src/* | sort > gen/out.txt`. No network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=930 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TALOS_RETRY_SLEEP_SCALE=0
MARK='<!-- talos:queue -->'
GEN='cat gen/src/* | sort > gen/out.txt'

# ── fixtures ─────────────────────────────────────────────────────────────────
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
export Q_ORIGIN="$ORIGIN" Q_SEED="$SEED"
git remote set-url origin "$ORIGIN"

GQ="$SANDBOX/gq"
mkdir -p "$GQ"
cp "$GS"/* "$GQ/"
for s in pipeline-worktree.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GQ/$s"
done
cp "$TALOS_ROOT/scripts/pipeline-mergebase.sh" "$GQ/mergebase-real.sh"
cat > "$GQ/pipeline-mergebase.sh" <<'TALOS_mbshimW4tK8bPz2'
#!/usr/bin/env bash
printf 'mergebase %s\n' "$*" >> "${STUB_DIR:?}/journal"
exec bash "$(dirname "$0")/mergebase-real.sh" "$@"
TALOS_mbshimW4tK8bPz2

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
  mkdir -p "$SEED/gen/src"
  printf 'base\n' > "$SEED/base.txt"
  printf '# Changelog\n\n## [Unreleased]\n\n' > "$SEED/CHANGELOG.md"
  printf 'a\n' > "$SEED/gen/src/a.txt"
  printf 'a\n' > "$SEED/gen/out.txt"
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
elig() { printf '2026-11-01T00:00:%02dZ' "$1"; }
# q_pr <pr> <issue> <file> <line>: one queued PR on feat/issue-<issue>-q, eligible in call
# order; $Q_POST (a shell snippet run in the seed repo) edits more before the commit.
q_pr() {
  local _pr="$1" _n="$2" _br="feat/issue-$2-q" _h
  sg checkout -q -B "$_br" main
  printf '%s\n' "$4" >> "$SEED/$3"
  if [ -n "${Q_POST:-}" ]; then ( cd "$SEED" && eval "$Q_POST" ); fi
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
# gen_pr <pr> <issue> <name>: a PR that adds gen/src/<name>.txt and regenerates gen/out.txt
gen_pr() { Q_POST="$GEN" q_pr "$1" "$2" "gen/src/$3.txt" "$3"; }
# q_cfg [generated paths JSON] [generate command]: the repo config; each key only when given
q_cfg() {
  python3 -I -c '
import json, sys
merge = {"queue": "talos", "method": "squash"}
if sys.argv[1]:
    merge["generated_paths"] = json.loads(sys.argv[1])
if sys.argv[2]:
    merge["generate_command"] = sys.argv[2]
print(json.dumps({"vcs": {"provider": "github"}, "base_branch": "main", "merge": merge}))' \
    "${1-}" "${2-}" > "$SANDBOX/talos.pipeline.json"
}
HEAD_HOOK='printf "%s" "$(git --git-dir="$Q_ORIGIN" rev-parse "refs/heads/$(cat "$d/branch.$2")")" > "$d/pr-head.$2"'
MERGE_HOOK='if [ "$1" = merge-pr ]; then
  { git -C "$Q_SEED" fetch -q origin && git -C "$Q_SEED" checkout -q main && git -C "$Q_SEED" reset -q --hard origin/main \
    && git -C "$Q_SEED" merge -q --squash "$4" && git -C "$Q_SEED" -c commit.gpgsign=false commit -q -m "squash #$2" \
    && git -C "$Q_SEED" push -q origin main; } >/dev/null 2>&1 || echo "$2" >> "$d/merge.fail"
fi'
# the candidate's gen/out.txt, kept when its checks are read
CAND_HOOK='if [ "$1" = ref-checks-required ]; then git --git-dir="$Q_ORIGIN" show "$2:gen/out.txt" > "$d/cand.out" 2>/dev/null; fi'
q_reset() {  # [<generated paths JSON> <generate command>]
  reset_stubs
  LEASE_RESET
  Q_LIST=""; Q_SEQ=0
  export LIST_PRS="[]" LIST_ISSUES="[]"
  unset TALOS_HOME
  printf 'owner' > "$STUB_DIR/current-user"
  printf 'talos:checkout state=kept' > "$STUB_DIR/worktree.out"
  printf '.github/workflows/*\n' > "$STUB_DIR/forbidden-files-patterns.out"
  printf 'open\n' > "$STUB_DIR/base-protection.out"
  printf '%s' "$HEAD_HOOK" > "$STUB_DIR/hook.pr-head"
  printf '%s' "$MERGE_HOOK" > "$STUB_DIR/hook.merge-pr"
  printf '%s' "$CAND_HOOK" > "$STUB_DIR/hook.ref-checks-required"
  q_cfg "${1-}" "${2-}"
  origin_reset
}
qr() { OUT="$(bash "$GQ/talos.sh" queue run </dev/null 2>"$ERR")"; RC=$?; }
jc() { journal | grep -c -E "$1"; }
line1() { printf '%s\n' "$OUT" | sed -n 1p; }
has_line() { grep -qx -- "$1" <<< "$OUT"; }
assert_line() { if has_line "$2"; then pass "$1"; else fail "$1" "no line '$2' in: $(printf '%s' "$OUT" | tr '\n' '|')"; fi; }
assert_no_line() { if has_line "$2"; then fail "$1" "line '$2' in: $(printf '%s' "$OUT" | tr '\n' '|')"; else pass "$1"; fi; }
merged_prs() { journal | sed -n 's/^vcs merge-pr \([0-9]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//'; }
origin_head() { git -C "$ORIGIN" rev-parse "refs/heads/feat/issue-$1-q"; }
first_cand() { printf '%s\n' "$OUT" | sed -n 's/^candidate=.* prs=//p' | head -n 1; }
merge_failed() { cat "$STUB_DIR/merge.fail" 2>/dev/null; }
cand_out() { cat "$STUB_DIR/cand.out" 2>/dev/null; }
main_out() { git -C "$ORIGIN" show main:gen/out.txt 2>/dev/null; }
EXPECT=$'a\nb\nc'
# base_moved <name>: the base moves with a commit that adds gen/src/<name>.txt and regenerates
# gen/out.txt, so a PR that regenerates the file conflicts with the base itself
base_moved() {
  sg checkout -q main
  printf '%s\n' "$1" > "$SEED/gen/src/$1.txt"
  ( cd "$SEED" && eval "$GEN" )
  sg add -A
  sg commit -q -m "main: gen $1"
  sg push -q origin main
}

# ── AC1: two PRs regenerating one file share a candidate ─────────────────────
q_reset '["gen/out.txt"]' "$GEN"
gen_pr 11 41 b
gen_pr 12 42 c
OLD12="$(origin_head 42)"
qr
assert_eq "verdict=merged" "$(line1)" "AC1 two PRs that regenerate gen/out.txt: verdict=merged"
assert_eq "11,12" "$(first_cand)" "AC1 both PRs share one candidate"
assert_eq "$EXPECT" "$(cand_out)" "AC1 the candidate's gen/out.txt is the generator's output on the combined tree"
assert_line "AC1 regenerated=12 is printed for the second PR" "regenerated=12"
assert_no_line "AC1 the first PR applied plainly, no regeneration" "regenerated=11"
assert_eq "1" "$(jc '^vcs ref-checks-required')" "AC1 one candidate, one check call"
assert_eq "11 12" "$(merged_prs)" "AC1 both merge, in queue order"
assert_eq "1|0" "$(jc '^mergebase 12$')|$(jc '^mergebase 11$')" "AC1 the second PR is synced through pipeline-mergebase.sh, the first is not"
assert_eq "" "$(merge_failed)" "AC1 every merge-pr was made against a head that merges"
assert_eq "different" "$([ "$(origin_head 42)" != "$OLD12" ] && echo different || echo same)" "AC1 the synced head is a new head"
assert_eq "$EXPECT" "$(main_out)" "AC1 main's gen/out.txt is the generator's output on the combined tree"
assert_eq "$(origin_head 42)" "$(journal | sed -n 's/^vcs merge-pr 12 --sha \([0-9a-f]*\).*/\1/p')" "AC1 the second PR merges at its synced head"

# ── AC2: a failing generator leaves the PR out ───────────────────────────────
q_reset '["gen/out.txt"]' "$GEN; exit 3"
gen_pr 11 41 b
gen_pr 12 42 c
OLD12="$(origin_head 42)"
qr
assert_line "AC2 a failing generator: conflict=12 action=generate-failed" "conflict=12 action=generate-failed"
assert_eq "11" "$(first_cand)" "AC2 the candidate holds only the PR that applies plainly"
assert_eq "11" "$(merged_prs)" "AC2 the PR left out is not merged"
assert_eq "$OLD12" "$(origin_head 42)" "AC2 nothing is pushed for the PR left out"
assert_no_line "AC2 no regenerated line for a failed regeneration" "regenerated=12"
assert_eq "0" "$(jc '^mergebase 12$')" "AC2 the failed PR is not synced"

# ── AC3: a regeneration that touches a file outside merge.generated_paths ────
q_reset '["gen/out.txt"]' "$GEN; echo stray > stray.txt"
gen_pr 11 41 b
gen_pr 12 42 c
OLD12="$(origin_head 42)"
qr
assert_line "AC3 a new file outside merge.generated_paths: generate-failed" "conflict=12 action=generate-failed"
assert_eq "11" "$(merged_prs)" "AC3 the PR left out is not merged"
assert_eq "$OLD12" "$(origin_head 42)" "AC3 nothing is pushed for the PR left out"
q_reset '["gen/out.txt"]' "$GEN; echo more >> base.txt"
gen_pr 11 41 b
gen_pr 12 42 c
qr
assert_line "AC3 a tracked file outside merge.generated_paths changed: generate-failed" "conflict=12 action=generate-failed"
assert_eq "11" "$(merged_prs)" "AC3 the PR with a stray change to a tracked file is not merged"
q_reset '["gen/out.txt"]' "$GEN; echo '<<<<<<< x' >> gen/out.txt"
gen_pr 11 41 b
gen_pr 12 42 c
qr
assert_line "AC3 a conflict marker left in a generated file: generate-failed" "conflict=12 action=generate-failed"
assert_eq "11" "$(merged_prs)" "AC3 the PR whose regeneration left a marker is not merged"

# ── AC4: merge.generate_command is repo config only ──────────────────────────
GH="$SANDBOX/talos-home"
rm -rf "${GH:?}"; mkdir -p "$GH"
printf '{"merge":{"generate_command":"echo from-user"}}' > "$GH/talos.pipeline.json"
q_reset
CMD="$(TALOS_HOME="$GH" bash "$TALOS_ROOT/scripts/pipeline-config.sh" merge.generate_command 2>"$ERR")"
assert_eq "" "$CMD" "AC4 a user-level merge.generate_command reads as unset"
assert_eq "1" "$(wc -l < "$ERR" | tr -d ' ')" "AC4 the user-level key is dropped with one stderr line"
assert_contains "$(cat "$ERR")" "merge.generate_command" "AC4 the stderr line names the key"
# the queue does not run it: the repo sets only the paths, the user the command
q_reset '["gen/out.txt"]' ""
q_pr 11 41 a11.txt x11
gen_pr 12 42 c
base_moved d
OUT="$(TALOS_HOME="$GH" bash "$GQ/talos.sh" queue run </dev/null 2>"$ERR")"; RC=$?
assert_line "AC4 a user-level command is not run: PR 12 is left out as without keys" "conflict=12 action=developer"
assert_no_line "AC4 no regeneration from a user-level command" "regenerated=12"
assert_eq "11" "$(merged_prs)" "AC4 only the PR that applies merges"

# ── AC5 (same): no generated keys keeps today's conflict handling ────────────
q_reset
q_pr 11 41 a11.txt x11
gen_pr 12 42 c
base_moved d
qr
assert_line "AC5 keys unset: a conflict in gen/out.txt is the merge-base task" "conflict=12 action=developer"
assert_eq "11" "$(first_cand)" "AC5 keys unset: PR 12 is left out of the candidate"
assert_eq "11" "$(merged_prs)" "AC5 keys unset: PR 12 is not merged"
assert_eq "1" "$(jc '^mergebase 12$')" "AC5 keys unset: pipeline-mergebase.sh runs for PR 12"
assert_no_line "AC5 keys unset: nothing is regenerated" "regenerated=12"
q_reset '["gen/out.txt"]' ""
q_pr 11 41 a11.txt x11
gen_pr 12 42 c
base_moved d
qr
assert_line "AC5 only the paths set: as without keys" "conflict=12 action=developer"
q_reset '' "$GEN"
q_pr 11 41 a11.txt x11
gen_pr 12 42 c
base_moved d
qr
assert_line "AC5 only the command set: as without keys" "conflict=12 action=developer"

# ── a protected base keeps today's behaviour: nothing is regenerated in the candidate ──
q_reset '["gen/out.txt"]' "$GEN"
printf 'checks\n' > "$STUB_DIR/base-protection.out"; printf 1 > "$STUB_DIR/base-protection.rc"
q_pr 11 41 a11.txt x11
gen_pr 12 42 c
base_moved d
qr
assert_eq "11" "$(first_cand)" "AC5 a protected base: PR 12 is left out of the candidate"
assert_no_line "AC5 a protected base: nothing is regenerated in the candidate" "regenerated=12"
assert_line "AC5 a protected base: PR 12 is synced by the merge-base step" "conflict=12 action=mergebase"
# ── a regeneration against a moved base, in the cut (AC1's other shape) ──
q_reset '["gen/out.txt"]' "$GEN"
q_pr 11 41 a11.txt x11
gen_pr 12 42 c
base_moved d
qr
assert_eq "11,12" "$(first_cand)" "AC1 a PR that conflicts with the base itself shares the candidate"
assert_eq $'a\nc\nd' "$(cand_out)" "AC1 the candidate holds the generator's output on base plus PR"
assert_line "AC1 regenerated=12 for a PR that conflicts with the base" "regenerated=12"
assert_eq "11 12" "$(merged_prs)" "AC1 both merge"
assert_eq $'a\nc\nd' "$(main_out)" "AC1 main holds the regenerated file"

finish
