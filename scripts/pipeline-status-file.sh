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
#        pipeline-status-file.sh assemble [--pr <pr> --issue <n>] [--refresh]
#        pipeline-status-file.sh refresh [--print]
#
#   init      Create status.file in the current working tree with a title, a
#             one-line "resume with any LLM" note, the status.resume_heading
#             section and the status.log_heading section. An existing file is
#             left alone, except that a missing heading is appended. Ignores
#             status.enabled.
#   assemble  Fold fragments <issue>-<pr>.md from status.fragments_dir on
#             origin/<base> into the log section of status.file on the base
#             branch. Checks status.enabled first (false -> exit 0, no
#             commit), then validates the paths. With --refresh the Resume
#             block (below) is regenerated in the SAME commit, so a merge costs
#             one status commit; if the GitHub read fails the log is still
#             assembled and pushed and stderr carries one line saying the
#             Resume block was not refreshed.
#   refresh   Regenerate the Resume block and push it (subject `docs(status):
#             refresh resume block [skip ci]`); a block identical to the base's
#             is a no-op (exit 0, no commit). Checks status.enabled first.
#   refresh --print
#             The block on stdout (heading, blank line, lines). Ignores
#             status.enabled. Creates no worktree, commit or push and calls no
#             write verb; it does run `git fetch origin <base>`, which only
#             moves origin/<base>, so Base matches what refresh computes.
#
# The Resume block (everything from status.resume_heading up to the next
# Markdown heading of ANY level, so a `# Resume here` above `## Log` never
# swallows the log). A pure function of the GitHub state and of origin/<base>: no
# timestamp, no hostname, explicit sorting, so concurrent runs converge on the
# same bytes. Lines, in this order (a group with nothing in it is omitted):
#   - Base: <base_branch> @ <sha>      newest commit on origin/<base> touching a
#                                      path outside status.file, status.fragments_dir
#                                      and status.archive_dir (`none` if there is none)
#   - Next: <action>                   see below
#   - PR #<M> (#<N>) head <sha> next: <stage>
#                                      one per open PR of the pipeline, ascending.
#                                      A pipeline PR has a head branch matching
#                                      ^(fix|feat)/issue-<digits>(-|$), baseRefName
#                                      equal to the base branch, and either a Talos
#                                      label (exactly a name in the stage or
#                                      approval lists of pipeline-contract.sh:
#                                      pipeline:ready ... pipeline:epic-children-done,
#                                      qa:pass, docs:done, review:approved,
#                                      security:approved, adversarial:approved; an
#                                      unlisted `pipeline:x` is not one) or a listing
#                                      that says isCrossRepository is false (absent
#                                      means a label is needed): a fork PR cannot
#                                      claim a pipeline slot by its branch name.
#                                      Others are never looked up and get no PR line.
#   - Blocked: <issue|PR> #<n> [question] <q>   pipeline:blocked; <q> is the
#                                      needs-owner question; without one the line
#                                      is `[see comments]`
#   - Owner: #<n> [answered|unanswered|unverified] <question>   one per
#                                      `list-needs-owner --json` item; the status
#                                      is a fixed field BEFORE the untrusted
#                                      question, `unverified` when
#                                      talos:marker-authors-unverified was printed
#   - Queued: #a, #b, ...              open issues labelled pipeline:ready in p0,
#                                      p1, p2, unlabelled order, then by number
#   - Ignored: <K> open PR(s) with a pipeline-style branch name and no Talos
#                                      label from a fork   (count only; never cut)
#   - Note: ...                        only when list-prs or list-issues reported
#                                      a cap; always the last line (never cut)
# Next, first match wins: `merge #M` (lowest-numbered PR at stage merge);
# `resume #M at <stage>` (lowest-numbered PR at any other stage except blocked
# and human-merge; `unverified` renders `resume #M at unverified`); `start #n`
# (first queued issue); `waiting on human merge of #M` (lowest PR at
# human-merge); `waiting on owner` (no PR is actionable, nothing is queued, and
# an Owner or Blocked line exists or a PR carries pipeline:needs-owner);
# `nothing queued`. A PR (or its issue) labelled pipeline:needs-owner is never
# offered as merge or resume, and an issue labelled both pipeline:ready and
# pipeline:needs-owner is never offered as `start #n` (it still counts as
# waiting on owner, and still appears on the Queued line). Next sees only the PRs
# that were looked up: the lowest-numbered ones the line cap shows, plus every
# higher-numbered PR that carries the approval label of every enabled role (and
# neither pipeline:blocked nor pipeline:needs-owner), so a merge-ready PR is never
# hidden by the cap. Those extra PRs are looked up like the others; their lines
# are cut by the cap like any other line, and `Next` still names them. At most as
# many extra PRs are looked up as the cap shows (the lowest-numbered ones), so the
# cost stays bounded even when no role is enabled and every PR qualifies.
# Stage of a PR, first match wins, counting only enabled roles (roles.qa,
# docs, reviewer, security default true; roles.adversarial defaults false) and
# treating an approval label as missing when check-approval-sha --stale-list
# names its role: `blocked` (the PR or its issue carries pipeline:blocked);
# when pr.draft is true and pr-is-draft exits 0: docs, reviewer, security,
# adversarial, `ready` (exit 2: `unverified`; exit 1 uses the default order);
# otherwise qa, docs, reviewer, security, adversarial; `ci` when
# merge.required_checks is set and pr-checks-required is not exit 0; then
# `merge` (merge.auto, default true) or `human-merge`.
# The block is capped at status.resume_max_lines (default 40, never fewer than
# 3 lines): Base and Next are kept, the rest is cut and the last line says
# `- +<K> more`. The cap is applied BEFORE the per-PR reads: only the lowest-
# numbered PRs that will be shown are looked up (pr-head, check-approval-sha,
# pr-is-draft, pr-checks-required), the rest are counted in the `more` line, so
# 300 PRs cost the same number of reads as 40. Text of the other sections is
# never touched.
# The whole read phase has a deadline (120 s, TALOS_STATUS_READ_DEADLINE
# overrides it, in seconds; 1 to 4 ASCII digits, 1..3600, anything else is the
# default): a read verb that is still running when it passes
# is killed and counts as a failed read (`refresh` exits 1 and pushes nothing;
# `assemble --refresh` assembles the log only). INT, TERM or HUP that reaches the
# read phase kills the running read verb (its whole process group) before the
# script exits. A signal that reaches only the outer bash waits for the read
# phase to finish (bash runs its trap after the foreground command), bounded by
# the deadline.
#
# Reads (GitHub, once, before the retry loop; read verbs only, nothing is
# written to GitHub): list-prs, list-issues, pr-head, check-approval-sha
# --stale-list (only `stale role=` lines count; exit 1 without one is a failed
# read), pr-checks-required, pr-is-draft, list-needs-owner --json (never
# --clear-answered). Fail closed: list-prs, list-issues, pr-head,
# check-approval-sha or list-needs-owner exiting non-zero (list-needs-owner
# exit 2, an unsupported provider, excepted: no Owner lines) makes `refresh`
# exit 1 with nothing pushed. `talos:marker-authors-unverified` on
# list-needs-owner's stderr means `answered` is unverified: every Owner line is
# `[unverified]`, never `[answered]`.
# Every rendered line is one line: control characters removed, Markdown
# escaped (no heading, list item, code fence, link or `<!--`), 160 characters.
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
#   * Spend (#384): an entry whose (issue, PR) pair has stage events in the
#     events log reads `- DATE PR #P (#I): [3.41M tokens] <text>` (or
#     `[PR 3.41M · issue 3.52M tokens]` when the issue total differs, `, +K
#     unrecorded`, or `[tokens unrecorded]`). The figures come from
#     `pipeline-events.sh cost --json` run in the caller's checkout before the
#     temporary worktree exists, orchestrator rows dropped, and reach python as
#     files, formatted by pipeline-spend-format.py (loaded by explicit path
#     from this script's directory). No log, no events for the pair, an
#     unusable result or a missing module: the entry is untagged. The tag leads
#     the text, so the cap above only cuts the text. Only a new fragment for
#     the same PR replaces an entry (and retags it); a second --pr fallback
#     run is a no-op.
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
# than 512 BYTES (not characters: `é` is two), a `..` or `.git` segment, a
# backslash and control characters
# are rejected, then the NORMALISED path (`./-rf` is `-rf`) must not start with
# `-` or `:` (exit 1, stderr names the key). The three normalised paths must not
# be equal and none may sit inside another (`docs/status` over
# `docs/status/archive`), compared casefolded (the macOS default filesystem is
# case-insensitive): exit 1, stderr names both keys. The RESOLVED path must
# stay inside the checkout root, and neither the status file, an archive file nor any
# directory component of the three paths may be a symlink. The headings are
# matched as fixed strings; they must start with `#`, be at most 256 BYTES,
# contain no control character, and differ from each other.
# A config file that cannot be read (malformed, or PyYAML missing for a YAML
# file) while status.enabled is not set in another layer is an error, not
# "disabled": assemble and refresh exit 1 with their own message.
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
# Accepted limits (the next run repairs both, by design):
#   - A retry reuses the GitHub snapshot read before the loop; only origin/<base>
#     is refetched. If GitHub changed meanwhile, the pushed block is one run
#     old and the next refresh republishes the right one.
#   - A signal that reaches only the outer bash while the push runs lets the
#     push land, and the script then exits 128+signal (143 for TERM) although
#     it pushed. A rerun finds the block up to date and the fragments consumed.
#
# Exit codes:
#   0  done, or nothing to do (including status.enabled false).
#   1  usage, config, path, git or push error, or (refresh) a failed GitHub
#      read. Nothing pushed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  # cfg() (#169): config lookups from a per-invocation cache. It owns the EXIT
  # trap; register cleanup through _talos_on_exit so neither clobbers the other.
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  # No per-call fallback (#440): it ran pipeline-config.sh under 2>/dev/null
  # inside $(...), so a broken defaults table (exit 3) would read as "role off".
  echo "talos: pipeline-cfg-cache.sh missing; reinstall Talos" >&2
  exit 1
