#!/usr/bin/env bash
# talos.sh -- the orchestrator's one entry point (#465, slice 1 of epic #422).
#
# Usage: talos.sh env
#        talos.sh gate fix-round <N> <stage> [--pr M]
#        talos.sh gate merge <pr> <issue>
#        talos.sh help
#
# One script with verbs; each later slice adds a verb and deletes the playbook
# prose it replaces. Slice 1 added `env`, slice 2 (#466) adds `gate`.
#
#   env    Everything Step 0 of skills/pipeline/SKILL.md and the per-role runner
#          resolution used to make the orchestrator gather by hand, in one call:
#          every resolved config value Step 0 lists, the isolation gate, PR_DRAFT
#          (pipeline-draft-check.sh resolve), the evidence line (pipeline-
#          evidence.sh enabled), the startup diagnostic's two facts and, for
#          each role, the answers of `pipeline-agent.sh --resolve <role>` and
#          `--check-effort <role>`. Their logic is called, never copied.
#
# Output (stdout), one line each, nothing else:
#   KEY=value                  a config value or a per-role field. Keys are
#                              [A-Za-z][A-Za-z0-9_.]*: SCRIPTS_DIR and
#                              AGENT_SOURCE (the startup diagnostic), the Step 0
#                              names (BASE_BRANCH, MERGE_AUTO, ...) and
#                              agent.<role>.<field> (runner, runner_cmd, model,
#                              effort, fallback, effort_notice); only runner is
#                              always printed, an absent field is empty.
#   warn reason=<enum> [role=<role>|key=<KEY>]
#                              the run can go on; the line says what is missing.
#   stop reason=<enum>         the run must not start (exit non-zero).
# A list value (verify commands, required checks, skip labels) is its items
# joined by the two characters \n; inside an item a backslash prints as \\, so
# the text \n in a config value (printed \\n) is never a list separator. Every
# value is config or script text, so it is sanitised in one python3 -I pass: a
# control character, DEL and a C1 control print as \xNN, an invalid UTF-8 byte as
# \xNN, a bidi control (U+202A-U+202E, U+2066-U+2069, U+200E, U+200F, U+061C) or
# invisible character (U+200B-U+200D, U+2060, U+00AD, U+2028, U+2029, U+FEFF) as
# \uXXXX, a tag character (U+E0000-U+E007F) as \UXXXXXXXX, and a value over 8192
# characters is cut, ends in the marker [truncated] and is followed by `warn
# reason=value-truncated key=<KEY>`. A real "[truncated]" inside a value prints
# as \x5btruncated], so the marker only ever means a cut. Free text never
# travels on argv: values go to the sanitiser on stdin, a file carries them there.
# A child's stderr line (config, draft or evidence warning, an isolation error)
# is passed through on stderr, unchanged.
#
# env-reasons: scripts-missing python-missing scratch-unavailable config-unreadable isolation-invalid usage unknown-verb draft-resolve-failed resolve-failed effort-check-failed value-truncated
#   stop: scripts-missing python-missing scratch-unavailable config-unreadable
#         isolation-invalid usage unknown-verb draft-resolve-failed
#   warn: resolve-failed effort-check-failed value-truncated
#
# gate    Two verbs that compose the pipeline-vcs.sh and pipeline-budget.sh calls the
#         playbook used to list, in the same order, and print one verdict. They
#         write only what that prose wrote (labels, a PR comment, the `blocked`
#         notice, record-attempt's marker, the budget hook, the base-update push)
#         and never merge: on `verdict=merge` the orchestrator runs `merge-pr`.
#
#   gate fix-round <N> <stage> [--pr M]
#          Step 3's order: pipeline-budget.sh check, record-attempt (with --pr
#          when a PR exists), then the unblock (label-pr/label-issue --remove
#          pipeline:blocked). <stage> is developer qa reviewer security docs
#          validator pm adversarial.
#            verdict=redispatch  stage=<stage> count=<k> total=<t> [budget=<warn line>]
#            verdict=block       reason=budget-exceeded|max-fix-attempts|
#                                max-total-dispatches|record-failed, blocked_by=<text>
#          A block has set pipeline:blocked on the issue (and the PR); the
#          orchestrator posts blocked.md (or marks needs-owner) with blocked_by.
#   gate merge <pr> <issue>
#          Step 4's order: labels (blocked, skip-qa, the approval labels of the
#          enabled roles), check-approval-sha --stale-list, check-pr-files,
#          check-closing-keyword, pr-is-draft (PR_DRAFT only), pr-checks-required
#          with the 2-re-runs-per-head budget, the stale-base guard, then
#          merge.auto: handoff, or merge.
#            verdict=merge      [ci_runs=<n>]   gates passed: pr-ci-runs was read (PR_DRAFT)
#            verdict=handoff                    merge.auto is off: pipeline:approved is set
#            verdict=redispatch reason=stale-approvals stale=<roles, re-stamp order>
#                                 | draft-pr | ci-failed (PR_DRAFT) | merge-conflict
#            verdict=wait       reason=blocked-label | approvals-missing missing=<labels>
#                                 | ci-pending | ci-rerun attempt=<k> | rerun-unsupported
#                                 | ci-failed | base-synced | awaiting-human-merge
#            verdict=block      reason=forbidden-files | closing-keyword | siblings-capped
#          A `stop` means a gate could not be checked (exit 1): do not merge.
#          Not added to the old order on purpose: pr-mergeable (Step 3c, and only
#          after a base update here) and assert-sync (Step 0, before 3e).
#
# gate-reasons: budget-exceeded max-fix-attempts max-total-dispatches record-failed stale-approvals draft-pr ci-failed merge-conflict blocked-label approvals-missing ci-pending ci-rerun rerun-unsupported base-synced awaiting-human-merge forbidden-files closing-keyword siblings-capped
#   stop: usage unknown-verb scripts-missing python-missing scratch-unavailable config-unreadable
#         draft-resolve-failed view-failed labels-unreadable approval-sha-failed
#         unsupported-verb:<verb> draft-unverified ci-unverified head-unresolved
#         comments-unreadable handoff-label-failed
#   warn: closing-keyword-unverified ci-runs-unrecorded budget-check-failed
#         unblock-failed comment-failed label-failed conflict-check-failed value-truncated
#
# Exit codes: 0 ok (for gate: a verdict was printed), 1 a `stop`, 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1

