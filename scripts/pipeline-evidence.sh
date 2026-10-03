#!/usr/bin/env bash
# pipeline-evidence.sh -- run the repo's evidence command, choose which of the
# files it wrote may leave the machine, and attach them to a PR (#406, #415,
# #409, part of epic #352).
#
# Usage:
#   pipeline-evidence.sh capture
#   pipeline-evidence.sh collect <dir> [--since <epoch>] [--stage <dir>]
#   pipeline-evidence.sh upload <pr> [--since <epoch>] [--dry-run]
#   pipeline-evidence.sh attach <pr> [--since <epoch>] [--dry-run]
#   pipeline-evidence.sh dir
#   pipeline-evidence.sh enabled
#
# capture, collect, dir and enabled are local: no network call, no git write. upload
# (and attach, which runs it) is the only subcommand that talks to GitHub
# (`gh pr comment --attach`).
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
#   the caller's (`attach` does it). Exit codes:
#     0  a line was printed (whatever the command's own rc)
#     1  the log could not be created, or the runner failed
#     2  usage (any argument) or not inside a worktree
#
# collect <dir> [--since <epoch>] [--stage <dir>]
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
#        file-mb=<largest>/<per-file cap>`, nothing selected
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
#   a total), plus a fixed per-file cap (`_EVIDENCE_FILE_MB`, in MiB, GitHub's
#   free-plan image and video limit; the one place the number is written). Over any of them is exit 4, never a partial selection.
#   --stage <dir> (#415): <dir> must be an existing, EMPTY directory outside
#   the evidence dir. Each selected file's bytes are copied from the file
#   descriptor that was already opened and judged (never reopened by name, so a
#   file swapped for a symlink afterwards cannot redirect the copy) into
#   <dir>/<relpath>: subdirectories 0700, files 0600. The size caps are
#   re-checked against the bytes actually copied (the manifest's byte count is
#   then the copied size). A refusal, exit 3 or exit 4 removes what was staged.
#   stdout stays the same manifest; without --stage nothing is written.
#
# upload <pr> [--since <epoch>] [--dry-run]
#   Posts ONE evidence comment on PR <pr> (digits only) with
#   `gh pr comment --attach`, then deletes the author's older evidence
#   comments. It takes no manifest and no directory: it reads evidence.dir
#   (default .talos/evidence), makes its own 0700 `mktemp -d` staging dir
#   outside the worktree (removed on exit), runs `collect --stage` into it and
#   attaches ONLY from there. `gh --attach` opens paths again by name and
#   follows symlinks, so attaching from the evidence dir would let a file
#   swapped after selection leave the machine; a private copy cannot be
#   swapped. --since is passed to collect (the epoch `capture` printed) so a
#   stale earlier capture is never republished.
#   Order: provider check, collect, the capability probe, the login lookup, the
#   comment list, the post, the deletes. Nothing is posted unless every earlier
#   step succeeded.
#   - provider: `github`, or `github-api` when a `gh` binary exists; anything
#     else is exit 2 `not implemented for provider '<p>'`.
#   - capability: `gh pr comment --help` (stdout, no network) must list
#     `--attach` (gh v2.99.0 or newer), else exit 2 and no other gh call.
#   - login: `gh api user --jq .login` must exit 0 AND print a GitHub login
#     (the check upsert-pr-comment uses, #381/#392); anything else is exit 1
#     and nothing is posted. A comment is only ever deleted when that login
#     wrote it AND its last non-blank line is `<!-- talos:evidence -->`.
#   - strategy: create-then-delete. gh uploads inside the comment write, and
#     `--edit-last` edits "the current user's last comment" of any kind (every
#     stage comment shares one login), so editing is never used. The new
#     comment is posted first (a failed post leaves the old evidence in place);
#     older own evidence comments are deleted only after a good post.
#   - gh runs with cwd = the staging dir and `--repo <owner>/<repo>`; the body
#     and every `--attach` value use the same `./<relpath>` (gh matches them as
#     absolute paths from its cwd; `--repo` only selects the PR, it does not
#     change how attachments are read). The body goes on stdin (`--body-file
#     -`) and every path is its own argv element.
#   Output, one line on stdout:
#     evidence-upload pr=<n> images=<i> videos=<v> comment=<url> mode=<new|replace|skip>
#   new = no older evidence comment was deleted, replace = at least one was,
#   skip = nothing to attach (comment= empty, exit 3, no gh call).
#   Exit codes:
#     0  posted, and older evidence comments deleted
#     1  a collect, staging or gh failure, one line naming the reason; a failed
#        delete after a good post names the comment id and still prints the
#        line with the new URL
#     2  usage, unsupported provider, no gh binary, or gh without --attach
#     3  nothing to attach (collect exit 3)
#   Not supported by gh: GitHub Enterprise Server, and an Actions GITHUB_TOKEN
#   (gh refuses it; that is exit 1 with gh's own reason). Needs write access
#   to the repository. Gating on evidence.enabled is the caller's.
#   --dry-run prints the planned gh calls and makes none (no probe, no login
#   lookup); collect still runs, locally.
#
# attach <pr> [--since <epoch>] [--dry-run]   (#409)
#   The one call a stage makes: gate, capture, upload, one status line. <pr> and
#   --since are digits only (anything else is usage, exit 2). Order:
#   1. gate: `evidence.enabled` (default false) must be `true`, else exit 2,
#      `evidence-attach: evidence disabled` on stderr, empty stdout, and
#      nothing runs: no gh/git/curl call and no `evidence.command`, because
#      capture runs arbitrary shell.
#   2. provider: the same check as upload (one shared function): `github`, or
#      `github-api` with a `gh` binary; anything else is exit 2.
#   3. capture (the function, run in-process, so the caller's stage identity
#      applies when this script is wrapped in pipeline-verify.sh), then
#      `upload <pr> --since <epoch>`. A non-zero capture rc never stops the
#      upload. In command mode --since is the `since=` capture printed (the
#      caller's --since is ignored); in agent mode (`evidence-capture
#      mode=agent`, no evidence.command) it is the caller's --since, if given:
#      the stage notes `date +%s` before saving screenshots.
#   Output, ONE line on stdout (no PR or issue text is ever in it):
#     evidence-attach pr=<n> status=<s> images=<i> videos=<v> capture=<c> comment=<url>
#   capture is the command's rc (124 on timeout), `agent`, or `skipped`
#   (--dry-run); when capture itself failed to run it is capture's own exit
#   code. comment is empty unless a comment was posted.
#   upload's stderr is forwarded untouched (over-cap numbers, the refusal
#   reason, a delete warning). Status from upload's exit code and stderr:
#     upload 0                                  posted
#     upload 3                                  empty
#     upload 1, `evidence-upload: collect failed (rc=4)` at a line start
#                                               over-cap
#     upload 1, `evidence-upload: collect failed (rc=1)` at a line start
#                                               refused
#     upload 1, any other                       failed
#     upload 1 AND a non-empty comment= URL     posted (the post succeeded and
#                                               only deleting the older comment
#                                               failed; the warning naming the
#                                               undeleted id is on stderr)
#     upload 2                                  exit 2, its stderr, no stdout
#   `posted` always carries a URL: a caller decides from status= and a non-empty
#   comment=, never from the exit code alone. No status-only comment is ever
#   posted: over-cap, empty and refused are this one line. Known limitation:
#   upload deletes older evidence only after a good post, so after an over-cap
#   or empty later round the earlier evidence comment stays; the line is the
#   signal. Exit codes:
#     0  posted, empty, over-cap
#     1  refused, failed
#     2  usage, evidence disabled, unsupported provider, no gh binary, or gh
#        without --attach
#   --dry-run runs the gate and the provider check, skips capture (it would run
#   evidence.command), prints the plan and the caps, then `upload <pr>
#   --dry-run` (collect runs locally, no gh call) and exits with the same map
#   (no status line is printed).
#
# enabled   (#410)
#   The one call Step 0 of the playbook makes: is evidence on for this run?
#   Takes no argument. Reads config and `gh pr comment --help` (stdout, no
#   network); it runs no evidence.command and makes no provider call. Order:
#   1. `evidence.enabled` (the gate `attach` shares, `_evidence_enabled`) must
#      be `true`, else exit 1 with no output at all.
#   2. provider `github`, or `github-api`, with a `gh` binary that lists
#      `--attach` (the probe `upload` shares, `_gh_has_attach`); otherwise
#      exit 1 with ONE stderr line `pipeline: evidence ignored: <reason>`
#      (the reason is one of a fixed set, never issue or PR text): warn once,
#      treat evidence as off, like `pr.draft`.
#   3. on: exit 0 and, on stdout, exactly
#        evidence on when=<user-facing|always> mode=<command|agent>
#      both words fixed enums (an unknown or absent evidence.when is
#      `user-facing`); mode=agent means evidence.command is empty.
#
# dir
#   Prints the evidence dir, relative to the worktree toplevel: evidence.dir or
#   `.talos/evidence`. Exit 0. This is the only place the default is written
#   (see _evidence_dir), and where an agent that captures by itself looks.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFG_SH="$SCRIPT_DIR/pipeline-config.sh"

