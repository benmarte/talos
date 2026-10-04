#!/usr/bin/env bash
# test-status-file-assemble.sh -- unit tests for scripts/pipeline-status-file.sh
# (#344, sub-task 2 of epic #333): `init` and `assemble`.
#
# Contract:
#   init      creates status.file with both headings; a second run is
#             byte-identical; a file lacking a heading gets it appended.
#   assemble  folds <issue>-<pr>.md fragments from origin/<base> into the log
#             section: one entry per PR, newest first, capped, windowed
#             (rotation to <archive_dir>/YYYY-MM.md), fragments deleted in the
#             same commit, pushed with up to 3 attempts.
#   exit 1    bad path/heading config, listing failure, push failure after 3
#             attempts. Nothing pushed; the caller's checkout is untouched.
#
# Every assemble runs against a bare `origin` inside the sandbox (no network),
# the same fixture shape as test-changelog-assemble.sh. A second clone (WORK)
# plays the PRs that add fragments to the base.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

SF="$TALOS_ROOT/scripts/pipeline-status-file.sh"
export TALOS_STATUS_TODAY="2026-09-20"

git config user.email "test@talos.invalid"
git config user.name "talos-test"
git config commit.gpgsign false

PARENT="$(mktemp -d "${TMPDIR:-/tmp}/talos-sf-origin.XXXXXX")" || exit 1
UPSTREAM="$PARENT/upstream.git"
WORK="$PARENT/work"
OUTSIDE="$PARENT/outside"
mkdir -p "$OUTSIDE" || exit 1
trap 'rm -rf "$SANDBOX" "$PARENT"' EXIT

# rm_under <root> <path>...: rm -rf that can only act on paths strictly under
# <root>, which must be an existing directory (a checked mktemp -d). An empty
# root, a path outside it, or a ".." component is refused instead of removed
# (#448). rm_under_parent is the $PARENT case; the sandbox cwd uses $SANDBOX.
rm_under() {
  local root="$1" d
  shift
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "rm_under: refusing, root '$root' is not a directory" >&2; exit 1
  fi
  for d in "$@"; do
    case "$d" in
      "$root"/*) ;;
      *) echo "rm_under: refusing '$d' (not under $root)" >&2; exit 1 ;;
    esac
    case "$d" in
      */../*|*/..) echo "rm_under: refusing '$d' (.. component)" >&2; exit 1 ;;
    esac
    rm -rf "$d"
  done
}
rm_under_parent() { rm_under "$PARENT" "$@"; }
# Hermetic temp dir: every mktemp the script makes lands here, so the leak
# assertion at the end counts only this run's talos-status.* directories.
mkdir -p "$PARENT/tmp"
export TMPDIR="$PARENT/tmp"

echo "seed" > README.md
printf 'talos.pipeline.json\n' >> .git/info/exclude
git add README.md
git commit -q -m "seed"
git branch -M main

cfg_status() {  # $1 = extra JSON members for the status block (optional)
  printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main", "status": {"enabled": true%s}}\n' \
    "${1:+, $1}" > talos.pipeline.json
}

reset_fixture() {  # fresh bare origin holding only the seed commit, fresh WORK clone
  rm_under_parent "$UPSTREAM" "$WORK"
  # Nothing here may rely on ambient git config (init.defaultBranch, identity,
  # pull.rebase, commit.gpgsign): a CI runner has none, and a developer machine
  # with init.defaultBranch=main would hide the difference. So the bare origin's
  # HEAD is pointed at main explicitly (older git has no `init -b`) and the
  # clone names its branch.
  git init -q --bare "$UPSTREAM"
  git --git-dir="$UPSTREAM" symbolic-ref HEAD refs/heads/main
  git remote set-url origin "$UPSTREAM"
  git push -q -f origin main
  git fetch -q origin main
  git clone -q -b main "$UPSTREAM" "$WORK"
  git -C "$WORK" config user.email "pr@talos.invalid"
  git -C "$WORK" config user.name "pr-author"
  git -C "$WORK" config commit.gpgsign false
  git -C "$WORK" config pull.rebase false
}

wk_sync() {
  git -C "$WORK" fetch -q origin main && git -C "$WORK" checkout -q -B main origin/main
}

wk_add() {  # path content date  (commit one file on WORK with a fixed committer date)
  mkdir -p "$WORK/$(dirname "$1")"
  printf '%s\n' "$2" > "$WORK/$1"
  git -C "$WORK" add -- "$1"
  GIT_AUTHOR_DATE="$3T12:00:00" GIT_COMMITTER_DATE="$3T12:00:00" \
    git -C "$WORK" commit -q -m "add $1"
}

wk_push() { git -C "$WORK" push -q origin HEAD:main; }

ofetch() { git fetch -q origin main; }
oshow() { git show "origin/main:$1" 2>/dev/null; }
osha() { git rev-parse origin/main; }
nentries() { printf '%s\n' "$1" | grep -c '^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] PR #'; }
archive_entries() {  # total entries under status/archive on origin/main
  local f n=0
  for f in $(git ls-tree --name-only "origin/main:${1:-status/archive}" 2>/dev/null); do
    n=$((n + $(nentries "$(oshow "${1:-status/archive}/$f")")))
  done
  echo "$n"
}
run_sf() { bash "$SF" "$@" 2>&1; }
# Like run_sf, but INT and QUIT are reset to their defaults first: a test run in
# the background (run-tests.sh runs files in parallel) inherits them as ignored,
# and a signal that is ignored on entry cannot be trapped. exec keeps the
# command line `bash <script> <args>`.
run_sf_dfl() {
  python3 -I -c 'import os, signal, sys
for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGHUP, signal.SIGTERM):
    signal.signal(s, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' bash "$SF" "$@" 2>&1
}
wt_count() { git worktree list | wc -l | tr -d ' '; }
status_tmp_dirs() { ls -d "$PARENT"/tmp/talos-status.* 2>/dev/null | wc -l | tr -d ' '; }

# ── line 2 header ────────────────────────────────────────────────────────────
line2="$(sed -n 2p "$SF")"
assert_contains "$line2" "status file" "header: line 2 says it maintains the status file"
assert_contains "$line2" "not pipeline-status.sh" "header: line 2 says it is not pipeline-status.sh"
assert_contains "$line2" "Project board" "header: line 2 says pipeline-status.sh sets the board status"

