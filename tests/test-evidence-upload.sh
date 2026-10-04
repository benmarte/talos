#!/usr/bin/env bash
# test-evidence-upload.sh -- covers issue #415 (sub-task of epic #352):
# scripts/pipeline-evidence.sh `upload <pr>` posts ONE evidence comment with
# `gh pr comment --attach`, from a private staged copy of the files `collect`
# selected, and keeps exactly one evidence comment per PR (create the new one,
# then delete the author's older ones).
# Everything runs against tests/stubs/gh (put first on PATH): no real GitHub
# call, no real `gh pr comment --attach`. The stub fails loudly on --edit-last
# and --delete-last, so a test notices if the script ever uses them.
#
# Decisions pinned here:
#   - strategy: create-then-delete (mode=new|replace; mode=skip when collect
#     finds nothing); --edit-last is never used.
#   - gh runs with cwd = the staging dir and --repo <owner>/<repo>, and the
#     body and every --attach value are `./<relpath>`.
#   - only the author's own comments whose LAST non-blank line is the marker
#     are ever deleted.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

EV="$TALOS_ROOT/scripts/pipeline-evidence.sh"
assert_file_exists "$EV" "pipeline-evidence.sh exists"

# TMPDIR inside the scratch dir: staging dirs land here, never in the repo.
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
use_stubs
export GH_STDIN_LOG="$SANDBOX/gh.stdin.log"
export STUB_ATTACH_LOG="$SANDBOX/attach.log"
export STUB_COMMENT_STORE="$SANDBOX/comments.json"
export STUB_CURRENT_USER="talosbot"
MARKER='<!-- talos:evidence -->'

OUT="$SANDBOX/out.txt"
ERR="$SANDBOX/err.txt"
RC=0

