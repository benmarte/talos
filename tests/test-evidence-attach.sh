#!/usr/bin/env bash
# test-evidence-attach.sh -- covers issue #409 (sub-task of epic #352):
# scripts/pipeline-evidence.sh `attach <pr>` is the one call a stage makes:
# gate (evidence.enabled, provider), then capture, then upload, then ONE status
# line `evidence-attach pr=<n> status=<posted|empty|over-cap|refused|failed> ...`.
# `dir` prints the configured-or-default evidence dir.
# Everything runs against tests/stubs/gh (put first on PATH): no real GitHub
# call, no real `gh pr comment --attach`, never a post to a real PR.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

EV="$TALOS_ROOT/scripts/pipeline-evidence.sh"
assert_file_exists "$EV" "pipeline-evidence.sh exists"

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
PNG_MAGIC='\211PNG\r\n\032\n'
mk() { mkdir -p "$(dirname "$1")"; { printf "$2"; printf '%s' "${3:-body}"; } > "$1"; }
png()  { mk "$1" "$PNG_MAGIC" "${2:-pixels}"; }
webm() { mk "$1" '\032\105\337\243\102\202\204webm' "${2:-video}"; }
setm() { python3 -I -c 'import os,sys; t=float(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
fixtures() { png ev/shot-a.png "alpha"; png ev/shot-b.png "bravo"; webm ev/0-run.webm "clip"; }

# The command-mode capture script: writes 2 PNG + 1 WEBM into ev/ (run through
# `bash -c "bash <this>"` at the worktree toplevel). Lives outside the repo.
MKEV="$SANDBOX/mkev.sh"
cat > "$MKEV" <<'TALOS_MKEV_Bq7Nw3Yd9Kc'
mkdir -p ev
printf '\211PNG\r\n\032\nalpha' > ev/shot-a.png
printf '\211PNG\r\n\032\nbravo' > ev/shot-b.png
printf '\032\105\337\243\102\202\204webmclip' > ev/0-run.webm
TALOS_MKEV_Bq7Nw3Yd9Kc

DEFAULT_CFG='{"evidence": {"enabled": true, "dir": "ev"}}'
# new_repo [<config-json>] -- a fresh repo whose config has attach enabled.
new_repo() {
  REPO="$(mktemp -d "$SANDBOX/repo.XXXXXX")"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.name "talos test"
  git -C "$REPO" config user.email "test@talos.invalid"
  printf 'ev/\n' > "$REPO/.gitignore"
  git -C "$REPO" add .gitignore
  git -C "$REPO" commit -q -m init
  mkdir -p "$REPO/ev"
  printf '%s\n' "${1:-$DEFAULT_CFG}" > "$REPO/talos.pipeline.json"
  cd "$REPO" || exit 1
}
cfgjson() { printf '%s\n' "$1" > talos.pipeline.json; }
reset() {
  : > "$GH_LOG"; : > "$CURL_LOG"; : > "$GH_STDIN_LOG"; : > "$STUB_ATTACH_LOG"
  printf '[]' > "$STUB_COMMENT_STORE"
  unset STUB_CURRENT_USER_FAIL STUB_GH_API_FAIL STUB_ATTACH_FAIL STUB_ATTACH_PARTIAL \
        STUB_COMMENT_DELETE_FAIL STUB_GH_ATTACH STUB_GH_VERSION STUB_PR_TITLE STUB_ISSUE_TITLE
  export STUB_CURRENT_USER="talosbot"
}
attach() { bash "$EV" attach "$@" >"$OUT" 2>"$ERR"; RC=$?; }
out() { cat "$OUT"; }
err() { cat "$ERR"; }
gh_log() { cat "$GH_LOG"; }
posts() { grep -c -- '--body-file' "$GH_LOG" || true; }
lines() { wc -l < "$1" | tr -d ' '; }
all_ids() { python3 -I -c 'import json,sys; print(" ".join(str(c["id"]) for c in json.load(open(sys.argv[1]))))' "$STUB_COMMENT_STORE"; }
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
OLD_BODY="$(printf '### Evidence\n\nold\n\n%s\n' "$MARKER")"
URL1="https://github.com/acme/widget/pull/7#issuecomment-5001"

# =============================================================================
# usage: exit 2, nothing called
# =============================================================================
new_repo; fixtures; reset
attach;                       assert_eq "2" "$RC" "usage: no PR -> exit 2"
attach 12a;                   assert_eq "2" "$RC" "usage: non-digit PR -> exit 2"
attach '7;touch pwned';       assert_eq "2" "$RC" "usage: shell text as the PR -> exit 2"
attach 7 8;                   assert_eq "2" "$RC" "usage: two PRs -> exit 2"
attach 7 --bogus;             assert_eq "2" "$RC" "usage: unknown flag -> exit 2"
attach 7 --since;             assert_eq "2" "$RC" "usage: --since without a value -> exit 2"
attach 7 --since abc;         assert_eq "2" "$RC" "usage: --since abc -> exit 2"
attach 7 --since '1;touch pwned'; assert_eq "2" "$RC" "usage: shell text as --since -> exit 2"
assert_eq "" "$(out)" "usage: empty stdout"
assert_eq "" "$(gh_log)" "usage: no gh call"
assert_file_absent "$REPO/pwned" "usage: shell text did not run"
bash "$EV" dir extra >/dev/null 2>&1; assert_eq "2" "$?" "usage: dir takes no argument"
bash "$EV" bogus >/dev/null 2>&1;     assert_eq "2" "$?" "usage: unknown subcommand"

# =============================================================================
# gate first: disabled or absent -> exit 2, empty stdout, nothing ran
# =============================================================================
SENTINEL_CMD='touch SENTINEL'
for cfgtxt in \
  "{\"evidence\": {\"enabled\": false, \"dir\": \"ev\", \"command\": \"$SENTINEL_CMD\"}}" \
  "{\"evidence\": {\"dir\": \"ev\", \"command\": \"$SENTINEL_CMD\"}}" \
  "{\"evidence\": {\"enabled\": \"yes\", \"dir\": \"ev\", \"command\": \"$SENTINEL_CMD\"}}" \
  "{}"; do
  new_repo "$cfgtxt"; fixtures; reset
  attach 7
  assert_eq "2" "$RC" "gate [$cfgtxt]: exit 2"
  assert_eq "" "$(out)" "gate: empty stdout"
  assert_contains "$(err)" "evidence-attach: evidence disabled" "gate: says so on stderr"
  assert_eq "" "$(gh_log)" "gate: zero gh calls"
  assert_eq "" "$(cat "$CURL_LOG")" "gate: zero curl calls"
  assert_file_absent "$REPO/SENTINEL" "gate: evidence.command did not run"
  attach 7 --dry-run
  assert_eq "2" "$RC" "gate: --dry-run is gated too"
done

# =============================================================================
# provider second, still before capture
# =============================================================================
for prov in gitlab azure file; do
  new_repo "{\"vcs\": {\"provider\": \"$prov\"}, \"evidence\": {\"enabled\": true, \"dir\": \"ev\", \"command\": \"$SENTINEL_CMD\"}}"
  fixtures; reset
  attach 7
  assert_eq "2" "$RC" "provider $prov: exit 2"
  assert_eq "" "$(out)" "provider $prov: empty stdout"
  assert_contains "$(err)" "not implemented for provider '$prov'" "provider $prov: says so"
  assert_eq "" "$(gh_log)" "provider $prov: no gh call"
  assert_file_absent "$REPO/SENTINEL" "provider $prov: evidence.command did not run"
done

# github-api without a gh binary: exit 2, nothing ran. With gh it goes on.
NOGH="$SANDBOX/nogh-bin"; mkdir -p "$NOGH"
for t in bash git python3 dirname basename cat sed grep awk tr head tail mktemp rm mkdir cut sort wc env date uname ls find id readlink cp mv ln chmod tee xargs seq; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$NOGH/$t"
done
new_repo "{\"vcs\": {\"provider\": \"github-api\"}, \"evidence\": {\"enabled\": true, \"dir\": \"ev\", \"command\": \"$SENTINEL_CMD; bash $MKEV\"}}"
reset
PATH="$NOGH" bash "$EV" attach 7 >"$OUT" 2>"$ERR"; RC=$?
assert_eq "2" "$RC" "github-api without gh: exit 2"
assert_eq "" "$(out)" "github-api without gh: empty stdout"
assert_contains "$(err)" "no gh binary" "github-api without gh: says why"
assert_file_absent "$REPO/SENTINEL" "github-api without gh: evidence.command did not run"
attach 7
assert_contains "$(gh_log)" "pr comment --help" "github-api with gh: gets past the gate and the provider check to upload"
assert_contains "$(out)" "evidence-attach pr=7 status=" "github-api with gh: prints the status line"

# =============================================================================
# command mode: capture writes 2 PNG + 1 WEBM, one --attach post, one line
# =============================================================================
new_repo "{\"evidence\": {\"enabled\": true, \"dir\": \"ev\", \"command\": \"bash $MKEV\"}}"
reset
png ev/stale.png "from an earlier capture"; setm ev/stale.png 1000
attach 7
assert_eq "0" "$RC" "command mode: exit 0"
assert_eq "evidence-attach pr=7 status=posted images=2 videos=1 capture=0 comment=$URL1" "$(out)" "command mode: the one status line"
assert_eq "1" "$(lines "$OUT")" "command mode: exactly one stdout line"
assert_eq "1" "$(posts)" "command mode: one post"
assert_eq "pr comment 7 --repo acme/widget --body-file - --attach ./shot-a.png --attach ./shot-b.png --attach ./0-run.webm" "$(grep -- '--body-file' "$GH_LOG")" "command mode: one --attach per file"
assert_not_contains "$(gh_log)" "stale.png" "command mode: since= comes from capture, the stale file never reaches gh"
assert_eq "5001" "$(all_ids)" "command mode: one evidence comment"
assert_not_contains "$(gh_log)" "edit-last" "command mode: --edit-last never used"

# a second run replaces the first: still one comment, still posted
attach 7
assert_contains "$(out)" "status=posted images=2 videos=1 capture=0 comment=https://github.com/acme/widget/pull/7#issuecomment-5002" "second run: posted"
assert_eq "5002" "$(all_ids)" "second run: the older evidence comment was deleted"

# =============================================================================
# agent mode: no evidence.command, --since from the caller
# =============================================================================
new_repo; reset
png ev/old.png "stale"; png ev/new.png "fresh"
setm ev/old.png 1000; setm ev/new.png 2000000000
attach 7 --since 1500000000
assert_eq "0" "$RC" "agent mode: exit 0"
assert_eq "evidence-attach pr=7 status=posted images=1 videos=0 capture=agent comment=$URL1" "$(out)" "agent mode: capture=agent, one file"
assert_contains "$(gh_log)" "--attach ./new.png" "agent mode: the fresh file is attached"
assert_not_contains "$(gh_log)" "old.png" "agent mode: the file older than --since never reaches gh"
# without --since both files are attached
new_repo; reset
png ev/old.png "stale"; png ev/new.png "fresh"; setm ev/old.png 1000
attach 7
assert_contains "$(out)" "images=2 videos=0 capture=agent" "agent mode without --since: both files"

# =============================================================================
# empty: nothing to attach -> status=empty, exit 0, no gh call, no comment
# =============================================================================
new_repo; reset
attach 7
assert_eq "0" "$RC" "empty: exit 0"
assert_eq "evidence-attach pr=7 status=empty images=0 videos=0 capture=agent comment=" "$(out)" "empty: the status line"
assert_eq "" "$(gh_log)" "empty: no gh call, so no status-only comment"

# =============================================================================
# over-cap: status=over-cap, exit 0, numbers on stderr, nothing posted
# =============================================================================
new_repo '{"evidence": {"enabled": true, "dir": "ev", "max_files": 2}}'; fixtures; reset
attach 7
assert_eq "0" "$RC" "over-cap: exit 0"
assert_eq "evidence-attach pr=7 status=over-cap images=0 videos=0 capture=agent comment=" "$(out)" "over-cap: the status line"
assert_contains "$(err)" "evidence-collect over-cap files=3/2" "over-cap: upload's stderr is forwarded untouched"
assert_eq "" "$(gh_log)" "over-cap: no gh call (no status-only comment)"

# =============================================================================
# refused: collect refuses (dir not ignored) -> status=refused, exit 1
# =============================================================================
new_repo; fixtures; reset
printf '' > .gitignore
attach 7
assert_eq "1" "$RC" "refused: exit 1"
assert_eq "evidence-attach pr=7 status=refused images=0 videos=0 capture=agent comment=" "$(out)" "refused: the status line"
assert_contains "$(err)" "evidence-collect refused: dir is not ignored" "refused: the reason is forwarded"
assert_eq "" "$(gh_log)" "refused: no gh call"

# =============================================================================
# failed: gh post fails -> status=failed, exit 1, no URL
# =============================================================================
new_repo; fixtures; reset
seed 4002 talosbot "$OLD_BODY"
export STUB_ATTACH_FAIL=1
attach 7
assert_eq "1" "$RC" "failed: exit 1"
assert_eq "evidence-attach pr=7 status=failed images=0 videos=0 capture=agent comment=" "$(out)" "failed: the status line, empty comment="
assert_contains "$(err)" "gh pr comment failed" "failed: upload's reason is forwarded"
assert_eq "4002" "$(all_ids)" "failed: the older evidence comment is kept"
unset STUB_ATTACH_FAIL
# a login that cannot be resolved is a failure too (not over-cap, not refused)
reset
export STUB_CURRENT_USER_FAIL=1
attach 7
assert_eq "1" "$RC" "failed (login): exit 1"
assert_contains "$(out)" "status=failed" "failed (login): status=failed"
unset STUB_CURRENT_USER_FAIL

# =============================================================================
# post ok, delete fails -> posted with the URL, exit 0, warning on stderr
# =============================================================================
new_repo; fixtures; reset
seed 4002 talosbot "$OLD_BODY"
export STUB_COMMENT_DELETE_FAIL=1
attach 7
assert_eq "0" "$RC" "delete fails: exit 0 (the post succeeded)"
assert_eq "evidence-attach pr=7 status=posted images=2 videos=1 capture=agent comment=$URL1" "$(out)" "delete fails: posted, with the new URL"
assert_contains "$(err)" "4002" "delete fails: the warning names the undeleted comment id"
assert_contains "$(err)" "could not delete" "delete fails: the warning is forwarded"
unset STUB_COMMENT_DELETE_FAIL

# =============================================================================
# gh without --attach: exit 2, empty stdout, no post
# =============================================================================
new_repo; fixtures; reset
export STUB_GH_ATTACH=0 STUB_GH_VERSION='gh version 2.94.0 (stub)'
attach 7
assert_eq "2" "$RC" "no --attach: exit 2"
assert_eq "" "$(out)" "no --attach: empty stdout"
assert_contains "$(err)" "gh 2.94.0 has no --attach" "no --attach: upload's message is forwarded"
assert_eq "0" "$(posts)" "no --attach: nothing posted"
unset STUB_GH_ATTACH STUB_GH_VERSION

# =============================================================================
# a capture that times out (rc 124) still uploads and reports capture=124
# =============================================================================
new_repo "{\"verify\": {\"timeout_ms\": 1000}, \"evidence\": {\"enabled\": true, \"dir\": \"ev\", \"command\": \"bash $MKEV; sleep 30\"}}"
reset
attach 7
assert_eq "0" "$RC" "capture timeout: exit 0"
assert_eq "evidence-attach pr=7 status=posted images=2 videos=1 capture=124 comment=$URL1" "$(out)" "capture timeout: still uploads, capture=124"
assert_contains "$(err)" "evidence.command exited 124" "capture timeout: one stderr note"
# a plain non-zero rc too
new_repo "{\"evidence\": {\"enabled\": true, \"dir\": \"ev\", \"command\": \"bash $MKEV; exit 3\"}}"
reset
attach 7
assert_contains "$(out)" "status=posted images=2 videos=1 capture=3" "capture rc 3: still uploads, capture=3"

# =============================================================================
# --dry-run: gate + provider, capture skipped, upload --dry-run, no gh call
# =============================================================================
new_repo "{\"evidence\": {\"enabled\": true, \"dir\": \"ev\", \"command\": \"$SENTINEL_CMD\"}}"
fixtures; reset
attach 7 --dry-run
assert_eq "0" "$RC" "dry-run: exit 0"
assert_eq "" "$(gh_log)" "dry-run: no gh call"
assert_file_absent "$REPO/SENTINEL" "dry-run: evidence.command did not run"
assert_contains "$(out)" "[dry-run] capture: skipped" "dry-run: capture is skipped"
assert_contains "$(out)" "caps: files<=10 mb<=20 per-file<=10 (dir: ev)" "dry-run: the caps line uses the shared defaults"
assert_contains "$(out)" "gh pr comment 7 --repo" "dry-run: plans the post"
assert_contains "$(out)" "--attach ./shot-a.png --attach ./shot-b.png --attach ./0-run.webm" "dry-run: the --attach list"
assert_not_contains "$(out)" "evidence-attach pr=" "dry-run: no status line"
assert_eq "[]" "$(cat "$STUB_COMMENT_STORE")" "dry-run: nothing posted"
new_repo; reset
attach 7 --dry-run
assert_eq "0" "$RC" "dry-run with nothing to attach: exit 0"
new_repo '{"evidence": {"enabled": true, "dir": "ev", "max_files": 1}}'; fixtures; reset
attach 7 --dry-run
assert_eq "0" "$RC" "dry-run over-cap: exit 0 like the real run"
new_repo; fixtures; reset
printf '' > .gitignore
attach 7 --dry-run
assert_eq "1" "$RC" "dry-run refused: exit 1 like the real run"

# =============================================================================
# the output carries no PR or issue text, and no file names
# =============================================================================
new_repo "{\"evidence\": {\"enabled\": true, \"dir\": \"ev\", \"command\": \"bash $MKEV\"}}"
reset
STUB_PR_TITLE='pwn $(touch PWNED) `id`' STUB_ISSUE_TITLE='Title $(touch PWNED2)' attach 7
assert_eq "0" "$RC" "hostile text: exit 0"
case "$(out)" in
  "evidence-attach pr=7 status=posted images=2 videos=1 capture=0 comment=https://github.com/"*"#issuecomment-"[0-9]*) pass "hostile text: the line is the fixed shape" ;;
  *) fail "hostile text: the line is the fixed shape" "$(out)" ;;