# ── status.enabled gates assemble, not init ─────────────────────────────────
reset_fixture
wk_add docs/status.d/12-40.md "fragment text" 2026-09-10; wk_push; ofetch
before="$(osha)"
rm -f talos.pipeline.json
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "enabled: unset exits 0"
assert_contains "$out" "status.enabled is false" "enabled: unset prints the reason"
assert_eq "$before" "$(osha)" "enabled: unset makes no commit on origin/main"
printf '{"status": {"enabled": false}, "base_branch": "main"}\n' > talos.pipeline.json
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "enabled: false exits 0"
assert_contains "$out" "status.enabled is false" "enabled: false prints the reason"
ofetch
assert_eq "$before" "$(osha)" "enabled: false makes no commit on origin/main"
assert_contains "$(oshow docs/status.d/12-40.md)" "fragment text" "enabled: false leaves the fragment"
out="$(run_sf init)"; rc=$?
assert_eq "0" "$rc" "enabled: init ignores status.enabled"
assert_file_exists TALOS_STATUS.md "enabled: init created the file with the key false"
rm -f TALOS_STATUS.md

# ── init ─────────────────────────────────────────────────────────────────────
cfg_status
out="$(run_sf init)"; rc=$?
assert_eq "0" "$rc" "init: exits 0 in a repo without TALOS_STATUS.md"
body="$(cat TALOS_STATUS.md)"
assert_contains "$body" "## Resume here" "init: has the resume heading"
assert_contains "$body" "## Log" "init: has the log heading"
assert_contains "$body" "read this file and the repo's CLAUDE.md/AGENTS.md" "init: has the resume-with-any-LLM note"
assert_eq "# Project status" "$(sed -n 1p TALOS_STATUS.md)" "init: line 1 is a title"
sum1="$(cksum < TALOS_STATUS.md)"
out="$(run_sf init)"; rc=$?
assert_eq "0" "$rc" "init: second run exits 0"
assert_eq "$sum1" "$(cksum < TALOS_STATUS.md)" "init: second run leaves the file byte-identical"
rm -f TALOS_STATUS.md

mkdir -p docs
printf '# My tracker\n\nSome notes I wrote.\n' > docs/TRACKER.md
cfg_status '"file": "docs/TRACKER.md"'
out="$(run_sf init)"; rc=$?
assert_eq "0" "$rc" "init: existing file exits 0"
body="$(cat docs/TRACKER.md)"
assert_contains "$body" "Some notes I wrote." "init: existing content preserved"
assert_contains "$body" "## Resume here" "init: appended the missing resume heading"
assert_contains "$body" "## Log" "init: appended the missing log heading"
assert_eq "# My tracker" "$(sed -n 1p docs/TRACKER.md)" "init: existing first line untouched"
sum1="$(cksum < docs/TRACKER.md)"
run_sf init >/dev/null
assert_eq "$sum1" "$(cksum < docs/TRACKER.md)" "init: appended file is stable on a second run"
# only the log heading missing -> only that one is appended
printf '# T\n\n## Resume here\n\nmine\n' > docs/TRACKER.md
run_sf init >/dev/null
assert_eq "1" "$(grep -c '^## Resume here$' docs/TRACKER.md)" "init: an existing heading is not duplicated"
assert_eq "1" "$(grep -c '^## Log$' docs/TRACKER.md)" "init: the missing log heading is appended"
rm_under "$SANDBOX" "$SANDBOX/docs" "$SANDBOX/TALOS_STATUS.md"

# ── path / heading validation: every verb, nothing written ──────────────────
reset_fixture
wk_add docs/status.d/12-40.md "x" 2026-09-10; wk_push; ofetch
before="$(osha)"
git status --porcelain > "$PARENT/porcelain.before"
for key in file fragments_dir archive_dir; do
  for bad in '/etc/x' '../x' 'a/../b' '..' '-rf' './-rf' 'a/./-x/..' ':(top)x' ''; do
    cfg_status "\"$key\": \"$bad\""
    for verb in init assemble; do
      out="$(run_sf $verb)"; rc=$?
      label="validation: status.$key='$bad' $verb"
      assert_eq "1" "$rc" "$label exits 1"
      assert_contains "$out" "status.$key" "$label names the key"
    done
  done
  # newline and control characters
  cfg_status "\"$key\": \"a\\nb\""
  out="$(run_sf init)"; rc=$?
  assert_eq "1" "$rc" "validation: status.$key with a newline exits 1"
  assert_contains "$out" "status.$key" "validation: status.$key newline names the key"
done
ofetch
assert_eq "$before" "$(osha)" "validation: nothing was pushed"
git status --porcelain > "$PARENT/porcelain.after"
assert_eq "$(cat "$PARENT/porcelain.before")" "$(cat "$PARENT/porcelain.after")" "validation: nothing was written to the checkout"
assert_file_absent TALOS_STATUS.md "validation: no status file was created"
assert_file_absent status "validation: no archive dir was created"

for hkey in log_heading resume_heading; do
  cfg_status "\"$hkey\": \"## A\\n## B\""
  out="$(run_sf init)"; rc=$?
  assert_eq "1" "$rc" "validation: $hkey with a newline exits 1"
  assert_contains "$out" "status.$hkey" "validation: $hkey newline names the key"
done
cfg_status '"log_heading": "## Same", "resume_heading": "## Same"'
out="$(run_sf init)"; rc=$?
assert_eq "1" "$rc" "validation: identical headings exit 1"
assert_file_absent TALOS_STATUS.md "validation: identical headings write nothing"

# a symlink leaving the root is rejected (resolved-path check)
ln -s "$OUTSIDE" docs
cfg_status '"file": "docs/S.md"'
out="$(run_sf init)"; rc=$?
assert_eq "1" "$rc" "symlink: init through a symlink leaving the root exits 1"
assert_contains "$out" "status.file" "symlink: names the key"
assert_eq "0" "$(ls "$OUTSIDE" | wc -l | tr -d ' ')" "symlink: nothing written outside the root"
rm -f docs