# ---- helpers ----------------------------------------------------------------
new_repo() {
  REPO="$(safe_mktemp_dir "$SANDBOX/repo.XXXXXX")" || exit 1
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.name "talos test"
  git -C "$REPO" config user.email "test@talos.invalid"
  printf 'ev/\n' > "$REPO/.gitignore"
  git -C "$REPO" add .gitignore
  git -C "$REPO" commit -q -m init
  mkdir -p "$REPO/ev"
  printf '{"evidence": {"dir": "ev"}}\n' > "$REPO/talos.pipeline.json"
  cd "$REPO" || exit 1
}
reset() {
  : > "$GH_LOG"; : > "$GH_STDIN_LOG"; : > "$STUB_ATTACH_LOG"
  printf '[]' > "$STUB_COMMENT_STORE"
  unset STUB_CURRENT_USER_FAIL STUB_GH_API_FAIL STUB_ATTACH_FAIL STUB_ATTACH_PARTIAL \
        STUB_COMMENT_DELETE_FAIL STUB_GH_ATTACH STUB_GH_VERSION
  export STUB_CURRENT_USER="talosbot"
}
PNG_MAGIC='\211PNG\r\n\032\n'
mk() { mkdir -p "$(dirname "$1")"; { printf "$2"; printf '%s' "${3:-body}"; } > "$1"; }
png()  { mk "$1" "$PNG_MAGIC" "${2:-pixels}"; }
webm() { mk "$1" '\032\105\337\243\102\202\204webm' "${2:-video}"; }
setm() { python3 -I -c 'import os,sys; t=float(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
fixtures() { png ev/shot-a.png "alpha"; png ev/shot-b.png "bravo"; webm ev/0-run.webm "clip"; }

upload() { bash "$EV" upload "$@" >"$OUT" 2>"$ERR"; RC=$?; }
out() { cat "$OUT"; }
err() { cat "$ERR"; }
gh_log() { cat "$GH_LOG"; }
posts() { grep -c -- '--body-file' "$GH_LOG" || true; }
deletes() { grep -c -- 'DELETE' "$GH_LOG" || true; }
stage_dirs() { find "$TMPDIR" -maxdepth 1 -name 'talos-evidence-stage.*' | wc -l | tr -d ' '; }

# seed <id> <login> <body> -- add a comment to the stub's store.
seed() {
  python3 -I -c '
import json, sys
store, cid, login, body = sys.argv[1:5]
items = json.load(open(store))
items.append({"id": int(cid), "user": {"login": login}, "body": body,
              "created_at": "2026-10-02T00:00:00Z",
              "html_url": "https://github.com/acme/widget/pull/7#issuecomment-" + cid})
json.dump(items, open(store, "w"))' "$STUB_COMMENT_STORE" "$1" "$2" "$3"
}
# ids <login-or-*> -- ids in the store whose last non-blank line is the marker.
marker_ids() {
  python3 -I -c '
import json, sys
store, who = sys.argv[1:3]
for c in json.load(open(store)):
    last = [l for l in c["body"].replace("\r\n", "\n").split("\n") if l.strip()]
    if last and last[-1].strip() == "<!-- talos:evidence -->" and who in ("*", c["user"]["login"]):
        print(c["id"])' "$STUB_COMMENT_STORE" "$1" | tr '\n' ' ' | sed 's/ $//'
}
all_ids() { python3 -I -c 'import json,sys; print(" ".join(str(c["id"]) for c in json.load(open(sys.argv[1]))))' "$STUB_COMMENT_STORE"; }
body_of() {
  python3 -I -c '
import json, sys
for c in json.load(open(sys.argv[1])):
    if str(c["id"]) == sys.argv[2]:
        sys.stdout.write(c["body"])' "$STUB_COMMENT_STORE" "$1"
}

OLD_BODY="$(printf '### Evidence\n\nold\n\n%s\n' "$MARKER")"

# =============================================================================
# usage: exit 2, no gh call
# =============================================================================
new_repo; fixtures; reset
upload;                       assert_eq "2" "$RC" "usage: no PR -> exit 2"
upload 12a;                   assert_eq "2" "$RC" "usage: non-digit PR -> exit 2"
upload '7;touch pwned';       assert_eq "2" "$RC" "usage: shell text as the PR -> exit 2"
upload 7 8;                   assert_eq "2" "$RC" "usage: two PRs -> exit 2"
upload 7 --bogus;             assert_eq "2" "$RC" "usage: unknown flag -> exit 2"
upload 7 --manifest m.tsv;    assert_eq "2" "$RC" "usage: --manifest is not an option -> exit 2"
upload 7 --since;             assert_eq "2" "$RC" "usage: --since without a value -> exit 2"
upload 7 --since abc;         assert_eq "2" "$RC" "usage: --since abc -> exit 2"
assert_eq "" "$(gh_log)" "usage: no gh call was made"
assert_file_absent "$REPO/pwned" "usage: shell text in the PR argument did not run"
assert_eq "0" "$(stage_dirs)" "usage: no staging dir was left behind"

# =============================================================================
# providers
# =============================================================================
reset
printf '{"vcs": {"provider": "gitlab"}, "evidence": {"dir": "ev"}}\n' > talos.pipeline.json
upload 7
assert_eq "2" "$RC" "provider gitlab: exit 2"
assert_contains "$(err)" "not implemented for provider 'gitlab'" "provider gitlab: says so"
assert_eq "" "$(gh_log)" "provider gitlab: no gh call"
printf '{"vcs": {"provider": "azure"}, "evidence": {"dir": "ev"}}\n' > talos.pipeline.json
upload 7
assert_eq "2" "$RC" "provider azure: exit 2"
assert_contains "$(err)" "not implemented for provider 'azure'" "provider azure: says so"

# github-api without a gh binary: a PATH holding the tools the script needs but no gh
NOGH="$SANDBOX/nogh-bin"; mkdir -p "$NOGH"
for t in bash git python3 dirname basename cat sed grep awk tr head tail mktemp rm mkdir cut sort wc env date uname ls find id readlink cp mv ln chmod tee xargs seq; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$NOGH/$t"
done
printf '{"vcs": {"provider": "github-api"}, "evidence": {"dir": "ev"}}\n' > talos.pipeline.json
PATH="$NOGH" bash "$EV" upload 7 >"$OUT" 2>"$ERR"; RC=$?
assert_eq "2" "$RC" "github-api without gh: exit 2"
assert_contains "$(err)" "no gh binary" "github-api without gh: says why"
assert_eq "0" "$(stage_dirs)" "github-api without gh: nothing staged"
# ... and with gh it goes on (the stub answers)
upload 7
assert_contains "$(gh_log)" "pr comment --help" "github-api with gh: gets past the binary check to the capability probe"
printf '{"evidence": {"dir": "ev"}}\n' > talos.pipeline.json

# =============================================================================
# nothing to attach: mode=skip, exit 3, no gh call
# =============================================================================
new_repo; reset
upload 7
assert_eq "3" "$RC" "nothing to attach: exit 3"
assert_eq "evidence-upload pr=7 images=0 videos=0 comment= mode=skip" "$(out)" "nothing to attach: the skip line"
assert_eq "" "$(gh_log)" "nothing to attach: no gh call (not even the --help probe)"
assert_eq "0" "$(stage_dirs)" "nothing to attach: staging dir removed"
mk ev/notes.txt hi
upload 7
assert_eq "3" "$RC" "only non-allowlisted files: exit 3"

# =============================================================================
# (i) gh without --attach: exit 2, no other call
# =============================================================================
new_repo; fixtures; reset
export STUB_GH_ATTACH=0 STUB_GH_VERSION='gh version 2.94.0 (stub)'
upload 7
assert_eq "2" "$RC" "no --attach: exit 2"
assert_eq "" "$(out)" "no --attach: nothing on stdout"
assert_eq "evidence-upload unsupported: gh 2.94.0 has no --attach (gh v2.99.0 or newer required)" "$(err)" "no --attach: the capability message"
EXTRA="$(grep -v -x -e 'pr comment --help' -e '--version' "$GH_LOG" || true)"
assert_eq "" "$EXTRA" "no --attach: GH_LOG holds only the help/version calls"
assert_eq "[]" "$(cat "$STUB_COMMENT_STORE")" "no --attach: nothing posted"
assert_eq "0" "$(stage_dirs)" "no --attach: staging dir removed"
unset STUB_GH_ATTACH STUB_GH_VERSION

# =============================================================================
# (ii) two runs -> exactly one evidence comment
# =============================================================================
new_repo; fixtures; reset
upload 7
assert_eq "0" "$RC" "run 1: exit 0"
assert_eq "evidence-upload pr=7 images=2 videos=1 comment=https://github.com/acme/widget/pull/7#issuecomment-5001 mode=new" "$(out)" "run 1: one line, mode=new"
assert_eq "5001" "$(marker_ids '*')" "run 1: exactly one evidence comment"
assert_eq "0" "$(deletes)" "run 1: nothing deleted"
assert_eq "1" "$(posts)" "run 1: one post"

NEW_BODY="$(body_of 5001)"
LAST="$(printf '%s\n' "$NEW_BODY" | grep -v '^[[:space:]]*$' | tail -n 1)"
assert_eq "$MARKER" "$LAST" "run 1: the marker is the last non-blank line (nothing appended after it)"
assert_eq "3" "$(printf '%s\n' "$NEW_BODY" | grep -c 'https://github.com/user-attachments/assets/')" "run 1: every file reference was rewritten to an upload URL"
assert_not_contains "$NEW_BODY" "](./" "run 1: no local reference is left"
assert_contains "$NEW_BODY" "public" "run 1: the public-repo footer"
assert_contains "$NEW_BODY" "secrets" "run 1: the on-screen-secrets footer"

SENT="$(cat "$GH_STDIN_LOG")"
LA="$(printf '%s\n' "$SENT" | grep -n -F '![shot-a.png](./shot-a.png)' | cut -d: -f1)"
LB="$(printf '%s\n' "$SENT" | grep -n -F '![shot-b.png](./shot-b.png)' | cut -d: -f1)"
LV="$(printf '%s\n' "$SENT" | grep -n -F '![0-run.webm](./0-run.webm)' | cut -d: -f1)"
if [ -n "$LA" ] && [ -n "$LB" ] && [ -n "$LV" ] && [ "$LA" -lt "$LB" ] && [ "$LB" -lt "$LV" ]; then
  pass "run 1: images first (sorted), then the recording"
else
  fail "run 1: images first, then the recording" "lines a=$LA b=$LB v=$LV"
fi
assert_eq '![0-run.webm](./0-run.webm)' "$(printf '%s\n' "$SENT" | awk 'BEGIN{RS=""} /0-run\.webm/ {print}')" "run 1: the recording is alone in its own paragraph (gh turns it into a player)"

POST_LINE="$(grep -- '--body-file' "$GH_LOG")"
assert_eq "pr comment 7 --repo acme/widget --body-file - --attach ./shot-a.png --attach ./shot-b.png --attach ./0-run.webm" "$POST_LINE" "run 1: argv is --body-file - plus one --attach ./<rel> per file, images first"
assert_not_contains "$POST_LINE" "edit-last" "run 1: --edit-last is never used"
assert_not_contains "$POST_LINE" "$REPO" "run 1: no worktree path on argv"

CWD1="$(cut -f1 "$STUB_ATTACH_LOG" | sort -u)"
case "$CWD1" in
  */talos-evidence-stage.*/files) pass "run 1: gh ran inside the private staging dir" ;;
  *) fail "run 1: gh ran inside the private staging dir" "cwd: $CWD1" ;;