esac
assert_not_contains "$(out)$(err)" "pwn" "hostile text: PR title is not in the output"
assert_not_contains "$(out)" "shot-a" "hostile text: no file name in the status line"
assert_file_absent "$REPO/PWNED" "hostile text: nothing was evaluated"
assert_file_absent "$REPO/PWNED2" "hostile text: nothing was evaluated (issue)"
assert_not_contains "$(cat "$GH_STDIN_LOG")" "pwn" "hostile text: not in the comment body either"

# a plain gh failure is a failure, not an over-cap
new_repo; fixtures; reset
export STUB_ATTACH_FAIL=1
attach 7
assert_not_contains "$(out)" "over-cap" "mapping: a plain gh failure is not over-cap"
unset STUB_ATTACH_FAIL

# =============================================================================
# dir: the configured value, or the one default
# =============================================================================
new_repo '{}'
assert_eq ".talos/evidence" "$(bash "$EV" dir)" "dir: the default when unset"
bash "$EV" dir >/dev/null 2>&1; assert_eq "0" "$?" "dir: exit 0"
cfgjson '{"evidence": {"dir": "shots/out"}}'
assert_eq "shots/out" "$(bash "$EV" dir)" "dir: the configured value"
assert_eq "1" "$(bash "$EV" dir | wc -l | tr -d ' ')" "dir: one line"
cd "$REPO/ev" || exit 1
assert_eq "shots/out" "$(bash "$EV" dir)" "dir: the same from a subdirectory (toplevel config)"
cd "$REPO" || exit 1
# upload reads the same dir the helper reports (no private default in upload)
cfgjson '{}'
mkdir -p .talos/evidence; printf '.talos/\n' >> .gitignore
png .talos/evidence/d.png "default dir"
reset
bash "$EV" upload 7 >"$OUT" 2>"$ERR"; RC=$?
assert_eq "0" "$RC" "upload uses the default dir that dir prints: exit 0"
assert_contains "$(out)" "images=1" "upload uses the default dir that dir prints: one image"

finish
