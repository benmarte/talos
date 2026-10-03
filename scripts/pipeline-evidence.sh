#!/usr/bin/env bash
# pipeline-evidence.sh -- run the repo's evidence command and choose which of
# the files it wrote may leave the machine (#406, part of epic #352).
#
# Usage:
#   pipeline-evidence.sh capture
#   pipeline-evidence.sh collect <dir> [--since <epoch>]
#
# Everything here is local: no network call, no git write. Uploading the
# manifest is a later step (#415, `gh pr comment --attach`).
#
# capture
#   Takes NO command text on argv (any argument is a usage error): the command
#   is `evidence.command`, read through pipeline-config.sh, and runs as
#   `bash -c` in the worktree toplevel, with stdin on /dev/null and stdout +
#   stderr in a log file. The caller wraps this script in pipeline-verify.sh
#   (`pipeline-verify.sh -- pipeline-evidence.sh capture`) so the stage identity
#   is exported; capture inherits it. Same trust and reach as `verify:`.
#   pipeline-verify.sh does NOT enforce verify.timeout_ms, so capture does:
#   `verify.timeout_ms` (default 600000) is a hard limit on the command's
#   process group (SIGTERM, a short wait, SIGKILL; macOS has no timeout(1)).
#   Whatever is left of the group when the command ends is killed too. The log
#   is a 0600 `mktemp` file in ${TMPDIR:-/tmp}, never in the worktree (it can
#   hold secrets and must never sit near publishable files); it is never
#   deleted and never published. Output, one line, exit 0:
#     evidence-capture rc=<n> log=<path> since=<epoch>
#   rc is the command's (124 on timeout, 128+N when killed by signal N). A
#   non-zero rc is reported, not a failure: capture is evidence, not a gate.
#   An empty or absent evidence.command prints `evidence-capture mode=agent`
#   and runs nothing. capture does not check evidence.enabled; that gating is
#   the caller's.
#
# collect <dir> [--since <epoch>]
#   <dir> is relative to the worktree toplevel (an absolute path is refused).
#   It prints the manifest of files that are safe to publish: sorted TSV lines
#   `<relpath>\t<bytes>\t<image|video>` on stdout, relpath relative to <dir>.
#   Every status line goes to stderr, so a failing collect leaves an empty
#   manifest. Exit codes:
#     0  manifest printed (stderr: `evidence-collect selected=<n> skipped=<m>`)
#     1  refused, one line `evidence-collect refused: <reason>`:
#        - <dir> has a component outside [A-Za-z0-9._-], starting with `-`,
#          or is `.git`
#        - the path escapes the worktree or is the worktree root
#        - <dir> or any component below the root is a symlink, or it is not a
#          directory (the root itself may sit behind a symlink, e.g. /tmp)
#        - <dir> is not ignored: `git check-ignore -q -- <dir>/probe.png` must
#          succeed (a child path, because `ev/*` ignores the children and not
#          the directory); unconditional, since a non-ignored directory would
#          be staged by `git add -A` or abort assert-sync under isolation:
#          branch. Any other check-ignore failure is a refusal too.
#        - `git ls-files -- <dir>` lists a tracked file
#     2  usage
#     3  nothing selected (also when <dir> does not exist)
#     4  over a cap: `evidence-collect over-cap files=<n>/<max> mb=<x>/<max>
#        file-mb=<largest>/10`, nothing selected
#   Selection (everything else is skipped and counted):
#   - the walk uses os.scandir and never follows a symlink; files are opened
#     with O_NOFOLLOW|O_NONBLOCK and judged by fstat: regular files with a
#     single link (a hard link is skipped), so a FIFO or a swapped symlink
#     cannot hang or redirect the read
#   - at most 3 path components below <dir>; every component matches
#     [A-Za-z0-9._-]+ and does not start with `-` (gh would read it as a flag)
#     or `.` (hidden); at most 5000 directory entries are looked at
#   - the extension (compared lowercased, name stored as given) is one of
#     png jpg jpeg gif webm mp4 mov: svg and html are never published, even
#     when evidence.include names them; the basename also matches an
#     evidence.include glob (default: those extensions)
#   - the first bytes match the extension: PNG 89 50 4E 47 0D 0A 1A 0A; JPEG
#     FF D8 FF; GIF87a/GIF89a; webm 1A 45 DF A3 with `webm` in the first 64
#     bytes (a Matroska .mkv renamed is rejected); mp4/mov `ftyp` at offset 4,
#     brand `qt  ` for mov and any other brand for mp4. Magic bytes prove the
#     type, not that the picture is free of secrets: the real boundary is
#     <dir> + the allowlist + --since.
#   - --since <epoch> (digits only) drops files with int(mtime) < epoch, so a
#     file written in the same second the capture started is kept and a stale
#     earlier capture is never republished. Nothing is ever deleted.
#   Caps: evidence.max_files (default 10) and evidence.max_mb (default 20, MiB,
#   a total), plus a fixed 10 MiB per file (GitHub's free-plan image and video
#   limit). Over any of them is exit 4, never a partial selection.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFG_SH="$SCRIPT_DIR/pipeline-config.sh"

