#!/usr/bin/env bash
# pipeline-defaults.sh -- the config schema table (#439, part of #437): every
# documented config key, its type and its default, in one place.
#
# Source this file (it defines functions and one variable, runs nothing).
# pipeline-config.sh and pipeline-cfg-cache.sh source it; nothing else should
# carry a copy of a default.
#
# Table format: TSV rows, one key per row, six tab-separated columns.
#
#   key   type   default   derived   env-override   scope
#
#   key           dot path; "*" stands for a dynamic segment
#                 (board.status_map.*, agents.roles.*.model, ...)
#   type          str | path | int | float | bool | enum | list
#   default       the value used when the key is absent from every config
#                 layer, as `cfg KEY` / `pipeline-config.sh KEY` print it:
#                 bools are true/false, a list is its items joined by the
#                 two characters \n (decoded to newlines on output), empty
#                 means "empty string". For a derived key it stays empty.
#   derived       "derived" when the default is computed (from another key,
#                 git, the environment or a built-in list), so the table
#                 cannot state it; the caller keeps its own fallback. "-"
#                 otherwise.
#   env-override  name of an environment variable that overrides the key, or
#                 "-". It is the fourth config layer (#441): defaults, global
#                 file, repo file, then this variable when it is set and not
#                 empty. Only the already-documented per-key variables are
#                 listed; there is no generic TALOS_CFG_* mapping.
#   scope         "any" when the key may be set in the global file
#                 ($TALOS_HOME/talos.pipeline.*), "repo" when it describes one
#                 repository and is honoured only in the repo's own file (#441):
#                 a "repo" key found in the global file is dropped with one
#                 stderr note that names the key, never the value. The env
#                 variable of a "repo" key still applies (env is the last layer).
#
#   Example row:  limits.warn_at<TAB>float<TAB>0.8<TAB>-<TAB>-<TAB>any
#
# Derived keys and where their default really comes from:
#   base_branch, repo, vcs.repo, board.owner   git remote / gh / other keys
#   verify.qa_mode                             merge.required_checks
#   agents.restamp_model, agents.restamp_effort, agents.roles.*.*
#                                              the chain role -> global ->
#                                              agents.model / agents.effort
#   merge.forbidden_files                      the built-in pattern list in
#                                              pipeline-vcs.sh
#   merge.approval_waiver_paths, merge.union_paths
#                                              built-in lists in the consumer
#   board.statuses.*, board.status_map.*, board.azure_states.*
#                                              per-status values in the caller
#   pr.draft                                   scripts/pipeline-draft-check.sh
#                                              resolve (the one resolver, #435;
#                                              no second copy here)
#
# Lookup rule (see cfg in pipeline-cfg-cache.sh and pipeline-config.sh): a key
# that is set in a config layer wins; otherwise a caller-supplied default (even
# an empty one) wins; only a call with NO default argument falls back to this
# table. That keeps every existing `cfg KEY "literal"` call site exactly as it
# was while the call sites are migrated to the table (#440).
#
# Bash 3.2 safe (no associative arrays, no ${var,,}); the lookups are plain
# parameter expansion, so a lookup spawns no process, python3 included.
# Tabs matter: keep a real tab between columns. tests/test-config-defaults-table.sh
# checks that every row has six fields.

