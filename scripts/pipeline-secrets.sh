#!/usr/bin/env bash
# pipeline-secrets.sh -- secret references (env:NAME) and the trust check for the
# user-level files Talos reads (#443, part of #437). Source it; it defines
# functions and runs nothing. pipeline-notify.sh uses talos_secret_load;
# pipeline-config.sh runs the same python trust_problem (_TALOS_TRUST_LIB) on the
# global config file inside its loader: ONE stat check, for both.
#
# ── Secret references ────────────────────────────────────────────────────────
# A secret never lives in a config file. A key that holds one (the secret-typed
# rows of pipeline-defaults.sh) is a REFERENCE, `env:NAME`, and the value comes
# from the environment:
#
#   talos_secret_load VAR [CONFIG_KEY [url]]
#
# resolves VAR (also its documented environment name, e.g. SLACK_WEBHOOK_URL)
# into the shell variable VAR, first match wins:
#   1. the exported environment
#   2. the repo's .env (<git toplevel or $PWD>/.env; parsed, never sourced)
#   3. the config reference at CONFIG_KEY: `env:NAME` makes NAME the name looked
#      up in steps 1, 2, 4 and 5; a reference that does not resolve ends the
#      lookup (the caller skips the platform), so an explicit reference never
#      silently falls back to another variable
#   4. ${TALOS_HOME:-$HOME/.talos}/.env
#   5. the legacy ~/.hermes/.env, with ONE deprecation line per process
#      (TALOS_HERMES_ENV=<path> moves it, an empty value switches it off)
# Returns 0 and sets VAR when a value was found; 1 (VAR untouched, one stderr line
# when a reference was involved) when not; 2 on a bad call. With the third
# argument `url`, a value that came through a reference must start with https://.
#
# NAME must match [A-Za-z_][A-Za-z0-9_]*. A config value that is not
# `env:<valid name>` (a literal secret pasted into the file, `env:` alone, a name
# with a space or `$`) is rejected with one stderr line that names the KEY and
# never the value. Names and values are only compared and assigned with `case`
# and `printf -v`: no eval, no command substitution of a looked-up value, no
# ${!x} on a name that has not been validated. Values never reach argv or a log; a
# value holding a control character (a newline would let it add lines to the curl
# config the caller builds) is dropped as unusable.
#
# ── The trust check ──────────────────────────────────────────────────────────
#   talos_trust_check LABEL POLICY PATH [WHAT [TAIL]]
# Returns 0 when PATH is trustworthy; otherwise prints ONE stderr line naming PATH
# and the fix (never reading the file) and returns 1. POLICY:
#   secret-file  a .env: a regular file (a symlink is refused), owned by the
#                current user, mode exactly 0600, outside every git work tree
#   config-file  the global config: a regular file, or a symlink the user owns
#                pointing at one; owned by the user, neither group- nor
#                world-writable (it drives hooks.* and notifications.cmd)
# It stats with `python3 -I` (same on macOS and Linux); without python3 nothing
# can be verified, so the file is refused. Bash 3.2 safe.

# The stat check as a python library, prepended by pipeline-config.sh to its own
# loader (no extra python3 spawn). trust_problem(uid, policy, path) returns None
# for a trustworthy path, else a (why, fix) pair of plain sentences. It stats only.
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
# expected owner passed in, so a test can ask "owned by someone else?" without a
# second user. talos_trust_check always passes the real uid.
_talos_trust_py_run() { python3 -I -c "$_TALOS_TRUST_LIB$_TALOS_TRUST_CLI" "$@"; }

talos_trust_check() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "${1:-talos}: python3 not found, cannot verify ${4:-file} ${3:-} -- ignoring it" >&2
    return 1
  fi
  _talos_trust_py_run "$(id -u)" "$@"
}

# ── What a .env may set (#476) ───────────────────────────────────────────────
# The repo .env comes from the checkout Talos works in, which can be a PR branch,
# so it must never set BASH_ENV, PATH, LD_PRELOAD and the like. A .env is PARSED,
# never evaluated, and only _TALOS_DOTENV_ALLOW (the notification variables
# pipeline-notify.sh reads: add a name here, nowhere else) is exported from it;
# every other key is ignored with one stderr line. _talos_dotenv_denied is a hard
# deny list that wins even over the allow list. An env:NAME reference to a name
# outside the allow list is still looked up (read, never exported), except a
# denied name, which talos_secret_load refuses before reading anything.
_TALOS_DOTENV_ALLOW=" SLACK_WEBHOOK_URL DISCORD_WEBHOOK_URL TEAMS_WEBHOOK_URL SLACK_BOT_TOKEN DISCORD_BOT_TOKEN BUZZ_BOT_PRIVATE_KEY BUZZ_RELAY_URL PIPELINE_SLACK_CHANNEL PIPELINE_DISCORD_CHANNEL PIPELINE_BUZZ_CHANNEL PIPELINE_BUZZ_RELAY "

