#!/usr/bin/env bash
# pipeline-cfg-cache.sh -- per-invocation config cache for cfg() (#169).
#
# Source this file (after SCRIPT_DIR is set) wherever a script used to
# define its own `cfg() { "$SCRIPT_DIR/pipeline-config.sh" "$@"; }`
# one-liner: pipeline-vcs.sh, pipeline-notify.sh, pipeline-status.sh,
# pipeline-agent.sh, pipeline-worktree.sh.
#
# cfg() used to shell out to pipeline-config.sh on every call -- a fresh
# python3 process re-parsing the whole config file from disk, even for
# repeat lookups within the same verb (59 call sites across these 5
# scripts, ~26ms each -- issue #169). Instead, the first cfg() call in a
# script invocation dumps the whole resolved config once
# (`pipeline-config.sh --dump`, one python3 spawn, or zero if no config
# file exists) into a per-invocation cache dir, and every cfg() call
# after that -- in this call or any later one -- is answered from that
# cache with pure shell, no python3 involved.
#
# Subshell note: almost every real cfg() call site is written
# `x="$(cfg key default)"` -- a command-substitution subshell. A subshell
# inherits its parent's variables at fork time but can never write state
# back to the parent, so a naive "have I loaded yet?" flag set *inside*
# cfg() would never be visible to the next `$(cfg ...)` call -- each one
# would see the flag as unset and re-dump, defeating the cache entirely
# (caught by the spawn-count regression test). The fix: only the cache
# *paths* need to exist before any cfg() call can happen, and those are
# created here, synchronously, at source time (mktemp -d -- cheap, no
# python3) -- every subshell inherits the same paths. Whether the dump has
# actually been populated yet is tracked as a *file on disk* (a sentinel
# file), not a shell variable, so it is visible to every subshell
# regardless of which one populates it first.
#
# Cache semantics are strictly per invocation, not global: the dump
# happens at most once per process -- a config file edit made
# mid-invocation is NOT picked up. A new script invocation sources this
# file again, gets a fresh cache dir, and always re-dumps, seeing the
# edit.
#
# The cache dir is unique per invocation (mktemp -d) and is always
# removed on exit, including on error, via a small composable EXIT-trap
# registry: some scripts (pipeline-vcs.sh's post-approval verb) already
# register their own EXIT trap for an unrelated temp file, and a bare
# `trap ... EXIT` from either site would silently clobber the other's.
#
# Bash 3.2 (macOS) compatible: a plain indexed array, no associative
# arrays.

# The config schema table (#439): the fallback for a cfg call with no default.
# It is loaded only when intact (pipeline-defaults-check.sh, shared with
# pipeline-config.sh): readable, complete (a truncated copy lacks its final
# sentinel) and holding a row for every security-relevant key. When it is not,
# such a call prints nothing, as an unknown key always did -- EXCEPT for a
# security-relevant key (merge.auto, limits.*, hooks.*, the forbidden-files and
# approval-waiver lists, markers.*_authors), which fails closed (#440): one
# stderr line, then SIGTERM to the whole script. A `$(cfg ...)` runs in a
# subshell, where `exit` would only end the subshell and let the caller carry on
# with an empty value; $$ is always the main script, so the kill reaches it from
# anywhere (its EXIT hooks run). If the check helper itself is missing nothing
# can say which keys are safe, so every no-default lookup fails closed.
if [ -f "$SCRIPT_DIR/pipeline-defaults-check.sh" ] \
   && . "$SCRIPT_DIR/pipeline-defaults-check.sh" \
   && _talos_load_defaults "$SCRIPT_DIR/pipeline-defaults.sh"; then
  :
else
  if ! [ "$(type -t _talos_security_key)" = "function" ]; then _talos_security_key() { return 0; }; fi
  _talos_default() {
    _talos_security_key "${1:-}" || return 0
    echo "pipeline: pipeline-defaults.sh is missing or unusable; stopping rather than guess the default of ${1:-}" >&2
    kill -s TERM "$$"
    return 1
  }
fi

_TALOS_EXIT_HOOKS=()

# _talos_on_exit CMD -- register a shell command string to run at exit,
# in addition to (never instead of) any hook already registered.
_talos_on_exit() { _TALOS_EXIT_HOOKS+=("$1"); }

_talos_run_exit_hooks() {
  local _hook
  for _hook in "${_TALOS_EXIT_HOOKS[@]:-}"; do
    [ -n "$_hook" ] && eval "$_hook"
  done
}

trap _talos_run_exit_hooks EXIT

_CFG_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/talos-cfg-cache.XXXXXX" 2>/dev/null)" || _CFG_CACHE_DIR=""
if [ -n "$_CFG_CACHE_DIR" ]; then
  _talos_on_exit 'rm -rf "$_CFG_CACHE_DIR"'
fi
_CFG_CACHE_FILE="$_CFG_CACHE_DIR/dump"
_CFG_CACHE_DONE="$_CFG_CACHE_DIR/done"

# cfg KEY [DEFAULT] -- same contract as `pipeline-config.sh KEY [DEFAULT]`:
# prints the resolved value when KEY is set in a config layer; else DEFAULT
# when a second argument was given (even ""); else (#439) KEY's default from
# the config schema table in pipeline-defaults.sh -- empty for a derived or
# unknown key. The table lookup is pure shell: a call that falls back to it
# spawns nothing, and with no config file the dump spawns nothing either.
# Safe to call from any number of command-substitution subshells; the
# first call anywhere (in this process) to actually need the dump
# populates it, every other call just reads it.
cfg() {
  local _key="${1:-}" _default="${2:-}"
  if [ -n "$_CFG_CACHE_DIR" ]; then
    if [ ! -e "$_CFG_CACHE_DONE" ]; then
      # stderr intentionally NOT redirected (#176): --dump's stderr is where
      # pipeline-config.sh's unknown-config-key warning (and the
      # verify.qa_mode / verify.timeout_ms / verify.ci_wait_s fail-closed
      # notices) lives, and this dump is the only pipeline-config.sh call
      # every cfg()-caching script makes (pipeline-vcs.sh, pipeline-notify.sh,
      # pipeline-status.sh, pipeline-agent.sh, pipeline-worktree.sh) --
      # swallowing stderr here meant none of them ever surfaced a config
      # typo. --dump's "no config file found" case exits before touching
      # python3 and never wrote to stderr, so there was never a routine
      # message this redirect was hiding.
      "$SCRIPT_DIR/pipeline-config.sh" --dump > "$_CFG_CACHE_FILE"
      : > "$_CFG_CACHE_DONE"
    fi
    if [ -f "$_CFG_CACHE_FILE" ]; then
      local _k _v
      while IFS= read -r -d '' _k && IFS= read -r -d '' _v; do
        if [ "$_k" = "$_key" ]; then
          printf '%s' "$_v"
          return 0
        fi
      done < "$_CFG_CACHE_FILE"
    fi
  fi
  if [ "$#" -lt 2 ]; then _talos_default "$_key"; return $?; fi
  printf '%s' "$_default"
}