esac
case "$CWD1" in "$REPO"*) fail "run 1: gh cwd is outside the worktree" "$CWD1" ;; *) pass "run 1: gh cwd is outside the worktree" ;; esac
assert_eq "0o600 0o600 0o600" "$(cut -f3 "$STUB_ATTACH_LOG" | tr '\n' ' ' | sed 's/ $//')" "run 1: the attached files are the 0600 staged copies"
assert_eq "0" "$(stage_dirs)" "run 1: the staging dir is removed on exit"

: > "$GH_LOG"
upload 7
assert_eq "0" "$RC" "run 2: exit 0"
assert_eq "evidence-upload pr=7 images=2 videos=1 comment=https://github.com/acme/widget/pull/7#issuecomment-5002 mode=replace" "$(out)" "run 2: mode=replace with the new URL"
assert_eq "5002" "$(marker_ids '*')" "run 2: exactly one evidence comment after two runs"
assert_eq "1" "$(deletes)" "run 2: one delete"
assert_contains "$(gh_log)" "api --method DELETE repos/acme/widget/issues/comments/5001" "run 2: the old comment was deleted by id"
FIRST_POST="$(grep -n -- '--body-file' "$GH_LOG" | head -n 1 | cut -d: -f1)"
FIRST_DEL="$(grep -n -- 'DELETE' "$GH_LOG" | head -n 1 | cut -d: -f1)"
if [ "$FIRST_POST" -lt "$FIRST_DEL" ]; then pass "run 2: the new comment is posted before the old one is deleted"; else fail "run 2: post before delete" "post=$FIRST_POST delete=$FIRST_DEL"; fi
upload 7
assert_eq "5003" "$(marker_ids '*')" "run 3: still exactly one evidence comment"
assert_contains "$(out)" "mode=replace" "run 3: mode=replace"
assert_not_contains "$(gh_log)" "edit-last" "runs 1-3: --edit-last never used"
assert_not_contains "$(gh_log)" "delete-last" "runs 1-3: --delete-last never used"
assert_not_contains "$(gh_log)" "--method PATCH" "runs 1-3: no PATCH"