usage() {
  echo "Usage: pipeline-evidence.sh capture | collect <dir> [--since <epoch>] [--stage <dir>] | upload <pr> [--since <epoch>] [--dry-run] | attach <pr> [--since <epoch>] [--dry-run] | dir | enabled" >&2
  exit 2
}

cfg() { bash "$CFG_SH" "$@"; }

# The one way every subcommand runs its embedded python: isolated mode (no
# PYTHON* env, no cwd on sys.path, so a planted re.py in the worktree is never
# imported), the source handed in as argv and exec'd, and an unexpected
# exception turned into one `<prefix>: internal error (<Type>)` line and exit 1
# instead of a traceback. Inside the source sys.argv[1:] are the arguments.
read -r -d '' _RUN_PY_WRAPPER <<'TALOS_RUN_PY_Wd4Hs6Nb2Yc' || true
import sys
label, src = sys.argv[1:3]
sys.argv = sys.argv[2:]
try:
    exec(compile(src, "pipeline-evidence", "exec"))
except SystemExit:
    raise
except Exception as exc:
    sys.stderr.write("%s: internal error (%s)\n" % (label, type(exc).__name__))
    sys.exit(1)
TALOS_RUN_PY_Wd4Hs6Nb2Yc

# _run_py <error-prefix> <python-source> [args...]
_run_py() {
  local label="$1" src="$2"; shift 2
  python3 -I -c "$_RUN_PY_WRAPPER" "$label" "$src" "$@"
}

