#!/usr/bin/env bash
# pipeline-defaults-check.sh -- load scripts/pipeline-defaults.sh only when it is
# intact, and say which keys must fail closed when it is not (#440, epic #437).
#
# Source this file; it defines functions and runs nothing. pipeline-config.sh and
# pipeline-cfg-cache.sh both use it, so there is ONE definition of "the table is
# usable" and of "a security-relevant key".
#
# Why: no call site passes a default any more, so a key that is absent from the
# config is answered by the table. A table that is missing, unreadable (mode 000)
# or cut short (an interrupted install: the heredoc ends at end-of-file and bash
# only warns) would answer empty for merge.auto, limits.*, markers.verify_authors
# and the rest -- which switches the attempt caps and the author check off. A
# plain `[ -f ]` before `.` catches only the first case.
#
# _talos_load_defaults FILE  returns 0 only when FILE is a readable regular file,
#                            sources without error, reached its final line (it ends
#                            by setting _TALOS_DEFAULTS_END=1, so a truncated copy
#                            lacks it), defines the lookup, and has a row for every
#                            security-relevant key. On 1 the caller installs its
#                            fail-closed stubs; whatever a failed source defined is
#                            then overwritten or never called.
# _talos_security_key KEY    returns 0 for a key that must fail closed when the
#                            table is unusable.

# Keys read by the merge gate, the attempt caps, the author check, the hooks and
# the stage roles (a broken table must not read as "role off"). This list is the
# one definition: _talos_load_defaults requires a table row for each entry, and
# _talos_security_key is derived from it. Every limits.* and hooks.* key is also
# security-relevant, listed or not (a prefix match below).
_TALOS_SECURITY_KEYS="merge.forbidden_files merge.forbidden_files_replace merge.forbidden_files_allow
merge.approval_waiver_paths merge.auto markers.verify_authors markers.trusted_authors
limits.max_fix_attempts limits.max_total_dispatches limits.max_retries
limits.tokens_per_issue limits.warn_at hooks.pre_dispatch hooks.post_stage hooks.timeout_s
roles.qa roles.reviewer roles.security"

_talos_security_key() {
  local _k="${1:-}" _s
  case "$_k" in limits.*|hooks.*) return 0 ;; esac
  for _s in $_TALOS_SECURITY_KEYS; do
    [ "$_s" = "$_k" ] && return 0
  done
  return 1
}

_talos_load_defaults() {
  local _f="${1:-}" _k _row _need
  _TALOS_DEFAULTS_END=""
  [ -f "$_f" ] && [ -r "$_f" ] || return 1
  # Sourced for real (the table is small); a failed source leaves partial
  # definitions that the caller's stubs replace.
  # shellcheck disable=SC1090
  . "$_f" 2>/dev/null || return 1
  [ "${_TALOS_DEFAULTS_END:-}" = "1" ] || return 1
  [ "$(type -t _talos_default)" = "function" ] || return 1
  [ "$(type -t _talos_defaults_row)" = "function" ] || return 1
  [ "$(type -t _talos_defaults_split)" = "function" ] || return 1
  # One pass over the table's rows, striking each security key off a pending
  # list as its own row goes by; any key still pending means a missing row. (It
  # used to look each of the 17 keys up in the ~16 KB table string, ~7 ms apiece:
  # 125 ms in every config-reading process, #483.) An EXACT row is required, as
  # it always effectively was: no security key is covered by a "*" template.
  _need=" ${_TALOS_SECURITY_KEYS//$'\n'/ } "
  _talos_defaults_split
  for _row in ${_TD_ROWS[@]+"${_TD_ROWS[@]}"}; do
    _k="${_row%%$'\t'*}"
    case "$_need" in *" $_k "*) _need="${_need/ $_k / }" ;; esac
  done
  [ -z "${_need// /}" ] || return 1
  return 0
}
