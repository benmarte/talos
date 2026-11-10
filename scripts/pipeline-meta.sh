#!/usr/bin/env bash
# pipeline-meta.sh -- the repo facts a notification names (#554).
#
# Usage: pipeline-meta.sh [--repo <owner/name>] board
#        pipeline-meta.sh [--repo <owner/name>] repo-url
#        pipeline-meta.sh [--repo <owner/name>] issue-title <n>
#        pipeline-meta.sh [--repo <owner/name>] pr-title <n>
#        pipeline-meta.sh [--repo <owner/name>] cache-titles   (stdin: "<n> <title>" lines)
#
# pipeline-notify.sh asked GitHub for all four on every message: `gh repo view`
# (twice), `gh issue view` and `gh pr view` -- GraphQL, for facts that do not
# change between messages. Here:
#   board, repo-url   derived from --repo (vcs.repo) or the git remote: no call.
#                     With neither, the old `gh repo view` answers.
#   issue-title,      one REST read (`gh api`, the core quota), kept for 6 hours
#   pr-title          in a user-private file per repo and number. A failed read is
#                     not kept, and neither is a value that is empty, JSON (starts
#                     with `{`, or names "documentation_url": a GitHub error body)
#                     or longer than one line (#886). Only the GitHub providers
#                     (vcs.provider github or github-api) reach `gh`; any other
#                     provider still serves a good cache file but makes no call.
#   cache-titles      fills the issue-title cache from "<n> <title>" lines on stdin
#                     (pipeline-next.py collect hands it the titles `list-issues`
#                     already read): no provider call, the same value checks.
# Prints the value, or nothing when it cannot be had; always exits 0 (a
# notification must never fail the pipeline, and the caller treats empty as
# "no title / no link", as it did when `gh` failed).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ARG=""
if [ "${1:-}" = "--repo" ]; then REPO_ARG="${2:-}"; shift 2 2>/dev/null || shift "$#"; fi
WHAT="${1:-}"
NUM="${2:-}"

# _slug_ok <owner/name> -- exactly two segments of GitHub's name characters. The
# slug lands in a link URL and a REST path, so anything else is not a slug.
_slug_ok() {
  case "$1" in
    ''|*[!A-Za-z0-9._/-]*|/*|*/|*/*/*) return 1 ;;
    */*) return 0 ;;
  esac
  return 1
}

# _slug -- owner/name from --repo, else the git remote; nothing when neither says.
_slug() {
  local _u _o
  if _slug_ok "$REPO_ARG"; then printf '%s' "$REPO_ARG"; return 0; fi
  _u="$(git remote get-url origin 2>/dev/null)" || return 1
  _u="${_u%.git}"; _u="${_u%/}"
  case "$_u" in
    *://*) _u="${_u#*://}"; _u="${_u#*@}"; _u="${_u#*/}" ;;
    *@*:*) _u="${_u#*:}" ;;
    *) return 1 ;;
  esac
  case "$_u" in
    */*) _o="${_u%/*}"; _u="${_o##*/}/${_u##*/}" ;;
    *) return 1 ;;
  esac
  _slug_ok "$_u" || return 1
  printf '%s' "$_u"
}

# _host -- the git host: the remote's, else GH_HOST, else github.com.
_host() {
  local _u
  _u="$(git remote get-url origin 2>/dev/null)" || _u=""
  _u="${_u%.git}"
  case "$_u" in
    *://*) _u="${_u#*://}"; _u="${_u#*@}"; printf '%s' "${_u%%/*}"; return 0 ;;
    *@*:*) _u="${_u#*@}"; printf '%s' "${_u%%:*}"; return 0 ;;
  esac
  printf '%s' "${GH_HOST:-github.com}"
}

# _cache_dir -- the user-private directory that keeps the titles; nothing when it
# cannot be made.
_cache_dir() {
  local _d="${XDG_RUNTIME_DIR:-${HOME:-/nonexistent}/.cache}/talos/meta"
  install -d -m 700 "$_d" 2>/dev/null || { mkdir -p "$_d" 2>/dev/null && chmod 700 "$_d" 2>/dev/null; } || return 1
  printf '%s' "$_d"
}