# 0 when $1 is on the hard deny list: shell start-up files, the search path, the
# dynamic linker, interpreter module paths, git, proxies (a proxy would route a
# webhook call elsewhere), Talos's own control variables, and the forge and model
# credentials Talos itself holds.
_talos_dotenv_denied() {
  case "$1" in
    BASH_ENV|ENV|PATH|IFS|PROMPT_COMMAND|SHELLOPTS|BASHOPTS|HOME|TMPDIR|SHELL|CDPATH|GLOBIGNORE) return 0 ;;
    BASH_*|LD_*|DYLD_*|PYTHON*|GIT_*|TALOS_*|PS[0-9]|NODE_*|PERL*|RUBY*|CURL_*|SSL_*) return 0 ;;
    GH_*|GITHUB_*|GITLAB_*|AZURE_*|ANTHROPIC_*|AWS_*) return 0 ;;
    *_PROXY|*_proxy) return 0 ;;
  esac
  return 1
}

# 0 when $1 is a valid variable name. Pure `case`; LC_ALL=C so a range cannot
# match a letter of the current locale.
_talos_secret_name_ok() {
  local LC_ALL=C
  case "${1:-}" in ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;; esac
  return 0
}

# 0 when a .env may export $1: a valid name, on the allow list, not denied.
_talos_dotenv_allowed() {
  _talos_secret_name_ok "$1" && ! _talos_dotenv_denied "$1" || return 1
  case "$_TALOS_DOTENV_ALLOW" in *" $1 "*) return 0 ;; esac
  return 1
}

# _talos_env_line LINE -- parse "NAME=value" / "export NAME=value" into _TS_K and
# _TS_V (CRLF tolerated, one surrounding pair of quotes stripped, $(...) and
# backticks left as plain text). Rc 1 for a blank, comment or non-assignment line.
_talos_env_line() {
  local l="${1%$'\r'}"
  case "$l" in ''|'#'*) return 1 ;; 'export '*) l="${l#export }" ;; esac
  case "$l" in *=*) ;; *) return 1 ;; esac
  _TS_K="${l%%=*}"
  _TS_V="${l#*=}"
  case "$_TS_V" in
    '"'*'"') _TS_V="${_TS_V#'"'}"; _TS_V="${_TS_V%'"'}" ;;
    "'"*"'") _TS_V="${_TS_V#"'"}"; _TS_V="${_TS_V%"'"}" ;;
  esac
}

# talos_dotenv_load FILE [LABEL] -- export the allow-listed keys of FILE that are
# not already set (dotenv precedence: exported wins). Every other key is ignored
# with ONE stderr line per key per run naming the key, never the value. A missing
# file is a no-op. Always returns 0.
talos_dotenv_load() {
  local _f="${1:-}" _label="${2:-.env}" _line _skipped=" "
  [ -f "$_f" ] && [ -r "$_f" ] || return 0
  while IFS= read -r _line || [ -n "$_line" ]; do
    _talos_env_line "$_line" || continue
    # A key that is not a plain name is never echoed: it is not a variable.
    _talos_secret_name_ok "$_TS_K" || continue
    if ! _talos_dotenv_allowed "$_TS_K"; then
      case "$_skipped" in
        *" $_TS_K "*) ;;
        *) _skipped="$_skipped$_TS_K "
           echo "pipeline-secrets: $_label: ignoring $_TS_K (not a notification variable Talos reads from a .env)" >&2 ;;
      esac
      continue
    fi
    case "$_TS_V" in
      *[[:cntrl:]]*) echo "pipeline-secrets: $_label: the value for $_TS_K holds a control character; ignoring it" >&2
                     continue ;;
    esac
    if [ -z "${!_TS_K+x}" ]; then
      printf -v "$_TS_K" '%s' "$_TS_V"
      export "$_TS_K"
    fi
  done < "$_f"
  return 0
}

# ── Secret lookup ────────────────────────────────────────────────────────────
_TS_VAL=""            # the last value a lookup found; never printed
_TS_REPO_ENV=""       # the repo .env path, computed once
_TS_HERMES_WARNED=""