# _digits_or DEFAULT VALUE -- VALUE when it is all digits and not empty.
_digits_or() {
  case "$2" in
    ''|*[!0-9]*) printf '%s' "$1" ;;
    *) printf '%s' "$2" ;;
  esac
}

# The evidence defaults, written once. `collect` and `attach` (its dry-run
# caps line) read the caps through these helpers, `upload`, `attach` and `dir`
# the directory through _evidence_dir. The config layer (#405) never injects a
# default.
_EVIDENCE_DEFAULT_DIR=".talos/evidence"
_EVIDENCE_DEFAULT_MAX_FILES=10
_EVIDENCE_DEFAULT_MAX_MB=20
_EVIDENCE_FILE_MB=10   # MiB: the fixed per-file cap, passed to collect's and upload's python

_evidence_dir() { cfg evidence.dir "$_EVIDENCE_DEFAULT_DIR"; }
_evidence_max_files() {
  _digits_or "$_EVIDENCE_DEFAULT_MAX_FILES" "$(cfg evidence.max_files "$_EVIDENCE_DEFAULT_MAX_FILES")"
}
_evidence_max_mb() {
  _digits_or "$_EVIDENCE_DEFAULT_MAX_MB" "$(cfg evidence.max_mb "$_EVIDENCE_DEFAULT_MAX_MB")"
}

# _evidence_enabled -- true only when evidence.enabled is exactly `true` (an
# absent key, `false` and any other value are off). The one gate `attach` and
# `enabled` share; needs the toplevel as cwd (reads the config).
_evidence_enabled() { [ "$(cfg evidence.enabled false)" = "true" ]; }