# The roles `pipeline-agent.sh --resolve-all` lists, in the same order.
_TALOS_ROLES="validator pm developer qa reviewer security adversarial docs planner"

# The Step 0 settings: VARIABLE, config key, kind (s = scalar, l = list). The
# order is the order of the output. A key absent from every config layer prints
# the schema table's default (pipeline-defaults.sh), never a copy made here.
_talos_env_table() {
  cat <<'TABLE'
VCS_PROVIDER	vcs.provider	s
BOARD_ENABLED	board.enabled	s
PROJECT_NUMBER	board.project_number	s
BOARD_OWNER	board.owner	s
MAX_PARALLEL	issues.max_parallel	s
MAX_FIX_ATTEMPTS	limits.max_fix_attempts	s
LABEL_FILTER	issues.label_filter	s
SKIP_LABELS	issues.skip_labels	l
MERGE_AUTO	merge.auto	s
MERGE_AUTO_SYNC	merge.auto_sync	s
MERGE_REQUIRED_CHECKS	merge.required_checks	l
VERIFY_COMMANDS	verify	l
VERIFY_QA_MODE	verify.qa_mode	s
VERIFY_TARGETED	verify.targeted	s
VERIFY_CI_WAIT_S	verify.ci_wait_s	s
VERIFY_TIMEOUT_MS	verify.timeout_ms	s
ROLE_VALIDATOR	roles.validator	s
ROLE_PM	roles.pm	s
ROLE_QA	roles.qa	s
ROLE_REVIEWER	roles.reviewer	s
ROLE_SECURITY	roles.security	s
ROLE_DOCS	roles.docs	s
ROLE_PLANNER	roles.planner	s
ROLE_ADVERSARIAL	roles.adversarial	s
ROLE_PM_SKIP_WHEN_SPEC_PRESENT	roles.pm_skip_when_spec_present	s
ROLE_CHANGELOG_FRAGMENTS	roles.changelog_fragments	s
ROLE_DOCS_MODE	roles.docs_mode	s
STATUS_ENABLED	status.enabled	s
STATUS_FILE	status.file	s
STATUS_FRAGMENTS_DIR	status.fragments_dir	s
COMMENTS_ENABLED	comments.enabled	s
COMMENTS_HEADER_TPL	comments.header	s
COMMENTS_TMPL_DIR	comments.templates_dir	s
SPEND_COMMENT	spend.comment	s
AGENTS_RUNNER	agents.runner	s
AGENTS_SUBAGENTS	agents.subagents	s
FILE_SOURCE_PATH	vcs.file.source.path	s
ISOLATION	execution.isolation	s
WORKTREE_WARN_THRESHOLD	execution.worktree_warn_threshold	s
TABLE
}