# ── the three paths must be disjoint (#454) ─────────────────────────────────
# Equal or nested, and assemble would write the log into its own fragments or
# archive; every verb refuses before touching anything, naming both keys.
before_porcelain="$(git status --porcelain)"
overlap() {  # label file fragments_dir archive_dir key_a key_b
  local verb
  cfg_status "\"file\": \"$2\", \"fragments_dir\": \"$3\", \"archive_dir\": \"$4\""
  for verb in init assemble; do
    out="$(run_sf $verb)"; rc=$?
    assert_eq "1" "$rc" "overlap: $1 ($verb) exits 1"
    assert_contains "$out" "$5" "overlap: $1 ($verb) names $5"
    assert_contains "$out" "$6" "overlap: $1 ($verb) names $6"
  done
}
overlap "file = fragments_dir" S.md S.md docs/arch status.file status.fragments_dir
overlap "file = archive_dir" S.md docs/frag S.md status.file status.archive_dir
overlap "fragments_dir = archive_dir" S.md docs/d docs/d status.fragments_dir status.archive_dir
overlap "equal after normalisation" ./S.md docs/frag ./S.md/ status.file status.archive_dir
overlap "file inside fragments_dir" docs/status/S.md docs/status docs/arch status.file status.fragments_dir
overlap "file inside archive_dir" docs/arch/S.md docs/frag docs/arch status.file status.archive_dir
overlap "fragments_dir inside archive_dir" S.md docs/arch/frag docs/arch status.fragments_dir status.archive_dir
overlap "archive_dir inside fragments_dir" S.md docs/status docs/status/archive status.fragments_dir status.archive_dir
assert_eq "$before_porcelain" "$(git status --porcelain)" "overlap: nothing was written to the checkout"
assert_file_absent S.md "overlap: no status file was created"
# a shared string prefix is not nesting: docs/status and docs/status-archive are siblings
cfg_status '"file": "S.md", "fragments_dir": "docs/status", "archive_dir": "docs/status-archive"'
out="$(run_sf init)"; rc=$?
assert_eq "0" "$rc" "overlap: sibling directories that share a name prefix are accepted"
rm_under "$SANDBOX" "$SANDBOX/S.md"

# ── the 512 / 256 caps count bytes, not characters (#454) ───────────────────
# `é` is two bytes. In a UTF-8 locale ${#v} counted it once, so a 601-byte path
# and a 403-byte heading passed (and the path then died in an OSError).
UTF8_LOCALE="$(locale -a 2>/dev/null | grep -i -m1 -E '^(en_US|C)\.utf-?8$')"
e200="$(python3 -I -c 'print("é" * 200)')"
e100="$(python3 -I -c 'print("é" * 100)')"
e120="$(python3 -I -c 'print("é" * 120)')"
for key in file fragments_dir archive_dir; do
  cfg_status "\"$key\": \"$e200/$e100\""
  out="$(LC_ALL="${UTF8_LOCALE:-C}" run_sf init)"; rc=$?
  assert_eq "1" "$rc" "bytes: status.$key of 600 bytes (301 characters) exits 1"
  assert_contains "$out" "status.$key is longer than 512 bytes" "bytes: status.$key names the key and the byte cap"
  assert_not_contains "$out" "Traceback" "bytes: status.$key is refused before python sees it"
done
for hkey in log_heading resume_heading; do
  cfg_status "\"$hkey\": \"## $e200\""
  out="$(LC_ALL="${UTF8_LOCALE:-C}" run_sf init)"; rc=$?
  assert_eq "1" "$rc" "bytes: status.$hkey of 403 bytes (203 characters) exits 1"
  assert_contains "$out" "status.$hkey is longer than 256 bytes" "bytes: status.$hkey names the key and the byte cap"
done
cfg_status "\"log_heading\": \"## $e120\""
out="$(LC_ALL="${UTF8_LOCALE:-C}" run_sf init)"; rc=$?
assert_eq "0" "$rc" "bytes: a 243-byte multi-byte heading is under the cap and accepted"
rm_under "$SANDBOX" "$SANDBOX/TALOS_STATUS.md"

# ── a config that cannot be read is not "status.enabled is false" (#454) ────
reset_fixture
wk_add docs/status.d/12-40.md "unread config" 2026-09-10; wk_push; ofetch
before="$(osha)"
printf '{ not json\n' > talos.pipeline.json
for verb in assemble refresh; do
  out="$(run_sf $verb)"; rc=$?
  assert_eq "1" "$rc" "unreadable config: $verb exits 1"
  assert_contains "$out" "cannot read the config" "unreadable config: $verb says the config could not be read"
  assert_not_contains "$out" "status.enabled is false" "unreadable config: $verb does not claim status.enabled is false"
done
ofetch
assert_eq "$before" "$(osha)" "unreadable config: nothing was pushed"
assert_contains "$(oshow docs/status.d/12-40.md)" "unread config" "unreadable config: the fragment is left in place"
cfg_status

# ── assemble: no fragments, no --pr ─────────────────────────────────────────
reset_fixture
cfg_status
before="$(osha)"
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "nothing: exits 0"
assert_contains "$out" "nothing to assemble" "nothing: says so"
ofetch
assert_eq "$before" "$(osha)" "nothing: origin/main unchanged"
out="$(run_sf assemble --pr 5)"; rc=$?
assert_eq "1" "$rc" "args: --pr without --issue exits 1"
out="$(run_sf assemble --issue 5)"; rc=$?
assert_eq "1" "$rc" "args: --issue without --pr exits 1"
out="$(run_sf assemble --pr x --issue 5)"; rc=$?
assert_eq "1" "$rc" "args: a non-numeric --pr exits 1"

# ── assemble: two fragments ─────────────────────────────────────────────────
reset_fixture
wk_add docs/status.d/12-40.md "Added the thing for issue twelve." 2026-09-10
wk_add docs/status.d/13-41.md "Added the other thing for issue thirteen." 2026-09-12
wk_add docs/status.d/notes.txt "not a fragment" 2026-09-12
wk_add docs/status.d/1-2.txt "not a fragment either" 2026-09-12
wk_push
wt_before="$(wt_count)"
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "two: exits 0"
ofetch
st="$(oshow TALOS_STATUS.md)"
assert_eq "2" "$(nentries "$st")" "two: exactly two entries"
assert_eq "- 2026-09-12 PR #41 (#13): Added the other thing for issue thirteen." \
  "$(printf '%s\n' "$st" | grep '^- ' | sed -n 1p)" "two: newest first, entry shape"
assert_eq "- 2026-09-10 PR #40 (#12): Added the thing for issue twelve." \
  "$(printf '%s\n' "$st" | grep '^- ' | sed -n 2p)" "two: second entry shape"
