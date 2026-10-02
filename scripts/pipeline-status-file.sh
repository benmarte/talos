#!/usr/bin/env bash
# pipeline-status-file.sh -- maintains the tracked status file (TALOS_STATUS.md); not pipeline-status.sh, which sets the Project board status.
#
# Part of epic #333 (status file and resume), sub-task 2 (#344). A sibling of
# pipeline-changelog.sh with the same shape (fragments read from origin/<base>,
# a throwaway detached worktree under with_lock, consumed fragments deleted in
# the same commit, push to the base), but with a per-entry length cap, a
# rolling window and an archive, none of which the changelog script has.
# Nothing calls this script yet; default behaviour is unchanged.
#
# Usage: pipeline-status-file.sh init
#        pipeline-status-file.sh assemble [--pr <pr> --issue <n>]
#
#   init      Create status.file in the current working tree with a title, a
#             one-line "resume with any LLM" note, the status.resume_heading
#             section and the status.log_heading section. An existing file is
#             left alone, except that a missing heading is appended. Ignores
#             status.enabled.
#   assemble  Fold fragments <issue>-<pr>.md from status.fragments_dir on
#             origin/<base> into the log section of status.file on the base
#             branch. Checks status.enabled first (false -> exit 0, no
#             commit), then validates the paths.
#
# Log entries (one per PR, keyed by the prefix `PR #<n> `, trailing space
# included, so #4 never matches #41):
#   - YYYY-MM-DD PR #41 (#13): <text>
#   * The date is the committer date (`git log -1 --format=%cs`) of the last
#     commit on origin/<base> touching the fragment. That is the committer's
#     LOCAL date, not UTC, and in a shallow clone every fragment gets the tip
#     commit's date. Tests use full clones.
#   * The whole entry, `- YYYY-MM-DD PR #n (#m): ` prefix included, is capped
#     at 3 lines and 400 characters (the `…` counts). Continuation lines are
#     indented two spaces. `…` is appended only when something was cut.
#   * Fragment text and PR titles are untrusted: control characters are
#     stripped, each line is whitespace-collapsed, and only 65536 bytes of a
#     fragment are read. Continuation lines are indented, so a fragment cannot
#     start a heading or forge another PR's entry (a line starting with `#`
#     or made only of -=_* is backslash-escaped).
#   * A new entry for a PR that is in the log replaces that entry. A PR that
#     is already in a file under status.archive_dir is not written again.
#     Two fragments for one PR: the highest issue number wins.
#   * Fallback: with --pr/--issue (given together) and no entry for that PR
#     in the fragments, the log or any archive file, one entry is written from
#     the PR title (`pipeline-vcs.sh view-pr <pr>`; the text `merged` when the
#     title cannot be read), dated today.
#
# Rolling window: "today" is UTC, or TALOS_STATUS_TODAY=YYYY-MM-DD. Entries
# are sorted newest first (date, then PR number, descending); an entry is
# kept when (today - entry date) in days <= status.log_days, and at most
# status.log_max are kept. Every other entry is appended to
# <status.archive_dir>/YYYY-MM.md by its own month. Nothing is deleted.
# status.log_days is clamped to 36500 and status.log_max to 10000 (config
# gives them no upper bound); a non-integer or zero value uses the default.
#
# Paths. status.file, status.fragments_dir and status.archive_dir are
# validated by EVERY verb before any read or write: empty, absolute, longer
# than 512 bytes, a `..` or `.git` segment, a backslash and control characters
# are rejected, then the NORMALISED path (`./-rf` is `-rf`) must not start with
# `-` or `:` (exit 1, stderr names the key). The RESOLVED path must stay inside
# the checkout root, and neither the status file, an archive file nor any
# directory component of the three paths may be a symlink. The headings are
# matched as fixed strings; they must start with `#`, be at most 256 bytes,
# contain no control character, and differ from each other.
#
# Staging. The status commit holds exactly what assemble wrote: python lists
# the files it changed in a manifest, which is staged with `git add -f --`
# (status file, archive files) and `git rm -f --` (consumed fragments) under
# --literal-pathspecs; the staged name list is then checked against the
# manifest and anything else aborts before the commit. Nothing is staged with
# `add -A`, so a dirty fresh checkout is never swept in and a status path
# matching .gitignore still lands.
#
# Every python invocation is `python3 -I` (isolated: no cwd on sys.path, no
# user site, no PYTHON* variables), so a module in the caller's cwd is never
# imported.
#
# Push. The push is never forced. Any failed push (non-fast-forward, or a ref
# that moved under the push) refetches and re-assembles from the new base,
# up to 3 attempts. After the third the script exits 1: fragments remain on the
# base, the next run retries, and the caller's checkout is untouched.
#
# Exit codes:
#   0  done, or nothing to do (including status.enabled false).
#   1  usage, config, path, git or push error. Nothing pushed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  # cfg() (#169): config lookups from a per-invocation cache. It owns the EXIT
  # trap; register cleanup through _talos_on_exit so neither clobbers the other.
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  cfg() {
    bash "$SCRIPT_DIR/pipeline-config.sh" "$1" "${2:-}" 2>/dev/null
  }
  # shellcheck disable=SC2064
  _talos_on_exit() { trap "$1" EXIT; }