# The sanitiser: NUL-delimited KEY, VALUE pairs on stdin, one line each on
# stdout. `stop` and `warn` pairs print as `<key> <value>`, the rest as
# `KEY=value`. A key written `@KEY` carries a list: its items are the
# newline-separated lines of the value, joined by the two characters \n. Runs as
# `python3 -I` with the program on argv and the data on stdin.
_TALOS_SANITISER='
import re, sys
CAP = 8192
KEY = re.compile(r"[A-Za-z][A-Za-z0-9_.]*\Z")
HIDDEN = set(range(0x202A, 0x202F)) | set(range(0x2066, 0x206A)) | set(range(0xE0000, 0xE0080)) | {0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x061C, 0x2060, 0x00AD, 0x2028, 0x2029, 0xFEFF}
parts = sys.stdin.buffer.read().split(b"\0")
if parts and parts[-1] == b"":
    parts.pop()
def one(c):
    n = ord(c)
    if c == "\\":
        return "\\\\"
    if 0xDC80 <= n <= 0xDCFF:
        return "\\x%02x" % (n - 0xDC00)
    if n < 32 or 0x7F <= n <= 0x9F:
        return "\\x%02x" % n
    if n in HIDDEN:
        return "\\u%04x" % n if n < 0x10000 else "\\U%08x" % n
    return c
def esc(s):
    # A real "[truncated]" must not look like the cut marker added below.
    return "".join(one(c) for c in s).replace("[truncated]", "\\x5btruncated]")
out = []
warns = []
for i in range(0, len(parts) - 1, 2):
    key = parts[i].decode("ascii", "replace")
    is_list = key.startswith("@")
    key = key.lstrip("@")
    if not KEY.match(key):
        continue
    val = parts[i + 1].decode("utf-8", "surrogateescape")
    cut = len(val) > CAP
    if cut:
        val = val[:CAP]
        warns.append("warn reason=value-truncated key=" + key)
    val = "\\n".join(esc(x) for x in val.split("\n")) if is_list else esc(val)
    if cut:
        val += "[truncated]"
    out.append(key + (" " if key in ("stop", "warn") else "=") + val)
sys.stdout.buffer.write(("\n".join(out + warns) + "\n").encode("utf-8"))
'

# Buffer file for the pairs of this run; set once the scratch dir exists.
_TALOS_OUT=""

_talos_emit() { printf '%s\0%s\0' "$1" "$2" >> "$_TALOS_OUT"; }

# _talos_flush: sanitise the buffer to stdout.
_talos_flush() { python3 -I -c "$_TALOS_SANITISER" < "$_TALOS_OUT"; }

# _talos_stop <reason> [exit-code]: print the one line `stop reason=<reason>`
# (nothing collected so far is printed) and leave.
_talos_stop() {
  if [ -n "$_TALOS_OUT" ] && [ -f "$_TALOS_OUT" ]; then
    : > "$_TALOS_OUT"
    _talos_emit stop "reason=$1"
    _talos_flush
  else
    printf 'stop reason=%s\n' "$1"
  fi
  exit "${2:-1}"
}

# _talos_prepare <name> <script>...: the scripts a verb calls must exist,
# python3 must be there and the scratch dir must be usable. pipeline-cfg-cache.sh
# gives every cfg call after this the one resolved dump (one python3 spawn, none
# without a config file) and removes its scratch dir on exit; the output buffer
# and the verb's temp files live in that dir.
_talos_prepare() {
  local _name="$1" _f
  shift
  for _f in "$@"; do
    [ -f "$SCRIPT_DIR/$_f" ] || _talos_stop scripts-missing
  done
  command -v python3 >/dev/null 2>&1 || _talos_stop python-missing

  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
  if [ -z "${_CFG_CACHE_DIR:-}" ] || [ ! -d "$_CFG_CACHE_DIR" ]; then
    _talos_stop scratch-unavailable
  fi
  _TALOS_OUT="$_CFG_CACHE_DIR/$_name.pairs"
  : > "$_TALOS_OUT" || _talos_stop scratch-unavailable

  # Prime the cache here instead of on the first cfg call, to see the exit code.
  if "$SCRIPT_DIR/pipeline-config.sh" --dump > "$_CFG_CACHE_FILE"; then
    : > "$_CFG_CACHE_DONE"
  else
    _talos_stop config-unreadable
  fi
}

_talos_help() {
  cat <<'HELP'
usage: talos.sh <verb>
verbs:
  env                                print every Step 0 setting, PR_DRAFT, the
                                     evidence line and the per-role
                                     runner/model/effort as sanitised KEY=value lines
  gate fix-round <N> <stage> [--pr M]  the checks before a developer fix round:
                                     verdict=redispatch or verdict=block
  gate merge <pr> <issue>            every Step 4 merge gate, one verdict:
                                     merge|handoff|redispatch|wait|block
  help                               this text
HELP
}