# the body is a fixed template: PR/issue text never reaches it
new_repo; fixtures; reset
STUB_PR_TITLE='pwn $(touch PWNED) `id`' STUB_ISSUE_TITLE='Title $(touch PWNED2)' upload 7
assert_eq "0" "$RC" "template: exit 0"
assert_not_contains "$(cat "$GH_STDIN_LOG")" "pwn" "template: PR title text is not in the body"
assert_not_contains "$(cat "$GH_STDIN_LOG")" "Title" "template: issue title text is not in the body"
assert_file_absent "$REPO/PWNED" "template: nothing was evaluated"

# --since: a stale earlier capture is not republished
new_repo; reset
png ev/old.png "stale"; png ev/new.png "fresh"
setm ev/old.png 1000; setm ev/new.png 2000000000
upload 7 --since 1500000000
assert_eq "0" "$RC" "--since: exit 0"
assert_contains "$(out)" "images=1 videos=0" "--since: only the fresh file is attached"
assert_contains "$(gh_log)" "--attach ./new.png" "--since: new.png attached"
assert_not_contains "$(gh_log)" "old.png" "--since: old.png never reaches gh"

# subdirectories keep their ./<dir>/<file> reference in both places
new_repo; reset
png ev/l1/l2/deep.png "deep"
upload 7
assert_eq "0" "$RC" "nested file: exit 0"
assert_contains "$(gh_log)" "--attach ./l1/l2/deep.png" "nested file: --attach ./l1/l2/deep.png"
assert_contains "$(cat "$GH_STDIN_LOG")" "![l1/l2/deep.png](./l1/l2/deep.png)" "nested file: the body names the same ./ path"