fi

if [ -f "$SCRIPT_DIR/pipeline-lock.sh" ]; then
  # with_lock (#180): serialize git worktree mutations across stages.
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/pipeline-lock.sh"
else
  with_lock() { shift 3 2>/dev/null; "$@"; }  # unlocked fallback
fi

# The Talos label list (#454): `refresh` counts a PR as the pipeline's when it
# carries a label named in the contract, not one that merely starts `pipeline:`.
# A missing file leaves the arrays unset; _sf_collect then fails the read.
if [ -f "$SCRIPT_DIR/pipeline-contract.sh" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/pipeline-contract.sh"
fi

_sf_err() { echo "pipeline-status-file: $*" >&2; }

USAGE="usage: pipeline-status-file.sh init | assemble [--pr <pr> --issue <n>] [--refresh] | refresh [--print]"

verb="${1:-}"
case "$verb" in
  init|assemble|refresh) shift ;;
  *) echo "$USAGE" >&2; exit 1 ;;
esac

PR=""
ISSUE=""
ARG_ERR=""
PRINT=""    # refresh --print: block on stdout, no writes
REFRESH=""  # assemble --refresh: regenerate the block in the same commit
if [ "$verb" = "init" ]; then
  [ "$#" -eq 0 ] || ARG_ERR="init takes no arguments"
elif [ "$verb" = "refresh" ]; then
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --print) [ -z "$PRINT" ] || { ARG_ERR="--print given twice"; break; }; PRINT=1; shift ;;
      *) ARG_ERR="unknown argument: $1"; break ;;
    esac
  done
else
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pr)    PR="${2:-}"; shift 2 2>/dev/null || { ARG_ERR="--pr needs a value"; break; } ;;
      --issue) ISSUE="${2:-}"; shift 2 2>/dev/null || { ARG_ERR="--issue needs a value"; break; } ;;
      --refresh) [ -z "$REFRESH" ] || { ARG_ERR="--refresh given twice"; break; }; REFRESH=1; shift ;;
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

