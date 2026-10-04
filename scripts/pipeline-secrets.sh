#!/usr/bin/env bash
# pipeline-secrets.sh -- secret references (env:NAME) and the trust check for
# the user-level files Talos reads (#443, part of #437).
#
# Source this file; it defines functions and runs nothing. pipeline-notify.sh
# uses talos_secret_load; pipeline-config.sh runs the same python trust_problem
# (_TALOS_TRUST_LIB, below) on the global config file inside its loader. There
# is ONE stat check, for both.
#
# ── Secret references ────────────────────────────────────────────────────────
# A secret never lives in a config file. A config key that holds one (the
# secret-typed rows of pipeline-defaults.sh: notifications.slack.webhook, ...)
# is a REFERENCE, `env:NAME`, and the value comes from the environment:
#
#   talos_secret_load VAR [CONFIG_KEY [url]]
#
# resolves VAR (also its documented environment name, e.g. SLACK_WEBHOOK_URL)
# into the shell variable VAR, first match wins:
#
#   1. the exported environment
#   2. the repo's .env (<git toplevel or $PWD>/.env; parsed, never sourced)
#   3. the config reference at CONFIG_KEY: `env:NAME` makes NAME the name that
#      is looked up in steps 1, 2, 4 and 5; a reference that does not resolve
#      ends the lookup (the caller skips the platform), so an explicit
#      reference never silently falls back to another variable
#   4. ${TALOS_HOME:-$HOME/.talos}/.env
#   5. the legacy ~/.hermes/.env, with ONE deprecation line per process
#
# Returns 0 and sets VAR when a value was found; returns 1 and leaves VAR as it
# was when not (one stderr line says why when a reference was involved); 2 on a
# bad call. With the optional third argument `url`, a value that came through a
# config reference must start with https:// (a repo-controlled reference must
# not be able to point a webhook call at "whatever the variable holds").
#
# NAME must match [A-Za-z_][A-Za-z0-9_]*. A config value that is not
# `env:<valid name>` (a literal secret pasted into the file, `env:` with no
# name, a name with a space or a `$`) is rejected: one stderr line that names
# the KEY and never the value, and nothing is looked up. Names and values are
# only ever compared and assigned with `case` and `printf -v` -- there is no
# eval, no command substitution of a looked-up value and no ${!x} on a name that
# has not been validated.
#
# Values never reach argv: they are read by the shell's own `read` builtin and
# held in shell variables. A value holding a control character (a newline would
# let a value add lines to the curl config the caller builds) is dropped as
# unusable. Nothing in this file prints a value.
#
# ── The trust check ──────────────────────────────────────────────────────────
#   talos_trust_check LABEL POLICY PATH [WHAT [TAIL]]
#
# Returns 0 when PATH is trustworthy; otherwise prints ONE stderr line, which
# names PATH and the fix and never reads the file, and returns 1. POLICY:
#   secret-file  a .env: a regular file (a symlink is refused), owned by the
#                current user, mode exactly 0600, outside every git work tree
#   config-file  the global config: a regular file, or a symlink that the user
#                owns pointing at one, owned by the current user and neither
#                group- nor world-writable (it drives hooks.* and
#                notifications.cmd, which run commands)
# It stats with `python3 -I` (the same on macOS and Linux; `stat` differs).
# Without python3 nothing can be verified, so the file is refused.
#
# The residual window between this check and the read that follows is the
# usual check-then-open one; closing it needs an attacker who can already
# replace files in the user's own ~/.talos, who has won anyway.
#
# Bash 3.2 safe (printf -v, no namerefs, no associative arrays).

# The stat check as a python library. pipeline-config.sh prepends it to its own
# loader (so the global-config check costs no extra python3 spawn); the CLI
# below runs it on its own for a .env. trust_problem(uid, policy, path) returns
# None for a trustworthy path, else a (why, fix) pair of plain sentences. It
# stats only; it never opens the file.
IFS= read -r -d '' _TALOS_TRUST_LIB <<'TALOS_PYtrust4Kq8Wd2Mx' || true
import os
import stat


def trust_clean(s):
    return "".join(c if c.isprintable() else "?" for c in s)