IFS= read -r -d '' _TALOS_DEFAULTS_RAW <<'TALOS_Qz7vK2mXr9Lp' || true
base_branch	str		derived	-	repo
release_branch	str	main	-	-	repo
repo	str		derived	-	repo
vcs.provider	enum	github	-	-	repo
vcs.repo	str		derived	PIPELINE_REPO	repo
vcs.token_env	str		-	-	any
vcs.azure.org_url	str		-	-	repo
vcs.azure.project	str		-	-	repo
vcs.azure.work_item_type	str	Product Backlog Item	-	-	repo
vcs.azure.area_path	str		-	-	repo
vcs.file.source.path	path	plan.md	-	-	repo
board.enabled	bool	true	-	-	repo
board.project_number	int		-	PIPELINE_PROJECT_NUMBER	repo
board.owner	str		derived	PIPELINE_BOARD_OWNER	repo
board.status_field	str	Status	-	PIPELINE_STATUS_FIELD	repo
board.statuses.*	str		derived	-	repo
board.status_map.*	str		derived	-	repo
board.azure_states.*	str		derived	-	repo
verify	list		-	-	repo
verify.commands	list		-	-	repo
verify.qa_mode	enum		derived	-	repo
verify.targeted	bool	true	-	-	any
verify.ci_wait_s	int	900	-	-	any
verify.timeout_ms	int	600000	-	-	any
merge.auto	bool	true	-	-	any
merge.method	enum	squash	-	-	any
merge.required_checks	list		-	-	repo
merge.delete_branch	bool	true	-	-	any
merge.forbidden_files	list		derived	-	repo
merge.forbidden_files_replace	bool	false	-	-	repo
merge.forbidden_files_allow	list		-	-	repo
merge.approval_waiver_paths	list		derived	-	repo
merge.union_paths	list		derived	-	repo
merge.auto_sync	bool	true	-	-	any
issues.label_filter	str	pipeline:ready	-	-	repo
issues.skip_labels	list	pipeline:blocked\nwontfix	-	-	repo
issues.max_parallel	int	1	-	-	any
issues.assignee	str	self	-	-	any
execution.isolation	enum	worktree	-	-	any
execution.worktree_warn_threshold	int	10	-	-	any
roles.validator	bool	true	-	-	any
roles.pm	bool	true	-	-	any
roles.pm_skip_when_spec_present	bool	true	-	-	any
roles.qa	bool	true	-	-	any
roles.reviewer	bool	true	-	-	any
roles.security	bool	true	-	-	any
roles.adversarial	bool	false	-	-	any
roles.docs	bool	true	-	-	any
roles.docs_mode	enum	auto	-	-	any
roles.planner	bool	false	-	-	any
roles.changelog_fragments	bool	false	-	-	any
comments.enabled	bool	true	-	-	any
comments.header	str	**Agent:** {role} (talos)	-	-	any
comments.templates_dir	path	templates/comments	-	-	any
notifications.slack_channel	str		-	PIPELINE_SLACK_CHANNEL	any
notifications.discord_channel	str		-	PIPELINE_DISCORD_CHANNEL	any
notifications.buzz_channel	str		-	PIPELINE_BUZZ_CHANNEL	any
notifications.buzz_relay	str		-	PIPELINE_BUZZ_RELAY	any
notifications.buzz_timeout_s	int	15	-	-	any
notifications.templates_dir	path	templates/notifications	-	-	any
notifications.threading	bool	true	-	-	any
notifications.events	list		-	-	any
notifications.cmd	str		-	-	any
notifications.cmd_timeout_s	int	10	-	-	any
agents.runner	enum	claude	-	-	any
agents.subagents	enum	auto	-	-	any
agents.runner_args	str		-	-	any
agents.runner_cmd	str		-	-	any
agents.model	str		-	-	any
agents.restamp_model	str		derived	-	any
agents.effort	enum		-	-	any
agents.restamp_effort	enum		derived	-	any
agents.roles.*.model	str		derived	-	any
agents.roles.*.runner	enum		derived	-	any
agents.roles.*.runner_cmd	str		derived	-	any
agents.roles.*.restamp_model	str		derived	-	any
agents.roles.*.effort	enum		derived	-	any
agents.roles.*.restamp_effort	enum		derived	-	any
agents.fallback	list		-	-	any
agents.roles.*.fallback	list		derived	-	any
agents.provider_down_s	int	900	-	-	any
limits.max_fix_attempts	int	3	-	-	any
limits.max_total_dispatches	int	8	-	-	any
limits.max_retries	int	5	-	-	any
limits.tokens_per_issue	int		-	-	any
limits.warn_at	float	0.8	-	-	any
spend.comment	bool	true	-	-	any
pr.draft	bool		derived	-	any
status.enabled	bool	false	-	-	any
status.file	path	TALOS_STATUS.md	-	-	repo
status.log_heading	str	## Log	-	-	any
status.resume_heading	str	## Resume here	-	-	any
status.fragments_dir	path	docs/status.d	-	-	repo
status.archive_dir	path	status/archive	-	-	repo
status.log_days	int	30	-	-	any
status.log_max	int	50	-	-	any
status.resume_max_lines	int	40	-	-	any
markers.trusted_authors	list		-	-	repo
markers.verify_authors	bool	true	-	-	repo
hooks.pre_dispatch	str		-	-	any
hooks.post_stage	str		-	-	any
hooks.timeout_s	int	30	-	-	any
events.enabled	bool	true	-	-	any
events.path	path	.talos/events.jsonl	-	-	any
evidence.enabled	bool	false	-	-	any
evidence.command	str		-	-	repo
evidence.dir	path	.talos/evidence	-	-	any
evidence.include	list		-	-	any
evidence.when	enum	user-facing	-	-	any
evidence.store	enum	attach	-	-	any
evidence.max_files	int	10	-	-	any
evidence.max_mb	int	20	-	-	any
TALOS_Qz7vK2mXr9Lp
# Leading and trailing newline so every row can be matched as "\nKEY\t".
_TALOS_DEFAULTS_TSV=$'\n'"${_TALOS_DEFAULTS_RAW%$'\n'}"$'\n'

