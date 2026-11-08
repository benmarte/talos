#!/usr/bin/env bash
# test-talos-post-merge-closing-822.sh -- `talos.sh post-merge` and the `sweep`
# heal close an issue only when the merged PR closes it (#822). A PR that is
# "Part of #N" leaves the issue open (a part-of comment, board `In progress`);
# a verdict that cannot be read closes nothing and warns.
# Every test runs on stubs under make_sandbox (the stub-scripts-dir pattern of
# test-talos-postmerge.sh): no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
ERR="$SANDBOX/stderr"

# ── fixtures ─────────────────────────────────────────────────────────────────
# A copy of the scripts directory in which every script a verb calls is one
# journaling stub. <key> is what the stub looks up in $STUB_DIR/<key>.{out,err,rc}
# (rc 0 by default): for pipeline-vcs.sh `<verb>.<first arg>` then `<verb>`.
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
case " $* " in *" --markdown "*) sfx=md ;; *" --line "*) sfx=line ;; *" --summary "*) sfx=summary ;; *) sfx="" ;; esac
if [ "$n" = "vcs" ]; then cands="${1:-}.${2:-} ${1:-}"
else cands="$n.${1:-}.$sfx $n.${1:-} $n"; fi
key=""
for c in $cands; do
  if [ -e "$d/$c.out" ] || [ -e "$d/$c.err" ] || [ -e "$d/$c.rc" ]; then key="$c"; break; fi
done
printf "%s %s\n" "$n" "$*" >> "$d/journal"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then
    if [ "$a" = "-" ]; then cat > "$d/stdin"; else { printf "[%s]\n" "$*"; cat "$a"; } >> "$d/bodies"; cp "$a" "$d/last-body"; fi
  fi
  prev="$a"
done
if [ "$n" = "hooks" ]; then cat >> "$d/hooks.stdin"; fi
if [ -n "$key" ]; then
  if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
  if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
  if [ -f "$d/$key.rc" ]; then exit "$(cat "$d/$key.rc")"; fi
fi
exit 0
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-mergebase.sh \
         pipeline-status.sh pipeline-worktree.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
PM="$GS/talos.sh"

cfg_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }
# set_stub <key> <rc> [out] [err]
set_stub() {
  printf '%s\n' "$2" > "$STUB_DIR/$1.rc"
  printf '%s' "${3:-}" > "$STUB_DIR/$1.out"
  printf '%s' "${4:-}" > "$STUB_DIR/$1.err"
}
# reset_stubs: a GitHub provider, a trusted bot user, no sibling PRs, no comments,
# issue 42 open, and a merged PR that closes it.
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  cfg_json '{"vcs": {"provider": "github"}}'
  set_stub current-user 0 "bot"
  set_stub list-prs 0 "[]"
  set_stub read-comments 0 '{"comments":[]}'
  set_stub list-issues 0 "[$(issue_json 42 "")]"
  set_stub worktree.to-base 0 "talos:checkout state=kept"
  set_stub pr-closes-issue.9 0 "closes"
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
# jr: the journal with the temp body path normalised.
jr() { journal | sed 's| --body-file [^ ]*| --body-file F|'; }
called() { journal | grep -c "^$1 \|^vcs $1 "; }
pm() { OUT="$(bash "$PM" post-merge "$@" 2>"$ERR")"; RC=$?; }
sw() { OUT="$(bash "$PM" sweep "$@" 2>"$ERR")"; RC=$?; }
issue_json() {  # number "labels,..." -> one list-issues item
  local n="$1" out="" l
  local IFS=,
  for l in $2; do out="${out:+$out,}{\"name\":\"$l\"}"; done
  printf '{"number":%s,"title":"t","labels":[%s],"body":""}' "$n" "$out"
}
# marker_comments <body-file>: a read-comments answer holding that comment by the bot.
marker_comments() {
  python3 -I -c 'import json, sys; print(json.dumps({"comments": [{"author": {"login": "bot"}, "body": sys.stdin.read()}]}))' < "$1"
}

PART_OF_TEXT="PR #9 merged (part of #42)"