# _talos_dotenv_get FILE NAME -- set _TS_VAL to NAME's value in FILE (first match
# wins, even an empty one); return 0 when there is a non-empty one. A name on the
# hard deny list is never read from a .env (the exported environment is guarded
# separately, in talos_secret_load).
_talos_dotenv_get() {
  local _line
  _TS_VAL=""
  [ -r "$1" ] || return 1
  _talos_dotenv_denied "$2" && return 1
  while IFS= read -r _line || [ -n "$_line" ]; do
    _talos_env_line "$_line" && [ "$_TS_K" = "$2" ] || continue
    [ -n "$_TS_V" ] || return 1
    _TS_VAL="$_TS_V"
    return 0
  done < "$1"
  return 1
}

# _talos_user_env_get KIND NAME -- NAME from the user-level .env of KIND (talos or
# hermes), after the trust check. The verdict (ok, bad, none) is cached per KIND
# for the process, so a refused file prints its one line once.
_talos_user_env_get() {
  local _kind="$1" _f="" _sv="_TS_STATE_$1" _state
  case "$_kind" in
    talos)  if [ -n "${TALOS_HOME:-}" ]; then _f="$TALOS_HOME/.env"; elif [ -n "${HOME:-}" ]; then _f="$HOME/.talos/.env"; fi ;;
    # TALOS_HERMES_ENV (#476) moves the legacy file, so a sandboxed test or QA run
    # never reads the real one: empty switches the fallback off.
    hermes) if [ -n "${TALOS_HERMES_ENV+x}" ]; then _f="$TALOS_HERMES_ENV"; elif [ -n "${HOME:-}" ]; then _f="$HOME/.hermes/.env"; fi ;;
  esac
  [ -n "$_f" ] || return 1
  _state="${!_sv:-}"
  if [ -z "$_state" ]; then
    _state=none
    if [ -e "$_f" ] || [ -L "$_f" ]; then
      if talos_trust_check pipeline-secrets secret-file "$_f" ".env" "ignoring it"; then _state=ok; else _state=bad; fi
    fi
    printf -v "$_sv" '%s' "$_state"
  fi
  [ "$_state" = "ok" ] && _talos_dotenv_get "$_f" "$2" || return 1
  if [ "$_kind" = "hermes" ] && [ -z "$_TS_HERMES_WARNED" ]; then
    _TS_HERMES_WARNED=1
    echo "pipeline-secrets: reading secrets from ~/.hermes/.env is deprecated; move them to ${TALOS_HOME:-~/.talos}/.env (chmod 600)" >&2
  fi
  return 0
}

# _talos_secret_env_layers NAME -- steps 1 and 2: the exported environment, then
# the repo .env.
_talos_secret_env_layers() {
  local _root
  if [ -n "${!1:-}" ]; then _TS_VAL="${!1}"; return 0; fi
  if [ -z "$_TS_REPO_ENV" ]; then
    _root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"
    _TS_REPO_ENV="${_root:-$PWD}/.env"
  fi
  _talos_dotenv_get "$_TS_REPO_ENV" "$1"
}

# _talos_secret_assign VAR SHAPE VIA_REF -- put _TS_VAL into VAR unless it holds a
# control character or fails the shape check. Never prints the value.
_talos_secret_assign() {
  case "$_TS_VAL" in
    *[[:cntrl:]]*) echo "pipeline-secrets: the value for $1 holds a control character; ignoring it" >&2; return 1 ;;
  esac
  if [ "$2" = "url" ] && [ "$3" = "1" ]; then
    case "$_TS_VAL" in
      https://?*) ;;
      *) echo "pipeline-secrets: the reference for $1 does not resolve to an https:// URL; ignoring it" >&2; return 1 ;;
    esac
  fi
  printf -v "$1" '%s' "$_TS_VAL"
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
    _name=""
    case "$_ref" in env:*) _name="${_ref#env:}" ;; esac
    if ! _talos_secret_name_ok "$_name"; then
      # Never echo the value: a literal secret pasted into the file lands here.
      echo "pipeline-secrets: $_key is not an env:NAME reference (NAME is letters, digits and underscore); a secret is never read from the config file itself -- ignoring it" >&2
      return 1
    fi
    # A denied name is refused before ANY source is read, the exported environment
    # included (env:GIT_ASKPASS would otherwise resolve from it).
    if _talos_dotenv_denied "$_name"; then
      echo "pipeline-secrets: $_key references $_name, which a config file may not point at (shell, search-path, git and Talos control variables are never read through env:NAME) -- ignoring it" >&2
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