# _talos_resolve_role <role>: the runner, command, model, effort and fallback
# of `pipeline-agent.sh --resolve`, then the --check-effort notice. The line is
# parsed from the right (model, effort and fallback have fixed shapes at its
# end), so a runner_cmd that holds the words "model=" cannot move a field.
_talos_resolve_role() {
  local _role="$1" _line _rc _notice _re _runner _rest
  _line="$(bash "$SCRIPT_DIR/pipeline-agent.sh" --resolve "$_role")"
  _rc=$?
  _re='^(.*) model=(.*) effort=(low|medium|high|max)?( fallback=([a-z,]+))?$'
  case "$_line" in
    "runner="*" runner_cmd="*) : ;;
    *) _rc=1 ;;
  esac
  if [ "$_rc" -ne 0 ]; then
    _talos_emit warn "reason=resolve-failed role=$_role"
    return 0
  fi
  _runner="${_line#runner=}"
  _runner="${_runner%% runner_cmd=*}"
  _rest="${_line#*" runner_cmd="}"
  if [[ "$_rest" =~ $_re ]]; then
    _talos_emit "agent.$_role.runner" "$_runner"
    # An empty field is not printed: an absent agent.<role>.<field> is empty.
    [ -z "${BASH_REMATCH[1]}" ] || _talos_emit "agent.$_role.runner_cmd" "${BASH_REMATCH[1]}"
    [ -z "${BASH_REMATCH[2]}" ] || _talos_emit "agent.$_role.model" "${BASH_REMATCH[2]}"
    [ -z "${BASH_REMATCH[3]}" ] || _talos_emit "agent.$_role.effort" "${BASH_REMATCH[3]}"
    [ -z "${BASH_REMATCH[5]}" ] || _talos_emit "agent.$_role.fallback" "${BASH_REMATCH[5]}"
  else
    _talos_emit warn "reason=resolve-failed role=$_role"
    return 0
  fi
  # --check-effort prints nothing when no effort is configured, so skip the spawn then.
  [ -n "${BASH_REMATCH[3]}" ] || return 0
  if ! _notice="$(bash "$SCRIPT_DIR/pipeline-agent.sh" --check-effort "$_role")"; then
    _talos_emit warn "reason=effort-check-failed role=$_role"
  elif [ -n "$_notice" ]; then
    _talos_emit "agent.$_role.effort_notice" "$_notice"
  fi
}

_talos_env() {
  [ "$#" -eq 0 ] || _talos_stop usage 2

  _talos_prepare env pipeline-config.sh pipeline-cfg-cache.sh pipeline-agent.sh pipeline-draft-check.sh \
                     pipeline-evidence.sh pipeline-isolation.sh

  # The startup isolation gate: its error text stays on stderr.
  if ! bash "$SCRIPT_DIR/pipeline-isolation.sh" validate >/dev/null; then
    _talos_stop isolation-invalid
  fi

  # The startup diagnostic's two facts: this scripts directory, and which of the
  # three subagent-name cases applies (the native path only looks at
  # .claude/agents/, so that is all this checks).
  local _base _var _key _kind _val
  _talos_emit SCRIPTS_DIR "$SCRIPT_DIR"
  if [ -f .claude/agents/developer.md ]; then
    _val="repo override (.claude/agents/)"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    _val='plugin (talos:<role>, $CLAUDE_PLUGIN_ROOT set)'
  else
    _val="global/bare (~/.claude/agents/ or none)"
  fi
  _talos_emit AGENT_SOURCE "$_val"

  _base="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')"
  _val="$(cfg base_branch)"
  [ -n "$_val" ] || _val="${_base:-main}"
  _talos_emit BASE_BRANCH "$_val"

  while IFS="$(printf '\t')" read -r _var _key _kind; do
    _val="$(cfg "$_key")"
    # A list's items are its lines; the sanitiser joins them with the two
    # characters \n (the `@` marks the key).
    [ "$_kind" = "l" ] && _var="@$_var"
    _talos_emit "$_var" "$_val"
  done <<EOF
$(_talos_env_table)
EOF

  # PR_DRAFT: pipeline-draft-check.sh is the one resolver (#435). Its stderr
  # warning line passes through. The old prose defined no fallback for a failed
  # resolve, so none is made up here: a draft default of false would run QA on a
  # PR that was meant to stay a draft.
  _val="$(bash "$SCRIPT_DIR/pipeline-draft-check.sh" resolve)" || _talos_stop draft-resolve-failed
  case "$_val" in
    true | false) : ;;
    *) _talos_stop draft-resolve-failed ;;
  esac
  _talos_emit PR_DRAFT "$_val"

  # EVIDENCE: enabled only when the call exits 0; the line is its stdout.
  if _val="$(bash "$SCRIPT_DIR/pipeline-evidence.sh" enabled)"; then
    _talos_emit EVIDENCE_ENABLED true
    _talos_emit EVIDENCE_LINE "$_val"
  else
    _talos_emit EVIDENCE_ENABLED false
    _talos_emit EVIDENCE_LINE ""
  fi

  local _role
  for _role in $_TALOS_ROLES; do
    _talos_resolve_role "$_role"
  done

  _talos_flush
}