usage() {
  echo "Usage: pipeline-evidence.sh capture | collect <dir> [--since <epoch>]" >&2
  exit 2
}

cfg() { bash "$CFG_SH" "$@"; }

# _digits_or DEFAULT VALUE -- VALUE when it is all digits and not empty.
_digits_or() {
  case "$2" in
    ''|*[!0-9]*) printf '%s' "$1" ;;
    *) printf '%s' "$2" ;;
  esac
}

# pipeline-config.sh reads ./talos.pipeline.*, so everything runs at the toplevel.
_enter_toplevel() {
  TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$TOPLEVEL" ] || {
    echo "pipeline-evidence: not inside a git work tree" >&2
    exit 2
  }
  cd "$TOPLEVEL" || exit 2
}

# ── capture ──────────────────────────────────────────────────────────────────
read -r -d '' _CAPTURE_PY <<'TALOS_CAPTURE_PY_Hq2Vn8Rt4Wx' || true
import os
import signal
import subprocess
import sys

top, timeout_ms, log, cmd = sys.argv[1:5]
secs = int(timeout_ms) / 1000
fd = os.open(log, os.O_WRONLY | os.O_APPEND)
proc = subprocess.Popen(
    ["bash", "-c", cmd], cwd=top, stdin=subprocess.DEVNULL,
    stdout=fd, stderr=subprocess.STDOUT, start_new_session=True)
os.close(fd)


def kill_group(sig):
    try:
        os.killpg(proc.pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


try:
    rc = proc.wait(timeout=secs)
    kill_group(signal.SIGKILL)          # anything the command left behind
    if rc < 0:
        rc = 128 - rc
except subprocess.TimeoutExpired:
    kill_group(signal.SIGTERM)
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    kill_group(signal.SIGKILL)
    proc.wait()
    rc = 124
print(rc)
TALOS_CAPTURE_PY_Hq2Vn8Rt4Wx

cmd_capture() {
  [ $# -eq 0 ] || usage
  _enter_toplevel
  local command timeout_ms since log rc
  command="$(cfg evidence.command "")"
  case "$command" in
    *[![:space:]]*) ;;
    *) echo "evidence-capture mode=agent"; return 0 ;;
  esac
  timeout_ms="$(_digits_or 600000 "$(cfg verify.timeout_ms 600000)")"
  [ "$timeout_ms" -gt 0 ] 2>/dev/null || timeout_ms=600000
  log="$(mktemp "${TMPDIR:-/tmp}/talos-evidence.XXXXXX")" || {
    echo "pipeline-evidence: cannot create the capture log in ${TMPDIR:-/tmp}" >&2
    return 1
  }
  since="$(date +%s)"
  rc="$(python3 -I -c "$_CAPTURE_PY" "$TOPLEVEL" "$timeout_ms" "$log" "$command")" || rc=""
  case "$rc" in
    ''|*[!0-9]*)
      echo "pipeline-evidence: could not run evidence.command (log: $log)" >&2
      return 1 ;;
  esac
  echo "evidence-capture rc=$rc log=$log since=$since"
}