assert_contains "$st" "## Resume here" "two: created from the init skeleton (resume heading)"
assert_contains "$st" "## Log" "two: created from the init skeleton (log heading)"
leftover="$(git ls-tree -r --name-only origin/main docs/status.d | tr '\n' ' ')"
assert_eq "docs/status.d/1-2.txt docs/status.d/notes.txt " "$leftover" "two: fragments deleted, non-matching files untouched"
assert_not_contains "$st" "not a fragment" "two: non-matching files are never folded in"
assert_eq "docs(status): assemble status log [skip ci]" "$(git log -1 --format=%s origin/main)" "two: commit subject"
assert_contains "$(git show --name-status --format= origin/main)" "TALOS_STATUS.md" "two: status file is in the commit"
assert_contains "$(git show --name-status --format= origin/main)" "D	docs/status.d/12-40.md" "two: fragment deleted in the same commit"
assert_eq "$wt_before" "$(wt_count)" "two: no worktree left behind"
assert_eq "" "$(git worktree list | grep talos-status)" "two: no talos-status worktree registered"

# a second run has nothing left
before="$(osha)"
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "two: second run exits 0"
assert_contains "$out" "nothing to assemble" "two: second run is a no-op"
ofetch
assert_eq "$before" "$(osha)" "two: second run does not commit"

# ── date: last commit touching the fragment ─────────────────────────────────
reset_fixture
wk_add docs/status.d/20-60.md "first draft" 2026-09-01
wk_add docs/status.d/20-60.md "final text" 2026-09-14
wk_add README.md "unrelated later commit" 2026-09-19
wk_push
run_sf assemble >/dev/null
ofetch
assert_contains "$(oshow TALOS_STATUS.md)" "- 2026-09-14 PR #60 (#20): final text" "date: committer date of the last commit touching the fragment"

# ── length cap ──────────────────────────────────────────────────────────────
reset_fixture
ten=""
for i in 1 2 3 4 5 6 7 8 9 10; do ten="$ten
line $i: $(printf 'x%.0s' $(seq 1 80))"; done
wk_add docs/status.d/30-70.md "${ten#?}" 2026-09-15
wk_add docs/status.d/31-71.md "$(printf 'y%.0s' $(seq 1 900))" 2026-09-15
wk_add docs/status.d/32-72.md "short and sweet" 2026-09-15
wk_push
run_sf assemble >/dev/null
ofetch
st="$(oshow TALOS_STATUS.md)"
for pr in 70 71; do
  entry="$(printf '%s\n' "$st" | awk -v p="PR #$pr " 'index($0,"- 2026")==1 && index($0,p) {on=1; print; next} on && /^  / {print; next} {on=0}')"
  lines="$(printf '%s\n' "$entry" | wc -l | tr -d ' ')"
  chars="$(printf '%s' "$entry" | python3 -c 'import sys; print(len(sys.stdin.read()))')"
  assert_eq "1" "$([ "$lines" -le 3 ] && echo 1 || echo 0)" "cap: PR #$pr entry is at most 3 lines ($lines)"
  assert_eq "1" "$([ "$chars" -le 400 ] && echo 1 || echo 0)" "cap: PR #$pr entry is at most 400 characters ($chars)"
  assert_eq "…" "$(printf '%s' "$entry" | python3 -c 'import sys; print(sys.stdin.read()[-1])')" "cap: PR #$pr entry ends in an ellipsis"
done
assert_contains "$st" "- 2026-09-15 PR #72 (#32): short and sweet" "cap: a short fragment is not truncated"
assert_not_contains "$(printf '%s\n' "$st" | grep 'PR #72 ')" "…" "cap: no ellipsis on a short fragment"

# ── untrusted fragment text ─────────────────────────────────────────────────
reset_fixture
forged="$(printf 'real text\n- 2026-01-01 PR #999 (#1): forged\n# Injected heading\n---\n## Log')"
wk_add docs/status.d/40-80.md "$forged" 2026-09-16
big="$(python3 -c "print('a' * 200000)")"
wk_add docs/status.d/41-81.md "$big" 2026-09-16
wk_add docs/status.d/42-82.md "$(printf 'bell\001 and esc\033[31m text')" 2026-09-16
wk_push
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "untrusted: exits 0"
ofetch
st="$(oshow TALOS_STATUS.md)"
assert_eq "3" "$(nentries "$st")" "untrusted: one entry per PR (a forged line forges nothing)"
assert_eq "0" "$(printf '%s\n' "$st" | grep -c '^- 2026-01-01')" "untrusted: no column-0 forged entry"
assert_eq "3" "$(printf '%s\n' "$st" | grep -c '^#')" "untrusted: only the title and the two headings start with #"
assert_eq "1" "$(printf '%s\n' "$st" | grep -c '^## Log$')" "untrusted: the log heading is not duplicated"
assert_eq "0" "$(printf '%s' "$st" | LC_ALL=C grep -c "$(printf '[\001\033]')")" "untrusted: control characters are stripped"

# ── one entry per PR (replace, not duplicate) ───────────────────────────────
reset_fixture
wk_add docs/status.d/13-41.md "first version" 2026-09-10
wk_add docs/status.d/14-4.md "pr four" 2026-09-10
wk_push
run_sf assemble >/dev/null
wk_sync
wk_add docs/status.d/13-41.md "second version" 2026-09-12
wk_push
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "replace: exits 0"
ofetch
st="$(oshow TALOS_STATUS.md)"
assert_eq "1" "$(printf '%s\n' "$st" | grep -c 'PR #41 ')" "replace: grep -c 'PR #41 ' prints 1"
assert_contains "$st" "second version" "replace: the entry holds the new text"
assert_not_contains "$st" "first version" "replace: the old text is gone"
assert_eq "1" "$(printf '%s\n' "$st" | grep -c 'PR #4 ')" "replace: PR #4 is a different key from PR #41"