# ── status.enabled gates assemble and refresh (init and refresh --print must
#    work with the key unset) ──
if [ "$verb" = "assemble" ] || { [ "$verb" = "refresh" ] && [ -z "$PRINT" ]; }; then
  # A config that cannot be read must not read as "disabled" (#454): --has exits
  # 3 when the key is not found AND a config file failed to parse (0 set, 1 absent).
  _sf_has_rc=0
  bash "$SCRIPT_DIR/pipeline-config.sh" --has status.enabled >/dev/null 2>&1 || _sf_has_rc=$?
  if [ "$_sf_has_rc" -ge 2 ]; then
    _sf_err "cannot read the config (a config file could not be parsed, or pipeline-config.sh failed, rc=$_sf_has_rc): not treating status.enabled as false"
    exit 1
  fi
  _sf_enabled="$(cfg status.enabled | tr '[:upper:]' '[:lower:]')"
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
# _sf_bytes VALUE: the length in BYTES (`${#v}` counts characters in a UTF-8
# locale, so `é` is 1 there and 2 on disk).
_sf_bytes() {
  local n
  n="$(printf '%s' "$1" | LC_ALL=C wc -c)"
  printf '%s' "$((n))"
}

_sf_norm_path() {
  local key="$1" val="$2" seg out="" parts
  if [ -z "$val" ]; then _sf_err "$key must not be empty"; return 1; fi
  if [ "$(_sf_bytes "$val")" -gt 512 ]; then _sf_err "$key is longer than 512 bytes"; return 1; fi
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
  if [ "$(_sf_bytes "$val")" -gt 256 ]; then _sf_err "$key is longer than 256 bytes"; return 1; fi
  case "$val" in
    *$'\n'*|*[[:cntrl:]]*) _sf_err "$key must not contain control characters or newlines"; return 1 ;;
    '#'*) ;;
    *) _sf_err "$key must start with '#' (a Markdown heading)"; return 1 ;;
  esac
}