# _gh_has_attach -- true when `gh pr comment --help` (stdout, no network) lists
# `--attach` (gh v2.99.0 or newer). The one probe `upload` and `enabled` share.
_gh_has_attach() {
  gh pr comment --help 2>/dev/null | grep -Eq '^[[:space:]]+--attach[[:space:]]'
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
  rc="$(_run_py "pipeline-evidence capture" "$_CAPTURE_PY" "$TOPLEVEL" "$timeout_ms" "$log" "$command")" || rc=""
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
EXTS = {"png": "image", "jpg": "image", "jpeg": "image", "gif": "image",
        "webm": "video", "mp4": "video", "mov": "video"}
NAME_RE = re.compile(r"[A-Za-z0-9._-]+")
MAX_DEPTH = 3
MAX_ENTRIES = 5000

top, dir_arg, since_s, max_files_s, max_mb_s, include_s, stage_arg, file_mb_s = sys.argv[1:9]
FILE_CAP_MIB = int(file_mb_s)
max_files = int(max_files_s)
max_mb = int(max_mb_s)
since = int(since_s) if since_s else None
includes = [g for g in include_s.split("\n") if g] or ["*." + e for e in EXTS]
stage = None            # the real path of the staging dir, when --stage is given
staged_files = []       # what this run wrote there, removed again on any failure
staged_dirs = []


def say(msg):
    sys.stderr.write("evidence-collect " + msg + "\n")


def unstage():
    for p in staged_files:
        try:
            os.unlink(p)
        except OSError:
            pass
    for d in reversed(staged_dirs):
        try:
            os.rmdir(d)
        except OSError:
            pass


def refuse(reason):
    unstage()
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

# 3b. --stage: an absolute, existing, empty directory that is not inside <dir>.
if stage_arg:
    if not stage_arg.startswith("/"):
        refuse("stage must be an absolute path")
    stage = os.path.realpath(stage_arg)
    if not os.path.isdir(stage):
        refuse("stage is not a directory")
    if os.listdir(stage):
        refuse("stage is not empty")
    if os.path.commonpath([stage, joined]) == joined:
        refuse("stage is inside the evidence dir")


def stage_copy(fd, head, relpath):
    """Copy the opened file (its first bytes already read as head) to
    <stage>/<relpath>, at most FILE_CAP_MIB + 1 byte. Returns the byte count."""
    parts = relpath.split("/")
    cur = stage
    for p in parts[:-1]:
        cur = os.path.join(cur, p)
        try:
            os.mkdir(cur, 0o700)
            staged_dirs.append(cur)
        except FileExistsError:
            pass
        st = os.lstat(cur)
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
            raise OSError("stage path is not a directory")
    dst = os.path.join(cur, parts[-1])
    out = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    staged_files.append(dst)
    limit = FILE_CAP_MIB * MIB + 1
    try:
        with os.fdopen(out, "wb") as f:
            f.write(head)
            total = len(head)
            while total < limit:
                chunk = os.read(fd, min(MIB, limit - total))
                if not chunk:
                    break
                f.write(chunk)
                total += len(chunk)
    except OSError:
        staged_files.remove(dst)
        try:
            os.unlink(dst)
        except OSError:
            pass
        raise
    return total


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
        size = 0
        try:
            st = os.fstat(fd)
            ok = stat.S_ISREG(st.st_mode) and st.st_nlink == 1
            if ok and since is not None and int(st.st_mtime) < since:
                ok = False
            head = os.read(fd, 64) if ok else b""
            ok = ok and magic_ok(ext, head)
            size = st.st_size
            if ok and stage is not None:
                # the copy reads this same descriptor: no reopen by name
                size = stage_copy(fd, head, prefix + name)
        except OSError:
            ok = False
        finally:
            os.close(fd)
        if not ok:
            skipped += 1
            continue
        chosen.append((prefix + name, size, EXTS[ext]))


walk(joined, "", 1)

if not chosen:
    say("none selected=0 skipped=%d" % skipped)
    sys.exit(3)

total = sum(c[1] for c in chosen)
largest = max(c[1] for c in chosen)
if len(chosen) > max_files or total > max_mb * MIB or largest > FILE_CAP_MIB * MIB:
    unstage()
    say("over-cap files=%d/%d mb=%.2f/%d file-mb=%.2f/%d" % (
        len(chosen), max_files, total / MIB, max_mb, largest / MIB, FILE_CAP_MIB))
    sys.exit(4)

chosen.sort()
sys.stdout.write("".join("%s\t%d\t%s\n" % c for c in chosen))
say("selected=%d skipped=%d" % (len(chosen), skipped))
TALOS_COLLECT_PY_Kd5Jb7Ye1Pz

cmd_collect() {
  local dir="" have_dir=0 since="" stage=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --since)
        [ $# -ge 2 ] || usage
        case "$2" in ''|*[!0-9]*) echo "pipeline-evidence: --since must be digits only" >&2; usage ;; esac
        since="$2"; shift 2 ;;
      --stage)
        [ $# -ge 2 ] && [ -n "$2" ] || usage
        stage="$2"; shift 2 ;;
      --*) usage ;;
      *)
        [ "$have_dir" = 0 ] || usage
        dir="$1"; have_dir=1; shift ;;
    esac
  done
  [ "$have_dir" = 1 ] || usage
  _enter_toplevel
  local max_files max_mb include
  max_files="$(_evidence_max_files)"
  max_mb="$(_evidence_max_mb)"
  include="$(cfg evidence.include "")"
  _run_py "evidence-collect refused" "$_COLLECT_PY" \
    "$TOPLEVEL" "$dir" "$since" "$max_files" "$max_mb" "$include" "$stage" "$_EVIDENCE_FILE_MB"
}

# ── upload ───────────────────────────────────────────────────────────────────
# Two modes, `body` and `select`, one source so both run through _run_py.
#   body <stage-dir> <body-file> <file-mb>   stdin: the collect manifest (TSV). Re-checks
#       every row against the staged tree (plain names, at most 3 components,
#       allowlisted extension that matches the kind, a regular single-link file
#       reached through no symlink, not empty, not over the per-file cap, at
#       most 50 rows), writes the comment body to <body-file> and prints
#       `<images> <videos>` and then one relpath per line in body order.
#       The body is a fixed template plus those names, never PR or issue text.
#       Every file is referenced in it (gh appends an unreferenced attachment
#       at the END of the body, after the marker); one paragraph per file, so
#       a video renders as a player.
#   select <login> <marker>        stdin: read-comments JSON. Prints the id of
#       every comment written by <login> (case-insensitive) whose LAST
#       non-blank line is <marker>, one per line. Nobody else's comment is ever
#       listed.
read -r -d '' _UPLOAD_PY <<'TALOS_UPLOAD_PY_Fm7Rc1Gk9Ts' || true
import json
import os
import re
import stat
import sys