# ── fallback ────────────────────────────────────────────────────────────────
reset_fixture
wk_add README.md "touch" 2026-09-01; wk_push
export STUB_PR_TITLE="fix: guard null session"
out="$(run_sf assemble --pr 50 --issue 20)"; rc=$?
assert_eq "0" "$rc" "fallback: exits 0"
ofetch
st="$(oshow TALOS_STATUS.md)"
assert_eq "- 2026-09-20 PR #50 (#20): fix: guard null session" "$(printf '%s\n' "$st" | grep '^- ')" "fallback: one entry from the PR title, dated today"
before="$(osha)"
out="$(run_sf assemble --pr 50 --issue 20)"; rc=$?
assert_eq "0" "$rc" "fallback: repeat exits 0"
ofetch
assert_eq "$before" "$(osha)" "fallback: repeat adds nothing"
assert_eq "1" "$(oshow TALOS_STATUS.md | grep -c 'PR #50 ')" "fallback: still exactly one entry"
# with the fragment present, its text is used and no fallback is written
wk_sync
wk_add docs/status.d/21-51.md "text from the fragment" 2026-09-18
wk_push
run_sf assemble --pr 51 --issue 21 >/dev/null
ofetch
st="$(oshow TALOS_STATUS.md)"
assert_eq "1" "$(printf '%s\n' "$st" | grep -c 'PR #51 ')" "fallback: fragment present gives one entry for the PR"
assert_contains "$st" "- 2026-09-18 PR #51 (#21): text from the fragment" "fallback: the fragment text is used"
assert_not_contains "$st" "guard null session (#21)" "fallback: no title entry for a PR with a fragment"
# an empty title reads as the text `merged`
STUB_PR_TITLE=" " run_sf assemble --pr 52 --issue 22 >/dev/null
ofetch
assert_contains "$(oshow TALOS_STATUS.md)" "- 2026-09-20 PR #52 (#22): merged" "fallback: an unreadable title reads as merged"
unset STUB_PR_TITLE

# ── rolling window, boundary, archive ───────────────────────────────────────
reset_fixture
cfg_status '"log_days": 30, "log_max": 50'
wk_add docs/status.d/1-101.md "age 29" 2026-08-22
wk_add docs/status.d/2-102.md "age 30 exactly" 2026-08-21
wk_add docs/status.d/3-103.md "age 31" 2026-08-20
wk_add docs/status.d/4-104.md "old july" 2026-07-04
wk_push
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "window: exits 0"
ofetch
st="$(oshow TALOS_STATUS.md)"
assert_contains "$st" "PR #101 " "window: age 29 kept"
assert_contains "$st" "PR #102 " "window: an entry exactly log_days old is kept"
assert_not_contains "$st" "PR #103 " "window: age 31 leaves the log"
assert_not_contains "$st" "PR #104 " "window: an old entry leaves the log"
assert_contains "$(oshow status/archive/2026-08.md)" "- 2026-08-20 PR #103 (#3): age 31" "window: archived under its own month (08)"
assert_contains "$(oshow status/archive/2026-07.md)" "- 2026-07-04 PR #104 (#4): old july" "window: archived under its own month (07)"
# an archived PR is not written again, and never duplicated
wk_sync
wk_add docs/status.d/3-103.md "age 31 again" 2026-08-20
wk_push
run_sf assemble >/dev/null
ofetch
assert_eq "1" "$(oshow status/archive/2026-08.md | grep -c 'PR #103 ')" "window: an entry already archived is not duplicated"
assert_not_contains "$(oshow TALOS_STATUS.md)" "PR #103 " "window: a re-assembled archived PR does not return to the log"
assert_eq "" "$(git ls-tree --name-only origin/main docs/status.d/ | grep 103)" "window: that fragment was still consumed"
# fallback does not re-add a PR that only lives in the archive
out="$(run_sf assemble --pr 104 --issue 4)"; rc=$?
assert_eq "0" "$rc" "window: fallback for an archived PR exits 0"
ofetch
assert_not_contains "$(oshow TALOS_STATUS.md)" "PR #104 " "window: fallback does not re-add an archived PR"

# log_max binds before log_days
reset_fixture
cfg_status '"log_days": 30, "log_max": 2'
wk_add docs/status.d/1-111.md "a" 2026-09-10
wk_add docs/status.d/2-112.md "b" 2026-09-11
wk_add docs/status.d/3-113.md "c" 2026-09-12
wk_push
run_sf assemble >/dev/null
ofetch
st="$(oshow TALOS_STATUS.md)"
assert_eq "2" "$(nentries "$st")" "log_max: the log keeps at most log_max entries"
assert_contains "$st" "PR #113 " "log_max: the newest is kept"
assert_not_contains "$st" "PR #111 " "log_max: the oldest rotates out"
assert_contains "$(oshow status/archive/2026-09.md)" "PR #111 " "log_max: the rotated entry is in the archive"
# a custom archive dir
reset_fixture
cfg_status '"log_max": 1, "archive_dir": "history/old"'
wk_add docs/status.d/1-121.md "a" 2026-09-10
wk_add docs/status.d/2-122.md "b" 2026-09-11
wk_push
run_sf assemble >/dev/null
ofetch
assert_contains "$(oshow history/old/2026-09.md)" "PR #121 " "archive_dir: honoured"

# ── 100-PR case ─────────────────────────────────────────────────────────────
reset_fixture
cfg_status
dates="$(python3 - <<'EOF'
import datetime
t = datetime.date(2026, 9, 20)
for i in range(100):
    print((t - datetime.timedelta(days=int(i * 1.2))).isoformat())
EOF
)"
i=0
for d in $dates; do
  i=$((i + 1))
  mkdir -p "$WORK/docs/status.d"
  printf 'change %s\n' "$i" > "$WORK/docs/status.d/$i-$((1000 + i)).md"
  git -C "$WORK" add -- "docs/status.d/$i-$((1000 + i)).md"
  GIT_AUTHOR_DATE="${d}T12:00:00" GIT_COMMITTER_DATE="${d}T12:00:00" git -C "$WORK" commit -q -m "frag $i"
done
wk_push
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "100: exits 0"
ofetch
st="$(oshow TALOS_STATUS.md)"
n_log="$(nentries "$st")"
n_arch="$(archive_entries)"
assert_eq "1" "$([ "$n_log" -le 50 ] && [ "$n_log" -ge 1 ] && echo 1 || echo 0)" "100: at most 50 entries in the log ($n_log)"
assert_eq "100" "$((n_log + n_arch))" "100: log plus archive total exactly 100 ($n_log + $n_arch)"
oldest="$(printf '%s\n' "$st" | grep '^- 20' | tail -1 | cut -c3-12)"
assert_eq "1" "$([ "$oldest" \> "2026-08-20" ] && echo 1 || echo 0)" "100: no log entry is older than 30 days ($oldest)"
assert_eq "" "$(git ls-tree --name-only origin/main docs/status.d/ 2>/dev/null)" "100: every fragment was consumed"