# _talos_defaults_row KEY -- find KEY's row (an exact key first, then a "*"
# template with the same number of segments) and set _TD_KEY (the matching
# table key), _TD_TYPE, _TD_DEFAULT (raw, still \n-encoded), _TD_DERIVED,
# _TD_ENV and _TD_SCOPE. Returns 1, with those empty, when the table has no such key.
_talos_defaults_row() {
  local _k="${1:-}" _rest _line _t _dots
  _TD_KEY="" _TD_TYPE="" _TD_DEFAULT="" _TD_DERIVED="" _TD_ENV="" _TD_SCOPE=""
  [ -n "$_k" ] || return 1
  case "$_TALOS_DEFAULTS_TSV" in
    *$'\n'"$_k"$'\t'*)
      _TD_KEY="$_k"
      _rest="${_TALOS_DEFAULTS_TSV#*$'\n'"$_k"$'\t'}"
      _line="${_rest%%$'\n'*}"
      ;;
    *)
      _dots="${_k//[!.]/}"
      _rest="${_TALOS_DEFAULTS_TSV#$'\n'}"
      _line=""
      while [ -n "$_rest" ]; do
        _t="${_rest%%$'\t'*}"
        case "$_t" in
          *'*'*)
            # shellcheck disable=SC2053  # $_t is deliberately a glob
            if [ "${_t//[!.]/}" = "$_dots" ] && [[ $_k == $_t ]]; then
              _TD_KEY="$_t"
              _line="${_rest%%$'\n'*}"
              _line="${_line#*$'\t'}"
              break
            fi
            ;;
        esac
        case "$_rest" in *$'\n'*) _rest="${_rest#*$'\n'}" ;; *) _rest="" ;; esac
      done
      [ -n "$_TD_KEY" ] || return 1
      ;;
  esac
  _TD_TYPE="${_line%%$'\t'*}";    _line="${_line#*$'\t'}"
  _TD_DEFAULT="${_line%%$'\t'*}"; _line="${_line#*$'\t'}"
  _TD_DERIVED="${_line%%$'\t'*}"; _line="${_line#*$'\t'}"
  _TD_ENV="${_line%%$'\t'*}";     _line="${_line#*$'\t'}"
  _TD_SCOPE="$_line"
  return 0
}

# _talos_default KEY -- print KEY's table default (no trailing newline): empty
# for an unknown key and for a derived one (the caller keeps its own fallback).
_talos_default() {
  _talos_defaults_row "${1:-}" || return 0
  [ "$_TD_DERIVED" = "derived" ] && return 0
  printf '%s' "${_TD_DEFAULT//\\n/$'\n'}"
}