# ── collect ──────────────────────────────────────────────────────────────────
read -r -d '' _COLLECT_PY <<'TALOS_COLLECT_PY_Kd5Jb7Ye1Pz' || true
import fnmatch
import os
import re
import stat
import subprocess
import sys

MIB = 1024 * 1024
FILE_CAP_MIB = 10
EXTS = {"png": "image", "jpg": "image", "jpeg": "image", "gif": "image",
        "webm": "video", "mp4": "video", "mov": "video"}
NAME_RE = re.compile(r"[A-Za-z0-9._-]+")
MAX_DEPTH = 3
MAX_ENTRIES = 5000

top, dir_arg, since_s, max_files_s, max_mb_s, include_s = sys.argv[1:7]
max_files = int(max_files_s)
max_mb = int(max_mb_s)
since = int(since_s) if since_s else None
includes = [g for g in include_s.split("\n") if g] or ["*." + e for e in EXTS]


def say(msg):
    sys.stderr.write("evidence-collect " + msg + "\n")


def refuse(reason):
    say("refused: " + reason)
    sys.exit(1)


def safe_name(name):
    return NAME_RE.fullmatch(name) is not None and name[0] not in "-."


def git(*args):
    return subprocess.run(
        ["git"] + list(args), cwd=top,
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL)


# 1. the path: relative, plain names, inside the worktree, not the root.
if dir_arg.startswith("/"):
    refuse("dir must be relative to the worktree root")
raw = [p for p in dir_arg.split("/") if p]
if not raw or any(NAME_RE.fullmatch(p) is None or p.startswith("-") for p in raw):
    refuse("invalid dir (components must match [A-Za-z0-9._-]+ and not start with -)")
if any(p.lower() == ".git" for p in raw):
    refuse("dir may not contain a .git component")
root = os.path.realpath(top)
joined = os.path.normpath(os.path.join(root, dir_arg))
if os.path.commonpath([root, joined]) != root:
    refuse("dir escapes the worktree")
if joined == root:
    refuse("dir is the worktree root")
parts = joined[len(root):].strip("/").split("/")
if any(p.lower() == ".git" for p in parts):
    refuse("dir may not contain a .git component")
rel = "/".join(parts)

# 2. no symlink at any component below the root, and it must be a directory.
cur = root
for p in parts:
    cur = os.path.join(cur, p)
    try:
        st = os.lstat(cur)
    except FileNotFoundError:
        say("none dir-missing")
        sys.exit(3)
    except OSError as exc:
        refuse("cannot inspect dir (%s)" % type(exc).__name__)
    if stat.S_ISLNK(st.st_mode):
        refuse("dir has a symlink component: " + p)
    if not stat.S_ISDIR(st.st_mode):
        refuse("not a directory: " + p)

# 3. ignored (probed through a child path) and nothing tracked.
rc = git("check-ignore", "-q", "--", rel + "/probe.png").returncode
if rc == 1:
    refuse("dir is not ignored: add %s/ to .gitignore" % rel)
if rc != 0:
    refuse("git check-ignore failed (rc=%d)" % rc)
ls = git("--literal-pathspecs", "ls-files", "-z", "--", rel)
if ls.returncode != 0:
    refuse("git ls-files failed (rc=%d)" % ls.returncode)
if ls.stdout:
    refuse("dir holds tracked files")


# 4. selection
def magic_ok(ext, h):
    if ext == "png":
        return h.startswith(b"\x89PNG\r\n\x1a\n")
    if ext in ("jpg", "jpeg"):
        return h.startswith(b"\xff\xd8\xff")
    if ext == "gif":
        return h[:6] in (b"GIF87a", b"GIF89a")
    if ext == "webm":
        return h.startswith(b"\x1a\x45\xdf\xa3") and b"webm" in h[:64]
    if ext in ("mp4", "mov"):
        if h[4:8] != b"ftyp" or len(h) < 12:
            return False
        return (h[8:12] == b"qt  ") == (ext == "mov")
    return False