# ── gate ─────────────────────────────────────────────────────────────────────
# Each gate verb composes the pipeline-vcs.sh / pipeline-budget.sh verbs its
# playbook prose used to list, in the same order, and prints one verdict.

_talos_isnum() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac; }

_vcs() { bash "$SCRIPT_DIR/pipeline-vcs.sh" "$@"; }

# _talos_verdict <verdict>: print `verdict=<v>` first, then the pairs collected
# so far, and leave with 0.
_talos_verdict() {
  { printf 'verdict\0%s\0' "$1"; cat "$_TALOS_OUT"; } > "$_TALOS_OUT.v" \
    && mv "$_TALOS_OUT.v" "$_TALOS_OUT" || _talos_stop scratch-unavailable
  _talos_flush
  exit 0
}

# _talos_cap <cmd>...: run it with stdout in _OUT, stderr in _ERR (also passed on
# to stderr) and the exit status in _RC.
_talos_cap() {
  _OUT="$("$@" 2>"$_CFG_CACHE_DIR/err")"
  _RC=$?
  _ERR="$(cat "$_CFG_CACHE_DIR/err")"
  [ -z "$_ERR" ] || printf '%s\n' "$_ERR" >&2
}

# _talos_post <pr> <text>: a PR comment; the text reaches the verb in a file.
_talos_post() {
  { printf '%s\n' "$2" > "$_CFG_CACHE_DIR/body" \
      && _vcs comment-pr "$1" --body-file "$_CFG_CACHE_DIR/body" > /dev/null; } \
    || _talos_emit warn "reason=comment-failed"
}

# _talos_has <newline-list> <item>: the item is one line of the list.
_talos_has() { case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac; return 1; }

# _talos_block_labels <issue> <pr-or-empty>: set pipeline:blocked.
_talos_block_labels() {
  [ -z "$2" ] || _vcs label-pr "$2" --add pipeline:blocked > /dev/null || _talos_emit warn "reason=label-failed"
  _vcs label-issue "$1" --add pipeline:blocked > /dev/null || _talos_emit warn "reason=label-failed"
}

# The names of the labels in a view-pr / view-issue JSON object, one per line.
_TALOS_LABELS_PY='
import json, sys
for l in json.load(sys.stdin).get("labels", []):
    n = l.get("name") if isinstance(l, dict) else l
    if isinstance(n, str) and "\n" not in n:
        print(n)
'
_talos_labels() { python3 -I -c "$_TALOS_LABELS_PY" <<< "$1"; }

# How many comments of a read-comments object hold the marker (argv: the marker).
_TALOS_COUNT_PY='
import json, sys
print(sum(1 for c in json.load(sys.stdin).get("comments", []) if sys.argv[1] in (c.get("body") or "")))
'

# _talos_label_of <role>: the approval label of a role, from pipeline-contract.sh.
_talos_label_of() {
  local _i=0
  while [ "$_i" -lt "${#TALOS_APPROVAL_ROLES[@]}" ]; do
    if [ "${TALOS_APPROVAL_ROLES[$_i]}" = "$1" ]; then
      printf '%s' "${TALOS_APPROVAL_LABELS[$_i]%%|*}"
      return 0
    fi
    _i=$((_i + 1))
  done
  return 1
}

# _talos_role_enabled <role>: roles.<role> of an approval role (literal keys, so
# the config-key guard can see every one).
_talos_role_enabled() {
  case "$1" in
    qa) cfg roles.qa ;;
    reviewer) cfg roles.reviewer ;;
    security) cfg roles.security ;;
    adversarial) cfg roles.adversarial ;;
    docs) cfg roles.docs ;;
  esac
}