# ── concurrent fragments merge without conflict ─────────────────────────────
reset_fixture
cfg_status
git -C "$WORK" checkout -q -b pr-a
wk_add docs/status.d/50-200.md "branch a" 2026-09-10
git -C "$WORK" checkout -q -b pr-b origin/main
wk_add docs/status.d/51-201.md "branch b" 2026-09-11
git -C "$WORK" checkout -q -B main origin/main
git -C "$WORK" merge -q --no-edit pr-a >/dev/null 2>&1; rc1=$?
git -C "$WORK" merge -q --no-edit pr-b >/dev/null 2>&1; rc2=$?
assert_eq "0" "$rc1" "concurrent: first merge exits 0"
assert_eq "0" "$rc2" "concurrent: second merge exits 0, no conflict"
wk_push
run_sf assemble >/dev/null
ofetch
assert_eq "2" "$(nentries "$(oshow TALOS_STATUS.md)")" "concurrent: assemble produces two entries"

# ── missing / partial status file on the base ───────────────────────────────
reset_fixture
cfg_status
wk_add docs/status.d/60-300.md "needs a file" 2026-09-10
wk_push
run_sf assemble >/dev/null
ofetch
st="$(oshow TALOS_STATUS.md)"
assert_contains "$st" "## Resume here" "missing file: created with the resume heading"
assert_contains "$st" "PR #300 " "missing file: created in the same commit as the entry"
assert_eq "TALOS_STATUS.md" "$(git show --name-only --format= origin/main -- TALOS_STATUS.md)" "missing file: added by the assemble commit"
reset_fixture
wk_add TALOS_STATUS.md "$(printf '# Mine\n\nhand written\n\n## Resume here\n\nstuff')" 2026-09-01
wk_add docs/status.d/61-301.md "text" 2026-09-10
wk_push
run_sf assemble >/dev/null
ofetch
st="$(oshow TALOS_STATUS.md)"
assert_contains "$st" "hand written" "partial file: existing content preserved"
assert_eq "1" "$(printf '%s\n' "$st" | grep -c '^## Log$')" "partial file: the missing log heading is appended"
assert_contains "$st" "PR #301 " "partial file: the entry lands under it"

# ── a listing that fails fails the verb ─────────────────────────────────────
reset_fixture
wk_add docs/status.d "i am a file, not a directory" 2026-09-10
wk_push; ofetch
before="$(osha)"
out="$(run_sf assemble)"; rc=$?
assert_eq "1" "$rc" "listing: a fragments dir that is not a directory fails the verb"
ofetch
assert_eq "$before" "$(osha)" "listing: nothing pushed"

# ── push race: refetch and retry, up to 3 attempts ──────────────────────────
install_race_hook() {  # $1 = number of pushes to race
  local state="$PARENT/hook-state"
  rm_under_parent "$state"; mkdir -p "$state"
  echo 0 > "$state/n"; echo "$1" > "$state/max"
  cat > "$UPSTREAM/hooks/pre-receive" <<EOF
#!/bin/sh
unset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES  # refs cannot move inside the quarantine
n=\$(cat "$state/n"); max=\$(cat "$state/max")
if [ "\$n" -lt "\$max" ]; then
  echo \$((n + 1)) > "$state/n"
  parent=\$(git rev-parse refs/heads/main)
  tree=\$(git rev-parse refs/heads/main^{tree})
  c=\$(GIT_AUTHOR_NAME=racer GIT_AUTHOR_EMAIL=r@x GIT_COMMITTER_NAME=racer GIT_COMMITTER_EMAIL=r@x git commit-tree -m "race \$n" -p "\$parent" "\$tree")
  git update-ref refs/heads/main "\$c"
fi
exit 0
EOF
  chmod +x "$UPSTREAM/hooks/pre-receive"
}

reset_fixture
cfg_status
wk_add docs/status.d/70-400.md "race me" 2026-09-10
wk_push; ofetch
install_race_hook 1
wt_before="$(wt_count)"
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "race once: exits 0 after a retry"
assert_eq "1" "$(cat "$PARENT/hook-state/n")" "race once: the hook raced exactly one push"
ofetch
assert_contains "$(oshow TALOS_STATUS.md)" "PR #400 " "race once: the entry landed on the new base"
assert_eq "1" "$(git log --format=%s origin/main | grep -c '^race 0$')" "race once: the racing commit is still in the history"
assert_eq "" "$(git ls-tree --name-only origin/main docs/status.d/ 2>/dev/null)" "race once: fragment consumed"
assert_eq "$wt_before" "$(wt_count)" "race once: no worktree left behind"

reset_fixture
wk_add docs/status.d/71-401.md "lose every race" 2026-09-10
wk_push; ofetch
install_race_hook 99
git status --porcelain > "$PARENT/porcelain.before"
out="$(run_sf assemble)"; rc=$?
assert_eq "1" "$rc" "race always: exits 1 after 3 attempts"
assert_eq "3" "$(cat "$PARENT/hook-state/n")" "race always: exactly 3 attempts were made"
assert_contains "$out" "3 attempts" "race always: says it gave up after 3 attempts"
ofetch
assert_contains "$(git ls-tree --name-only origin/main docs/status.d/)" "71-401.md" "race always: the fragment remains on the base"
assert_not_contains "$(oshow TALOS_STATUS.md)" "PR #401 " "race always: nothing was assembled on the base"
git status --porcelain > "$PARENT/porcelain.after"
assert_eq "$(cat "$PARENT/porcelain.before")" "$(cat "$PARENT/porcelain.after")" "race always: the caller's checkout is untouched (git status --porcelain unchanged)"
assert_eq "$wt_before" "$(wt_count)" "race always: no worktree left behind"
assert_eq "" "$(git worktree list | grep talos-status)" "race always: no talos-status worktree registered"

# ── F1: the status commit stages only what assemble wrote ───────────────────
changed_files() { git diff --name-only origin/main~1 origin/main | LC_ALL=C sort | tr '\n' ' '; }