chosen = []          # (relpath, bytes, kind)
skipped = 0
scanned = 0


def walk(path, prefix, depth):
    global skipped, scanned
    try:
        entries = sorted(os.scandir(path), key=lambda e: e.name)
    except OSError:
        skipped += 1
        return
    for e in entries:
        scanned += 1
        if scanned > MAX_ENTRIES:
            refuse("more than %d directory entries" % MAX_ENTRIES)
        name = e.name
        try:
            if e.is_symlink():
                skipped += 1
                continue
            is_dir = e.is_dir(follow_symlinks=False)
        except OSError:
            skipped += 1
            continue
        if not safe_name(name):
            skipped += 1
            continue
        if is_dir:
            if depth >= MAX_DEPTH:
                skipped += 1
            else:
                walk(e.path, prefix + name + "/", depth + 1)
            continue
        stem, dot, ext = name.rpartition(".")
        ext = ext.lower()
        lowered = stem + "." + ext
        if not dot or ext not in EXTS or not any(
                fnmatch.fnmatchcase(n, g) for n in (name, lowered) for g in includes):
            skipped += 1
            continue
        try:
            fd = os.open(e.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except OSError:
            skipped += 1
            continue
        try:
            st = os.fstat(fd)
            ok = stat.S_ISREG(st.st_mode) and st.st_nlink == 1
            if ok and since is not None and int(st.st_mtime) < since:
                ok = False
            head = os.read(fd, 64) if ok else b""
        except OSError:
            ok, head = False, b""
        finally:
            os.close(fd)
        if not ok or not magic_ok(ext, head):
            skipped += 1
            continue
        chosen.append((prefix + name, st.st_size, EXTS[ext]))


walk(joined, "", 1)

if not chosen:
    say("none selected=0 skipped=%d" % skipped)
    sys.exit(3)

total = sum(c[1] for c in chosen)
largest = max(c[1] for c in chosen)
if len(chosen) > max_files or total > max_mb * MIB or largest > FILE_CAP_MIB * MIB:
    say("over-cap files=%d/%d mb=%.2f/%d file-mb=%.2f/%d" % (
        len(chosen), max_files, total / MIB, max_mb, largest / MIB, FILE_CAP_MIB))
    sys.exit(4)

chosen.sort()
sys.stdout.write("".join("%s\t%d\t%s\n" % c for c in chosen))
say("selected=%d skipped=%d" % (len(chosen), skipped))
TALOS_COLLECT_PY_Kd5Jb7Ye1Pz

cmd_collect() {
  local dir="" have_dir=0 since=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --since)
        [ $# -ge 2 ] || usage
        case "$2" in ''|*[!0-9]*) echo "pipeline-evidence: --since must be digits only" >&2; usage ;; esac
        since="$2"; shift 2 ;;
      --*) usage ;;
      *)
        [ "$have_dir" = 0 ] || usage
        dir="$1"; have_dir=1; shift ;;
    esac
  done
  [ "$have_dir" = 1 ] || usage
  _enter_toplevel
  local max_files max_mb include
  max_files="$(_digits_or 10 "$(cfg evidence.max_files 10)")"
  max_mb="$(_digits_or 20 "$(cfg evidence.max_mb 20)")"
  include="$(cfg evidence.include "")"
  python3 -I -c "
import sys
src = sys.argv[1]
sys.argv = sys.argv[1:]
try:
    exec(compile(src, 'pipeline-evidence-collect', 'exec'))
except SystemExit:
    raise
except Exception as exc:
    sys.stderr.write('evidence-collect refused: internal error (%s)\n' % type(exc).__name__)
    sys.exit(1)
" "$_COLLECT_PY" "$TOPLEVEL" "$dir" "$since" "$max_files" "$max_mb" "$include"
}

case "${1:-}" in
  capture) shift; cmd_capture "$@" ;;
  collect) shift; cmd_collect "$@" ;;
  *) usage ;;
esac