fi

if [ -f "$SCRIPT_DIR/pipeline-lock.sh" ]; then
  # with_lock (#180): serialize git worktree mutations across stages.
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/pipeline-lock.sh"
else
  with_lock() { shift 3 2>/dev/null; "$@"; }  # unlocked fallback
fi

_sf_err() { echo "pipeline-status-file: $*" >&2; }

USAGE="usage: pipeline-status-file.sh init | assemble [--pr <pr> --issue <n>]"

verb="${1:-}"
case "$verb" in
  init|assemble) shift ;;
  *) echo "$USAGE" >&2; exit 1 ;;
esac

PR=""
ISSUE=""
ARG_ERR=""
if [ "$verb" = "init" ]; then
  [ "$#" -eq 0 ] || ARG_ERR="init takes no arguments"
else
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pr)    PR="${2:-}"; shift 2 2>/dev/null || { ARG_ERR="--pr needs a value"; break; } ;;
      --issue) ISSUE="${2:-}"; shift 2 2>/dev/null || { ARG_ERR="--issue needs a value"; break; } ;;
      *) ARG_ERR="unknown argument: $1"; break ;;
    esac
  done
  if [ -z "$ARG_ERR" ]; then
    if [ -n "$PR" ] || [ -n "$ISSUE" ]; then
      case "$PR" in ''|*[!0-9]*) ARG_ERR="--pr must be a number and be given together with --issue" ;; esac
      case "$ISSUE" in ''|*[!0-9]*) ARG_ERR="--issue must be a number and be given together with --pr" ;; esac
      [ "${#PR}" -le 9 ] && [ "${#ISSUE}" -le 9 ] || ARG_ERR="--pr/--issue are too long"
    fi
  fi
fi

# ── status.enabled gates assemble only (init must work with the key unset) ──
if [ "$verb" = "assemble" ]; then
  _sf_enabled="$(cfg status.enabled false | tr '[:upper:]' '[:lower:]')"
  if [ "$_sf_enabled" != "true" ]; then
    echo "pipeline-status-file: status.enabled is false — nothing to do"
    exit 0
  fi
fi

if [ -n "$ARG_ERR" ]; then
  _sf_err "$ARG_ERR"
  echo "$USAGE" >&2
  exit 1
fi