# =============================================================================
# (iii) another user's marker comment is never edited or deleted
# =============================================================================
new_repo; fixtures; reset
seed 4001 someoneelse "$OLD_BODY"
seed 4002 talosbot "$OLD_BODY"
seed 4003 talosbot "$(printf '**Agent:** developer (talos)\n\nstage comment, no marker\n')"
seed 4004 talosbot "$(printf 'mentions %s in the middle\n\nand then more text\n' "$MARKER")"
seed 4005 TalosBot "$OLD_BODY"
upload 7
assert_eq "0" "$RC" "foreign marker: exit 0"
assert_contains "$(out)" "mode=replace" "foreign marker: own old comments replaced"
ALL="$(all_ids)"
case " $ALL " in *" 4001 "*) pass "foreign marker: the other user's comment survives" ;; *) fail "foreign marker: the other user's comment survives" "ids: $ALL" ;; esac
case " $ALL " in *" 4003 "*) pass "foreign marker: an own comment without the marker survives" ;; *) fail "foreign marker: own comment without the marker survives" "ids: $ALL" ;; esac
case " $ALL " in *" 4004 "*) pass "foreign marker: an own comment with the marker NOT last survives" ;; *) fail "foreign marker: marker-not-last comment survives" "ids: $ALL" ;; esac
case " $ALL " in *" 4002 "*|*" 4005 "*) fail "foreign marker: own old evidence comments (any login case) are deleted" "ids: $ALL" ;; *) pass "foreign marker: own old evidence comments (any login case) are deleted" ;; esac
assert_not_contains "$(gh_log)" "comments/4001" "foreign marker: no call touches the other user's comment id"
assert_not_contains "$(gh_log)" "comments/4003" "foreign marker: no call touches the marker-less comment id"
assert_not_contains "$(gh_log)" "comments/4004" "foreign marker: no call touches the marker-in-the-middle comment id"
assert_eq "2" "$(deletes)" "foreign marker: exactly the two own evidence comments were deleted"

# a foreign marker comment alone: new post, nothing deleted
new_repo; fixtures; reset
seed 4001 someoneelse "$OLD_BODY"
upload 7
assert_contains "$(out)" "mode=new" "only a foreign marker comment: mode=new"
assert_eq "0" "$(deletes)" "only a foreign marker comment: nothing deleted"
assert_eq "2" "$(marker_ids '*' | wc -w | tr -d ' ')" "only a foreign marker comment: theirs plus ours"

# =============================================================================
# (iv) the login lookup fails closed
# =============================================================================
new_repo; fixtures; reset
seed 4002 talosbot "$OLD_BODY"
export STUB_CURRENT_USER_FAIL=1
upload 7
assert_eq "1" "$RC" "login refused: exit 1"
assert_eq "" "$(out)" "login refused: nothing on stdout"
assert_contains "$(err)" "could not resolve the authenticated user" "login refused: one-line reason"
assert_eq "0" "$(posts)" "login refused: nothing posted"
assert_eq "0" "$(deletes)" "login refused: nothing deleted"
assert_eq "4002" "$(all_ids)" "login refused: the store is untouched"
unset STUB_CURRENT_USER_FAIL
# a lookup that exits 0 but prints nothing / junk is refused too
export STUB_CURRENT_USER=""
upload 7
assert_eq "1" "$RC" "empty login: exit 1"
assert_eq "0" "$(posts)" "empty login: nothing posted"
export STUB_CURRENT_USER='{"message":"Not Found"}'
upload 7
assert_eq "1" "$RC" "raw error JSON as the login: exit 1"
assert_eq "0" "$(posts)" "raw error JSON as the login: nothing posted"
export STUB_CURRENT_USER="talosbot"

# =============================================================================
# failures around the comment list and the post
# =============================================================================
new_repo; fixtures; reset
seed 4002 talosbot "$OLD_BODY"
export STUB_GH_API_FAIL=comments
upload 7
assert_eq "1" "$RC" "comment list fails: exit 1"
assert_contains "$(err)" "could not read the comments of #7" "comment list fails: one-line reason"
assert_eq "0" "$(posts)" "comment list fails: nothing posted"
assert_eq "0" "$(deletes)" "comment list fails: nothing deleted"
unset STUB_GH_API_FAIL

