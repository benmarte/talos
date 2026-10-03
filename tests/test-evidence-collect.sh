#!/usr/bin/env bash
# test-evidence-collect.sh -- covers issue #406 (sub-task 2 of epic #352):
# scripts/pipeline-evidence.sh `capture` (runs evidence.command, never from
# argv, with a timeout it enforces itself) and `collect` (a manifest of the
# files that may leave the machine: allowlisted extensions, matching magic
# bytes, no symlinks / FIFOs / hard links, hardened names, size caps).
# Everything is local: stub command, throwaway repos, no gh, no network, no git
# writes.
#
# Decisions pinned here (the issue left them open):
#   - status lines (refusals, over-cap, none, the selected/skipped report) go
#     to stderr; stdout is the TSV manifest only, so a failing collect always
#     leaves an empty manifest.
#   - relpath in the manifest is relative to <dir>.
#   - an absolute <dir> is refused (the config key is relative).
#   - mov needs the `qt  ` brand, mp4 any other brand.
#   - the per-file cap is 10 MiB, max_mb is MiB.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

EV="$TALOS_ROOT/scripts/pipeline-evidence.sh"
assert_file_exists "$EV" "pipeline-evidence.sh exists"

# TMPDIR inside the scratch dir: the capture log lands here, never in the repo.
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
use_stubs   # gh/curl stubs first on PATH; their logs must stay empty (no network)

OUT="$SANDBOX/out.txt"
ERR="$SANDBOX/err.txt"
RC=0

# ---- helpers ----------------------------------------------------------------
# new_repo -- a fresh repo (ev/ ignored, one commit), cd into it; sets REPO.
new_repo() {
  REPO="$(mktemp -d "$SANDBOX/repo.XXXXXX")"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.name "talos test"
  git -C "$REPO" config user.email "test@talos.invalid"
  printf 'ev/\n' > "$REPO/.gitignore"
  git -C "$REPO" add .gitignore
  git -C "$REPO" commit -q -m init
  mkdir -p "$REPO/ev"
  cd "$REPO" || exit 1
}
set_cfg() { printf '%s\n' "$1" > "$REPO/talos.pipeline.json"; }
# cfg_ev <json-members> -- evidence block with dir "ev" plus the given members.
cfg_ev() { set_cfg "{\"evidence\": {\"dir\": \"ev\"${1:+, $1}}}"; }

PNG_MAGIC='\211PNG\r\n\032\n'
mk() {  # mk <path> <printf-format-bytes> [body]
  mkdir -p "$(dirname "$1")"
  { printf "$2"; printf '%s' "${3:-body}"; } > "$1"
}
png()  { mk "$1" "$PNG_MAGIC" "${2:-pixels}"; }
jpg()  { mk "$1" '\377\330\377\340' "${2:-pixels}"; }
gif()  { mk "$1" 'GIF89a' "${2:-pixels}"; }
webm() { mk "$1" '\032\105\337\243\102\202\204webm' "${2:-video}"; }
mkv()  { mk "$1" '\032\105\337\243\102\202\210matroska' "${2:-video}"; }
mp4()  { mk "$1" '\000\000\000\030ftypisom' "${2:-video}"; }
mov()  { mk "$1" '\000\000\000\024ftypqt  ' "${2:-video}"; }
setm() { python3 -I -c 'import os,sys; t=float(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
fsize() { wc -c < "$1" | tr -d ' '; }
# bigfile <path> <bytes> -- a PNG header padded with zeros to exactly <bytes>.
bigfile() {
  python3 -I -c '
import sys
n = int(sys.argv[2]); head = b"\x89PNG\r\n\x1a\n"
with open(sys.argv[1], "wb") as f:
    f.write(head); f.write(b"\0" * (n - len(head)))' "$1" "$2"
}
collect() { bash "$EV" collect "$@" >"$OUT" 2>"$ERR"; RC=$?; }
errlines() { wc -l < "$ERR" | tr -d ' '; }
out() { cat "$OUT"; }
err() { cat "$ERR"; }
# refused <label> <reason-fragment> -- last collect refused with exit 1: one
# line naming the reason, nothing on stdout.
refused() {
  assert_eq "1" "$RC" "$1: exit 1"
  assert_contains "$(err)" "evidence-collect refused: " "$1: refusal line"
  assert_contains "$(err)" "$2" "$1: names the reason ($2)"
  assert_eq "1" "$(errlines)" "$1: exactly one line"
  assert_eq "" "$(out)" "$1: empty manifest"
}
# listed <file-relpath-in-dir> -- 0 when the manifest names it as a first field.
listed() { cut -f1 "$OUT" | grep -qxF -- "$1"; }
tsv() {  # tsv <dir> <relpath> <kind> -- one expected manifest line
  printf '%s\t%s\t%s\n' "$2" "$(fsize "$1/$2")" "$3"
}

# =============================================================================
# capture
# =============================================================================
new_repo
cat > "$SANDBOX/stub-shots.sh" <<'TALOS_STUBSHOTS_x7Qm3vLd9Z'
mkdir -p ev
printf '\211PNG\r\n\032\nshot-one' > ev/b-shot.png
printf '\211PNG\r\n\032\nshot-two' > ev/a-shot.png
printf '\032\105\337\243\102\202\204webm\000video' > ev/run.webm
echo "stub stdout"; echo "stub stderr" >&2
pwd
TALOS_ISSUE_NUMBER="${TALOS_ISSUE_NUMBER:-unset}"; echo "issue=$TALOS_ISSUE_NUMBER"
TALOS_STUBSHOTS_x7Qm3vLd9Z
cfg_ev "\"command\": \"bash $SANDBOX/stub-shots.sh\""
BEFORE_T="$(date +%s)"
git status --porcelain > "$SANDBOX/status.before"
TALOS_ISSUE_NUMBER=406 bash "$EV" capture >"$OUT" 2>"$ERR"; RC=$?
AFTER_T="$(date +%s)"
assert_eq "0" "$RC" "capture: exit 0"
LINE="$(out)"
case "$LINE" in
  "evidence-capture rc=0 log=$TMPDIR/talos-evidence."*" since="*) pass "capture: one line, rc=0, log under TMPDIR" ;;
  *) fail "capture: line shape" "got: $LINE" ;;