# ── Config validation (every verb, before any read or write) ─────────────────
# _sf_norm_path KEY VALUE: print the normalized relative path (no empty or `.`
# segments); on a bad value print one stderr line naming KEY and return 1.
_sf_norm_path() {
  local key="$1" val="$2" seg out="" parts
  if [ -z "$val" ]; then _sf_err "$key must not be empty"; return 1; fi
  if [ "${#val}" -gt 512 ]; then _sf_err "$key is longer than 512 bytes"; return 1; fi
  case "$val" in
    /*) _sf_err "$key must be a relative path, not an absolute path"; return 1 ;;
    *\\*) _sf_err "$key must not contain a backslash"; return 1 ;;
    *$'\n'*|*[[:cntrl:]]*) _sf_err "$key must not contain control characters or newlines"; return 1 ;;
  esac
  IFS=/ read -r -a parts <<< "$val"
  for seg in "${parts[@]}"; do
    case "$seg" in
      ''|.) continue ;;
      ..) _sf_err "$key must not contain a '..' segment"; return 1 ;;
      .[Gg][Ii][Tt]) _sf_err "$key must not contain a '.git' segment"; return 1 ;;
    esac
    out="${out:+$out/}$seg"
  done
  if [ -z "$out" ]; then _sf_err "$key must name a path inside the repo"; return 1; fi
  # Validate the NORMALISED path: `./-rf` is `-rf`, and `:(top)x` is a pathspec.
  case "$out" in
    -*) _sf_err "$key must not start with '-'"; return 1 ;;
    :*) _sf_err "$key must not start with ':'"; return 1 ;;
  esac
  printf '%s' "$out"
}

# _sf_check_heading KEY VALUE: fixed-string heading, never a regex.
_sf_check_heading() {
  local key="$1" val="$2"
  if [ -z "$val" ]; then _sf_err "$key must not be empty"; return 1; fi
  if [ "${#val}" -gt 256 ]; then _sf_err "$key is longer than 256 bytes"; return 1; fi
  case "$val" in
    *$'\n'*|*[[:cntrl:]]*) _sf_err "$key must not contain control characters or newlines"; return 1 ;;
    '#'*) ;;
    *) _sf_err "$key must start with '#' (a Markdown heading)"; return 1 ;;
  esac
}

STATUS_FILE="$(_sf_norm_path status.file "$(cfg status.file TALOS_STATUS.md)")" || exit 1
FRAG_DIR="$(_sf_norm_path status.fragments_dir "$(cfg status.fragments_dir docs/status.d)")" || exit 1
ARCHIVE_DIR="$(_sf_norm_path status.archive_dir "$(cfg status.archive_dir status/archive)")" || exit 1
LOG_HEADING="$(cfg status.log_heading '## Log')"
RESUME_HEADING="$(cfg status.resume_heading '## Resume here')"
_sf_check_heading status.log_heading "$LOG_HEADING" || exit 1
_sf_check_heading status.resume_heading "$RESUME_HEADING" || exit 1
if [ "$LOG_HEADING" = "$RESUME_HEADING" ]; then
  _sf_err "status.log_heading and status.resume_heading must differ"
  exit 1
fi

# Positive integers with an upper clamp (the config has no upper bound).
_sf_posint() {  # KEY DEFAULT MAX
  local v
  v="$(cfg "$1" "$2")"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  [ "${#v}" -le 6 ] || v="$3"
  [ "$v" -ge 1 ] 2>/dev/null || v="$2"
  [ "$v" -le "$3" ] || v="$3"
  printf '%s' "$v"
}
LOG_DAYS="$(_sf_posint status.log_days 30 36500)"
LOG_MAX="$(_sf_posint status.log_max 50 10000)"

# ── Python: one implementation of the skeleton, the entry format and the
#    window, shared by init and assemble. Large inputs arrive on stdin
#    (assemble: "<sha> <name>" lines) or are read by python itself. ──────────
IFS= read -r -d '' SF_PY <<'PYEOF' || true
import datetime, json, os, re, subprocess, sys, unicodedata

MAX_LINES = 3
MAX_CHARS = 400
FRAG_READ_CAP = 65536
HEADER = ("# Project status\n\n"
          "To resume with any LLM, read this file and the repo's CLAUDE.md/AGENTS.md.\n")
PLACEHOLDER = "_No resume notes yet._"
# ASCII digits only and at most 9 digits for the PR number: a hand-edited line
# with other digits or a huge number is not an entry, so it is never mis-keyed
# (and int() of a huge string cannot raise).
ENTRY_RE = re.compile(r'^- ([0-9]{4}-[0-9]{2}-[0-9]{2}) PR #([0-9]{1,9}) ')
HEADING_RE = re.compile(r'^(#{1,6})(\s|$)')

(mode, root, status_rel, frag_rel, archive_rel, log_h, resume_h,
 log_days, log_max, today_s, pr_arg, issue_arg, title_file, manifest_file) = sys.argv[1:15]


log_h, resume_h = log_h.strip(), resume_h.strip()


def die(msg):
    sys.stderr.write('pipeline-status-file: %s\n' % msg)
    sys.exit(1)


def parse_date(s):
    try:
        return datetime.datetime.strptime(s, '%Y-%m-%d').date()
    except ValueError:
        return None


root_real = os.path.realpath(root)


def check_inside(rel, key):
    """No symlink on the path; the resolved path stays inside the root, not in .git."""
    cur = root_real
    for part in rel.split('/'):
        cur = os.path.join(cur, part)
        if os.path.islink(cur):
            die('%s has a symlink on its path: %s' % (key, rel))
    real = os.path.realpath(os.path.join(root_real, rel))
    if real != root_real and not real.startswith(root_real + os.sep):
        die('%s resolves outside the repo (symlink?): %s' % (key, rel))
    first = os.path.relpath(real, root_real).split(os.sep)[0]
    if first == '.git':
        die('%s resolves into .git: %s' % (key, rel))
    return os.path.join(root_real, rel)


def read_text(path):
    with open(path, 'r', encoding='utf-8', errors='surrogateescape', newline='') as f:
        return f.read()


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='') as f:
        f.write(text)


def ensure_headings(text):
    """Append whichever of the two headings is missing (resume first)."""
    lines = text.split('\n')
    present = lambda h: any(l.rstrip() == h for l in lines)
    blocks = []
    if not present(resume_h):
        blocks.append('%s\n\n%s\n' % (resume_h, PLACEHOLDER))
    if not present(log_h):
        blocks.append('%s\n' % log_h)
    if not blocks:
        return text
    base = text
    if base and not base.endswith('\n'):
        base += '\n'
    if base and not base.endswith('\n\n'):
        base += '\n'
    return base + '\n'.join(blocks)


def clean_line(s):
    out = []
    for ch in s:
        if ch == '\t':
            out.append(' ')
        elif unicodedata.category(ch) not in ('Cc', 'Cf', 'Cs', 'Co', 'Cn', 'Zl', 'Zp'):
            out.append(ch)
    return ' '.join(''.join(out).split())


def text_lines(raw):
    raw = raw.replace('\r\n', '\n').replace('\r', '\n')
    lines = [clean_line(l) for l in raw.split('\n')]
    lines = [l for l in lines if l]
    if lines:
        lines[0] = re.sub(r'^[-*+]\s+', '', lines[0]) or 'merged'
    return lines or ['merged']


def escape_cont(l):
    if l.startswith('#') or re.fullmatch(r'[-=_*]+', l):
        return '\\' + l
    return l


def build_entry(date, pr, issue, lines):
    out = ['- %s PR #%s (#%s): %s' % (date, pr, issue, lines[0])]
    out += ['  ' + escape_cont(l) for l in lines[1:]]
    cut = len(out) > MAX_LINES
    out = out[:MAX_LINES]
    text = '\n'.join(out)
    if len(text) > MAX_CHARS:
        cut = True
    if cut:
        text = text[:MAX_CHARS - 1].rstrip() + '…'
    return text


if mode == 'init':
    status_path = check_inside(status_rel, 'status.file')
    check_inside(frag_rel, 'status.fragments_dir')
    check_inside(archive_rel, 'status.archive_dir')
    if os.path.isdir(status_path):
        die('status.file is a directory: %s' % status_rel)
    if os.path.exists(status_path):
        old = read_text(status_path)
        new = ensure_headings(old)
        if new != old:
            write_text(status_path, new)
            print('pipeline-status-file: appended the missing heading(s) to %s' % status_rel)
        else:
            print('pipeline-status-file: %s already has both headings' % status_rel)
    else:
        write_text(status_path, ensure_headings(HEADER))
        print('pipeline-status-file: created %s' % status_rel)
    sys.exit(0)

if mode == 'verify':
    # stdin: `git diff --cached --name-status -z --no-renames` of the throwaway
    # worktree. The staged set must be exactly the manifest: the status file and
    # archive files (A or M), consumed fragments (D), and nothing else.
    fields = [f for f in sys.stdin.buffer.read().decode('utf-8', 'surrogateescape').split('\0') if f]
    if len(fields) % 2:
        die('could not parse the staged name list')
    staged = [(fields[i], fields[i + 1]) for i in range(0, len(fields), 2)]
    want = {}
    with open(manifest_file) as mf:
        for line in mf:
            letter, path = line.rstrip('\n').split('\t', 1)
            ok = (path == status_rel or path.startswith(archive_rel + '/')) if letter == 'A' \
                else path.startswith(frag_rel + '/')
            if not ok:
                die('refusing to commit: %s is not an expected status path' % path)
            want[path] = letter
    for letter, path in staged:
        exp = want.get(path)
        if exp is None or (exp == 'A' and letter not in ('A', 'M')) or (exp == 'D' and letter != 'D'):
            die('refusing to commit: unexpected staged change %s %s' % (letter, path))
    missing = sorted(set(want) - set(p for _, p in staged))
    if missing:
        die('refusing to commit: expected change not staged: %s' % ', '.join(missing))
    sys.exit(0)

# ── assemble (root is the throwaway worktree) ───────────────────────────────
today = parse_date(today_s)
if today is None:
    die('TALOS_STATUS_TODAY must be YYYY-MM-DD, got: %s' % today_s)
log_days = int(log_days)
log_max = int(log_max)

status_path = check_inside(status_rel, 'status.file')
frag_root = check_inside(frag_rel, 'status.fragments_dir')
archive_root = check_inside(archive_rel, 'status.archive_dir')

frags = []  # (pr, issue, sha, name)
for line in sys.stdin.read().splitlines():
    if ' ' not in line:
        continue
    sha, name = line.split(' ', 1)
    m = re.fullmatch(r'([0-9]{1,9})-([0-9]{1,9})\.md', name)
    if m and re.fullmatch(r'[0-9a-f]{40,64}', sha):
        frags.append((int(m.group(2)), int(m.group(1)), sha, name))


def git_out(*args):
    p = subprocess.run(['git', '-C', root_real] + list(args),
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.returncode, p.stdout.decode('utf-8', 'replace').strip()


def read_fragment(sha):
    p = subprocess.Popen(['git', '-C', root_real, 'cat-file', 'blob', sha],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    data = p.stdout.read(FRAG_READ_CAP + 1)
    if len(data) > FRAG_READ_CAP:
        data = data[:FRAG_READ_CAP]
        p.kill()
        p.wait()
    elif p.wait() != 0:
        die('could not read fragment blob %s' % sha)
    p.stdout.close()
    return data.decode('utf-8', 'replace')


def fragment_date(name):
    rc, out = git_out('log', '-1', '--format=%cs', 'HEAD', '--', '%s/%s' % (frag_rel, name))
    return out if rc == 0 and parse_date(out) else today.isoformat()


# Archive: which PRs are already archived.
archived = set()
if os.path.isdir(archive_root):
    for fn in sorted(os.listdir(archive_root)):
        ap = os.path.join(archive_root, fn)
        if fn.endswith('.md'):
            check_inside(os.path.join(archive_rel, fn), 'status.archive_dir')
        if fn.endswith('.md') and os.path.isfile(ap):
            for l in read_text(ap).split('\n'):
                m = ENTRY_RE.match(l)
                if m:
                    archived.add(int(m.group(2)))

# Status file: the existing text (or the skeleton) with both headings.
if os.path.exists(status_path):
    if os.path.isdir(status_path):
        die('status.file is a directory: %s' % status_rel)
    orig_text = read_text(status_path)
else:
    orig_text = ''
text = ensure_headings(orig_text if os.path.exists(status_path) else HEADER)
lines = text.split('\n')
if lines and lines[-1] == '':
    lines.pop()

idx = next(i for i, l in enumerate(lines) if l.rstrip() == log_h)
level = len(log_h) - len(log_h.lstrip('#'))
end = len(lines)
for j in range(idx + 1, len(lines)):
    m = HEADING_RE.match(lines[j])
    if m and len(m.group(1)) <= level:
        end = j
        break
head, section, tail = lines[:idx], lines[idx + 1:end], lines[end:]

entries = []  # [date, pr, text]
pre = []
cur = None
for l in section:
    m = ENTRY_RE.match(l)
    if m and parse_date(m.group(1)):
        cur = [m.group(1), int(m.group(2)), [l]]
        entries.append(cur)
    elif cur is not None and l[:1] in (' ', '\t'):
        cur[2].append(l)
    elif l.strip() == '':
        cur = None
        if not entries:
            pre.append(l)
    else:
        cur = None
        pre.append(l)
entries = [[d, p, '\n'.join(t)] for d, p, t in entries]
while pre and pre[0].strip() == '':
    pre.pop(0)
while pre and pre[-1].strip() == '':
    pre.pop()
log_keys = set(e[1] for e in entries)

# New entries from fragments (one per PR, highest issue number wins).
new = {}
for pr, issue, sha, name in sorted(frags, key=lambda f: (f[0], f[1])):
    new[pr] = (issue, name, sha)
consumed = [f[3] for f in frags]
added = {}
for pr, (issue, name, sha) in new.items():
    if pr in archived and pr not in log_keys:
        continue
    date = fragment_date(name)
    added[pr] = [date, pr, build_entry(date, pr, issue, text_lines(read_fragment(sha)))]

fallback_pr = None
if pr_arg:
    pr_n = int(pr_arg)
    if pr_n not in new and pr_n not in log_keys and pr_n not in archived:
        title = 'merged'
        try:
            with open(title_file, 'rb') as f:
                obj = json.loads(f.read(65536).decode('utf-8', 'replace'))
            if isinstance(obj, dict) and isinstance(obj.get('title'), str):
                title = text_lines(obj['title'])[0]
        except (OSError, ValueError):
            pass
        added[pr_n] = [today.isoformat(), pr_n,
                       build_entry(today.isoformat(), pr_n, issue_arg, [title])]
        fallback_pr = pr_n

entries = [e for e in entries if e[1] not in added] + list(added.values())

# Window: newest first, keep age <= log_days, then the log_max cut.
entries.sort(key=lambda e: (e[0], e[1]), reverse=True)
kept, rotated = [], []
for e in entries:
    age = (today - parse_date(e[0])).days
    if age <= log_days and len(kept) < log_max:
        kept.append(e)
    else:
        rotated.append(e)

# Archive writes, by the entry's own month; an archived PR is never duplicated.
written = []  # (letter, repo-relative path) of everything changed, for the staging step
by_month = {}
for e in rotated:
    if e[1] in archived:
        continue
    archived.add(e[1])
    by_month.setdefault(e[0][:7], []).append(e[2])
for month in sorted(by_month):
    ap = check_inside(os.path.join(archive_rel, month + '.md'), 'status.archive_dir')
    body = read_text(ap) if os.path.exists(ap) else '# Status archive %s\n\n' % month
    if not body.endswith('\n'):
        body += '\n'
    write_text(ap, body + '\n'.join(by_month[month]) + '\n')
    written.append(('A', '%s/%s.md' % (archive_rel, month)))

body = list(pre)
if pre and kept:
    body.append('')
for e in kept:
    body += e[2].split('\n')
out = head + [lines[idx]] + ([''] + body if body else [])
if tail:
    out += [''] + tail
new_text = '\n'.join(out) + '\n'
if new_text != orig_text:
    write_text(status_path, new_text)
    written.append(('A', status_rel))

# Consumed fragments are removed by `git rm` in the staging step, not here.
for name in sorted(set(consumed)):
    written.append(('D', '%s/%s' % (frag_rel, name)))
with open(manifest_file, 'w') as mf:
    for letter, path in written:
        mf.write('%s\t%s\n' % (letter, path))

print('pipeline-status-file: assembled %d fragment(s)%s, %d entr%s archived' % (
    len(set(consumed)),
    ', 1 fallback entry for PR #%d' % fallback_pr if fallback_pr else '',
    len(rotated), 'y' if len(rotated) == 1 else 'ies'))
PYEOF

TODAY="${TALOS_STATUS_TODAY:-$(date -u +%Y-%m-%d)}"

# ── init: operates on the caller's working tree ──────────────────────────────
if [ "$verb" = "init" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  python3 -I -c "$SF_PY" init "$ROOT" "$STATUS_FILE" "$FRAG_DIR" "$ARCHIVE_DIR" \
    "$LOG_HEADING" "$RESUME_HEADING" "$LOG_DAYS" "$LOG_MAX" "$TODAY" "" "" "" "" </dev/null
  exit $?
fi

# ── assemble ─────────────────────────────────────────────────────────────────
BASE_BRANCH="$(cfg base_branch "" 2>/dev/null)"
if [ -z "$BASE_BRANCH" ]; then
  BASE_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')"
fi
[ -z "$BASE_BRANCH" ] && BASE_BRANCH="main"
# Conservative ref-name set: starts with an alphanumeric (never an option),
# then letters, digits and . _ / - only; no `..`, `//`, trailing `/` or `.lock`.
case "$BASE_BRANCH" in
  [!A-Za-z0-9]*|*[!A-Za-z0-9._/-]*|*..*|*//*|*/|*.lock)
    _sf_err "base branch is not an accepted branch name: $BASE_BRANCH"
    exit 1
    ;;