# gate fix-round <N> <stage> [--pr M]: the Step 3 intro, in its order. The
# budget guard (exit 1 = exceeded), then record-attempt (with --pr when a PR
# exists), then the unblock after a fix round is cleared to run.
_talos_gate_fix_round() {
  [ "$#" -ge 2 ] || _talos_stop usage 2
  local _n="$1" _stage="$2" _pr="" _s _ok=1 _bout _brc=0 _r _by _line
  shift 2
  case "$#" in
    0) : ;;
    2) [ "$1" = "--pr" ] || _talos_stop usage 2; _pr="$2" ;;
    *) _talos_stop usage 2 ;;
  esac
  _talos_isnum "$_n" || _talos_stop usage 2
  [ -z "$_pr" ] || _talos_isnum "$_pr" || _talos_stop usage 2
  for _s in developer qa reviewer security docs validator pm adversarial; do
    [ "$_s" = "$_stage" ] && _ok=0
  done
  [ "$_ok" -eq 0 ] || _talos_stop usage 2
  _talos_prepare gate-fix-round pipeline-vcs.sh pipeline-config.sh pipeline-cfg-cache.sh \
                                pipeline-budget.sh pipeline-hooks.sh

  # Exit 1 (exceeded) is the signal, so it is captured and never aborts.
  # With limits.tokens_per_issue unset the check prints nothing and exits 0,
  # so the fix-round flow is unchanged.
  _bout="$(bash "$SCRIPT_DIR/pipeline-budget.sh" check --issue "$_n")" || _brc=$?
  case "$_brc" in
    0) case "$_bout" in "talos:budget warn "*) _talos_emit budget "$_bout" ;; esac ;;
    1)
      _talos_emit budget "$_bout"
      _talos_block_labels "$_n" "$_pr"
      printf '%s' "$_bout" | bash "$SCRIPT_DIR/pipeline-hooks.sh" post_stage budget-blocked orchestrator "$_n" \
        ${_pr:+--pr "$_pr"} --summary - > /dev/null
      _talos_emit reason budget-exceeded
      _talos_emit blocked_by "talos.pipeline.yml:limits.tokens_per_issue (explicit)"
      _talos_verdict block ;;
    *) _talos_emit warn "reason=budget-check-failed" ;;
  esac

  _talos_cap _vcs record-attempt "$_n" "$_stage" ${_pr:+--pr "$_pr"}
  _line="$(grep '^stage=' <<< "$_OUT" | tail -n 1)"
  if [[ "$_line" =~ ^stage=[a-z]+\ count=([0-9]+)\ total=([0-9]+)$ ]]; then
    _talos_emit count "${BASH_REMATCH[1]}"
    _talos_emit total "${BASH_REMATCH[2]}"
  fi
  if [ "$_RC" -ne 0 ]; then
    _talos_block_labels "$_n" "$_pr"
    case "$_ERR" in
      *max_total_dispatches*) _r=max-total-dispatches; _by="talos.pipeline.yml:limits.max_total_dispatches (explicit)" ;;
      *max_fix_attempts*) _r=max-fix-attempts; _by="talos.pipeline.yml:limits.max_fix_attempts (explicit)" ;;
      *) _r=record-failed; _by="scripts/pipeline-vcs.sh:record-attempt exited non-zero (interpreted)" ;;
    esac
    _talos_emit reason "$_r"
    _talos_emit blocked_by "$_by"
    _talos_verdict block
  fi

  # Only the orchestrator clears pipeline:blocked, right before the fix round.
  if [ -n "$_pr" ]; then
    _vcs label-pr "$_pr" --remove pipeline:blocked > /dev/null || _talos_emit warn "reason=unblock-failed"
  fi
  _vcs label-issue "$_n" --remove pipeline:blocked > /dev/null || _talos_emit warn "reason=unblock-failed"
  _talos_emit stage "$_stage"
  _talos_verdict redispatch
}

# _talos_gate_block <reason> <pr> <issue> <comment> <notice>: the three steps of a
# gate that a human has to clear: the label, the comment, the `blocked` notice.
_talos_gate_block() {
  _vcs label-pr "$2" --add pipeline:blocked > /dev/null || _talos_emit warn "reason=label-failed"
  _talos_post "$2" "$4"
  bash "$SCRIPT_DIR/pipeline-notify.sh" blocked "#$3" "$5" "$3" > /dev/null
  _talos_emit reason "$1"
  _talos_verdict block
}