# gh fails before posting anything: old evidence stays
reset; seed 4002 talosbot "$OLD_BODY"
export STUB_ATTACH_FAIL=1
upload 7
assert_eq "1" "$RC" "gh failure: exit 1"
assert_eq "" "$(out)" "gh failure: nothing on stdout"
assert_contains "$(err)" "gh pr comment failed: gh: unsupported authentication type" "gh failure: gh's own reason, one line"
assert_eq "1" "$(wc -l < "$ERR" | tr -d ' ')" "gh failure: exactly one stderr line"
assert_eq "0" "$(deletes)" "gh failure: the old evidence comment is kept"
assert_eq "4002" "$(all_ids)" "gh failure: the store is untouched"
assert_eq "0" "$(stage_dirs)" "gh failure: staging dir removed"
unset STUB_ATTACH_FAIL

# partial failure: gh posted AND exited non-zero. Nothing is deleted; the next
# clean run leaves exactly one evidence comment.
reset; seed 4002 talosbot "$OLD_BODY"
export STUB_ATTACH_PARTIAL=1
upload 7
assert_eq "1" "$RC" "partial: exit 1"
assert_eq "0" "$(deletes)" "partial: the old evidence comment is NOT deleted"
assert_eq "2" "$(marker_ids talosbot | wc -w | tr -d ' ')" "partial: old comment plus the one gh posted"
unset STUB_ATTACH_PARTIAL
upload 7
assert_eq "0" "$RC" "partial, then a clean run: exit 0"
assert_contains "$(out)" "mode=replace" "partial, then a clean run: mode=replace"
assert_eq "1" "$(marker_ids talosbot | wc -w | tr -d ' ')" "partial, then a clean run: exactly one evidence comment"

# delete failure after a good post: exit 1, names the id, still prints the new URL
reset; seed 4002 talosbot "$OLD_BODY"
export STUB_COMMENT_DELETE_FAIL=1
upload 7
assert_eq "1" "$RC" "delete fails: exit 1"
assert_contains "$(out)" "comment=https://github.com/acme/widget/pull/7#issuecomment-5001" "delete fails: the new URL is still printed"
assert_contains "$(out)" "mode=new" "delete fails: nothing was deleted, so mode=new"
assert_contains "$(err)" "4002" "delete fails: the stderr line names the comment id"
unset STUB_COMMENT_DELETE_FAIL

# =============================================================================
# --dry-run: planned calls, no gh call
# =============================================================================
new_repo; fixtures; reset
seed 4002 talosbot "$OLD_BODY"
upload 7 --dry-run
assert_eq "0" "$RC" "dry-run: exit 0"
assert_eq "" "$(gh_log)" "dry-run: no gh call at all (no probe, no login lookup)"
assert_contains "$(out)" "[dry-run] gh pr comment --help" "dry-run: plans the capability probe"
assert_contains "$(out)" "gh api user --jq .login" "dry-run: plans the login lookup"
assert_contains "$(out)" "gh pr comment 7 --repo" "dry-run: plans the post"
assert_contains "$(out)" "--attach ./shot-a.png --attach ./shot-b.png --attach ./0-run.webm" "dry-run: the --attach list"
assert_contains "$(out)" "DELETE repos/" "dry-run: plans the delete"
assert_not_contains "$(out)" "$TMPDIR" "dry-run: no temp path in the output"
assert_eq "4002" "$(all_ids)" "dry-run: the store is untouched"
assert_eq "0" "$(stage_dirs)" "dry-run: staging dir removed"
new_repo; reset
upload 7 --dry-run
assert_eq "3" "$RC" "dry-run with nothing to attach: exit 3"

# a collect failure (a refusal, or over a cap) is exit 1 with the reason, no gh call
new_repo; fixtures; reset
printf '' > .gitignore
upload 7
assert_eq "1" "$RC" "collect refuses: upload exits 1"
assert_contains "$(err)" "collect failed (rc=1): evidence-collect refused: dir is not ignored" "collect refuses: the one-line reason"
assert_eq "" "$(gh_log)" "collect refuses: no gh call"
new_repo; fixtures; reset
printf '{"evidence": {"dir": "ev", "max_files": 2}}\n' > talos.pipeline.json
upload 7
assert_eq "1" "$RC" "collect over-cap: upload exits 1"
assert_contains "$(err)" "collect failed (rc=4)" "collect over-cap: names rc=4"
assert_eq "" "$(gh_log)" "collect over-cap: no gh call"
assert_eq "0" "$(stage_dirs)" "collect over-cap: staging dir removed"