MIB = 1024 * 1024
FILE_CAP = None         # bytes; set from argv by the `body` dispatch below
MAX_FILES = 50
EXTS = {"png": "image", "jpg": "image", "jpeg": "image", "gif": "image",
        "webm": "video", "mp4": "video", "mov": "video"}
NAME_RE = re.compile(r"[A-Za-z0-9._-]+")
MARKER = "<!-- talos:evidence -->"
FOOTER = (
    "On a public repository these attachments are public: anyone with the "
    "link can open them. Screenshots and recordings can show on-screen "
    "secrets, so check them before relying on them."
)


def refuse(reason):
    sys.stderr.write("evidence-upload refused: %s\n" % reason)
    sys.exit(1)


def check_row(stage, rel, kind):
    parts = rel.split("/")
    if not 1 <= len(parts) <= 3:
        refuse("bad path depth: " + rel)
    for p in parts:
        if NAME_RE.fullmatch(p) is None or p[0] in "-.":
            refuse("unsafe name: " + rel)
    stem, dot, ext = parts[-1].rpartition(".")
    if not dot or EXTS.get(ext.lower()) != kind:
        refuse("extension does not match the kind: " + rel)
    cur = stage
    for i, p in enumerate(parts):
        cur = os.path.join(cur, p)
        try:
            st = os.lstat(cur)
        except OSError:
            refuse("staged file is missing: " + rel)
        if stat.S_ISLNK(st.st_mode):
            refuse("symlink in the staged tree: " + rel)
        if i < len(parts) - 1:
            if not stat.S_ISDIR(st.st_mode):
                refuse("not a directory in the staged tree: " + rel)
        elif not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            refuse("not a regular single-link file: " + rel)
    if st.st_size == 0 or st.st_size > FILE_CAP:
        refuse("empty or over the per-file cap: " + rel)


def mode_body(stage, body_path):
    rows = []
    for line in sys.stdin.read().split("\n"):
        if not line:
            continue
        cols = line.split("\t")
        if len(cols) != 3:
            refuse("malformed manifest row")
        rows.append((cols[0], cols[2]))
    if not 1 <= len(rows) <= MAX_FILES:
        refuse("expected 1-%d files, got %d" % (MAX_FILES, len(rows)))
    if len({r[0] for r in rows}) != len(rows):
        refuse("duplicate path in the manifest")
    for rel, kind in rows:
        check_row(stage, rel, kind)
    ordered = [r for r in rows if r[1] == "image"] + [r for r in rows if r[1] == "video"]
    paras = ["### Evidence", "Screenshots and recordings captured for this change."]
    paras += ["![%s](./%s)" % (rel, rel) for rel, _ in ordered]
    paras += [FOOTER, MARKER]
    with open(body_path, "w", encoding="utf-8") as f:
        f.write("\n\n".join(paras) + "\n")
    images = sum(1 for r in rows if r[1] == "image")
    sys.stdout.write("%d %d\n" % (images, len(rows) - images))
    sys.stdout.write("".join(rel + "\n" for rel, _ in ordered))


def mode_select(login, marker):
    try:
        data = json.load(sys.stdin)
    except ValueError:
        data = None
    items = data.get("comments") if isinstance(data, dict) else data
    if not isinstance(items, list):
        sys.exit("the comments are not a JSON array")
    ids = []
    for c in items:
        if not isinstance(c, dict):
            continue
        who = (c.get("user") or c.get("author") or {}).get("login") or ""
        body = (c.get("body") or "").replace("\r\n", "\n").rstrip()
        if who.lower() == login.lower() and body.rsplit("\n", 1)[-1].strip() == marker:
            ids.append(int(c["id"]))
    sys.stdout.write("".join("%d\n" % i for i in sorted(ids)))


if sys.argv[1] == "body":
    FILE_CAP = int(sys.argv[4]) * MIB
    mode_body(sys.argv[2], sys.argv[3])
else:
    mode_select(sys.argv[2], sys.argv[3])
TALOS_UPLOAD_PY_Fm7Rc1Gk9Ts

# _require_gh_provider <verb> -- the provider check upload and attach share:
# `github`, or `github-api` with a `gh` binary on PATH; returns 2 with one
# stderr line otherwise. Needs the toplevel as cwd (reads the config).
_require_gh_provider() {
  local verb="$1" provider
  provider="$(cfg vcs.provider github)"
  case "$provider" in
    github) ;;
    github-api) ;;
    *) echo "pipeline-evidence: $verb: not implemented for provider '$provider'" >&2; return 2 ;;
  esac
  command -v gh >/dev/null 2>&1 || {
    echo "evidence-$verb unsupported: no gh binary on PATH (gh v2.99.0 or newer required)" >&2
    return 2
  }
}

# _one_line <text> -- the first line of <text>, printable ASCII only, at most
# 200 characters: gh's own stderr, made safe to echo as a reason.
_one_line() {
  local first
  first="$(printf '%s\n' "$1" | head -n 1 | LC_ALL=C tr -c '[:print:]' '?')"
  printf '%s' "${first:0:200}"
}