esac
if ! git check-ref-format "refs/heads/$BASE_BRANCH" 2>/dev/null; then
  _sf_err "base branch is not a valid branch name: $BASE_BRANCH"
  exit 1
fi

# _sf_list_fragments: print "<sha> <name>" for each regular-file fragment
# (<issue>-<pr>.md) in status.fragments_dir on origin/<base>. A missing dir is
# no fragments (rc 0); a listing that fails, or a dir that is not a tree (a
# file or a symlink), is rc 1, never "no fragments". Read through the object
# store, so no symlink on the working tree can redirect it.
_sf_list_fragments() {
  local tree="origin/$BASE_BRANCH:$FRAG_DIR" out
  if ! git cat-file -e "$tree" 2>/dev/null; then
    git rev-parse -q --verify "origin/$BASE_BRANCH^{tree}" >/dev/null 2>&1 || return 1
    return 0
  fi
  [ "$(git cat-file -t "$tree" 2>/dev/null)" = "tree" ] || return 1
  out="$(git ls-tree "$tree")" || return 1
  printf '%s\n' "$out" | awk -F'\t' \
    '$1 ~ /^100(644|755) blob / && $2 ~ /^[0-9]+-[0-9]+\.md$/ && length($2) <= 22 { split($1, a, " "); print a[3] " " $2 }'
}