# (a) a fresh checkout that is already dirty (line-ending drift) is not swept in
reset_fixture
cfg_status
printf 'a\r\nb\r\n' > "$WORK/x.dat"
git -C "$WORK" add x.dat
git -C "$WORK" commit -q -m "crlf blob"
printf '*.dat text eol=lf\n' > "$WORK/.gitattributes"
git -C "$WORK" add .gitattributes
git -C "$WORK" commit -q -m "attributes"
wk_add docs/status.d/80-500.md "dirty tree" 2026-09-10
wk_push
git clone -q -b main "$UPSTREAM" "$PARENT/probe"
assert_contains "$(git -C "$PARENT/probe" status --porcelain)" "x.dat" "stage (a): precondition, a fresh checkout of the base is dirty"
rm_under_parent "$PARENT/probe"
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "stage (a): exits 0"
ofetch
assert_eq "TALOS_STATUS.md docs/status.d/80-500.md " "$(changed_files)" "stage (a): the commit holds only the status file and the fragment deletion"
assert_eq "$(printf 'a\r\nb\r\n' | cksum)" "$(git show origin/main:x.dat | cksum)" "stage (a): the unrelated dirty file is untouched on the base"

# (b) status.file is a symlink to another tracked file: refused, nothing written
reset_fixture
cfg_status
mkdir -p "$WORK/scripts"
printf '#!/bin/sh\necho deploy\n' > "$WORK/scripts/deploy.sh"
git -C "$WORK" add scripts/deploy.sh
git -C "$WORK" commit -q -m "deploy script"
ln -s scripts/deploy.sh "$WORK/TALOS_STATUS.md"
git -C "$WORK" add TALOS_STATUS.md
git -C "$WORK" commit -q -m "status file is a symlink"
wk_add docs/status.d/81-501.md "must not land in deploy.sh" 2026-09-10
wk_push; ofetch
before="$(osha)"
out="$(run_sf assemble)"; rc=$?
assert_eq "1" "$rc" "stage (b): a symlinked status.file exits 1"
assert_contains "$out" "status.file" "stage (b): names the key"
ofetch
assert_eq "$before" "$(osha)" "stage (b): nothing pushed"
assert_not_contains "$(oshow scripts/deploy.sh)" "PR #" "stage (b): the symlink target is untouched"
assert_contains "$(git ls-tree --name-only origin/main docs/status.d/)" "81-501.md" "stage (b): the fragment remains"

# (b2) a symlinked directory component of status.file or status.archive_dir
reset_fixture
mkdir -p "$WORK/real"
echo keep > "$WORK/real/keep"
ln -s real "$WORK/link"
git -C "$WORK" add real link
git -C "$WORK" commit -q -m "a directory symlink inside the repo"
wk_add docs/status.d/82-502.md "x" 2026-09-10
wk_push; ofetch
before="$(osha)"
cfg_status '"file": "link/S.md"'
out="$(run_sf assemble)"; rc=$?
assert_eq "1" "$rc" "stage (b2): status.file under a symlinked directory exits 1"
assert_contains "$out" "status.file" "stage (b2): names status.file"
cfg_status '"archive_dir": "link/arch"'
out="$(run_sf assemble)"; rc=$?
assert_eq "1" "$rc" "stage (b2): status.archive_dir under a symlinked directory exits 1"
assert_contains "$out" "status.archive_dir" "stage (b2): names status.archive_dir"
cfg_status '"fragments_dir": "link/frags"'
out="$(run_sf assemble --pr 9 --issue 9)"; rc=$?
assert_eq "1" "$rc" "stage (b2): status.fragments_dir under a symlinked directory exits 1"
assert_contains "$out" "status.fragments_dir" "stage (b2): names status.fragments_dir"
ofetch
assert_eq "$before" "$(osha)" "stage (b2): nothing pushed"
assert_eq "0" "$(git ls-tree -r --name-only origin/main real | grep -c 'S.md\|arch')" "stage (b2): nothing written through the symlink"

# (c) a new status file and a new archive path that match .gitignore still land
reset_fixture
printf 'TALOS_STATUS.md\nstatus/\n' > "$WORK/.gitignore"
git -C "$WORK" add .gitignore
git -C "$WORK" commit -q -m "ignore the status paths"
cfg_status '"log_max": 1'
wk_add docs/status.d/83-503.md "older" 2026-09-10
wk_add docs/status.d/84-504.md "newer" 2026-09-11
wk_push; ofetch
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "stage (c): exits 0"
ofetch
assert_contains "$(oshow TALOS_STATUS.md)" "PR #504 " "stage (c): the ignored new status file was committed with its entry"
assert_contains "$(oshow status/archive/2026-09.md)" "PR #503 " "stage (c): the ignored new archive file was committed"
assert_eq "" "$(git ls-tree --name-only origin/main docs/status.d/)" "stage (c): fragments deleted in the same commit"

# ── F2: a base branch that looks like an option is refused ──────────────────
reset_fixture
wk_add docs/status.d/85-505.md "x" 2026-09-10
wk_push; ofetch
before="$(osha)"
for bb in "--upload-pack=touch $PARENT/pwned" "-x" "a b" "x..y" "x;y" "x/"; do
  printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "%s", "status": {"enabled": true}}\n' "$bb" > talos.pipeline.json
  out="$(run_sf assemble)"; rc=$?
  assert_eq "1" "$rc" "base branch '$bb': exits 1"
  assert_contains "$out" "base branch" "base branch '$bb': says why"
done
assert_file_absent "$PARENT/pwned" "base branch: --upload-pack was never run"
ofetch
assert_eq "$before" "$(osha)" "base branch: nothing pushed"

# ── F3: python runs isolated, a module in the cwd is never imported ─────────
reset_fixture
cfg_status
printf 'open("%s", "w").write("pwned")\n' "$PARENT/pwned-py" > unicodedata.py
out="$(run_sf init)"; rc=$?
assert_eq "0" "$rc" "isolated: init exits 0 with a hostile module in the cwd"
wk_add docs/status.d/86-506.md "x" 2026-09-10; wk_push
out="$(run_sf assemble --pr 87 --issue 7)"; rc=$?
assert_eq "0" "$rc" "isolated: assemble exits 0 with a hostile module in the cwd"
assert_file_absent "$PARENT/pwned-py" "isolated: the cwd module was never imported by this script's python"
rm -f unicodedata.py TALOS_STATUS.md
rm_under "$SANDBOX" "$SANDBOX/__pycache__"