# gate merge <pr> <issue>: Step 4 in its order, one verdict. It writes only what
# the prose wrote (labels, comments, the notice, the update push) and never
# merges: on `merge` the orchestrator runs `merge-pr`.
_talos_gate_merge() {
  [ "$#" -eq 2 ] || _talos_stop usage 2
  local _pr="$1" _n="$2" _prl _isl _all _i=0 _role _label _missing="" _line _r _stale="" _stalelist=""
  local _draft _cierr _sha _cnt _synced=0
  _talos_isnum "$_pr" && _talos_isnum "$_n" || _talos_stop usage 2
  _talos_prepare gate-merge pipeline-vcs.sh pipeline-config.sh pipeline-cfg-cache.sh pipeline-contract.sh \
                            pipeline-draft-check.sh pipeline-notify.sh pipeline-mergebase.sh
  . "$SCRIPT_DIR/pipeline-contract.sh"

  # 1. Ready: no pipeline:blocked on the PR or the issue; every approval label of
  # an enabled role on the PR, unless the PR or the issue carries skip-qa.
  _talos_cap _vcs view-pr "$_pr"
  [ "$_RC" -eq 0 ] || _talos_stop view-failed
  _prl="$(_talos_labels "$_OUT")" || _talos_stop labels-unreadable
  _talos_cap _vcs view-issue "$_n"
  [ "$_RC" -eq 0 ] || _talos_stop view-failed
  _isl="$(_talos_labels "$_OUT")" || _talos_stop labels-unreadable
  _all="$_prl"$'\n'"$_isl"
  if _talos_has "$_all" pipeline:blocked; then
    _talos_emit reason blocked-label
    _talos_verdict wait
  fi
  if ! _talos_has "$_all" skip-qa; then
    while [ "$_i" -lt "${#TALOS_APPROVAL_ROLES[@]}" ]; do
      _role="${TALOS_APPROVAL_ROLES[$_i]}"
      _label="${TALOS_APPROVAL_LABELS[$_i]%%|*}"
      _i=$((_i + 1))
      [ "$(_talos_role_enabled "$_role")" = "true" ] || continue
      _talos_has "$_prl" "$_label" || _missing="${_missing:+$_missing,}$_label"
    done
    if [ -n "$_missing" ]; then
      _talos_emit reason approvals-missing
      _talos_emit missing "$_missing"
      _talos_verdict wait
    fi
  fi

  # 2. Approval SHAs: strip the stale labels, say so on the PR, name the roles.
  _talos_cap _vcs check-approval-sha "$_pr" --stale-list
  if [ "$_RC" -ne 0 ]; then
    while IFS= read -r _line; do
      case "$_line" in
        "stale role="*" label="*) _r="${_line#stale role=}"; _stalelist="$_stalelist${_r%% *}"$'\n' ;;
      esac
    done <<< "$_OUT"
    # The order the re-stamps run in: QA, then docs, then the parallel reviewers.
    for _r in qa docs reviewer security adversarial; do
      _talos_has "$_stalelist" "$_r" || continue
      _stale="${_stale:+$_stale,}$_r"
      _vcs label-pr "$_pr" --remove "$(_talos_label_of "$_r")" > /dev/null || _talos_emit warn "reason=label-failed"
    done
    [ -n "$_stale" ] || _talos_stop approval-sha-failed
    _talos_post "$_pr" "Stale approvals reset for re-review: $_stale"$'\n\n'"$_ERR"
    _talos_emit reason stale-approvals
    _talos_emit stale "$_stale"
    _talos_verdict redispatch
  fi

  # 3. Forbidden files (skip-qa never waives it): a human clears the block.
  _talos_cap _vcs check-pr-files "$_pr"
  case "$_RC" in
    0) : ;;
    1) _talos_gate_block forbidden-files "$_pr" "$_n" "$_OUT"$'\n'"$_ERR" "forbidden files in PR #$_pr" ;;
    *) _talos_stop "unsupported-verb:check-pr-files" ;;
  esac

  # 4. Closing keyword.
  _talos_cap _vcs check-closing-keyword "$_pr" "$_n"
  case "$_RC" in
    0)
      case "$_OUT" in
        *"talos:closing-keyword-unverified"*"reason=siblings-capped"*)
          _talos_gate_block siblings-capped "$_pr" "$_n" "$_OUT" "closing keyword unverified for PR #$_pr: siblings capped" ;;
        *"talos:closing-keyword-unverified"*) _talos_emit warn "reason=closing-keyword-unverified" ;;
      esac ;;
    1) _talos_gate_block closing-keyword "$_pr" "$_n" "$_ERR" "closing keyword in PR #$_pr with sibling PRs open" ;;
    *) _talos_stop "unsupported-verb:check-closing-keyword" ;;
  esac

  # 5. Draft state, only with PR_DRAFT = true: a draft was never CI-verified.
  _draft="$(bash "$SCRIPT_DIR/pipeline-draft-check.sh" resolve)" || _talos_stop draft-resolve-failed
  case "$_draft" in true | false) : ;; *) _talos_stop draft-resolve-failed ;; esac
  if [ "$_draft" = "true" ]; then
    _talos_cap _vcs pr-is-draft "$_pr"
    if [ "$_RC" -eq 0 ] && [ "$_OUT" = "draft" ]; then
      _talos_emit reason draft-pr
      _talos_verdict redispatch
    elif ! { [ "$_RC" -eq 1 ] && [ "$_OUT" = "ready" ]; }; then
      _talos_stop draft-unverified
    fi
  fi

  # 6. Required CI. Exit 2 is pending or missing. Exit 1 with the `failed:` line is
  # a red check: re-run it, at most twice per head SHA (the talos:ci-rerun markers).
  _talos_cap _vcs pr-checks-required "$_pr"
  case "$_RC" in
    0) : ;;
    2) _talos_emit reason ci-pending; _talos_verdict wait ;;
    *)
      case "$_ERR" in *"pr-checks-required: failed:"*) : ;; *) _talos_stop ci-unverified ;; esac
      _cierr="$_ERR"
      _sha="$(_vcs pr-head "$_pr")" || _talos_stop head-unresolved
      [[ "$_sha" =~ ^[0-9a-f]{40}$ ]] || _talos_stop head-unresolved
      _talos_cap _vcs read-comments "$_pr"
      [ "$_RC" -eq 0 ] || _talos_stop comments-unreadable
      _cnt="$(python3 -I -c "$_TALOS_COUNT_PY" "<!-- talos:ci-rerun $_sha -->" <<< "$_OUT")" || _talos_stop comments-unreadable
      _talos_isnum "$_cnt" || _talos_stop comments-unreadable
      if [ "$_cnt" -lt 2 ]; then
        if _vcs rerun-ci "$_pr" > /dev/null; then
          _talos_post "$_pr" "CI re-run $((_cnt + 1)) of 2 for this head."$'\n'"<!-- talos:ci-rerun $_sha -->"
          _talos_emit reason ci-rerun
          _talos_emit attempt "$((_cnt + 1))"
        else
          _talos_emit reason rerun-unsupported
        fi
        _talos_verdict wait
      fi
      _talos_post "$_pr" "CI still failing after 2 re-runs for this head; not merging."$'\n\n'"$_cierr"
      _talos_emit reason ci-failed
      if [ "$_draft" = "true" ]; then _talos_verdict redispatch; fi
      _talos_verdict wait ;;
  esac

  # 7. Stale-base guard (#288, generalising the #256 CHANGELOG guard: a CHANGELOG
  # conflict is simply its most common instance). Before EACH merge verdict a
  # conflict with the base is resolved: by pipeline-mergebase.sh (every
  # conflicting path in merge.union_paths, else it exits 3), else by
  # update-branch (merge.auto_sync), else by the developer's merge-base task. A
  # pushed head is not CI-verified, so it ends in `wait`.
  _talos_cap _vcs conflict-files "$_pr"
  if [ "$_RC" -ne 0 ]; then
    _talos_emit warn "reason=conflict-check-failed"
  elif [ -n "$_OUT" ]; then
    if bash "$SCRIPT_DIR/pipeline-mergebase.sh" "$_pr" > /dev/null; then
      _synced=1
    elif [ "$(cfg merge.auto_sync)" = "true" ] && _vcs update-branch "$_pr" > /dev/null; then
      _synced=1
    fi
    if [ "$_synced" -eq 1 ]; then
      _r=0
      _vcs pr-mergeable "$_pr" > /dev/null || _r=$?
      if [ "$_r" -ne 1 ]; then
        _talos_emit reason base-synced
        _talos_verdict wait
      fi
    fi
    _talos_emit reason merge-conflict
    _talos_verdict redispatch
  fi

  # 8. Human-merge mode, else the merge. The CI-run count must be read while the
  # PR is open: merge-pr deletes the head branch.
  if [ "$(cfg merge.auto)" != "true" ]; then
    if _talos_has "$_prl" pipeline:approved; then
      _talos_emit reason awaiting-human-merge
      _talos_verdict wait
    fi
    _vcs label-pr "$_pr" --add pipeline:approved > /dev/null || _talos_stop handoff-label-failed
    _talos_verdict handoff
  fi
  if [ "$_draft" = "true" ]; then
    _talos_cap _vcs pr-ci-runs "$_pr"
    if [ "$_RC" -eq 0 ] && _talos_isnum "$_OUT"; then
      _talos_emit ci_runs "$_OUT"
    else
      _talos_emit warn "reason=ci-runs-unrecorded"
    fi
  fi
  _talos_verdict merge
}

_talos_gate() {
  local _sub="${1:-}"
  [ "$#" -eq 0 ] || shift
  case "$_sub" in
    fix-round) _talos_gate_fix_round "$@" ;;
    merge) _talos_gate_merge "$@" ;;
    *) _talos_stop usage 2 ;;
  esac
}

verb="${1:-}"
[ "$#" -eq 0 ] || shift

case "$verb" in
  env) _talos_env "$@" ;;
  gate) _talos_gate "$@" ;;
  help | -h | --help) _talos_help ;;
  "") _talos_help >&2; exit 2 ;;
  *) printf 'stop reason=unknown-verb\n'; exit 2 ;;
esac