# ── Disposable worktree (same shape as pipeline-changelog.sh): outside any
# checkout, serialized with with_lock on the key pipeline-worktree.sh uses,
# removed on every exit path including INT/TERM. ─────────────────────────────
_SF_LOCK="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/talos-worktree"
_SF_TMP=""
_sf_drop_wt() {
  [ -n "$_SF_TMP" ] || return 0
  if [ -d "$_SF_TMP/wt" ]; then
    with_lock "$_SF_LOCK" 10 -- git worktree remove --force "$_SF_TMP/wt" >/dev/null 2>&1
  fi
  rm -rf "$_SF_TMP/wt" 2>/dev/null
  return 0
}
_sf_cleanup() {
  # A second signal must not abort the cleanup half-way and leak the checkout.
  trap '' INT TERM HUP QUIT
  _sf_drop_wt
  [ -n "$_SF_TMP" ] && rm -rf "$_SF_TMP" 2>/dev/null
  _SF_TMP=""
  return 0
}
_talos_on_exit '_sf_cleanup'
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM

_SF_TMP="$(mktemp -d "${TMPDIR:-/tmp}/talos-status.XXXXXX" 2>/dev/null)"
if [ -z "$_SF_TMP" ]; then
  _sf_err "mktemp failed"
  exit 1