esac
assert_eq "1" "$(wc -l < "$OUT" | tr -d ' ')" "capture: prints exactly one line"
LOG="${LINE#*log=}"; LOG="${LOG%% since=*}"
SINCE="${LINE##*since=}"
case "$SINCE" in ''|*[!0-9]*) fail "capture: since is an epoch" "got: $SINCE" ;;
  *) if [ "$SINCE" -ge "$BEFORE_T" ] && [ "$SINCE" -le "$AFTER_T" ]; then pass "capture: since is the start time"; else fail "capture: since is the start time" "since=$SINCE not in [$BEFORE_T,$AFTER_T]"; fi ;;
esac
assert_file_exists "$LOG" "capture: log file exists"
assert_contains "$(cat "$LOG")" "stub stdout" "capture: stdout goes to the log"
assert_contains "$(cat "$LOG")" "stub stderr" "capture: stderr goes to the log"
assert_contains "$(cat "$LOG")" "issue=406" "capture: caller identity env is inherited"
EXPECT_TOP="$(git rev-parse --show-toplevel)"
assert_contains "$(cat "$LOG")" "$EXPECT_TOP" "capture: runs in the worktree toplevel"
assert_eq "" "$(err)" "capture: stderr silent"
git status --porcelain > "$SANDBOX/status.after"
assert_eq "$(cat "$SANDBOX/status.before")" "$(cat "$SANDBOX/status.after")" "capture: the worktree gained no files (log is in TMPDIR)"
case "$LOG" in "$REPO"/*) fail "capture: log not in the worktree" "$LOG" ;; *) pass "capture: log not in the worktree" ;; esac

# end to end: capture then collect --since picks the 2 PNG + 1 WEBM, not a stale file
png ev/stale.png "old"; setm ev/stale.png $((SINCE - 100))
collect ev --since "$SINCE"
assert_eq "0" "$RC" "capture+collect: exit 0"
assert_eq "$(tsv ev a-shot.png image; tsv ev b-shot.png image; tsv ev run.webm video)" "$(out)" "capture+collect: 2 PNG + 1 WEBM, sorted TSV, stale file left out"

# capture from a subdirectory still runs at the toplevel
mkdir -p sub; cd sub || exit 1
bash "$EV" capture >"$OUT" 2>"$ERR"; RC=$?
LINE="$(out)"; LOG="${LINE#*log=}"; LOG="${LOG%% since=*}"
assert_eq "0" "$RC" "capture from a subdirectory: exit 0"
assert_contains "$(cat "$LOG")" "$EXPECT_TOP" "capture from a subdirectory: still runs at the toplevel"
cd "$REPO" || exit 1

# non-zero rc from the command: capture exits 0 and reports it
cfg_ev '"command": "echo oops; exit 7"'
bash "$EV" capture >"$OUT" 2>"$ERR"; RC=$?
assert_eq "0" "$RC" "capture: a failing command still exits 0 (evidence, not a gate)"
assert_contains "$(out)" "evidence-capture rc=7 log=" "capture: rc=7 reported in the line"

# empty / absent / blank command: agent mode, nothing runs, no log
for c in '"command": ""' '"command": "   "' ''; do
  cfg_ev "$c"
  LOGS_BEFORE="$(ls "$TMPDIR" | grep -c '^talos-evidence\.' || true)"
  bash "$EV" capture >"$OUT" 2>"$ERR"; RC=$?
  assert_eq "0" "$RC" "agent mode [$c]: exit 0"
  assert_eq "evidence-capture mode=agent" "$(out)" "agent mode [$c]: prints mode=agent"
  assert_eq "$LOGS_BEFORE" "$(ls "$TMPDIR" | grep -c '^talos-evidence\.' || true)" "agent mode [$c]: no log created"
done

# no command text on argv: it is refused and nothing runs
cfg_ev "\"command\": \"touch $SANDBOX/ran-from-config\""
bash "$EV" capture "touch $SANDBOX/ran-from-argv" >"$OUT" 2>"$ERR"; RC=$?
assert_eq "2" "$RC" "capture: argv is refused (exit 2)"
[ ! -e "$SANDBOX/ran-from-argv" ] && pass "capture: argv command did not run" || fail "capture: argv command did not run"
[ ! -e "$SANDBOX/ran-from-config" ] && pass "capture: nothing ran on a usage error" || fail "capture: nothing ran on a usage error"

# stdin is /dev/null: a command that reads stdin ends instead of hanging
cfg_ev '"command": "cat; echo after-cat"'
bash "$EV" capture >"$OUT" 2>"$ERR" < /dev/zero; RC=$?
LINE="$(out)"; LOG="${LINE#*log=}"; LOG="${LOG%% since=*}"
assert_contains "$(cat "$LOG")" "after-cat" "capture: stdin is /dev/null"

# timeout: verify.timeout_ms is enforced by capture itself, the whole group dies
set_cfg "{\"verify\": {\"timeout_ms\": 1000}, \"evidence\": {\"dir\": \"ev\", \"command\": \"sleep 30 & echo \$! > $SANDBOX/sleep.pid; wait\"}}"
T0="$(date +%s)"
bash "$EV" capture >"$OUT" 2>"$ERR"; RC=$?
T1="$(date +%s)"
assert_eq "0" "$RC" "timeout: capture exits 0"
assert_contains "$(out)" "evidence-capture rc=124 log=" "timeout: reported as rc=124"
if [ $((T1 - T0)) -le 12 ]; then pass "timeout: bounded runtime ($((T1 - T0))s for a 30s sleep)"; else fail "timeout: bounded runtime" "took $((T1 - T0))s"; fi
SPID="$(cat "$SANDBOX/sleep.pid" 2>/dev/null)"
ALIVE=1
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  kill -0 "$SPID" 2>/dev/null || { ALIVE=0; break; }
  sleep 0.1
done
assert_eq "0" "$ALIVE" "timeout: the command's child process did not survive"

# a command that finishes in time is not touched by a long timeout
set_cfg '{"verify": {"timeout_ms": 600000}, "evidence": {"dir": "ev", "command": "true"}}'
bash "$EV" capture >"$OUT" 2>"$ERR"; RC=$?
assert_contains "$(out)" "evidence-capture rc=0 log=" "no timeout: rc=0"

# a background child left behind by a finished command is cleaned up
set_cfg "{\"evidence\": {\"dir\": \"ev\", \"command\": \"sleep 30 & echo \$! > $SANDBOX/leftover.pid\"}}"
bash "$EV" capture >"$OUT" 2>"$ERR"; RC=$?
assert_contains "$(out)" "evidence-capture rc=0 log=" "leftover child: rc=0"
LPID="$(cat "$SANDBOX/leftover.pid" 2>/dev/null)"
ALIVE=1
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  kill -0 "$LPID" 2>/dev/null || { ALIVE=0; break; }
  sleep 0.1
done
assert_eq "0" "$ALIVE" "leftover child: killed when the command ends"

# outside a git repo: usage-level failure, nothing runs
NOGIT="$(mktemp -d "$SANDBOX/nogit.XXXXXX")"
( cd "$NOGIT" && GIT_CEILING_DIRECTORIES="$SANDBOX" bash "$EV" capture >"$OUT" 2>"$ERR" ); RC=$?
assert_eq "2" "$RC" "capture outside a git repo: exit 2"
assert_contains "$(err)" "not inside a git" "capture outside a git repo: says why"

# usage
bash "$EV" >"$OUT" 2>"$ERR"; assert_eq "2" "$?" "no subcommand: exit 2"
bash "$EV" bogus >"$OUT" 2>"$ERR"; assert_eq "2" "$?" "unknown subcommand: exit 2"

# =============================================================================
# collect: usage
# =============================================================================
new_repo
collect;                       assert_eq "2" "$RC" "collect: no dir -> exit 2"
collect ev --since;            assert_eq "2" "$RC" "collect: --since without a value -> exit 2"
collect ev --since abc;        assert_eq "2" "$RC" "collect: --since abc -> exit 2"
collect ev --since -5;         assert_eq "2" "$RC" "collect: --since -5 -> exit 2"
collect ev --since 1.5;        assert_eq "2" "$RC" "collect: --since 1.5 -> exit 2"
collect ev --since "";         assert_eq "2" "$RC" "collect: --since '' -> exit 2"
collect ev --bogus;            assert_eq "2" "$RC" "collect: unknown flag -> exit 2"
collect ev ev;                 assert_eq "2" "$RC" "collect: two dirs -> exit 2"

# =============================================================================
# collect: refusals (exit 1, one line, empty manifest)
# =============================================================================
new_repo; png ev/a.png
mkdir -p "$SANDBOX/outside-$$"; png "$SANDBOX/outside-$$/o.png"
collect ../outside;                refused "../ dir escapes" "escapes the worktree"
collect "ev/../../outside";        refused "ev/../../ dir escapes" "escapes the worktree"
collect "$SANDBOX/outside-$$";     refused "absolute dir outside" "relative"
collect "$REPO/ev";                refused "absolute dir (even inside)" "relative"
collect .;                         refused "worktree root ." "worktree root"
collect ./;                        refused "worktree root ./" "worktree root"
collect ev/..;                     refused "worktree root ev/.." "worktree root"
collect "";                        refused "empty dir" "invalid dir"
collect "e v";                     refused "space in dir" "invalid dir"
collect -ev;                       refused "leading - in dir" "invalid dir"
collect '.git';                    refused ".git dir" ".git"
collect 'ev/.GIT/x';               refused ".git component (any case)" ".git"
collect 'a$b';                     refused "shell char in dir" "invalid dir"

# symlinks: the dir itself, a component, a link out of the worktree
new_repo; png ev/a.png
ln -s ev evlink
printf 'evlink\nreal/\n' >> .gitignore
collect evlink;                    refused "dir is a symlink" "symlink"
mkdir -p real/ev; png real/ev/a.png; ln -s real linkparent
collect linkparent/ev;             refused "middle component is a symlink" "symlink"
ln -s "$SANDBOX/outside-$$" outlink
collect outlink;                   refused "dir symlinked outside the worktree" "symlink"
collect real/ev/../../evlink;      refused "symlink dir via .. normalisation" "symlink"
: > afile; collect afile;          refused "dir is a regular file" "not a directory"

# ignore: unconditional, probed with a child path
new_repo; printf '' > .gitignore; git add .gitignore; git commit -q -m noignore; png ev/a.png
collect ev;                        refused "dir not ignored" "not ignored"
new_repo; printf 'ev/*\n' > .gitignore; png ev/a.png
git check-ignore -q ev; DIR_IGN=$?
assert_eq "1" "$DIR_IGN" "fixture: 'ev/*' leaves the dir itself unmatched"
collect ev;                        assert_eq "0" "$RC" "ev/*-style ignore (child ignored, dir not) is accepted"
new_repo; mkdir -p .talos/evidence; printf '.talos/\n' > .gitignore; png .talos/evidence/a.png
collect .talos/evidence;           assert_eq "0" "$RC" "default dir .talos/evidence ignored through a parent rule"
assert_eq "$(tsv .talos/evidence a.png image)" "$(out)" ".talos/evidence: manifest"
new_repo; mkdir -p other; printf 'other/*.log\n' > .gitignore; png other/a.png
collect other;                     refused "a rule that does not cover a png" "not ignored"
new_repo; png ev/a.png; printf 'ev/*\n!ev/*.png\n' > .gitignore
collect ev;                        refused "child png re-included by a negation" "not ignored"

# tracked files in the dir
new_repo; png ev/a.png; png ev/b.png
git add -f ev/a.png; git commit -q -m track
collect ev;                        refused "tracked file in dir" "tracked"
new_repo; png ev/sub/deep.png; git add -f ev/sub/deep.png; git commit -q -m track
collect ev;                        refused "tracked file in a subdirectory" "tracked"

# missing dir: nothing to publish, not a refusal
new_repo
collect nope;                      assert_eq "3" "$RC" "missing dir: exit 3 (nothing selected)"
assert_eq "" "$(out)" "missing dir: empty manifest"

# =============================================================================
# collect: selection
# =============================================================================
new_repo
png ev/ok.png; jpg ev/a.jpg; jpg ev/b.jpeg; gif ev/c.gif; webm ev/d.webm; mp4 ev/e.mp4; mov ev/f.mov
png ev/UPPER.PNG
collect ev
assert_eq "0" "$RC" "all allowlisted types: exit 0"
EXPECT="$(tsv ev UPPER.PNG image; tsv ev a.jpg image; tsv ev b.jpeg image; tsv ev c.gif image; tsv ev d.webm video; tsv ev e.mp4 video; tsv ev f.mov video; tsv ev ok.png image)"
assert_eq "$EXPECT" "$(out)" "all allowlisted types: sorted TSV with image/video kinds, .PNG stored as given"
assert_contains "$(err)" "selected=8" "report: selected count on stderr"

# svg and html are never published, even when include names them
new_repo
png ev/ok.png; mk ev/x.svg '<svg/>'; mk ev/x.html '<html/>'; mk ev/x.txt 'hi'
cfg_ev '"include": ["*.png", "*.svg", "*.html", "*.txt"]'
collect ev
assert_eq "$(tsv ev ok.png image)" "$(out)" "svg/html/txt never selected even when include names them"
assert_contains "$(err)" "skipped=3" "report: skipped count"

# include filter
new_repo
png ev/shot-1.png; png ev/other.png; webm ev/shot-2.webm
cfg_ev '"include": ["shot-*.png", "*.webm"]'
collect ev
assert_eq "$(tsv ev shot-1.png image; tsv ev shot-2.webm video)" "$(out)" "include globs filter by basename"
cfg_ev '"include": ["*.png"]'
collect ev
assert_eq "$(tsv ev other.png image; tsv ev shot-1.png image)" "$(out)" "include *.png leaves the webm out"
cfg_ev '"include": ["nomatch-*"]'
collect ev
assert_eq "3" "$RC" "include matching nothing: exit 3"
# an uppercase extension still matches a lowercase include glob
new_repo; png ev/Shot.PNG; cfg_ev '"include": ["*.png"]'
collect ev
assert_eq "$(tsv ev Shot.PNG image)" "$(out)" "*.png include matches Shot.PNG (extension compared lowercased)"

# magic bytes must match the extension
new_repo
png ev/ok.png
mk ev/text.png 'this is just text'
mk ev/empty.png ''
png ev/actually-png.jpg
jpg ev/actually-jpg.png
gif ev/actually-gif.png
mp4 ev/actually-mp4.webm
mp4 ev/noftyp-mp4-as-mov.mov
mk ev/noftyp.mp4 '\000\000\000\030XXXXisom'
mk ev/short.webm '\032\105\337\243'
mkv ev/matroska.webm
mov ev/qt-as.mp4
mp4 ev/isom-as.mov
mk ev/gif87.gif 'GIF87a'
mk ev/gifbad.gif 'GIF90a'
collect ev
assert_eq "$(tsv ev gif87.gif image; tsv ev ok.png image)" "$(out)" "magic bytes: only matching content is selected (GIF87a ok, text/empty/mismatch/Matroska/no-ftyp/wrong brand skipped)"

# mp4/mov brand rules in isolation
new_repo; mp4 ev/a.mp4; mov ev/b.mov; mk ev/c.mp4 '\000\000\000\030ftypmp42'
collect ev
assert_eq "$(tsv ev a.mp4 video; tsv ev b.mov video; tsv ev c.mp4 video)" "$(out)" "mp4 any non-qt brand, mov qt brand"

# symlinks, FIFOs, hard links, directories named like files
new_repo; png ev/real.png
printf 'secret' > "$SANDBOX/outside-secret.txt"; png "$SANDBOX/outside-file.png" "outside"
ln -s "$SANDBOX/outside-file.png" ev/x.png
ln -s real.png ev/link-in-dir.png
mkdir -p "$SANDBOX/outside-dir"; png "$SANDBOX/outside-dir/in.png"; ln -s "$SANDBOX/outside-dir" ev/linked-dir
mkdir -p ev/realdir; png ev/realdir/in.png; ln -s realdir ev/dirlink
mkfifo ev/fifo.png
mkdir ev/dir.png
collect ev
assert_eq "0" "$RC" "unsafe entries: collect still succeeds on the safe ones"
assert_eq "$(tsv ev real.png image; tsv ev realdir/in.png image)" "$(out)" "unsafe entries: symlinks (file and dir), FIFO and a dir named .png never selected"

# hard links: both names are skipped, including a link to a file outside the dir
new_repo; png ev/solo.png; png ev/a.png "same"
ln ev/a.png ev/b.png
png "$SANDBOX/outside-hard.png" "hard"; ln "$SANDBOX/outside-hard.png" ev/h.png
collect ev
assert_eq "$(tsv ev solo.png image)" "$(out)" "hard links (st_nlink > 1) are skipped"

# names and depth
new_repo
png ev/ok.png
png "ev/with space.png"; png 'ev/back`tick.png'; png 'ev/dollar$x.png'; png 'ev/semi;colon.png'
png "$(printf 'ev/new\nline.png')"
png ev/-dash.png; png ev/.hidden.png; png 'ev/.hid/inside.png'; png 'ev/-d/inside.png'; png 'ev/sp ace/inside.png'
png ev/ünï.png
png ev/l1/ok2.png; png ev/l1/l2/ok3.png; png ev/l1/l2/l3/too-deep.png
collect ev
assert_eq "0" "$RC" "names: exit 0"
assert_eq "$(tsv ev l1/l2/ok3.png image; tsv ev l1/ok2.png image; tsv ev ok.png image)" "$(out)" "names: spaces, backticks, \$, ;, newline, leading -, dotfiles/dot dirs, non-ASCII and depth 4 skipped; depth <= 3 kept"
assert_eq "1" "$(errlines)" "names: one report line on success"

# a dir name that is listed through git without surprises (spaces in names never reach git)
assert_eq "" "$(git status --porcelain --ignored=no | grep -v '^??' || true)" "names: repo index untouched"

# --since
new_repo
png ev/old.png; png ev/exact.png; png ev/fraction.png; png ev/under.png; png ev/new.png
S=1700000000
setm ev/old.png $((S - 3600)); setm ev/exact.png "$S"; setm ev/fraction.png "$S.9"
setm ev/under.png "$((S - 1)).9"; setm ev/new.png $((S + 5))
collect ev --since "$S"
assert_eq "$(tsv ev exact.png image; tsv ev fraction.png image; tsv ev new.png image)" "$(out)" "--since: floor compare keeps mtime == since and since.9, drops older (incl. since-1.9)"
collect ev --since $((S + 100))
assert_eq "3" "$RC" "--since newer than everything: exit 3"
collect ev
assert_eq "5" "$(wc -l < "$OUT" | tr -d ' ')" "no --since: every file selected, nothing deleted"
for f in old exact fraction under new; do [ -f "ev/$f.png" ] || fail "--since never deletes: $f.png missing"; done
pass "--since never deletes anything"

# nothing selected -> exit 3
new_repo
collect ev;                          assert_eq "3" "$RC" "empty dir: exit 3"
assert_eq "" "$(out)" "empty dir: empty manifest"
assert_contains "$(err)" "evidence-collect none" "empty dir: says nothing selected"
mk ev/notes.txt 'x'; mk ev/x.svg '<svg/>'
collect ev;                          assert_eq "3" "$RC" "only non-matching files: exit 3"
assert_contains "$(err)" "skipped=2" "only non-matching files: skipped counted"

# =============================================================================
# collect: caps (exit 4, empty manifest, nothing partial)
# =============================================================================
new_repo
png ev/a.png; png ev/b.png; png ev/c.png
cfg_ev '"max_files": 2'
collect ev
assert_eq "4" "$RC" "max_files: 3 files over 2 -> exit 4"
assert_eq "" "$(out)" "max_files: empty manifest (nothing partial)"
assert_contains "$(err)" "evidence-collect over-cap files=3/2 mb=0.00/20 file-mb=0.00/10" "max_files: over-cap line (max_mb default 20, per-file 10)"
assert_eq "1" "$(errlines)" "max_files: one line"
cfg_ev '"max_files": 3'
collect ev
assert_eq "0" "$RC" "max_files: exactly at the cap is fine"
assert_eq "3" "$(wc -l < "$OUT" | tr -d ' ')" "max_files: all three listed"

# defaults: max_files 10
new_repo; for i in 1 2 3 4 5 6 7 8 9 10; do png "ev/f$i.png"; done
collect ev;                          assert_eq "0" "$RC" "default max_files: 10 files ok"
png ev/f11.png
collect ev;                          assert_eq "4" "$RC" "default max_files: 11 files -> exit 4"
assert_contains "$(err)" "over-cap files=11/10 mb=" "default max_files: line shows 11/10"

# max_mb: total over the cap
new_repo; bigfile ev/a.png 786432; bigfile ev/b.png 786432
cfg_ev '"max_mb": 1'
collect ev
assert_eq "4" "$RC" "max_mb: 1.5 MiB over 1 -> exit 4"
assert_eq "" "$(out)" "max_mb: empty manifest"
assert_contains "$(err)" "evidence-collect over-cap files=2/10 mb=1.50/1 file-mb=0.75/10" "max_mb: over-cap line"
cfg_ev '"max_mb": 2'
collect ev;                          assert_eq "0" "$RC" "max_mb: under the cap is fine"
new_repo; bigfile ev/a.png 524288; bigfile ev/b.png 524288
cfg_ev '"max_mb": 1'
collect ev;                          assert_eq "0" "$RC" "max_mb: total exactly at the cap is fine"

# stale files do not count toward the caps
new_repo; png ev/old1.png; png ev/old2.png; png ev/new.png
setm ev/old1.png 1000; setm ev/old2.png 1000; setm ev/new.png 2000000000
cfg_ev '"max_files": 1'
collect ev --since 1500000000
assert_eq "0" "$RC" "caps count only files that pass --since"
assert_eq "$(tsv ev new.png image)" "$(out)" "caps count only files that pass --since: manifest"

# the fixed per-file cap: 10 MiB
new_repo; bigfile ev/big.png 10485761; png ev/small.png
cfg_ev '"max_mb": 100'
collect ev
assert_eq "4" "$RC" "per-file cap: a file over 10 MiB -> exit 4 even under max_mb"
assert_eq "" "$(out)" "per-file cap: nothing selected (small.png not listed either)"
assert_contains "$(err)" "evidence-collect over-cap files=2/10 mb=10.00/100 file-mb=10.00/10" "per-file cap: line carries file-mb"
new_repo; bigfile ev/big.png 10485760
collect ev
assert_eq "0" "$RC" "per-file cap: exactly 10 MiB is fine (max_mb default 20)"

# =============================================================================
# collect --stage (#415): the bytes come from the descriptor collect judged
# =============================================================================
modeof() { python3 -I -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$1"; }
new_stage() { STAGE="$(mktemp -d "$SANDBOX/stage.XXXXXX")"; }
stage_empty() { [ -z "$(ls -A "$STAGE")" ]; }

new_repo; new_stage; png ev/a.png
collect ev --stage;                  assert_eq "2" "$RC" "stage: --stage without a value -> exit 2"
collect ev --stage "";               assert_eq "2" "$RC" "stage: --stage '' -> exit 2"

new_repo; png ev/a.png; mkdir -p ev/stg
collect ev --stage rel/dir;          refused "stage: relative path" "absolute"
collect ev --stage "$SANDBOX/nope-$$"; refused "stage: missing dir" "not a directory"
new_stage; : > "$STAGE/junk"
collect ev --stage "$STAGE";         refused "stage: non-empty dir" "not empty"
collect ev --stage "$REPO/ev/stg";   refused "stage: inside the evidence dir" "inside the evidence dir"
: > "$SANDBOX/afile"
collect ev --stage "$SANDBOX/afile"; refused "stage: a file, not a dir" "not a directory"

# staged bytes equal the source; manifest identical to a run without --stage;
# directories 0700 and files 0600
new_repo; new_stage
png ev/a.png "alpha"; webm ev/run.webm "clip"; png ev/l1/l2/deep.png "deeper"
collect ev
PLAIN="$(out)"
collect ev --stage "$STAGE"
assert_eq "0" "$RC" "stage: exit 0"
assert_eq "$PLAIN" "$(out)" "stage: stdout is the same manifest as without --stage"
for f in a.png run.webm l1/l2/deep.png; do
  if cmp -s "ev/$f" "$STAGE/$f"; then pass "stage: $f copied byte for byte"; else fail "stage: $f copied byte for byte"; fi
  assert_eq "0o600" "$(modeof "$STAGE/$f")" "stage: $f is 0600"
done
assert_eq "0o700" "$(modeof "$STAGE/l1")" "stage: subdirectory l1 is 0700"
assert_eq "0o700" "$(modeof "$STAGE/l1/l2")" "stage: subdirectory l1/l2 is 0700"
assert_eq "3" "$(find "$STAGE" -type f | wc -l | tr -d ' ')" "stage: exactly the selected files, nothing else"
assert_eq "$(fsize ev/a.png)" "$(awk -F'\t' '$1 == "a.png" {print $2}' "$OUT")" "stage: manifest byte count is the copied size"

# an entry that is a symlink at collect time is never staged
new_repo; new_stage; png ev/real.png
printf 'TOP-SECRET' > "$SANDBOX/secret-$$.png"
ln -s "$SANDBOX/secret-$$.png" ev/x.png
collect ev --stage "$STAGE"
assert_eq "$(tsv ev real.png image)" "$(out)" "stage: a symlinked entry is not selected"
assert_eq "1" "$(find "$STAGE" -type f | wc -l | tr -d ' ')" "stage: only the regular file was staged"
assert_eq "" "$(grep -rl TOP-SECRET "$STAGE" || true)" "stage: the link target's bytes are nowhere in the stage"

# a file swapped for a symlink AFTER selection: the stage keeps the judged bytes
new_repo; new_stage; png ev/a.png "original-bytes"
collect ev --stage "$STAGE"
cp "$STAGE/a.png" "$SANDBOX/judged.png"
rm ev/a.png; ln -s "$SANDBOX/secret-$$.png" ev/a.png
if cmp -s "$STAGE/a.png" "$SANDBOX/judged.png"; then pass "stage: the staged copy is unaffected by a later swap for a symlink"; else fail "stage: the staged copy is unaffected by a later swap"; fi
assert_eq "" "$(grep -l TOP-SECRET "$STAGE/a.png" || true)" "stage: nothing was read through the link"

# the caps are re-checked on the staged bytes; a failure leaves the stage empty
new_repo; new_stage; bigfile ev/big.png 10485761; png ev/small.png
cfg_ev '"max_mb": 100'
collect ev --stage "$STAGE"
assert_eq "4" "$RC" "stage: over the per-file cap -> exit 4"
assert_eq "" "$(out)" "stage: over-cap leaves an empty manifest"
stage_empty && pass "stage: over-cap removes what was staged" || fail "stage: over-cap removes what was staged" "$(ls -A "$STAGE")"
new_repo; new_stage; png ev/a.png; png ev/b.png; cfg_ev '"max_files": 1'
collect ev --stage "$STAGE"
assert_eq "4" "$RC" "stage: over max_files -> exit 4"
stage_empty && pass "stage: max_files over-cap removes what was staged" || fail "stage: max_files over-cap removes what was staged"
new_repo; new_stage; mk ev/notes.txt hi
collect ev --stage "$STAGE"
assert_eq "3" "$RC" "stage: nothing selected -> exit 3"
stage_empty && pass "stage: exit 3 leaves the stage empty" || fail "stage: exit 3 leaves the stage empty"
new_repo; new_stage; png ev/a.png
collect nope --stage "$STAGE"
assert_eq "3" "$RC" "stage: missing dir -> exit 3"
new_repo; new_stage; png ev/a.png; ln -s ev evlink; printf 'evlink\n' >> .gitignore
collect evlink --stage "$STAGE"
refused "stage: a refusal" "symlink"
stage_empty && pass "stage: a refusal leaves the stage empty" || fail "stage: a refusal leaves the stage empty"

# =============================================================================
# hygiene: no repo code on python's path, no git writes, no network
# =============================================================================
new_repo; png ev/a.png
for m in fnmatch subprocess re os; do
  printf 'open("PWNED-%s", "w").close()\n' "$m" > "$REPO/$m.py"
done
git add -A >/dev/null 2>&1; git commit -q -m planted
HEAD_BEFORE="$(git rev-parse HEAD)"; git status --porcelain > "$SANDBOX/status.before"
collect ev
assert_eq "0" "$RC" "planted modules: collect still works"
cfg_ev '"command": "true"'
bash "$EV" capture >"$OUT" 2>"$ERR"
assert_eq "0" "$?" "planted modules: capture still works"
[ -z "$(ls "$REPO" | grep '^PWNED' || true)" ] && pass "planted fnmatch/subprocess/re/os in the repo are never imported" || fail "planted modules were imported"
assert_eq "$HEAD_BEFORE" "$(git rev-parse HEAD)" "no commit was made"
git status --porcelain | grep -v 'talos.pipeline.json' > "$SANDBOX/status.after" || true
grep -v 'talos.pipeline.json' "$SANDBOX/status.before" > "$SANDBOX/status.before2" || true
assert_eq "$(cat "$SANDBOX/status.before2")" "$(cat "$SANDBOX/status.after")" "no git writes: working tree state unchanged"
assert_eq "" "$(cat "$GH_LOG" "$CURL_LOG")" "no gh or curl call was made"

finish