# _talos_defaults_keys -- print every table key, one per line, in table order.
_talos_defaults_keys() {
  local _rest="${_TALOS_DEFAULTS_TSV#$'\n'}"
  while [ -n "$_rest" ]; do
    printf '%s\n' "${_rest%%$'\t'*}"
    case "$_rest" in *$'\n'*) _rest="${_rest#*$'\n'}" ;; *) _rest="" ;; esac
  done
}

# _talos_known_keys_json -- the table's keys as a JSON array of strings: the
# known-config-keys list pipeline-config.sh hands to its unknown-key check.
# Generated here so the list can never drift from the table.
_talos_known_keys_json() {
  local _rest="${_TALOS_DEFAULTS_TSV#$'\n'}" _out="[" _sep=$'\n  '
  while [ -n "$_rest" ]; do
    _out="$_out$_sep\"${_rest%%$'\t'*}\""
    _sep=$',\n  '
    case "$_rest" in *$'\n'*) _rest="${_rest#*$'\n'}" ;; *) _rest="" ;; esac
  done
  printf '%s\n]' "$_out"
}

# _talos_scope_env_json -- the rows that matter to the python loader as a JSON
# array of [key, scope, env-var] triples: every repo-scoped key and every key
# that has an env override. pipeline-config.sh prepends it to the shared loader
# (_CFG_LOADER_PY) so the python side never carries its own copy of either list.
_talos_scope_env_json() {
  local _rest="${_TALOS_DEFAULTS_TSV#$'\n'}" _out="[" _sep=$'\n  ' _line _f
  local _key _scope _env
  while [ -n "$_rest" ]; do
    _line="${_rest%%$'\n'*}"
    _key="${_line%%$'\t'*}"; _f="${_line#*$'\t'}"        # type default derived env scope
    _f="${_f#*$'\t'}"; _f="${_f#*$'\t'}"; _f="${_f#*$'\t'}"  # env scope
    _env="${_f%%$'\t'*}"; _scope="${_f#*$'\t'}"
    if [ "$_scope" = "repo" ] || [ "$_env" != "-" ]; then
      _out="$_out$_sep[\"$_key\", \"$_scope\", \"$_env\"]"
      _sep=$',\n  '
    fi
    case "$_rest" in *$'\n'*) _rest="${_rest#*$'\n'}" ;; *) _rest="" ;; esac
  done
  printf '%s\n]' "$_out"
}

# _talos_env_value KEY -- print the value of KEY's env override (no trailing
# newline) and return 0 when KEY has one and it is set and not empty; return 1
# otherwise. Pure shell, for the paths that run with no config file (no python3).
_talos_env_value() {
  _talos_defaults_row "${1:-}" || return 1
  case "$_TD_ENV" in -|"") return 1 ;; esac
  [ -n "${!_TD_ENV:-}" ] || return 1
  printf '%s' "${!_TD_ENV}"
}

# _talos_env_dump -- print every env override that is set and not empty as
# NUL-delimited key/value pairs, the --dump format. Wildcard keys never carry
# an env override, so no key is expanded.
_talos_env_dump() {
  local _rest="${_TALOS_DEFAULTS_TSV#$'\n'}" _line _key _f _env
  while [ -n "$_rest" ]; do
    _line="${_rest%%$'\n'*}"
    _key="${_line%%$'\t'*}"; _f="${_line#*$'\t'}"
    _f="${_f#*$'\t'}"; _f="${_f#*$'\t'}"; _f="${_f#*$'\t'}"
    _env="${_f%%$'\t'*}"
    if [ "$_env" != "-" ] && [ -n "${!_env:-}" ]; then
      printf '%s\0%s\0' "$_key" "${!_env}"
    fi
    case "$_rest" in *$'\n'*) _rest="${_rest#*$'\n'}" ;; *) _rest="" ;; esac
  done
}