# _cache_key -- the repo's part of a cache file name (talos-map.py keys the same way).
_cache_key() { printf '%s' "${SLUG:-cwd}" | tr -c 'A-Za-z0-9_-' '_'; }

# _cache_file <kind> -- the user-private file that keeps a title; nothing when
# the directory cannot be made.
_cache_file() {
  local _d
  _d="$(_cache_dir)" || return 1
  printf '%s/%s.%s.%s' "$_d" "$(_cache_key)" "$1" "$NUM"
}

# _title_ok <value> -- a title is one non-empty line that is not a GitHub error
# body (#886): not JSON, and not naming "documentation_url".
_title_ok() {
  case "$1" in
    '' | '{'* | *'"documentation_url"'* | *$'\n'* | *$'\r'*) return 1 ;;
  esac
  return 0
}

# _github -- vcs.provider is github or github-api (default github); an unreadable
# config answers no. Only then may a title be asked of `gh api repos/...`.
_github() {
  local _p
  _p="$(bash "$SCRIPT_DIR/pipeline-config.sh" vcs.provider 2>/dev/null)" || return 1
  case "$(printf '%s' "${_p:-github}" | tr '[:upper:]' '[:lower:]')" in github | github-api) return 0 ;; esac
  return 1
}

# _cache_ok <file> -- a regular file of ours, not group/world-writable, under 6 h old.
_cache_ok() {
  [ -f "$1" ] && [ -O "$1" ] || return 1
  case "$(ls -l "$1" 2>/dev/null | cut -c1-10)" in ?????w????|????????w?) return 1 ;; esac
  [ -n "$(find "$1" -mmin -360 2>/dev/null)" ]
}

SLUG="$(_slug 2>/dev/null)" || SLUG=""

case "$WHAT" in
  board)
    if [ -n "$SLUG" ]; then printf '%s' "${SLUG//\//-}"
    else gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null | tr '/' '-' | tr -d '\n'; fi
    ;;
  repo-url)
    if [ -n "$SLUG" ]; then printf 'https://%s/%s' "$(_host)" "$SLUG"
    else gh repo view --json url -q .url 2>/dev/null | tr -d '\n'; fi
    ;;
  issue-title | pr-title)
    case "$NUM" in ''|*[!0-9]*) exit 0 ;; esac
    _kind="issue"; _path="issues"
    [ "$WHAT" = pr-title ] && { _kind="pr"; _path="pulls"; }
    _f="$(_cache_file "$_kind")" || _f=""
    # A kept file is served only when it is a clean title: a bad one already on
    # disk (an error body cached before #886) is read again, not printed.
    if [ -n "$_f" ] && _cache_ok "$_f" && _t="$(cat "$_f" 2>/dev/null)" && _title_ok "$_t"; then printf '%s' "$_t"; exit 0; fi
    command -v gh >/dev/null 2>&1 || exit 0
    _github || exit 0
    _rp="$SLUG"; [ -n "$_rp" ] || _rp='{owner}/{repo}'
    # gh's own exit status decides: a pipe into head hid it and a 404 body was cached.
    _t="$(gh api "repos/$_rp/$_path/$NUM" --jq .title 2>/dev/null)" || exit 0
    _title_ok "$_t" || exit 0
    [ -z "$_f" ] || (umask 177 && printf '%s' "$_t" > "$_f.$$" && mv "$_f.$$" "$_f") 2>/dev/null || rm -f "$_f.$$" 2>/dev/null
    printf '%s' "$_t"
    ;;
  cache-titles)
    # No provider call: one directory check, then a plain write per title. A link or
    # a file that is not ours is left alone; a bad value is skipped.
    _d="$(_cache_dir)" || exit 0
    _k="$(_cache_key)"
    umask 177
    while IFS=' ' read -r _n _t || [ -n "$_n" ]; do
      case "$_n" in '' | *[!0-9]*) continue ;; esac
      _title_ok "$_t" || continue
      _f="$_d/$_k.issue.$_n"
      { [ ! -e "$_f" ] || { [ -f "$_f" ] && [ ! -L "$_f" ] && [ -O "$_f" ]; }; } || continue
      printf '%s' "$_t" > "$_f" 2>/dev/null || true
    done
    ;;
esac
exit 0