def trust_problem(uid, policy, path):
    shown = trust_clean(path)
    try:
        lst = os.lstat(path)
    except OSError:
        return ("cannot stat it", "check the path")
    st = lst
    if stat.S_ISLNK(lst.st_mode):
        if policy == "secret-file":
            return ("it is a symbolic link", "use a regular file: chmod 600 it and put it here, not a link")
        if lst.st_uid != uid:
            return ("the symbolic link is not owned by you", "recreate it as your own user")
        try:
            st = os.stat(path)
        except OSError:
            return ("the symbolic link points nowhere", "fix or remove the link")
    if not stat.S_ISREG(st.st_mode):
        return ("it is not a regular file", "replace it with one")
    if st.st_uid != uid:
        return ("it is owned by uid %d, not by you (uid %d)" % (st.st_uid, uid),
                "recreate it as your own user" + (", then chmod 600 it" if policy == "secret-file" else ""))
    mode = stat.S_IMODE(st.st_mode)
    if policy == "secret-file":
        if mode != 0o600:
            return ("mode is %04o, want 0600" % mode, "run: chmod 600 '%s'" % shown)
        d = os.path.dirname(os.path.realpath(path))
        while True:
            if os.path.lexists(os.path.join(d, ".git")):
                return ("it is inside the git work tree %s" % trust_clean(d),
                        "move it outside every repository, e.g. to ~/.talos/.env")
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
    elif policy == "config-file":
        if mode & 0o022:
            return ("mode is %04o: group- or world-writable" % mode, "run: chmod go-w '%s'" % shown)
    else:
        return ("unknown trust policy", "internal error")
    return None
TALOS_PYtrust4Kq8Wd2Mx

IFS= read -r -d '' _TALOS_TRUST_CLI <<'TALOS_PYcli7Hn3Rv5Bz' || true

import sys

uid, label, policy, path = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
what = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else "file"
tail = sys.argv[6] if len(sys.argv) > 6 else ""
problem = trust_problem(uid, policy, path)
if problem:
    sys.stderr.write("%s: refusing %s %s: %s; %s%s\n"
                     % (label, what, trust_clean(path), problem[0], problem[1],
                        (" -- " + tail) if tail else ""))
    sys.exit(1)
TALOS_PYcli7Hn3Rv5Bz

# _talos_trust_py_run UID LABEL POLICY PATH [WHAT [TAIL]] -- the check with the
# expected owner passed in, so a test can ask "owned by someone else?" without
# a second user. talos_trust_check always passes the real uid.
_talos_trust_py_run() {
  python3 -I -c "$_TALOS_TRUST_LIB$_TALOS_TRUST_CLI" "$@"
}

talos_trust_check() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "${1:-talos}: python3 not found, cannot verify ${4:-file} ${3:-} -- ignoring it" >&2
    return 1
  fi
  _talos_trust_py_run "$(id -u)" "$@"
}

# ── Secret lookup ────────────────────────────────────────────────────────────

# 0 when $1 is a valid variable name. Pure `case`; LC_ALL=C so a range cannot
# match a letter of the current locale.
_talos_secret_name_ok() {
  local LC_ALL=C
  case "${1:-}" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

_TS_VAL=""            # the last value a lookup found; never printed
_TS_REPO_ENV=""       # the repo .env path, computed once
_TS_TALOS_STATE=""    # "", ok, bad, none -- the trust verdict for ~/.talos/.env
_TS_HERMES_STATE=""   # the same for ~/.hermes/.env
_TS_HERMES_WARNED=""

# _talos_dotenv_get FILE NAME -- set _TS_VAL to NAME's value in FILE (first
# match, one surrounding pair of quotes stripped, CRLF tolerated); return 0 when
# there is a non-empty one.
_talos_dotenv_get() {
  local _f="$1" _n="$2" _line _v
  _TS_VAL=""
  [ -r "$_f" ] || return 1
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line%$'\r'}"
    case "$_line" in
      "$_n="*) _v="${_line#*=}" ;;
      "export $_n="*) _v="${_line#*=}" ;;
      *) continue ;;
    esac
    case "$_v" in
      '"'*'"') _v="${_v#'"'}"; _v="${_v%'"'}" ;;
      "'"*"'") _v="${_v#"'"}"; _v="${_v%"'"}" ;;
    esac
    [ -n "$_v" ] || return 1
    _TS_VAL="$_v"
    return 0
  done < "$_f"
  return 1
}