# ── hand-edited log: odd digits, a huge number, a heading with trailing blanks
reset_fixture
cfg_status
printf '# Mine\n\n## Resume here\n\nr\n\n## Log   \n\nhand note\n- 2026-09-01 PR #\xd9\xa4\xd9\xa1 (#1): arabic-indic digits\n- 2026-09-02 PR #99999999999999999999999 (#1): huge number\n- 2026-09-03 PR #7 (#1): fine entry\n' > "$WORK/TALOS_STATUS.md"
git -C "$WORK" add TALOS_STATUS.md
GIT_AUTHOR_DATE="2026-09-03T12:00:00" GIT_COMMITTER_DATE="2026-09-03T12:00:00" git -C "$WORK" commit -q -m "hand-edited status file"
wk_add docs/status.d/88-508.md "new entry" 2026-09-10
wk_add docs/status.d/99999999999999999999-509.md "a fragment name with a huge issue number" 2026-09-10
wk_push; ofetch
out="$(run_sf assemble)"; rc=$?
assert_eq "0" "$rc" "hand-edited: exits 0, no crash"
ofetch
st="$(oshow TALOS_STATUS.md)"
assert_contains "$st" "hand note" "hand-edited: the hand-written line is preserved"
assert_contains "$st" "arabic-indic digits" "hand-edited: the non-ASCII-digit line is preserved, not parsed as an entry"
assert_contains "$st" "huge number" "hand-edited: the huge-number line is preserved"
assert_contains "$st" "- 2026-09-10 PR #508 (#88): new entry" "hand-edited: the new entry landed"
assert_eq "1" "$(printf '%s\n' "$st" | grep -c 'PR #7 ')" "hand-edited: the valid entry is keyed once"
assert_eq "1" "$(printf '%s\n' "$st" | grep -c '^## Log')" "hand-edited: the log heading was matched despite trailing blanks"

# ── SIGTERM mid-run: the trap removes the worktree and the script exits ────
# A PATH shim named git sends TERM to the status script when the push starts
# (the push runs inside a command substitution, so the script is the
# grandparent of the shim). The push starts after the temp worktree is created
# and committed in, so the signal always lands while the worktree exists. The
# shim proves it rather than assuming it: before signalling it records the
# target's command line and the worktree list, and the test asserts the target
# was the status script and that the list held the temp worktree.
reset_fixture
wk_add docs/status.d/72-402.md "interrupted" 2026-09-10
wk_push; ofetch
REAL_GIT="$(command -v git)"
SHIM="$PARENT/shim"
SIGLOG="$PARENT/signal.log"
mkdir -p "$SHIM"
: > "$SIGLOG"
cat > "$SHIM/git" <<EOF
#!/bin/sh
if [ "\$1" = "-C" ] && [ "\$3" = "push" ]; then
  # Walk up from the shim to the OUTERMOST process running the status script
  # (a command-substitution subshell shows the same command line, and how many
  # of them sit in between depends on the bash version).
  p="\$PPID"
  target=""
  n=0
  while [ \$n -lt 8 ] && [ -n "\$p" ] && [ "\$p" != 1 ]; do
    # Match the exact command line run_sf produces: a looser pattern could hit a
    # parent shell that merely mentions the script, and send it the signal.
    case "\$(ps -o command= -p "\$p")" in "bash $SF assemble") target="\$p" ;; esac
    p="\$(ps -o ppid= -p "\$p" | tr -d ' ')"
    n=\$((n + 1))
  done
  ps -o command= -p "\$target" > "$SIGLOG.target"
  "$REAL_GIT" worktree list > "$SIGLOG.worktrees"
  [ -n "\$target" ] && kill -TERM "\$target" && echo sent > "$SIGLOG"
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SHIM/git"
wt_before="$(wt_count)"
out="$(PATH="$SHIM:$PATH" run_sf_dfl assemble)"; rc=$?
assert_eq "sent" "$(cat "$SIGLOG")" "signal: the shim sent SIGTERM"
assert_contains "$(cat "$SIGLOG.target")" "pipeline-status-file.sh" "signal: the target was the status script"
assert_eq "$((wt_before + 1))" "$(wc -l < "$SIGLOG.worktrees" | tr -d ' ')" "signal: the temp worktree existed when the signal was sent"
assert_contains "$(cat "$SIGLOG.worktrees")" "/tmp/talos-status." "signal: that worktree is the script's temp worktree"
assert_eq "143" "$rc" "signal: SIGTERM exits 143"
assert_eq "$wt_before" "$(wt_count)" "signal: git worktree list shows only the caller's worktree afterwards"
assert_eq "" "$(git worktree list | grep talos-status)" "signal: no talos-status worktree registered afterwards"
assert_eq "0" "$(status_tmp_dirs)" "signal: the temp dir is removed"

# SIGHUP, SIGINT and SIGQUIT take the same cleanup path.
for sig in HUP INT QUIT; do
  # (the TERM run above let the push through, so each signal gets a new fragment)
  reset_fixture
  wk_add docs/status.d/73-403.md "interrupted again" 2026-09-10
  wk_push; ofetch
  : > "$SIGLOG"
  sed -i.bak "s/kill -TERM/kill -$sig/" "$SHIM/git" && rm -f "$SHIM/git.bak"
  case "$sig" in HUP) want=129 ;; INT) want=130 ;; QUIT) want=131 ;; esac
  out="$(PATH="$SHIM:$PATH" run_sf_dfl assemble)"; rc=$?
  assert_eq "sent" "$(cat "$SIGLOG")" "signal: the shim sent SIG$sig"
  assert_eq "$want" "$rc" "signal: SIG$sig exits $want"
  assert_eq "$wt_before" "$(wt_count)" "signal: SIG$sig leaves only the caller's worktree"
  assert_eq "0" "$(status_tmp_dirs)" "signal: SIG$sig removes the temp dir"
  sed -i.bak "s/kill -$sig/kill -TERM/" "$SHIM/git" && rm -f "$SHIM/git.bak"
done

# ── no leak across the whole file ───────────────────────────────────────────
assert_eq "0" "$(status_tmp_dirs)" "leak: no talos-status.* directory left in the test's TMPDIR after the whole file"

rm -f talos.pipeline.json
finish