fi

# _sf_stage_commit SUBJECT: stage exactly what python wrote (the manifest in
# $_SF_MANIFEST) in the throwaway worktree, check the staged set against the
# manifest, and commit it with SUBJECT. Returns 1 with a stderr line on any
# failure; nothing is pushed. Shared by every verb that commits.
_sf_stage_commit() {
  local subject="$1" k p
  # Stage exactly what python wrote, nothing else (never `add -A`: a dirty
  # fresh checkout must not be swept in, and a status path matching .gitignore
  # must still land, hence -f). Paths follow `--` and are literal, not pathspecs.
  _SF_ADDS=()
  _SF_DELS=()
  while IFS=$'\t' read -r k p; do
    case "$k" in
      A) _SF_ADDS+=("$p") ;;
      D) _SF_DELS+=("$p") ;;
    esac
  done < "$_SF_MANIFEST"
  if [ "${#_SF_ADDS[@]}" -gt 0 ] && \
     ! git --literal-pathspecs -C "$_SF_TMP/wt" add -f -- "${_SF_ADDS[@]}"; then
    _sf_err "git add failed"
    return 1
  fi
  if [ "${#_SF_DELS[@]}" -gt 0 ] && \
     ! git --literal-pathspecs -C "$_SF_TMP/wt" rm -q -f -- "${_SF_DELS[@]}"; then
    _sf_err "git rm failed"
    return 1
  fi
  # The staged name list must be exactly the manifest; anything else aborts.
  if ! git --literal-pathspecs -C "$_SF_TMP/wt" diff --cached --name-status -z --no-renames \
      | python3 -I -c "$SF_PY" verify "$_SF_TMP/wt" "$STATUS_FILE" "$FRAG_DIR" "$ARCHIVE_DIR" \
          "$LOG_HEADING" "$RESUME_HEADING" "$LOG_DAYS" "$LOG_MAX" "$TODAY" "" "" "" "$_SF_MANIFEST"; then
    _sf_err "staged changes differ from what $VERB wrote — nothing committed or pushed"
    return 1
  fi
  if ! git -C "$_SF_TMP/wt" -c user.email=talos@local -c user.name=talos-status \
      -c commit.gpgsign=false commit -q --no-verify -m "$subject"; then
    _sf_err "commit failed"
    return 1
  fi
  return 0
}

