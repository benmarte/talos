#!/usr/bin/env bash
# pipeline-defaults.sh -- the config schema table (#439, part of #437): every
# documented config key, its type and its default, in one place.
#
# Source this file (it defines functions and one variable, runs nothing).
# pipeline-config.sh and pipeline-cfg-cache.sh source it; nothing else should
# carry a copy of a default.
#
# Table format: TSV rows, one key per row, five tab-separated columns.
#
#   key   type   default   derived   env-override
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
#   env-override  name of an environment variable that call sites check
#                 before the config key, or "-". Documentation for now: the
#                 lookup functions below do not read it.
#
#   Example row:  limits.warn_at<TAB>float<TAB>0.8<TAB>-<TAB>-
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
# checks that every row has five fields.

IFS= read -r -d '' _TALOS_DEFAULTS_RAW <<'TALOS_Qz7vK2mXr9Lp' || true
base_branch	str		derived	-
release_branch	str	main	-	-
repo	str		derived	-
vcs.provider	enum	github	-	-
vcs.repo	str		derived	PIPELINE_REPO
vcs.token_env	str		-	-
vcs.azure.org_url	str		-	-
vcs.azure.project	str		-	-
vcs.azure.work_item_type	str	Product Backlog Item	-	-
vcs.azure.area_path	str		-	-
vcs.file.source.path	path	plan.md	-	-
board.enabled	bool	true	-	-
board.project_number	int		-	PIPELINE_PROJECT_NUMBER
board.owner	str		derived	PIPELINE_BOARD_OWNER
board.status_field	str	Status	-	PIPELINE_STATUS_FIELD
board.statuses.*	str		derived	-
board.status_map.*	str		derived	-
board.azure_states.*	str		derived	-
verify	list		-	-
verify.commands	list		-	-
verify.qa_mode	enum		derived	-
verify.targeted	bool	true	-	-
verify.ci_wait_s	int	900	-	-
verify.timeout_ms	int	600000	-	-
merge.auto	bool	true	-	-
merge.method	enum	squash	-	-
merge.required_checks	list		-	-
merge.delete_branch	bool	true	-	-
merge.forbidden_files	list		derived	-
merge.forbidden_files_replace	bool	false	-	-
merge.forbidden_files_allow	list		-	-
merge.approval_waiver_paths	list		derived	-
merge.union_paths	list		derived	-
merge.auto_sync	bool	true	-	-
issues.label_filter	str	pipeline:ready	-	-
issues.skip_labels	list	pipeline:blocked\nwontfix	-	-
issues.max_parallel	int	1	-	-
issues.assignee	str	self	-	-
execution.isolation	enum	worktree	-	-
execution.worktree_warn_threshold	int	10	-	-
roles.validator	bool	true	-	-
roles.pm	bool	true	-	-
roles.pm_skip_when_spec_present	bool	true	-	-
roles.qa	bool	true	-	-
roles.reviewer	bool	true	-	-
roles.security	bool	true	-	-
roles.adversarial	bool	false	-	-
roles.docs	bool	true	-	-
roles.docs_mode	enum	auto	-	-
roles.planner	bool	false	-	-
roles.changelog_fragments	bool	false	-	-
comments.enabled	bool	true	-	-
comments.header	str	**Agent:** {role} (talos)	-	-
comments.templates_dir	path	templates/comments	-	-
notifications.slack_channel	str		-	PIPELINE_SLACK_CHANNEL
notifications.discord_channel	str		-	PIPELINE_DISCORD_CHANNEL
notifications.buzz_channel	str		-	PIPELINE_BUZZ_CHANNEL
notifications.buzz_relay	str		-	PIPELINE_BUZZ_RELAY
notifications.buzz_timeout_s	int	15	-	-
notifications.templates_dir	path	templates/notifications	-	-
notifications.threading	bool	true	-	-
notifications.events	list		-	-
notifications.cmd	str		-	-
notifications.cmd_timeout_s	int	10	-	-
agents.runner	enum	claude	-	-
agents.subagents	enum	auto	-	-
agents.runner_args	str		-	-
agents.runner_cmd	str		-	-
agents.model	str		-	-
agents.restamp_model	str		derived	-
agents.effort	enum		-	-
agents.restamp_effort	enum		derived	-
agents.roles.*.model	str		derived	-
agents.roles.*.runner	enum		derived	-
agents.roles.*.runner_cmd	str		derived	-
agents.roles.*.restamp_model	str		derived	-
agents.roles.*.effort	enum		derived	-
agents.roles.*.restamp_effort	enum		derived	-
agents.fallback	list		-	-
agents.roles.*.fallback	list		derived	-
agents.provider_down_s	int	900	-	-
limits.max_fix_attempts	int	3	-	-
limits.max_total_dispatches	int	8	-	-
limits.max_retries	int	5	-	-
limits.tokens_per_issue	int		-	-
limits.warn_at	float	0.8	-	-
spend.comment	bool	true	-	-
pr.draft	bool		derived	-
status.enabled	bool	false	-	-
status.file	path	TALOS_STATUS.md	-	-
status.log_heading	str	## Log	-	-
status.resume_heading	str	## Resume here	-	-
status.fragments_dir	path	docs/status.d	-	-
status.archive_dir	path	status/archive	-	-
status.log_days	int	30	-	-
status.log_max	int	50	-	-
status.resume_max_lines	int	40	-	-
markers.trusted_authors	list		-	-
markers.verify_authors	bool	true	-	-
hooks.pre_dispatch	str		-	-
hooks.post_stage	str		-	-
hooks.timeout_s	int	30	-	-
events.enabled	bool	true	-	-
events.path	path	.talos/events.jsonl	-	-
evidence.enabled	bool	false	-	-
evidence.command	str		-	-
evidence.dir	path	.talos/evidence	-	-
evidence.include	list		-	-
evidence.when	enum	user-facing	-	-
evidence.store	enum	attach	-	-
evidence.max_files	int	10	-	-
evidence.max_mb	int	20	-	-
TALOS_Qz7vK2mXr9Lp
# Leading and trailing newline so every row can be matched as "\nKEY\t".
_TALOS_DEFAULTS_TSV=$'\n'"${_TALOS_DEFAULTS_RAW%$'\n'}"$'\n'

# _talos_defaults_row KEY -- find KEY's row (an exact key first, then a "*"
# template with the same number of segments) and set _TD_KEY (the matching
# table key), _TD_TYPE, _TD_DEFAULT (raw, still \n-encoded), _TD_DERIVED and
# _TD_ENV. Returns 1, with those empty, when the table has no such key.
_talos_defaults_row() {
  local _k="${1:-}" _rest _line _t _dots
  _TD_KEY="" _TD_TYPE="" _TD_DEFAULT="" _TD_DERIVED="" _TD_ENV=""
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
  _TD_ENV="$_line"
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