STATUS_FILE="$(_sf_norm_path status.file "$(cfg status.file)")" || exit 1
FRAG_DIR="$(_sf_norm_path status.fragments_dir "$(cfg status.fragments_dir)")" || exit 1
ARCHIVE_DIR="$(_sf_norm_path status.archive_dir "$(cfg status.archive_dir)")" || exit 1
# The three paths must be disjoint (#454): equal, or one inside another, and an
# assemble would write the log into its own fragments or archive. Compared
# CASEFOLDED, always: the macOS default filesystem is case-insensitive, so
# `Docs/status` and `docs/status/archive` are nested there; on a case-sensitive
# one the false "nested" only fails closed.
_sf_folded="$(python3 -I -c 'import sys; print("\n".join(a.casefold() for a in sys.argv[1:]))' \
  "$STATUS_FILE" "$FRAG_DIR" "$ARCHIVE_DIR")" || { _sf_err "python3 failed while comparing the status paths"; exit 1; }
{ read -r _sf_f_file; read -r _sf_f_frag; read -r _sf_f_arch; } <<< "$_sf_folded"
_sf_disjoint() {  # KEY_A PATH_A FOLDED_A KEY_B PATH_B FOLDED_B
  if [ "$3" = "$6" ]; then _sf_err "$1 and $4 must differ: $2 and $5 are the same path"; return 1; fi
  case "$3/" in "$6"/*) _sf_err "$1 ($2) must not be inside $4 ($5)"; return 1 ;; esac
  case "$6/" in "$3"/*) _sf_err "$4 ($5) must not be inside $1 ($2)"; return 1 ;; esac
}
_sf_disjoint status.file "$STATUS_FILE" "$_sf_f_file" status.fragments_dir "$FRAG_DIR" "$_sf_f_frag" || exit 1
_sf_disjoint status.file "$STATUS_FILE" "$_sf_f_file" status.archive_dir "$ARCHIVE_DIR" "$_sf_f_arch" || exit 1
_sf_disjoint status.fragments_dir "$FRAG_DIR" "$_sf_f_frag" status.archive_dir "$ARCHIVE_DIR" "$_sf_f_arch" || exit 1
LOG_HEADING="$(cfg status.log_heading)"
RESUME_HEADING="$(cfg status.resume_heading)"
_sf_check_heading status.log_heading "$LOG_HEADING" || exit 1
_sf_check_heading status.resume_heading "$RESUME_HEADING" || exit 1
if [ "$LOG_HEADING" = "$RESUME_HEADING" ]; then
  _sf_err "status.log_heading and status.resume_heading must differ"
  exit 1
fi

# Positive integers with an upper clamp (the config has no upper bound). The
# default is the table's (#440); only the clamp is stated here.
_sf_posint() {  # KEY
  local v d max
  case "$1" in
    status.log_days) max=36500 ;;
    status.log_max) max=10000 ;;
    *) max=1000 ;;  # status.resume_max_lines
  esac
  d="$(_talos_default "$1")"
  v="$(cfg "$1")"
  case "$v" in ''|*[!0-9]*) v="$d" ;; esac
  [ "${#v}" -le 6 ] || v="$max"
  [ "$v" -ge 1 ] 2>/dev/null || v="$d"
  [ "$v" -le "$max" ] || v="$max"
  printf '%s' "$v"
}
LOG_DAYS="$(_sf_posint status.log_days)"
LOG_MAX="$(_sf_posint status.log_max)"

# ── Python: one implementation of the skeleton, the entry format and the
#    window, shared by init and assemble. Large inputs arrive on stdin
#    (assemble: "<sha> <name>" lines) or are read by python itself. ──────────
IFS= read -r -d '' SF_PY <<'PYEOF' || true
import datetime, importlib, json, os, re, signal, subprocess, sys, time, unicodedata

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

# Named options (`--name value` pairs after the 14 positionals) belong to the
# refresh modes, so the positional list does not grow with them.
opts = {}
_extra = sys.argv[15:]
if len(_extra) % 2 or any(not k.startswith('--') for k in _extra[0::2]):
    sys.stderr.write('pipeline-status-file: bad named arguments\n')
    sys.exit(1)
for _i in range(0, len(_extra), 2):
    opts[_extra[_i][2:]] = _extra[_i + 1]


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


_fmt = []  # [module or None], filled by the first spend_tag that needs it


def load_fmt():
    """The shared formatter module (#393), loaded by explicit path from the
    script's own directory (never the cwd). Missing or broken: one stderr
    note, no tags, and assemble carries on."""
    if not _fmt:
        try:
            sys.path.insert(0, opts['script-dir'])
            _fmt.append(importlib.import_module('pipeline-spend-format'))
        except Exception as e:
            sys.stderr.write('pipeline-status-file: pipeline-spend-format.py '
                             'unavailable (%s); entries untagged\n' % type(e).__name__)
            _fmt.append(None)
    return _fmt[0]


def spend_scope(fmt, issue, pr, kind):
    """(events, tokens, unrecorded) from one saved `cost --json` result with
    the orchestrator row dropped, or None for anything unusable."""
    try:
        with open(os.path.join(opts['spend-dir'], '%d-%d.%s' % (issue, pr, kind)), 'rb') as f:
            obj = json.loads(f.read(1048576).decode('utf-8', 'replace'))
        sums = [0, 0, 0]
        for row in obj['rows']:
            if row['role'] == 'orchestrator':
                continue
            vals = [fmt.as_count(row[k]) for k in ('events', 'tokens', 'unrecorded')]
            if None in vals:
                return None
            sums = [a + b for a, b in zip(sums, vals)]
        return tuple(sums)
    except Exception:
        return None


def spend_tag(issue, pr):
    """'[3.41M tokens]' for the merged PR, or '' when there is nothing to say
    (no saved figures, no events for the pair, or any figure unusable)."""
    if 'spend-dir' not in opts or not os.path.isfile(
            os.path.join(opts['spend-dir'], '%d-%d.pr' % (issue, pr))):
        return ''
    fmt = load_fmt()
    if fmt is None:
        return ''
    on_pr = spend_scope(fmt, issue, pr, 'pr')
    on_issue = spend_scope(fmt, issue, pr, 'issue')
    if on_pr is None or on_issue is None or on_pr[0] == 0:
        return ''
    events, tokens, unrecorded = on_pr
    if unrecorded >= events:
        return '[tokens unrecorded]'
    shown = fmt.fmt_num(tokens)
    if on_issue[1] != tokens:
        shown = 'PR %s · issue %s' % (shown, fmt.fmt_num(on_issue[1]))
    return '[%s tokens%s]' % (shown, ', +%d unrecorded' % unrecorded if unrecorded else '')


def build_entry(date, pr, issue, lines):
    # The tag leads the first line, so the caps below only ever cut the text.
    tag = spend_tag(int(issue), pr) if str(issue).isdigit() else ''
    first = ('%s %s' % (tag, lines[0])) if tag and lines[0] else (tag or lines[0])
    out = ['- %s PR #%s (#%s): %s' % (date, pr, issue, first)]
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

# ── collect / refresh / print: the generated Resume block ────────────────────
# `collect` reads GitHub through the read verbs of pipeline-vcs.sh and writes
# the normalised state to --out. `refresh` (throwaway worktree) and `print`
# (the caller's checkout) turn that state plus the Base commit into the block;
# `refresh` splices it into the status file and lists the file in the manifest.
BLOCKED_LABEL = 'pipeline:blocked'
READY_LABEL = 'pipeline:ready'
BRANCH_RE = re.compile(r'^(?:fix|feat)/issue-([0-9]{1,9})(?:-|\Z)')
STALE_RE = re.compile(r'^stale role=([a-z]+) label=')
SHA_RE = re.compile(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})\Z')
CAP_RE = re.compile(r'result capped at')
APPROVALS = (('qa', 'qa:pass'), ('docs', 'docs:done'), ('reviewer', 'review:approved'),
             ('security', 'security:approved'), ('adversarial', 'adversarial:approved'))
PRIORITY = {'p0': 0, 'p1': 1, 'p2': 2}
LINE_CAP = 160       # characters of untrusted text per rendered line
QUEUE_SHOW = 50      # issue numbers named on the Queued line
MIN_BLOCK_LINES = 3  # Base, Next and the `more` marker are never dropped
READ_DEADLINE = 120  # seconds for the whole read phase; CALL_TIMEOUT for one verb
CALL_TIMEOUT = 180
NEEDS_OWNER_LABEL = 'pipeline:needs-owner'
# A label only a maintainer can apply: a PR carrying one is the pipeline's own.
# The EXACT names of the contract's stage and approval lists (--talos-labels,
# from pipeline-contract.sh), never a `pipeline:` prefix test.


def _num(item, key='number'):
    n = item.get(key) if isinstance(item, dict) else None
    return n if isinstance(n, int) and not isinstance(n, bool) and n > 0 else None


def _label_set(item):
    out = set()
    for l in item.get('labels') or []:
        name = l.get('name') if isinstance(l, dict) else l
        if isinstance(name, str):
            out.add(name)
    return out


def md_text(s):
    """Untrusted text as one escaped, length-capped line: no control character,
    no newline, and nothing that Markdown could read as a heading, a list item,
    a code fence, a link or an HTML comment."""
    s = re.sub(r'[\r\n\t\v\f\x85  ]+', ' ', str(s))
    s = clean_line(s)
    if len(s) > LINE_CAP:
        s = s[:LINE_CAP - 1].rstrip() + '…'
    # `<` and `>` become entities, so no `<!--` survives in the raw file text.
    s = s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    return re.sub(r'([\\`*_\[\]|~])', r'\\\1', s)


def _read_deadline():
    """Seconds the whole read phase may take (TALOS_STATUS_READ_DEADLINE, for tests)."""
    v = os.environ.get('TALOS_STATUS_READ_DEADLINE', '')
    # ASCII digits only, at most 4: str.isdigit() accepts `²`, which int() rejects.
    return int(v) if re.fullmatch(r'[0-9]{1,4}', v) and 1 <= int(v) <= 3600 else READ_DEADLINE


_deadline = time.monotonic() + _read_deadline()
_running = None  # the read verb's Popen, so a signal can stop it


def _stop_on_signal(signum, _frame):
    """INT, TERM or HUP during the read phase: kill the running verb's process
    group (it runs in its own session, so the terminal's signal never reaches it)
    and exit 128+signum, instead of leaving it to outlive this script."""
    p = _running
    if p is not None:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
    sys.exit(128 + signum)


def vcs(*args):
    """Run one read verb in its own session. The overall deadline and the
    per-call timeout both END the run: a verb that timed out has no answer, and
    must never read as `ready` (pr-is-draft exit 1) or `ci` (exit 1)."""
    left = _deadline - time.monotonic()
    if left <= 0:
        die('the GitHub read phase passed its %ds deadline' % _read_deadline())
    try:
        p = subprocess.Popen(['bash', opts['vcs']] + list(args), stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError:
        die('could not run the read verb %s' % args[0])
    global _running
    _running = p
    try:
        out, err = p.communicate(timeout=min(CALL_TIMEOUT, left))
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        die('the read verb %s timed out (read deadline %ds)' % (args[0], _read_deadline()))
    finally:
        _running = None
    return p.returncode, out.decode('utf-8', 'replace'), err.decode('utf-8', 'replace')


def parse_array(text, what):
    try:
        d = json.loads(text)
    except ValueError:
        die('%s did not return JSON' % what)
    if not isinstance(d, list):
        die('%s did not return a JSON array' % what)
    return d


def next_stage(n, labels, issue_labels, enabled):
    """First match wins: blocked, then the draft or default order, counting only
    enabled roles; an approval label that is missing or stale means that role."""
    if BLOCKED_LABEL in labels or BLOCKED_LABEL in issue_labels:
        return 'blocked'
    draft = False
    if opts.get('pr-draft') == 'true':
        rc, _, _ = vcs('pr-is-draft', str(n))
        if rc == 0:
            draft = True
        elif rc != 1:
            return 'unverified'
    stale = set()
    if any(label in labels for _, label in APPROVALS):
        rc, out, _ = vcs('check-approval-sha', str(n), '--stale-list')
        stale = set(m.group(1) for m in map(STALE_RE.match, out.splitlines()) if m)
        # exit 1 is both "stale approvals" (stale lines on stdout) and a failed read.
        if rc not in (0, 1) or (rc == 1 and not stale):
            die('check-approval-sha failed for PR #%d (rc=%d)' % (n, rc))
    for role, label in APPROVALS:
        if draft and role == 'qa':
            continue
        if role in enabled and (label not in labels or role in stale):
            return role
    if draft:
        return 'ready'
    if opts.get('required-checks') == 'yes':
        rc, _, _ = vcs('pr-checks-required', str(n))
        if rc != 0:
            return 'ci'
    return 'merge' if opts.get('merge-auto') == 'true' else 'human-merge'


def collect():
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, _stop_on_signal)
    talos_labels = frozenset(x for x in opts.get('talos-labels', '').split(',') if x)
    if not talos_labels:
        die('no Talos label list (pipeline-contract.sh missing or empty)')
    rc, out, err = vcs('list-prs')
    if rc != 0:
        die('list-prs failed (rc=%d)' % rc)
    raw_prs = parse_array(out, 'list-prs')
    capped = ['list-prs'] if CAP_RE.search(err) else []
    rc, out, err = vcs('list-issues')
    if rc != 0:
        die('list-issues failed (rc=%d)' % rc)
    raw_issues = parse_array(out, 'list-issues')
    if CAP_RE.search(err):
        capped.append('list-issues')
    issues = dict((_num(i), _label_set(i)) for i in raw_issues if _num(i))

    # list-needs-owner: exit 2 is an unsupported provider (no Owner lines); any
    # other failure is a failed read and fails the run like list-prs does.
    owners = None
    rc, out, err = vcs('list-needs-owner', '--json')
    if rc != 2:
        if rc != 0:
            die('list-needs-owner failed (rc=%d)' % rc)
        owners = []
        # The trust set was not resolved: every `answered` value is unverified.
        unverified = 'talos:marker-authors-unverified' in err
        for r in parse_array(out, 'list-needs-owner --json'):
            if not _num(r, 'n') or not isinstance(r.get('question', ''), str):
                die('list-needs-owner --json returned an item that is not {n, question, ...}')
            # The status goes in a fixed field before the untrusted question.
            status = 'unverified' if unverified else ('answered' if r.get('answered') == 'yes' else 'unanswered')
            owners.append({'n': r['n'], 'status': status, 'question': r.get('question', '')})
        owners.sort(key=lambda o: o['n'])

    # Which PRs are the pipeline's: a pipeline-style head branch alone is not
    # enough, anyone can open a PR named fix/issue-3-x from a fork. Same base, and
    # either a Talos label (a maintainer applied it) or the listing says the PR
    # is NOT from a fork. isCrossRepository absent means a label is required.
    base = opts['base-branch']
    eligible, ignored, blocked = [], 0, []
    for it in sorted((i for i in raw_prs if _num(i)), key=lambda i: i['number']):
        n, labels = it['number'], _label_set(it)
        if BLOCKED_LABEL in labels:
            blocked.append(('PR', n))
        branch = it.get('headRefName')
        m = BRANCH_RE.match(branch) if isinstance(branch, str) else None
        if not m or it.get('baseRefName') != base:
            continue
        if not (labels & talos_labels or it.get('isCrossRepository') is False):
            ignored += 1
            continue
        eligible.append((n, labels, int(m.group(1))))
    blocked += [('issue', n) for n in issues if BLOCKED_LABEL in issues[n]]
    blocked.sort(key=lambda b: (b[1], b[0]))
    queued = sorted((n for n in issues if READY_LABEL in issues[n]),
                    key=lambda n: (min([PRIORITY[l] for l in issues[n] if l in PRIORITY] or [3]), n))
    # Ready AND waiting on the owner: listed as queued, never offered as `start`.
    held = [n for n in queued if NEEDS_OWNER_LABEL in issues[n]]

    # Look up only the PRs the block will show (lowest numbers): the line cap
    # decides this BEFORE the per-PR reads, so 300 PRs cost the same as 40.
    # The rest are counted by the `- +<K> more` line. Next sees rendered PRs only.
    max_lines = int(opts['max-lines'])
    budget = max(max_lines - (1 if ignored else 0) - (1 if capped else 0), MIN_BLOCK_LINES)
    others = len(blocked) + len(owners or []) + (1 if queued else 0)
    shown = len(eligible) if 2 + len(eligible) + others <= budget else budget - 3
    enabled = set(x for x in opts.get('roles', '').split(',') if x)
    # `Next` must still see a merge-ready PR past the cap: any PR beyond it that
    # carries the approval label of every enabled role (and no blocked or
    # needs-owner label) is looked up as well, at most as many as the cap shows (with
    # no role enabled every PR qualifies); only its line can be cut.
    need = set(label for role, label in APPROVALS if role in enabled)
    pending = [e for e in eligible[shown:]
               if need <= e[1] and not ((e[1] | issues.get(e[2], set())) & {BLOCKED_LABEL, NEEDS_OWNER_LABEL})][:shown]
    prs = []
    for n, labels, issue in eligible[:shown] + pending:
        rc, out, _ = vcs('pr-head', str(n))
        head = out.strip()
        if rc != 0 or not SHA_RE.match(head):
            die('pr-head failed for PR #%d' % n)
        issue_labels = issues.get(issue, set())
        prs.append({'n': n, 'issue': issue, 'head': head,
                    'owner': NEEDS_OWNER_LABEL in labels or NEEDS_OWNER_LABEL in issue_labels,
                    'stage': next_stage(n, labels, issue_labels, enabled)})
    write_text(opts['out'], json.dumps({'prs': prs, 'pr_total': len(eligible), 'ignored': ignored,
                                        'blocked': blocked, 'queued': queued, 'held': held,
                                        'owners': owners, 'capped': capped}))


def base_sha(branch):
    """Newest commit on origin/<branch> that touches a path outside the status
    paths, so the block is stable across its own commits (`none` if there is
    none). Computed from whatever origin/<branch> is when this runs."""
    excl = [':(exclude,literal)%s' % p for p in (status_rel, frag_rel, archive_rel)]
    p = subprocess.run(['git', '--no-literal-pathspecs', '-C', root_real, 'log', '-1',
                        '--format=%H', 'origin/%s' % branch, '--', '.'] + excl,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    sha = p.stdout.decode('ascii', 'replace').strip()
    if p.returncode != 0 or (sha and not SHA_RE.match(sha)):
        die('could not resolve the Base commit on origin/%s' % branch)
    return sha or 'none'


def build_block(data, branch, base, max_lines):
    prs, queued, owners, blocked = data['prs'], data['queued'], data['owners'], data['blocked']
    by_owner = dict((o['n'], o) for o in owners or [])

    # A PR waiting on an owner decision is never offered as the next action.
    live = [p for p in prs if not p['owner']]
    merge = [p for p in live if p['stage'] == 'merge']
    actionable = [p for p in live if p['stage'] not in ('blocked', 'human-merge')]
    human = [p for p in live if p['stage'] == 'human-merge']
    startable = [n for n in queued if n not in data['held']]
    if merge:
        nxt = 'merge #%d' % merge[0]['n']
    elif actionable:
        nxt = 'resume #%d at %s' % (actionable[0]['n'], actionable[0]['stage'])
    elif startable:
        nxt = 'start #%d' % startable[0]
    elif human:
        nxt = 'waiting on human merge of #%d' % human[0]['n']
    elif blocked or owners or data['held'] or len(live) < len(prs):
        nxt = 'waiting on owner'
    else:
        nxt = 'nothing queued'

    # Fixed fields first, untrusted text last: nothing in a question can
    # change the status or kind that precedes it.
    lines = ['- Base: %s @ %s' % (branch, base), '- Next: %s' % nxt]
    for p in prs:
        lines.append('- PR #%d (#%d) head %s next: %s' % (p['n'], p['issue'], p['head'], p['stage']))
    for kind, n in blocked:
        q = md_text(by_owner[n]['question']) if n in by_owner else ''
        lines.append('- Blocked: %s #%d %s' % (kind, n, '[question] ' + q if q else '[see comments]'))
    for o in owners or []:
        lines.append('- Owner: #%d [%s] %s' % (o['n'], o['status'], md_text(o['question']) or '(no question text)'))
    if queued:
        shown = ', '.join('#%d' % n for n in queued[:QUEUE_SHOW])
        more = len(queued) - QUEUE_SHOW
        lines.append('- Queued: %s%s' % (shown, ' (+%d more)' % more if more > 0 else ''))

    # Never cut: what was left out of the listing (an ignored fork PR count, a
    # capped listing), so a truncated view is not shown as complete. The cap
    # note stays last.
    trailer = []
    if data['ignored']:
        trailer.append('- Ignored: %d open PR(s) with a pipeline-style branch name and no Talos label '
                       'from a fork' % data['ignored'])
    if data['capped']:
        trailer.append('- Note: %s result capped; PR, Blocked and Queued lines may be incomplete' %
                       ' and '.join(data['capped']))
    budget = max(max_lines - len(trailer), MIN_BLOCK_LINES)
    # PRs past the line cap were never looked up: their lines count as omitted.
    total = len(lines) + data['pr_total'] - len(prs)
    if total > budget:
        keep = lines[:budget - 1]
        lines = keep + ['- +%d more' % (total - len(keep))]
    return lines + trailer


def splice_block(text, block):
    """Replace everything under the resume heading, up to the next Markdown
    heading of ANY level, by the block; nothing else changes. Any level, so a
    resume heading above the log heading (`# Resume here`, `## Log`) can never
    swallow the log section."""
    lines = ensure_headings(text).split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    idx = next(i for i, l in enumerate(lines) if l.rstrip() == resume_h)
    end = len(lines)
    for j in range(idx + 1, len(lines)):
        if HEADING_RE.match(lines[j]):
            end = j
            break
    out = lines[:idx + 1] + [''] + block
    if end < len(lines):
        out += [''] + lines[end:]
    return '\n'.join(out) + '\n'


if mode == 'collect':
    collect()
    sys.exit(0)

if mode in ('refresh', 'print'):
    status_path = check_inside(status_rel, 'status.file')
    check_inside(frag_rel, 'status.fragments_dir')
    check_inside(archive_rel, 'status.archive_dir')
    with open(opts['data']) as f:
        data = json.load(f)
    block = build_block(data, opts['base-branch'], base_sha(opts['base-branch']), int(opts['max-lines']))
    if mode == 'print':
        sys.stdout.write('%s\n\n%s\n' % (resume_h, '\n'.join(block)))
        sys.exit(0)
    if os.path.isdir(status_path):
        die('status.file is a directory: %s' % status_rel)
    cur = read_text(status_path) if os.path.exists(status_path) else ''
    new_text = splice_block(cur or HEADER, block)
    if new_text != cur:
        write_text(status_path, new_text)
        # The manifest may already hold assemble's changes (assemble --refresh).
        have = read_text(manifest_file) if os.path.exists(manifest_file) else ''
        if 'A\t%s\n' % status_rel not in have:
            with open(manifest_file, 'a') as mf:
                mf.write('A\t%s\n' % status_rel)
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
BASE_BRANCH="$(cfg base_branch 2>/dev/null)"
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

# _sf_spend_fetch ISSUE PR: save `pipeline-events.sh cost --json` for the issue
# and for the (issue, PR) pair as $_SF_TMP/spend/<issue>-<pr>.{issue,pr} (ints,
# so 012-040.md and 12-40 are one pair). Python reads the files; the figures
# never ride in code or argv. Any failure leaves no file, so the entry stays
# untagged. A pair already fetched is kept: the log does not change with a push.
_sf_spend_fetch() {
  local i="$1" p="$2" base
  case "$i$p" in ''|*[!0-9]*) return 0 ;; esac
  [ "${#i}" -le 9 ] && [ "${#p}" -le 9 ] || return 0
  i=$((10#$i)) p=$((10#$p))
  base="$_SF_TMP/spend/$i-$p"
  [ ! -e "$base.pr" ] || return 0
  bash "$SCRIPT_DIR/pipeline-events.sh" cost --issue "$i" --json </dev/null \
      >"$base.issue.part" 2>/dev/null \
    && bash "$SCRIPT_DIR/pipeline-events.sh" cost --issue "$i" --pr "$p" --json </dev/null \
      >"$base.pr.part" 2>/dev/null \
    && mv "$base.issue.part" "$base.issue" && mv "$base.pr.part" "$base.pr"
  rm -f "$base.issue.part" "$base.pr.part"
  return 0
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
    _sf_err "staged changes differ from what $verb wrote — nothing committed or pushed"
    return 1
  fi
  if ! git -C "$_SF_TMP/wt" -c user.email=talos@local -c user.name=talos-status \
      -c commit.gpgsign=false commit -q --no-verify -m "$subject"; then
    _sf_err "commit failed"
    return 1
  fi
  return 0
}

# ── The Resume block (refresh, refresh --print, assemble --refresh) ──────────
# The GitHub state is read ONCE, before the retry loop (the block is a pure
# function of that state and of origin/<base>, which each attempt refetches).
# The reads go through pipeline-vcs.sh read verbs only; python does the calls
# and writes the normalised state to $_SF_TMP/gh.json.
_sf_role_on() {  # KEY: the table default decides: enabled when not false (default true) / true (default false)
  local v
  v="$(cfg "$1" | tr '[:upper:]' '[:lower:]')"
  if [ "$(_talos_default "$1")" = "true" ]; then [ "$v" != "false" ]; else [ "$v" = "true" ]; fi
}
MAX_LINES="$(_sf_posint status.resume_max_lines)"
# Named arguments of the python refresh and print modes (not more positionals).
_SF_RARGS=(--data "$_SF_TMP/gh.json" --base-branch "$BASE_BRANCH" --max-lines "$MAX_LINES")
_sf_collect() {
  local roles="" auto="true" checks="no" draft="false" talos_labels="" e
  # Names only (entries are name|color|description), comma-joined; no name has a comma.
  for e in ${TALOS_STAGE_LABELS[@]+"${TALOS_STAGE_LABELS[@]}"} ${TALOS_APPROVAL_LABELS[@]+"${TALOS_APPROVAL_LABELS[@]}"}; do
    talos_labels="${talos_labels}${e%%|*},"
  done
  if [ -z "$talos_labels" ]; then
    _sf_err "pipeline-contract.sh is missing or lists no labels; reinstall Talos"
    return 1
  fi
  _sf_role_on roles.qa && roles="${roles}qa,"
  _sf_role_on roles.docs && roles="${roles}docs,"
  _sf_role_on roles.reviewer && roles="${roles}reviewer,"
  _sf_role_on roles.security && roles="${roles}security,"
  _sf_role_on roles.adversarial && roles="${roles}adversarial,"
  [ "$(cfg merge.auto | tr '[:upper:]' '[:lower:]')" = "false" ] && auto="false"
  [ -n "$(cfg merge.required_checks | tr -d '[:space:]')" ] && checks="yes"
  # The same effective value Step 0 uses (#435): default true, false on github-api/file.
  [ "$(bash "$SCRIPT_DIR/pipeline-draft-check.sh" resolve 2>/dev/null)" = "true" ] && draft="true"
  python3 -I -c "$SF_PY" collect "$PWD" "$STATUS_FILE" "$FRAG_DIR" "$ARCHIVE_DIR" \
    "$LOG_HEADING" "$RESUME_HEADING" "$LOG_DAYS" "$LOG_MAX" "$TODAY" "" "" "" "" \
    --vcs "$SCRIPT_DIR/pipeline-vcs.sh" --out "$_SF_TMP/gh.json" --roles "$roles" \
    --merge-auto "$auto" --required-checks "$checks" --pr-draft "$draft" \
    --talos-labels "$talos_labels" --base-branch "$BASE_BRANCH" --max-lines "$MAX_LINES" </dev/null
}
# _sf_fetch_base: refresh origin/<base> (this only moves the remote-tracking ref).
_sf_fetch_base() {
  if ! git fetch -q -- origin "$BASE_BRANCH" 2>/dev/null; then
    _sf_err "git fetch origin $BASE_BRANCH failed"
    return 1
  fi
  if ! git rev-parse -q --verify "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    _sf_err "origin/$BASE_BRANCH does not resolve after fetch"
    return 1
  fi
}
REFRESH_ON=""
if [ "$verb" = "refresh" ] || [ -n "$REFRESH" ]; then
  _sf_collect
  _SF_RC=$?
  if [ "$_SF_RC" -eq 0 ]; then
    REFRESH_ON=1
  elif [ "$_SF_RC" -gt 128 ]; then
    exit "$_SF_RC"  # the read phase was interrupted (128+signal): never go on to push
  elif [ "$verb" = "refresh" ]; then
    _sf_err "could not read the GitHub state for the Resume block — nothing pushed"
    exit 1
  else
    _sf_err "Resume block was not refreshed (the GitHub read failed); assembling the log only"
  fi
fi

# refresh --print: the block on stdout. It runs git fetch (which only moves
# origin/<base>, so Base matches what refresh computes) and nothing else that
# writes: no worktree, no commit, no push, no label or comment.
if [ "$verb" = "refresh" ] && [ -n "$PRINT" ]; then
  _sf_fetch_base || exit 1
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  python3 -I -c "$SF_PY" print "$ROOT" "$STATUS_FILE" "$FRAG_DIR" "$ARCHIVE_DIR" \
    "$LOG_HEADING" "$RESUME_HEADING" "$LOG_DAYS" "$LOG_MAX" "$TODAY" "" "" "" "" \
    "${_SF_RARGS[@]}" </dev/null
  exit $?
fi

TITLE_TRIED=""
MAX_ATTEMPTS=3
attempt=1
while :; do
  _sf_fetch_base || exit 1

  FRAG_LIST=""
  if [ "$verb" = "assemble" ]; then
    FRAG_LIST="$(_sf_list_fragments)" || {
      _sf_err "could not list $FRAG_DIR on origin/$BASE_BRANCH"
      exit 1
    }
    if [ -z "$FRAG_LIST" ] && [ -z "$PR" ] && [ -z "$REFRESH_ON" ]; then
      echo "pipeline-status-file: no fragments under $FRAG_DIR on origin/$BASE_BRANCH — nothing to assemble"
      exit 0
    fi
  fi

  # The fallback title is fetched once, and only when no fragment names the pair.
  if [ -n "$PR" ] && [ -z "$TITLE_TRIED" ] && \
     ! grep -q " ${ISSUE}-${PR}\.md\$" <<<"$FRAG_LIST"; then
    TITLE_TRIED=1
    bash "$SCRIPT_DIR/pipeline-vcs.sh" view-pr "$PR" 2>/dev/null \
      | head -c 65536 > "$_SF_TMP/title.json" || true
  fi

  # Spend figures (#384) are read here, in the caller's checkout, before the
  # temporary worktree exists (the events log is found from this cwd).
  if [ "$verb" = "assemble" ]; then
    mkdir -p "$_SF_TMP/spend"
    [ -z "$PR" ] || _sf_spend_fetch "$ISSUE" "$PR"
    while read -r _sf_sha _sf_name; do
      _sf_name="${_sf_name%.md}"  # <issue>-<pr>
      case "$_sf_name" in
        *-*) _sf_spend_fetch "${_sf_name%%-*}" "${_sf_name#*-}" ;;
      esac
    done <<< "$FRAG_LIST"
  fi

  if ! with_lock "$_SF_LOCK" 10 -- \
      git worktree add -q --detach "$_SF_TMP/wt" "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    _sf_err "could not create temp worktree for origin/$BASE_BRANCH"
    exit 1
  fi

  _SF_MANIFEST="$_SF_TMP/manifest"
  rm -f "$_SF_MANIFEST"
  SUBJECT="docs(status): refresh resume block [skip ci]"
  DONE_MSG="refreshed the resume block in $STATUS_FILE on $BASE_BRANCH and pushed"
  if [ "$verb" = "assemble" ]; then
    printf '%s\n' "$FRAG_LIST" | python3 -I -B -c "$SF_PY" assemble "$_SF_TMP/wt" \
      "$STATUS_FILE" "$FRAG_DIR" "$ARCHIVE_DIR" "$LOG_HEADING" "$RESUME_HEADING" \
      "$LOG_DAYS" "$LOG_MAX" "$TODAY" "$PR" "$ISSUE" "$_SF_TMP/title.json" "$_SF_MANIFEST" \
      --spend-dir "$_SF_TMP/spend" --script-dir "$SCRIPT_DIR"
    _SF_RC=$?
    if [ "$_SF_RC" -ne 0 ]; then
      _sf_err "assembly failed (rc=$_SF_RC) — fragments left in place"
      exit 1
    fi
    if [ -s "$_SF_MANIFEST" ]; then
      SUBJECT="docs(status): assemble status log [skip ci]"
      DONE_MSG="assembled the status log into $STATUS_FILE on $BASE_BRANCH and pushed"
      if [ -n "$REFRESH_ON" ]; then
        SUBJECT="docs(status): assemble status log and refresh resume block [skip ci]"
        DONE_MSG="assembled the status log and refreshed the resume block in $STATUS_FILE on $BASE_BRANCH and pushed"
      fi
    fi
  fi

  # The block is regenerated from the freshly fetched base on every attempt, so
  # a push that lost a race re-derives it and finds it already there.
  if [ -n "$REFRESH_ON" ]; then
    python3 -I -c "$SF_PY" refresh "$_SF_TMP/wt" "$STATUS_FILE" "$FRAG_DIR" "$ARCHIVE_DIR" \
      "$LOG_HEADING" "$RESUME_HEADING" "$LOG_DAYS" "$LOG_MAX" "$TODAY" "" "" "" "$_SF_MANIFEST" \
      "${_SF_RARGS[@]}" </dev/null
    _SF_RC=$?
    if [ "$_SF_RC" -ne 0 ]; then
      _sf_err "could not regenerate the Resume block (rc=$_SF_RC) — nothing pushed"
      exit 1
    fi
  fi

  # Nothing changed (no new entry, no rotation, no fragment, block identical):
  # a no-op. This is what makes a repeated fallback or refresh quiet.
  if [ ! -s "$_SF_MANIFEST" ]; then
    if [ "$verb" = "refresh" ]; then
      echo "pipeline-status-file: resume block already up to date — nothing to do"
    else
      echo "pipeline-status-file: nothing to assemble"
    fi
    exit 0
  fi

  _sf_stage_commit "$SUBJECT" || exit 1

  if _SF_PUSH_ERR="$(git -C "$_SF_TMP/wt" push -q origin "HEAD:refs/heads/$BASE_BRANCH" 2>&1)"; then
    echo "pipeline-status-file: $DONE_MSG"
    exit 0
  fi

  _sf_err "push to $BASE_BRANCH failed (attempt $attempt of $MAX_ATTEMPTS)"
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    _sf_err "${_SF_PUSH_ERR:-no output from git push}"
    if [ "$verb" = "refresh" ]; then
      _sf_err "gave up after $MAX_ATTEMPTS attempts — the base is unchanged, the next refresh retries"
    else
      _sf_err "gave up after $MAX_ATTEMPTS attempts — fragments remain on $BASE_BRANCH, next assemble retries"
    fi
    exit 1
  fi
  _sf_drop_wt
  attempt=$((attempt + 1))
done