TITLE_TRIED=""
MAX_ATTEMPTS=3
attempt=1
while :; do
  if ! git fetch -q -- origin "$BASE_BRANCH" 2>/dev/null; then
    _sf_err "git fetch origin $BASE_BRANCH failed"
    exit 1
  fi
  if ! git rev-parse -q --verify "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    _sf_err "origin/$BASE_BRANCH does not resolve after fetch"
    exit 1
  fi

  FRAG_LIST="$(_sf_list_fragments)" || {
    _sf_err "could not list $FRAG_DIR on origin/$BASE_BRANCH"
    exit 1
  }
  if [ -z "$FRAG_LIST" ] && [ -z "$PR" ]; then
    echo "pipeline-status-file: no fragments under $FRAG_DIR on origin/$BASE_BRANCH — nothing to assemble"
    exit 0
  fi

  # The fallback title is fetched once, and only when no fragment names the pair.
  if [ -n "$PR" ] && [ -z "$TITLE_TRIED" ] && \
     ! printf '%s\n' "$FRAG_LIST" | grep -q " ${ISSUE}-${PR}\.md\$"; then
    TITLE_TRIED=1
    bash "$SCRIPT_DIR/pipeline-vcs.sh" view-pr "$PR" 2>/dev/null \
      | head -c 65536 > "$_SF_TMP/title.json" || true
  fi

  if ! with_lock "$_SF_LOCK" 10 -- \
      git worktree add -q --detach "$_SF_TMP/wt" "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    _sf_err "could not create temp worktree for origin/$BASE_BRANCH"
    exit 1
  fi

  _SF_MANIFEST="$_SF_TMP/manifest"
  rm -f "$_SF_MANIFEST"
  printf '%s\n' "$FRAG_LIST" | python3 -I -c "$SF_PY" assemble "$_SF_TMP/wt" \
    "$STATUS_FILE" "$FRAG_DIR" "$ARCHIVE_DIR" "$LOG_HEADING" "$RESUME_HEADING" \
    "$LOG_DAYS" "$LOG_MAX" "$TODAY" "$PR" "$ISSUE" "$_SF_TMP/title.json" "$_SF_MANIFEST"
  _SF_RC=$?
  if [ "$_SF_RC" -ne 0 ]; then
    _sf_err "assembly failed (rc=$_SF_RC) — fragments left in place"
    exit 1
  fi

  # Nothing changed (no new entry, no rotation, no fragment): a no-op. This is
  # what makes a repeated fallback quiet.
  if [ ! -s "$_SF_MANIFEST" ]; then
    echo "pipeline-status-file: nothing to assemble"
    exit 0
  fi

  _sf_stage_commit "docs(status): assemble status log [skip ci]" || exit 1

  if _SF_PUSH_ERR="$(git -C "$_SF_TMP/wt" push -q origin "HEAD:refs/heads/$BASE_BRANCH" 2>&1)"; then
    echo "pipeline-status-file: assembled the status log into $STATUS_FILE on $BASE_BRANCH and pushed"
    exit 0
  fi

  _sf_err "push to $BASE_BRANCH failed (attempt $attempt of $MAX_ATTEMPTS)"
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    _sf_err "${_SF_PUSH_ERR:-no output from git push}"
    _sf_err "gave up after $MAX_ATTEMPTS attempts — fragments remain on $BASE_BRANCH, next assemble retries"
    exit 1
  fi
  _sf_drop_wt
  attempt=$((attempt + 1))
done
