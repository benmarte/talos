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
make_sandbox
use_stubs

SF="$TALOS_ROOT/scripts/pipeline-status-file.sh"
export TALOS_STATUS_TODAY="2026-09-20"

git config user.email "test@talos.invalid"
git config user.name "talos-test"
git config commit.gpgsign false

PARENT="$(mktemp -d "${TMPDIR:-/tmp}/talos-sf-origin.XXXXXX")"
UPSTREAM="$PARENT/upstream.git"
WORK="$PARENT/work"
OUTSIDE="$PARENT/outside"
mkdir -p "$OUTSIDE"
trap 'rm -rf "$SANDBOX" "$PARENT"' EXIT

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
  rm -rf "$UPSTREAM" "$WORK"
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
wt_count() { git worktree list | wc -l | tr -d ' '; }

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
rm -rf docs TALOS_STATUS.md

# ── path / heading validation: every verb, nothing written ──────────────────
reset_fixture
wk_add docs/status.d/12-40.md "x" 2026-09-10; wk_push; ofetch
before="$(osha)"
git status --porcelain > "$PARENT/porcelain.before"
for key in file fragments_dir archive_dir; do
  for bad in '/etc/x' '../x' 'a/../b' '..' '-rf' ''; do
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
  rm -rf "$state"; mkdir -p "$state"
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
  target="\$(ps -o ppid= -p \$PPID | tr -d ' ')"
  ps -o command= -p "\$target" > "$SIGLOG.target"
  "$REAL_GIT" worktree list > "$SIGLOG.worktrees"
  kill -TERM "\$target"
  echo sent > "$SIGLOG"
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SHIM/git"
wt_before="$(wt_count)"
mkdir -p "$PARENT/tmp"
out="$(TMPDIR="$PARENT/tmp" PATH="$SHIM:$PATH" run_sf assemble)"; rc=$?
assert_eq "sent" "$(cat "$SIGLOG")" "signal: the shim sent SIGTERM"
assert_contains "$(cat "$SIGLOG.target")" "pipeline-status-file.sh" "signal: the target was the status script"
assert_eq "$((wt_before + 1))" "$(wc -l < "$SIGLOG.worktrees" | tr -d ' ')" "signal: the temp worktree existed when the signal was sent"
assert_contains "$(cat "$SIGLOG.worktrees")" "/tmp/talos-status." "signal: that worktree is the script's temp worktree"
assert_eq "143" "$rc" "signal: SIGTERM exits 143"
assert_eq "$wt_before" "$(wt_count)" "signal: git worktree list shows only the caller's worktree afterwards"
assert_eq "" "$(git worktree list | grep talos-status)" "signal: no talos-status worktree registered afterwards"
assert_eq "" "$(ls "$PARENT/tmp")" "signal: the temp dir is removed"

rm -f talos.pipeline.json
finish