# ── AC1, AC2: "Part of #N" leaves the issue open ─────────────────────────────
reset_stubs
set_stub pr-closes-issue.9 0 "part-of"
pm 9 42
assert_eq "0" "$RC" "AC1 part-of: post-merge exits 0"
assert_eq "0" "$(called close-issue)" "AC1 part-of: close-issue is never called"
assert_not_contains "$(cat "$STUB_DIR/bodies" 2>/dev/null)" "talos:issue-closed" "AC1 part-of: no issue-closed comment is posted"
assert_not_contains "$(cat "$STUB_DIR/bodies" 2>/dev/null)" "CLOSED" "AC1 part-of: nothing in the comment says the issue is closed"
assert_not_contains "$(journal)" "issue-closed" "AC1 part-of: no issue-closed notice or event"
assert_not_contains "$OUT" "warn" "AC1 part-of: no warning"

assert_eq "1" "$(called comment-issue)" "AC2 part-of: one comment is posted on the issue"
assert_contains "$(cat "$STUB_DIR/last-body")" "$PART_OF_TEXT" "AC2 part-of: the comment reads 'PR #9 merged (part of #42)'"
assert_contains "$(cat "$STUB_DIR/last-body")" "<!-- talos:part-of pr=9 -->" "AC2 part-of: the comment carries its marker"
assert_contains "$(journal)" "status 42 In progress" "AC2 part-of: the board goes to In progress"
assert_not_contains "$(journal)" "status 42 Done" "AC2 part-of: the board is not set to Done"
assert_contains "$(journal)" "notify merged #42 PR #9 merged 42" "AC2 part-of: the merged notice still goes out"

# Once, even if post-merge runs twice (the first run's comment is now on the issue).
cp "$STUB_DIR/last-body" "$SANDBOX/part-of.body"
set_stub read-comments 0 "$(marker_comments "$SANDBOX/part-of.body")"
rm -f "$STUB_DIR/journal" "$STUB_DIR/bodies"
pm 9 42
assert_eq "0" "$(called comment-issue)" "AC2 part-of: a second run posts no second comment"
assert_contains "$OUT" "recorded=yes" "AC2 part-of: the second run sees the marker"
assert_eq "0" "$(called close-issue)" "AC2 part-of: a second run still never closes"
assert_eq "0" "$(called notify)" "AC2 part-of: a second run sends no second notice"
# A marker for another PR does not count.
set_stub pr-closes-issue.8 0 "part-of"
rm -f "$STUB_DIR/journal"
pm 8 42
assert_eq "1" "$(called comment-issue)" "AC2 part-of: another PR's marker does not suppress this PR's comment"

# ── AC3: a verdict that cannot be read closes nothing ────────────────────────
reset_stubs
set_stub pr-closes-issue.9 2 "" "could not read"
pm 9 42
assert_eq "0" "$RC" "AC3 unverified: exits 0 like any non-fatal warn"
assert_eq "0" "$(called close-issue)" "AC3 unverified: close-issue is never called"
assert_not_contains "$(journal)" "status 42 Done" "AC3 unverified: the board is not set to Done"
assert_contains "$OUT" "warn reason=closing-unverified issue=42 pr=9" "AC3 unverified: a warn reason=closing-unverified line"
assert_eq "0" "$(called comment-issue)" "AC3 unverified: nothing is posted on the issue"
assert_contains "$(journal)" "worktree remove 42" "AC3 unverified: the other items still run"
# Output that is neither word is not a verdict either, whatever the exit status.
reset_stubs
set_stub pr-closes-issue.9 0 "maybe"
pm 9 42
assert_eq "0" "$(called close-issue)" "AC3 unverified: an unexpected answer closes nothing"
assert_contains "$OUT" "warn reason=closing-unverified issue=42 pr=9" "AC3 unverified: an unexpected answer warns"
reset_stubs
set_stub pr-closes-issue.9 0 ""
pm 9 42
assert_eq "0" "$(called close-issue)" "AC3 unverified: an empty answer closes nothing"
assert_contains "$OUT" "warn reason=closing-unverified issue=42 pr=9" "AC3 unverified: an empty answer warns"