# =============================================================================
# the staged copy is what gh sees, whatever happens to the evidence dir
# =============================================================================
new_repo; reset
png ev/a.png "judged-bytes"
printf 'TOP-SECRET' > "$SANDBOX/secret.png"
ln -s "$SANDBOX/secret.png" ev/link.png
upload 7
assert_eq "0" "$RC" "symlink in the evidence dir: exit 0"
assert_contains "$(out)" "images=1 videos=0" "symlink in the evidence dir: only the regular file is attached"
assert_not_contains "$(gh_log)" "link.png" "symlink in the evidence dir: never reaches gh"

# =============================================================================
# the staged tree is re-checked: a doctored collect result is refused, with no
# gh call. Runs against a COPY of the scripts whose `collect` also prints
# (and plants) what FAKE_PLANT says.
# =============================================================================
FS="$SANDBOX/fakescripts"
cp -R "$TALOS_ROOT/scripts" "$FS"
python3 -I - "$FS/pipeline-evidence.sh" <<'TALOS_PATCH_Hs3Kq8Xv2Lm'
import sys
p = sys.argv[1]
s = open(p).read()
target = '  collect) shift; cmd_collect "$@" ;;\n'
assert s.count(target) == 1, "dispatch line not found"
patch = (
    '  collect) shift; cmd_collect "$@"; _frc=$?; _st=""; _p=""\n'
    '    for _a in "$@"; do [ "$_p" = --stage ] && _st="$_a"; _p="$_a"; done\n'
    '    eval "${FAKE_PLANT:-:}"; exit $_frc ;;\n'
)
open(p, "w").write(s.replace(target, patch))
TALOS_PATCH_Hs3Kq8Xv2Lm
refused_upload() {  # refused_upload <label> <reason> <plant-snippet>
  new_repo; reset; png ev/a.png "real"
  SANDBOX="$SANDBOX" FAKE_PLANT="$3" bash "$FS/pipeline-evidence.sh" upload 7 >"$OUT" 2>"$ERR"; RC=$?
  assert_eq "1" "$RC" "re-check [$1]: exit 1"
  assert_contains "$(err)" "evidence-upload refused: $2" "re-check [$1]: names the reason"
  assert_eq "" "$(gh_log)" "re-check [$1]: no gh call"
  assert_eq "[]" "$(cat "$STUB_COMMENT_STORE")" "re-check [$1]: nothing posted"
  assert_eq "0" "$(stage_dirs)" "re-check [$1]: staging dir removed"
}
refused_upload "leading dash" "unsafe name" 'cp "$_st/a.png" "$_st/-rf.png"; printf -- "-rf.png\t5\timage\n"'
refused_upload "dot dot" "unsafe name" 'printf -- "../x.png\t5\timage\n"'
refused_upload "hidden name" "unsafe name" 'cp "$_st/a.png" "$_st/.h.png"; printf -- ".h.png\t5\timage\n"'
refused_upload "symlink in stage" "symlink in the staged tree" 'ln -s "$SANDBOX/secret.png" "$_st/link.png"; printf "link.png\t5\timage\n"'
refused_upload "svg extension" "extension does not match" 'cp "$_st/a.png" "$_st/x.svg"; printf "x.svg\t5\timage\n"'
refused_upload "kind mismatch" "extension does not match" 'cp "$_st/a.png" "$_st/b.png"; printf "b.png\t5\tvideo\n"'
refused_upload "missing staged file" "staged file is missing" 'printf "gone.png\t5\timage\n"'
refused_upload "duplicate row" "duplicate path" 'printf "a.png\t5\timage\n"'
refused_upload "too many files" "expected 1-50" 'for i in $(seq 1 51); do cp "$_st/a.png" "$_st/f$i.png"; printf "f%s.png\t5\timage\n" "$i"; done'
refused_upload "empty staged file" "empty or over" ': > "$_st/e.png"; printf "e.png\t0\timage\n"'
refused_upload "malformed row" "malformed manifest row" 'printf "just-one-column\n"'

# a clean pass through the same patched copy still works (the harness itself is sound)
new_repo; reset; png ev/a.png "real"
bash "$FS/pipeline-evidence.sh" upload 7 >"$OUT" 2>"$ERR"; RC=$?
assert_eq "0" "$RC" "patched copy without a plant: exit 0"

finish