# _talos_user_env_get KIND NAME -- NAME from the user-level .env of KIND (talos
# or hermes), after the trust check. The verdict is cached for the process, so a
# refused file prints its one line once.
_talos_user_env_get() {
  local _kind="$1" _name="$2" _f _state _what _tail
  case "$_kind" in
    talos)
      if [ -n "${TALOS_HOME:-}" ]; then _f="$TALOS_HOME/.env"
      elif [ -n "${HOME:-}" ]; then _f="$HOME/.talos/.env"
      else return 1; fi
      _state="$_TS_TALOS_STATE" ;;
    hermes)
      [ -n "${HOME:-}" ] || return 1
      _f="$HOME/.hermes/.env"
      _state="$_TS_HERMES_STATE" ;;
    *) return 1 ;;
  esac
  if [ -z "$_state" ]; then
    if [ -e "$_f" ] || [ -L "$_f" ]; then
      if talos_trust_check pipeline-secrets secret-file "$_f" ".env" "ignoring it"; then _state=ok; else _state=bad; fi
    else
      _state=none
    fi
    case "$_kind" in talos) _TS_TALOS_STATE="$_state" ;; *) _TS_HERMES_STATE="$_state" ;; esac
  fi
  [ "$_state" = "ok" ] || return 1
  _talos_dotenv_get "$_f" "$_name" || return 1
  if [ "$_kind" = "hermes" ] && [ -z "$_TS_HERMES_WARNED" ]; then
    _TS_HERMES_WARNED=1
    echo "pipeline-secrets: reading secrets from ~/.hermes/.env is deprecated; move them to ${TALOS_HOME:-~/.talos}/.env (chmod 600)" >&2
  fi
  return 0
}

# _talos_secret_env_layers NAME -- steps 1 and 2: the exported environment, then
# the repo .env.
_talos_secret_env_layers() {
  local _name="$1" _root
  if [ -n "${!_name:-}" ]; then _TS_VAL="${!_name}"; return 0; fi
  if [ -z "$_TS_REPO_ENV" ]; then
    _root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"
    _TS_REPO_ENV="${_root:-$PWD}/.env"
  fi
  _talos_dotenv_get "$_TS_REPO_ENV" "$_name"
}

# _talos_secret_assign VAR SHAPE VIA_REF -- put _TS_VAL into VAR unless it holds
# a control character or fails the shape check. Never prints the value.
_talos_secret_assign() {
  local _var="$1" _shape="$2" _via_ref="$3"
  case "$_TS_VAL" in
    *[[:cntrl:]]*)
      echo "pipeline-secrets: the value for $_var holds a control character; ignoring it" >&2
      return 1 ;;
  esac
  if [ "$_shape" = "url" ] && [ "$_via_ref" = "1" ]; then
    case "$_TS_VAL" in
      https://?*) ;;
      *) echo "pipeline-secrets: the reference for $_var does not resolve to an https:// URL; ignoring it" >&2
         return 1 ;;
    esac
  fi
  printf -v "$_var" '%s' "$_TS_VAL"
  return 0
}

talos_secret_load() {
  local _var="${1:-}" _key="${2:-}" _shape="${3:-}" _ref="" _name
  _talos_secret_name_ok "$_var" || return 2
  _TS_VAL=""
  if _talos_secret_env_layers "$_var"; then
    _talos_secret_assign "$_var" "$_shape" 0
    return $?
  fi
  if [ -n "$_key" ] && [ "$(type -t cfg)" = "function" ]; then
    _ref="$(cfg "$_key")"
  fi
  if [ -n "$_ref" ]; then
    case "$_ref" in
      env:*) _name="${_ref#env:}" ;;
      *) _name="" ;;
    esac
    if ! _talos_secret_name_ok "$_name"; then
      # Never echo the value: a literal secret pasted into the file lands here.
      echo "pipeline-secrets: $_key is not an env:NAME reference (NAME is letters, digits and underscore); a secret is never read from the config file itself -- ignoring it" >&2
      return 1
    fi
    if _talos_secret_env_layers "$_name" \
       || _talos_user_env_get talos "$_name" || _talos_user_env_get hermes "$_name"; then
      _talos_secret_assign "$_var" "$_shape" 1
      return $?
    fi
    echo "pipeline-secrets: $_key references $_name, which is not set in the environment, the repo .env, ${TALOS_HOME:-~/.talos}/.env or ~/.hermes/.env -- skipping" >&2
    return 1
  fi
  if _talos_user_env_get talos "$_var" || _talos_user_env_get hermes "$_var"; then
    _talos_secret_assign "$_var" "$_shape" 0
    return $?
  fi
  return 1
}