# ── AC4: a closing PR keeps today's flow and order ───────────────────────────
reset_stubs
pm 9 42
assert_eq "0" "$RC" "AC4 closes: exits 0"
assert_eq "vcs list-prs
vcs current-user
vcs read-comments 42
vcs list-issues
vcs pr-closes-issue 9 42
vcs comment-issue 42 --body-file F --allow-closed
vcs close-issue 42 closed by PR #9
status 42 Done
worktree to-base 42
worktree remove 42
notify orchestrator #42 all stages passed — merged PR #9, issue closed 42
notify merged #42 PR #9 merged 42
notify issue-closed #42 issue resolved 42
hooks post_stage merged orchestrator 42 --pr 9 --summary PR #9 merged
hooks post_stage issue-closed orchestrator 42 --pr 9 --summary issue resolved
events cost --issue 42 --pr 9 --line
events cost --issue 42 --pr 9 --markdown" "$(jr)" "AC4 closes: close-issue 'closed by PR #9', the issue-closed comment and Done, in today's order"
assert_contains "$(cat "$STUB_DIR/last-body")" "<!-- talos:issue-closed pr=9 -->" "AC4 closes: the issue-closed comment carries its marker"
assert_not_contains "$(cat "$STUB_DIR/last-body")" "part of" "AC4 closes: and no part-of text"

# ── AC5: an issue the forge already closed never asks ────────────────────────
reset_stubs
set_stub list-issues 0 "[$(issue_json 7 "")]"
set_stub pr-closes-issue.9 0 "part-of"
pm 9 42
assert_eq "0" "$(called pr-closes-issue)" "AC5 closed by the forge: pr-closes-issue is never asked"
assert_eq "0" "$(called close-issue)" "AC5 closed by the forge: no close-issue"
assert_eq "1" "$(called comment-issue)" "AC5 closed by the forge: the issue-closed comment is posted as today"
assert_contains "$(cat "$STUB_DIR/last-body")" "<!-- talos:issue-closed pr=9 -->" "AC5 closed by the forge: it is the issue-closed comment"
assert_contains "$(journal)" "status 42 Done" "AC5 closed by the forge: the board is Done as today"

# ── AC6, AC7: the sweep heal follows the same rule ───────────────────────────
reset_stubs
set_stub list-issues 0 "[$(issue_json 31 "pipeline:dev")]"
set_stub find-pr 0 '{"number":9}'
set_stub pr-closes-issue.9 0 "part-of"
sw
assert_eq "0" "$RC" "AC6 heal part-of: sweep exits 0"
assert_contains "$OUT" "heal=31 pr=9" "AC6 heal part-of: the merged PR is found"
assert_eq "0" "$(called close-issue)" "AC6 heal part-of: the issue stays open"
assert_contains "$(cat "$STUB_DIR/last-body")" "PR #9 merged (part of #31)" "AC6 heal part-of: the part-of comment is posted"
assert_not_contains "$(journal)" "status 31 Done" "AC6 heal part-of: the board is not set to Done"
assert_contains "$(journal)" "status 31 In progress" "AC6 heal part-of: the board goes to In progress"
assert_eq "1" "$(journal | grep -c '^vcs list-issues')" "AC6 heal part-of: the heal reuses its own list"
# The next sweep, with the part-of comment on the issue: no second comment.
cp "$STUB_DIR/last-body" "$SANDBOX/part-of.body"
set_stub read-comments 0 "$(marker_comments "$SANDBOX/part-of.body")"
rm -f "$STUB_DIR/journal"
sw
assert_eq "0" "$(called comment-issue)" "AC6 heal part-of: a second sweep posts no second comment"
assert_eq "0" "$(called close-issue)" "AC6 heal part-of: a second sweep still does not close"

reset_stubs
set_stub list-issues 0 "[$(issue_json 31 "pipeline:dev")]"
set_stub find-pr 0 '{"number":9}'
sw
assert_contains "$(journal)" "vcs close-issue 31 closed by PR #9" "AC7 heal closes: a closing PR still closes the issue"
assert_contains "$(journal)" "status 31 Done" "AC7 heal closes: and the board is Done"

finish