# _upload_cleanup -- removes the private staging dir (set by cmd_upload).
_upload_cleanup() {
  case "${_UP_ROOT:-}" in
    */talos-evidence-stage.*) rm -rf -- "$_UP_ROOT" ;;
  esac
}

cmd_upload() {
  local pr="" since="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --since)
        [ $# -ge 2 ] || usage
        case "$2" in ''|*[!0-9]*) echo "pipeline-evidence: --since must be digits only" >&2; usage ;; esac
        since="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --*) usage ;;
      *)
        [ -z "$pr" ] || usage
        pr="$1"; shift ;;
    esac
  done
  case "$pr" in ''|*[!0-9]*) echo "pipeline-evidence: upload needs a PR number (digits only)" >&2; usage ;; esac
  _enter_toplevel

  _require_gh_provider upload || return 2

  # The private staging dir: outside the worktree, 0700, removed on exit.
  local root files body
  root="$(mktemp -d "${TMPDIR:-/tmp}/talos-evidence-stage.XXXXXX")" || {
    echo "evidence-upload: cannot create a staging dir in ${TMPDIR:-/tmp}" >&2
    return 1
  }
  _UP_ROOT="$(cd "$root" && pwd -P)" || { rm -rf -- "$root"; return 1; }
  trap _upload_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  case "$_UP_ROOT/" in
    "$TOPLEVEL"/*)
      echo "evidence-upload: the staging dir is inside the worktree (TMPDIR=${TMPDIR:-/tmp}); refusing" >&2
      return 1 ;;
  esac
  files="$_UP_ROOT/files"
  body="$_UP_ROOT/body.md"
  mkdir -m 700 "$files" || return 1

  local dir manifest crc=0
  dir="$(_evidence_dir)"
  local collect_args=(collect "$dir" --stage "$files")
  [ -z "$since" ] || collect_args+=(--since "$since")
  manifest="$(bash "$SCRIPT_DIR/pipeline-evidence.sh" "${collect_args[@]}" 2>"$_UP_ROOT/collect.err")" || crc=$?
  if [ "$crc" = 3 ]; then
    echo "evidence-upload pr=$pr images=0 videos=0 comment= mode=skip"
    return 3
  fi
  if [ "$crc" != 0 ]; then
    echo "evidence-upload: collect failed (rc=$crc): $(_one_line "$(cat "$_UP_ROOT/collect.err" 2>/dev/null)"); nothing posted" >&2
    return 1
  fi

  local built images videos rel
  built="$(printf '%s\n' "$manifest" | _run_py "evidence-upload refused" "$_UPLOAD_PY" body "$files" "$body" "$_EVIDENCE_FILE_MB")" || {
    echo "evidence-upload: could not build the comment; nothing posted" >&2
    return 1
  }
  read -r images videos <<EOF
$(printf '%s\n' "$built" | head -n 1)
EOF
  local attach=()
  while IFS= read -r rel; do
    [ -n "$rel" ] && attach+=(--attach "./$rel")
  done <<EOF
$(printf '%s\n' "$built" | tail -n +2)
EOF
  [ "${#attach[@]}" -gt 0 ] || { echo "evidence-upload: nothing to attach after the re-check" >&2; return 1; }

  local marker="<!-- talos:evidence -->"

  if [ "$dry" = 1 ]; then
    local repo_shown
    repo_shown="$(cfg vcs.repo "")"
    [ -n "$repo_shown" ] || repo_shown="<owner>/<repo>"
    echo "[dry-run] gh pr comment --help (must list --attach)"
    echo "[dry-run] gh api user --jq .login"
    echo "[dry-run] gh api --paginate repos/$repo_shown/issues/$pr/comments (read-comments): own comments whose last line is $marker"
    echo "[dry-run] (cd <staging-dir> && gh pr comment $pr --repo $repo_shown --body-file - ${attach[*]})  # body on stdin"
    echo "[dry-run] gh api --method DELETE repos/$repo_shown/issues/comments/<id>  # each older own evidence comment, after a good post"
    return 0
  fi

  # 1. capability: gh's own help, stdout, no network
  local ver
  if ! _gh_has_attach; then
    ver="$(gh --version 2>/dev/null | head -n 1 | awk '{print $3}')"
    case "$ver" in ''|*[!A-Za-z0-9._+-]*) ver="unknown" ;; esac
    echo "evidence-upload unsupported: gh $ver has no --attach (gh v2.99.0 or newer required)" >&2
    return 2
  fi

  # 2. own login, fail closed (same check as upsert-pr-comment, #381/#392): the
  # lookup must exit 0 AND print a login, because `gh api --jq` prints the raw
  # error JSON to stdout when a token is refused.
  local user base login_re='^[A-Za-z0-9](-?[A-Za-z0-9])*$'
  user="$(gh api user --jq .login 2>/dev/null)" || user=""
  base="${user%"[bot]"}"
  if [ -z "$user" ] || [ "${#base}" -gt 39 ] || ! [[ "$base" =~ $login_re ]]; then
    echo "evidence-upload: could not resolve the authenticated user; nothing posted" >&2
    return 1
  fi

  # 3. repo, for --repo (gh runs outside the worktree) and the delete path
  local repo
  repo="$(cfg vcs.repo "")"
  [ -n "$repo" ] || repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || repo=""
  if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "evidence-upload: could not resolve the repository (set vcs.repo); nothing posted" >&2
    return 1
  fi

  # 4. the author's existing evidence comments (read-comments pages and merges)
  local comments old
  comments="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" read-comments "$pr" 2>/dev/null)" || {
    echo "evidence-upload: could not read the comments of #$pr; nothing posted" >&2
    return 1
  }
  old="$(printf '%s' "$comments" | _run_py "evidence-upload" "$_UPLOAD_PY" select "$user" "$marker")" || {
    echo "evidence-upload: could not parse the comments of #$pr; nothing posted" >&2
    return 1
  }

  # 5. post once (no retry: a retried post can double-post), body on stdin
  local gh_cmd=(gh pr comment "$pr" --repo "$repo" --body-file - "${attach[@]}")
  local out errf url newid
  errf="$_UP_ROOT/gh.err"
  if ! out="$(cd "$files" && "${gh_cmd[@]}" < "$body" 2>"$errf")"; then
    echo "evidence-upload: gh pr comment failed: $(_one_line "$(cat "$errf" 2>/dev/null)"); older evidence comments kept" >&2
    return 1
  fi
  url="$(printf '%s\n' "$out" | grep -E '^https://[^[:space:]]+#issuecomment-[0-9]+$' | tail -n 1)"
  newid="${url##*#issuecomment-}"
  if [ -z "$url" ]; then
    echo "evidence-upload: gh posted but printed no comment URL; older evidence comments kept" >&2
    return 1
  fi

  # 6. delete the older own evidence comments, only now
  local id deleted=0 failed="" mode=new
  for id in $old; do
    [ "$id" = "$newid" ] && continue
    case "$id" in ''|*[!0-9]*) continue ;; esac
    if gh api --method DELETE "repos/$repo/issues/comments/$id" >/dev/null 2>"$errf"; then
      deleted=$((deleted + 1))
    else
      failed="$failed $id"
    fi
  done
  [ "$deleted" -gt 0 ] && mode=replace
  echo "evidence-upload pr=$pr images=$images videos=$videos comment=$url mode=$mode"
  if [ -n "$failed" ]; then
    echo "evidence-upload: posted, but could not delete the older evidence comment(s):$failed" >&2
    return 1
  fi
}

# ── attach ───────────────────────────────────────────────────────────────────
# _attach_cleanup -- removes attach's stderr capture file.
_attach_cleanup() { [ -z "${_AT_ERR:-}" ] || rm -f -- "$_AT_ERR"; }

# _attach_status <upload-rc> <comment-url> <stderr-file> -- the status word for
# upload's exit code (see the header's mapping). The `collect failed` lines are
# matched at a line start: upload writes them itself, and every line that
# carries gh's own text is prefixed by a different reason.
_attach_status() {
  case "$1" in
    0) if [ -n "$2" ]; then echo posted; else echo failed; fi ;;
    3) echo empty ;;
    1)
      if [ -n "$2" ]; then echo posted
      elif grep -Eq '^evidence-upload: collect failed \(rc=4\):' "$3" 2>/dev/null; then echo over-cap
      elif grep -Eq '^evidence-upload: collect failed \(rc=1\):' "$3" 2>/dev/null; then echo refused
      else echo failed
      fi ;;
    *) echo failed ;;
  esac
}

cmd_attach() {
  local pr="" since="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --since)
        [ $# -ge 2 ] || usage
        case "$2" in ''|*[!0-9]*) echo "pipeline-evidence: --since must be digits only" >&2; usage ;; esac
        since="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --*) usage ;;
      *)
        [ -z "$pr" ] || usage
        pr="$1"; shift ;;
    esac
  done
  case "$pr" in ''|*[!0-9]*) echo "pipeline-evidence: attach needs a PR number (digits only)" >&2; usage ;; esac
  _enter_toplevel

  # 1. gate, before anything that can run a command or call a provider
  _evidence_enabled || {
    echo "evidence-attach: evidence disabled" >&2
    return 2
  }
  # 2. provider
  _require_gh_provider attach || return 2

  # 3. capture: in-process, and it never gates the upload
  local cap_out="" cap_rc=0 cap_status="" cap_val="" cap_since=""
  if [ "$dry" = 1 ]; then
    cap_status=skipped
  else
    cap_out="$(cmd_capture)" || cap_rc=$?
    case "$cap_out" in
      "evidence-capture mode=agent") cap_status=agent ;;
      "evidence-capture rc="*" log="*" since="*)
        cap_val="${cap_out#evidence-capture rc=}"; cap_val="${cap_val%% *}"
        cap_since="${cap_out##* since=}"
        case "$cap_val$cap_since" in
          ''|*[!0-9]*) cap_val=""; cap_since="" ;;
        esac
        [ -z "$cap_val" ] || cap_status="$cap_val"
        if [ "${cap_val:-0}" != 0 ]; then
          echo "evidence-attach: evidence.command exited $cap_val (log: ${cap_out#* log=})" >&2
        fi ;;
    esac
    [ -n "$cap_status" ] || cap_status="$cap_rc"
    [ -z "$cap_since" ] || since="$cap_since"
  fi

  # 4. upload: the function, in a subshell so its exit and traps stay its own
  local up_args=("$pr") up_out="" up_rc=0
  [ -z "$since" ] || up_args+=(--since "$since")
  [ "$dry" = 0 ] || up_args+=(--dry-run)
  _AT_ERR="$(mktemp "${TMPDIR:-/tmp}/talos-evidence-attach.XXXXXX")" || {
    echo "evidence-attach: cannot create a temp file in ${TMPDIR:-/tmp}" >&2
    return 1
  }
  trap _attach_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  up_out="$(cmd_upload "${up_args[@]}" 2>"$_AT_ERR")" || up_rc=$?
  cat "$_AT_ERR" >&2
  [ "$up_rc" != 2 ] || return 2

  # the one line upload prints in a real run: digits and a github URL only
  local line="" images=0 videos=0 comment="" re
  re='^evidence-upload pr=[0-9]+ images=([0-9]+) videos=([0-9]+) comment=(https://[^[:space:]]+#issuecomment-[0-9]+)? mode='
  line="$(printf '%s\n' "$up_out" | grep '^evidence-upload pr=' | tail -n 1)"
  if [[ "$line" =~ $re ]]; then
    images="${BASH_REMATCH[1]}"; videos="${BASH_REMATCH[2]}"; comment="${BASH_REMATCH[3]}"
  fi
  local status
  status="$(_attach_status "$up_rc" "$comment" "$_AT_ERR")"

  if [ "$dry" = 1 ]; then
    echo "[dry-run] gate: evidence.enabled=true, provider ok"
    echo "[dry-run] capture: skipped (a real run would run evidence.command, if set)"
    echo "[dry-run] caps: files<=$(_evidence_max_files) mb<=$(_evidence_max_mb) per-file<=$_EVIDENCE_FILE_MB (dir: $(_evidence_dir))"
    echo "[dry-run] upload $pr --dry-run:"
    printf '%s\n' "$up_out"
    [ "$up_rc" = 0 ] && return 0
  else
    [ "$status" = posted ] || comment=""
    echo "evidence-attach pr=$pr status=$status images=$images videos=$videos capture=$cap_status comment=$comment"
  fi
  case "$status" in
    refused|failed) return 1 ;;
  esac
  return 0
}

# ── enabled ──────────────────────────────────────────────────────────────────
# One call for Step 0 of the playbook: is evidence on for this run, and how.
cmd_enabled() {
  [ $# -eq 0 ] || usage
  _enter_toplevel
  _evidence_enabled || return 1
  local provider reason=""
  provider="$(cfg vcs.provider github)"
  case "$provider" in
    github|github-api)
      if ! command -v gh >/dev/null 2>&1; then
        reason="no gh binary on PATH"
      elif ! _gh_has_attach; then
        reason="gh has no --attach (gh v2.99.0 or newer required)"
      fi ;;
    *) reason="provider '$provider' is not supported" ;;
  esac
  if [ -n "$reason" ]; then
    echo "pipeline: evidence ignored: $reason" >&2
    return 1
  fi
  local when mode command
  when="$(cfg evidence.when user-facing)"
  case "$when" in always) ;; *) when="user-facing" ;; esac
  command="$(cfg evidence.command "")"
  case "$command" in *[![:space:]]*) mode=command ;; *) mode=agent ;; esac
  echo "evidence on when=$when mode=$mode"
}

# ── dir ──────────────────────────────────────────────────────────────────────
cmd_dir() {
  [ $# -eq 0 ] || usage
  _enter_toplevel
  printf '%s\n' "$(_evidence_dir)"
}

case "${1:-}" in
  capture) shift; cmd_capture "$@" ;;
  collect) shift; cmd_collect "$@" ;;
  upload) shift; cmd_upload "$@" ;;
  attach) shift; cmd_attach "$@" ;;
  dir) shift; cmd_dir "$@" ;;
  enabled) shift; cmd_enabled "$@" ;;
  *) usage ;;
esac
