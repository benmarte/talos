#!/usr/bin/env bash
# talos.sh -- the orchestrator's one entry point (#465, slice 1 of epic #422).
#
# Usage: talos.sh env
#        talos.sh gate fix-round <N> <stage> [--pr M]
#        talos.sh gate merge <pr> <issue>
#        talos.sh post-merge <pr> <issue> [--ci-runs <n>] [--heal]
#        talos.sh post-merge <pr> <issue> --handoff [--details-file <file>]
#        talos.sh sweep [<issue-id>...]
#        talos.sh summary [<issue-id>...]
#        talos.sh help
#
# One script with verbs; each later slice adds a verb and deletes the playbook
# prose it replaces. Slice 1 added `env`, slice 2 (#466) `gate`, slice 3 (#467)
# `post-merge`, `sweep` and `summary`.
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
#                                 | ci-failed | base-synced | conflict-check-unverified
#                                 | awaiting-human-merge
#            verdict=block      reason=forbidden-files | closing-keyword | siblings-capped
#          A `stop` means a gate could not be checked (exit 1): do not merge. A
#          conflict check that cannot run (github, github-api: conflict-files
#          exit non-zero; any other provider: pr-mergeable UNKNOWN or an error,
#          that provider having no conflict-files) is
#          `wait reason=conflict-check-unverified`, never a merge. The stderr of
#          each gate call (it can hold PR-author text) is relayed on stderr only
#          as `note gate=<verb> msg=<escaped>` lines, one per line, sanitised as
#          above, so no relayed line can begin with `verdict=` or any other key.
#          The ci-failed comment is posted once per head (<!-- talos:ci-failed
#          <sha> --> marker). Only markers by a trusted author count (the
#          ci-rerun ones too): markers.trusted_authors plus the `current-user`
#          login, as for approval markers; a refused identity with no
#          trusted_authors is `stop reason=trust-unverified`. A required check that never starts stays
#          `wait reason=ci-pending`: no head-age bound exists in the vcs verbs.
#          Not added to the old order on purpose: pr-mergeable (Step 3c, and only
#          after a base update here) and assert-sync (Step 0, before 3e).
#
# gate-reasons: budget-exceeded max-fix-attempts max-total-dispatches record-failed stale-approvals draft-pr ci-failed merge-conflict blocked-label approvals-missing ci-pending ci-rerun rerun-unsupported base-synced conflict-check-unverified awaiting-human-merge forbidden-files closing-keyword siblings-capped
#   stop: usage unknown-verb scripts-missing python-missing scratch-unavailable config-unreadable
#         draft-resolve-failed view-failed labels-unreadable approval-sha-failed
#         unsupported-verb:<verb> draft-unverified ci-unverified head-unresolved
#         comments-unreadable handoff-label-failed trust-unverified
#   warn: closing-keyword-unverified ci-runs-unrecorded budget-check-failed
#         unblock-failed comment-failed label-failed value-truncated
#
# post-merge, sweep, summary (#467). They write what the playbook's lists of calls
# wrote, in its order, and print KEY=value lines, no verdict: the first line is
# `post_merge=done|handoff`, `sweep=done` or `summary=done`, or a lone `stop`
# line. Every item is non-fatal: one that fails is a `warn reason=<enum>` line
# (with `issue=<n>` or `epic=<n>`) and the next still runs. Child stderr is
# relayed only as `note post-merge=<verb> msg=<escaped>` lines (`sweep=`,
# `summary=`), sanitised as above. Free text (an epic's unticked items) reaches
# the template renderer in a file, never on a command line.
#
#   post-merge <pr> <issue> [--ci-runs <n>] [--heal]
#          Order: sibling sync (a merge only: --heal skips it), changelog assemble
#          (roles.changelog_fragments), the issue-closed comment (--allow-closed:
#          GitHub closes the issue at merge), close-issue, board Done, status log
#          (status.enabled), worktree remove, the orchestrator/merged/issue-closed
#          notices, post_stage merged (with --ci-runs <n>, read BEFORE merge-pr,
#          which deletes the branch; none is never guessed) and issue-closed, the
#          spend block. Output keys: `sibling=<pr> action=clean|mergebase|
#          update-branch|developer|unverified` (developer: the orchestrator
#          dispatches the Step 3c merge-base task for the FIRST such PR only, then
#          re-checks pr-mergeable before the next), `recorded=yes|no`, `spend=<the
#          cost --line>`. The sibling sync runs when merge.auto_sync is true.
#          Idempotent per item: a second run is a safe no-op. changelog assemble,
#          board Done, the status log (an entry per PR is replaced), worktree
#          remove and a clean sibling are idempotent in their scripts. The issue-closed
#          comment carries <!-- talos:issue-closed pr=<M> -->: when a comment by a
#          trusted author (markers.trusted_authors plus the current user, as for
#          approval markers) already has it, `recorded=yes` and the comment,
#          close-issue, the notices, both events and the spend block are skipped, so a
#          re-run gives one comment, one close, one merged event. With
#          comments.enabled false there is no marker, so they repeat. A trust set
#          that cannot be resolved, or unreadable comments, count no marker (the
#          repeat is the lesser harm): `warn reason=trust-unverified|comments-
#          unreadable`. A close-issue that failed after the marker was posted
#          is not retried: close it by hand.
#   post-merge <pr> <issue> --handoff [--details-file <file>]
#          merge.auto is off: approved.md on the PR (the file's text, if given,
#          is DETAILS), then the orchestrator relay. Nothing else runs.
#   sweep [<issue-id>...]
#          The ids are this run's queue. Step 1 item 2: for each open issue with a
#          pipeline:* label, `find-pr <n> merged`; a merged PR is `heal=<n> pr=<m>`
#          and runs post-merge's items (--heal). find-pr exit 2 means NOT VERIFIED:
#          `warn reason=find-pr-unverified issue=<n>`, the heal skipped (never read
#          as "no merged PR"); any other failure is find-pr-failed. Item 4: the
#          worktree sweep (`worktree_sweep=<summary line>`). Item 5: `blocked_issues=<K>`,
#          `blocked_prs=<J>` and, when K+J > 0, the one `info backlog` notice.
#          With roles.planner: item 6 `epic=<n> action=closed|pending|waiting`
#          (closed: check-epic-acceptance exit 0; pending: the label and the comment
#          just posted, once per epic; waiting: already flagged; exit 2 is
#          `warn reason=epic-acceptance-unsupported epic=<n>`, the epic left open)
#          and item 7 `unblocked=<n>` (every issue named on its `Depends on:` lines
#          is no longer open). With status.enabled, item 8 `needs_owner_pending=<p>`,
#          `needs_owner_answered=<a>`; answered items are cleared once, except
#          under `warn reason=marker-authors-unverified` (all pending, no clear).
#   summary [<issue-id>...]
#          The ids are the issues processed in this run. Step 5 item 1: the worktree
#          sweep keeping those and every open pipeline PR's issue (the PR list
#          unreadable: `warn reason=prs-unlisted`, nothing swept), item 2
#          `worktree_warning=<line>` (relayed once as an `info worktrees` notice),
#          item 4 `cost=<line>` per line of the one cost --summary call, item 5 the
#          status resume refresh (status.enabled).
#
# post-merge-reasons: changelog-failed comments-unreadable trust-unverified comment-failed close-failed board-failed status-log-failed status-resume-not-refreshed worktree-remove-failed notify-failed spend-upsert-failed siblings-unlisted value-truncated
#   stop: usage scripts-missing python-missing scratch-unavailable config-unreadable
#   warn: all the others
# sweep-reasons: issues-unlisted prs-unlisted find-pr-unverified find-pr-failed worktree-sweep-failed epic-close-failed epic-label-failed epic-comment-failed epic-acceptance-unsupported unblock-failed marker-authors-unverified needs-owner-clear-failed needs-owner-list-failed notify-failed
#   stop: usage scripts-missing python-missing scratch-unavailable config-unreadable
#   warn: all the others, and the post-merge warns of a heal
# summary-reasons: prs-unlisted worktree-sweep-failed notify-failed status-refresh-failed
#   stop: usage scripts-missing python-missing scratch-unavailable config-unreadable
#   warn: all the others
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
    out.append(key + (" " if key in ("stop", "warn", "note") else "=") + val)
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
  post-merge <pr> <issue> [--ci-runs <n>] [--heal]
                                     what follows a merge, in order, once
  post-merge <pr> <issue> --handoff [--details-file F]
                                     the human-merge hand-off comment and relay
  sweep [<issue-id>...]              Step 1: heal merged-but-open issues,
                                     sweep worktrees, report blocked work,
                                     epics, dependencies, needs-owner
  summary [<issue-id>...]            Step 5: worktree sweep and warning, cost
                                     table, status resume block
  help                              this text
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

# _talos_base_branch: base_branch, else the remote's default branch, else main.
_talos_base_branch() {
  local _b
  _b="$(cfg base_branch)"
  [ -n "$_b" ] || _b="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')"
  printf '%s' "${_b:-main}"
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
  local _var _key _kind _val
  _talos_emit SCRIPTS_DIR "$SCRIPT_DIR"
  if [ -f .claude/agents/developer.md ]; then
    _val="repo override (.claude/agents/)"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    _val='plugin (talos:<role>, $CLAUDE_PLUGIN_ROOT set)'
  else
    _val="global/bare (~/.claude/agents/ or none)"
  fi
  _talos_emit AGENT_SOURCE "$_val"

  _talos_emit BASE_BRANCH "$(_talos_base_branch)"

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

# _talos_cap <cmd>...: run it with stdout in _OUT, stderr in _ERR (also relayed
# to stderr, see _talos_relay) and the exit status in _RC.
_talos_cap() { _talos_run "${2:-}" "$@"; }

# _talos_run <tag> <cmd>...: _talos_cap with an explicit relay tag, for a call
# whose second word is not a verb (a script path).
_talos_run() {
  local _tag="$1"
  shift
  _OUT="$("$@" 2>"$_CFG_CACHE_DIR/err")"
  _RC=$?
  _ERR="$(cat "$_CFG_CACHE_DIR/err")"
  _talos_relay "$_tag" "$_ERR"
}

# _talos_relay <verb> <text>: a gate's stderr can hold PR-author text (a file
# name may contain a newline), so each line goes through the sanitiser as
# `note <key>=<verb> msg=<escaped>` (<key> is `gate`, or _TALOS_NOTE_KEY): no
# relayed line starts with `verdict=` or any other key the orchestrator reads.
_talos_relay() {
  local _l _tag=""
  [[ "$1" =~ ^[a-z-]*$ ]] && _tag="$1"
  [ -n "$2" ] || return 0
  while IFS= read -r _l || [ -n "$_l" ]; do
    [ -z "$_l" ] || printf 'note\0%s=%s msg=%s\0' "${_TALOS_NOTE_KEY:-gate}" "$_tag" "$_l"
  done <<< "$2" | python3 -I -c "$_TALOS_SANITISER" >&2
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

# How many comments of a read-comments object hold the marker (argv: the marker,
# 1 or 0 for "only trusted authors count", the trusted logins one per line).
_TALOS_COUNT_PY='
import json, sys
marker, enforce, trusted = sys.argv[1], sys.argv[2] == "1", set(sys.argv[3].splitlines())
def login(c):
    a = c.get("author")
    return a.get("login") if isinstance(a, dict) else None
print(sum(1 for c in json.load(sys.stdin).get("comments", [])
          if marker in (c.get("body") or "") and (not enforce or login(c) in trusted)))
'

# _talos_trust: who may author a counted marker, the marker-author rule
# (check-approval-sha and read-attempt): markers.trusted_authors plus the
# authenticated login, unless markers.verify_authors is false. Sets _TRUST_ON
# (1 or 0) and _TRUST_SET. An identity that cannot be looked up and no
# trusted_authors is the same fail-open as those readers (every marker counts);
# one that was refused and no trusted_authors stops, as nothing could be counted.
_talos_trust() {
  _TRUST_ON=0; _TRUST_SET=""
  [ "$(cfg markers.verify_authors)" != "false" ] || return 0
  local _t _u _rc
  _t="$(cfg markers.trusted_authors)"
  _talos_cap _vcs current-user
  _rc="$_RC"; _u="$_OUT"
  case "$_rc" in
    0) [ -z "$_u" ] || _t="${_t:+$_t$'\n'}$_u" ;;
    1) : ;;
    *) _TRUST_ON=1 ;;
  esac
  [ -z "$_t" ] || _TRUST_ON=1
  _TRUST_SET="$_t"
  { [ "$_TRUST_ON" -eq 0 ] || [ -n "$_TRUST_SET" ]; } && return 0
  # post-merge sets _TALOS_TRUST_SOFT: its marker only guards against a repeat,
  # so no trusted author means "no marker counted", with a warning.
  [ -z "${_TALOS_TRUST_SOFT:-}" ] || { _talos_emit warn "reason=trust-unverified issue=${_PM_ISSUE:-}"; return 0; }
  _talos_stop trust-unverified
}
# _talos_count_marker <marker> <read-comments-json>
_talos_count_marker() {
  python3 -I -c "$_TALOS_COUNT_PY" "$1" "$_TRUST_ON" "$_TRUST_SET" <<< "$2"
}

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
      _talos_trust
      _talos_cap _vcs read-comments "$_pr"
      [ "$_RC" -eq 0 ] || _talos_stop comments-unreadable
      _cnt="$(_talos_count_marker "<!-- talos:ci-rerun $_sha -->" "$_OUT")" || _talos_stop comments-unreadable
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
      # The comment is posted once per head: its marker is looked up first.
      _cnt="$(_talos_count_marker "<!-- talos:ci-failed $_sha -->" "$_OUT")" || _talos_stop comments-unreadable
      _talos_isnum "$_cnt" || _talos_stop comments-unreadable
      if [ "$_cnt" -eq 0 ]; then
        _talos_post "$_pr" "CI still failing after 2 re-runs for this head; not merging."$'\n\n'"$_cierr"$'\n'"<!-- talos:ci-failed $_sha -->"
      fi
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
  # conflict-files exists for github and github-api only (it exits 1 "not
  # implemented" elsewhere, which is indistinguishable from a real failure on
  # github), so the provider decides: any other provider is judged by pr-mergeable
  # alone (no path list, so no union-path sync: CONFLICTING goes to the developer).
  case "$(cfg vcs.provider)" in
    github | github-api)
      _talos_cap _vcs conflict-files "$_pr"
      if [ "$_RC" -ne 0 ]; then
        # Fail closed: a conflict check that cannot run never ends in a merge.
        _talos_emit reason conflict-check-unverified
        _talos_verdict wait
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
      fi ;;
    *)
      _talos_cap _vcs pr-mergeable "$_pr"
      case "$_RC" in
        0) : ;;
        1) _talos_emit reason merge-conflict; _talos_verdict redispatch ;;
        *) _talos_emit reason conflict-check-unverified; _talos_verdict wait ;;
      esac ;;
  esac

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

# ── post-merge, sweep, summary (#467) ────────────────────────────────────────
# What follows a merge, the Step 1 sweeps and the Step 5 closing calls: the
# playbook's lists of script calls, run in the same order. Every item is
# non-fatal: a failing one is a `warn reason=<enum>` line and the next still runs.

# _TALOS_RENDER_PY: a stage-comment template (argv 1) rendered with the process
# environment (HEADER ISSUE PR VERDICT SUMMARY) and the text of the file argv 2
# as DETAILS. A template that is missing or cannot render falls back to an
# inline body, as the stage comment convention says.
_TALOS_RENDER_PY='
import os, string, sys
env = dict(os.environ)
env["DETAILS"] = open(sys.argv[2]).read().strip()
try:
    with open(sys.argv[1]) as f:
        out = string.Template(f.read()).substitute(env).strip()
except Exception:
    out = env["HEADER"] + "\n\n" + env["VERDICT"] + " - " + env["SUMMARY"] + ("\n\n" + env["DETAILS"] if env["DETAILS"] else "")
sys.stdout.write(out + "\n")
'

# The open pipeline PRs of a list-prs array, one line each `<pr> <issue> <blocked>`
# (blocked is 1 or 0), ascending: the rule pipeline-status-file.sh applies (a
# fix|feat/issue-<N> head, the base branch, and a Talos label or a PR that is not
# from a fork). argv: the base branch, the Talos label names joined by commas.
_TALOS_PRS_PY='
import json, re, sys
base, talos = sys.argv[1], set(sys.argv[2].split(","))
rx = re.compile(r"^(?:fix|feat)/issue-([0-9]{1,9})(?:-|\Z)")
rows = []
for p in json.load(sys.stdin):
    n, b = p.get("number"), p.get("headRefName")
    m = rx.match(b) if isinstance(b, str) else None
    if not isinstance(n, int) or not m or p.get("baseRefName") != base:
        continue
    names = set(l.get("name") if isinstance(l, dict) else l for l in p.get("labels") or [])
    if not (names & talos or p.get("isCrossRepository") is False):
        continue
    rows.append((n, int(m.group(1)), 1 if "pipeline:blocked" in names else 0))
for r in sorted(rows):
    print(*r)
'

# What the sweep reads out of the open issues (a list-issues array): `heal <n>`
# for each carrying a pipeline:* label, or (mode rest) `blocked <n>`, `epic <n>
# <carries children-done 0|1>` for each pipeline:epic-decomposed issue no open
# issue says `Part of #<n>` about, and `unblock <n>` for each issue without
# pipeline:ready whose `Depends on:` lines name only issues that are no longer
# open. argv: the mode, then the ids to leave out (already healed, so closed).
_TALOS_SWEEP_PY='
import json, re, sys
mode, skip = sys.argv[1], set(sys.argv[2].split(","))
items = []
for i in json.load(sys.stdin):
    n = i.get("number")
    if not isinstance(n, int) or str(n) in skip:
        continue
    names = set(l.get("name") if isinstance(l, dict) else l for l in i.get("labels") or [])
    items.append((n, names, i.get("body") or ""))
items.sort(key=lambda t: t[0])
if mode == "heal":
    for n, names, _ in items:
        if any(isinstance(x, str) and x.startswith("pipeline:") for x in names):
            print("heal", n)
    sys.exit(0)
opened = set(n for n, _, _ in items)
for n, names, _ in items:
    if "pipeline:blocked" in names:
        print("blocked", n)
for n, names, _ in items:
    if "pipeline:epic-decomposed" in names:
        part = re.compile(r"Part of #%d(?!\d)" % n)
        if not any(m != n and part.search(b) for m, _, b in items):
            print("epic", n, 1 if "pipeline:epic-children-done" in names else 0)
for n, names, b in items:
    if "pipeline:ready" in names:
        continue
    deps = [int(d) for ln in b.splitlines() if re.match(r"\s*Depends on:", ln) for d in re.findall(r"#([0-9]+)", ln)]
    if deps and not any(d in opened for d in deps):
        print("unblock", n)
'

_PM_ISSUE=""

# _talos_warn <reason> [key=value]: a non-fatal item that did not go through.
_talos_warn() { _talos_emit warn "reason=$1${2:+ $2}"; }

# _talos_render <template> <issue-ref> <pr-ref> <verdict> <summary> <details-file>:
# the comment body, from comments.templates_dir (then the installed copy), in
# _BODY. Fails when comments.header is empty: nothing is posted without it.
_talos_render() {
  local _h _t
  _h="$(cfg comments.header)"
  _h="${_h//\{role\}/orchestrator}"
  [ -n "$_h" ] || return 1
  _t="$(cfg comments.templates_dir)/$1.md"
  [ -f "$_t" ] || _t=".claude/talos/templates/comments/$1.md"
  _BODY="$(HEADER="$_h" ISSUE="$2" PR="$3" VERDICT="$4" SUMMARY="$5" python3 -I -c "$_TALOS_RENDER_PY" "$_t" "$6")" \
    && [ -n "$_BODY" ]
}

# _talos_say <verb> <n> [--allow-closed]: post _BODY (comment-issue|comment-pr),
# the text reaching the verb in a file.
_talos_say() {
  { printf '%s\n' "$_BODY" > "$_CFG_CACHE_DIR/body" \
      && _talos_run comment _vcs "$1" "$2" --body-file "$_CFG_CACHE_DIR/body" ${3:+"$3"}; } \
    && [ "$_RC" -eq 0 ]
}

# _talos_notify <args of pipeline-notify.sh>: the message is fixed words and
# numbers; a failed relay is a warning.
_talos_notify() {
  _talos_run notify bash "$SCRIPT_DIR/pipeline-notify.sh" "$@"
  [ "$_RC" -eq 0 ] || _talos_warn notify-failed "${_PM_ISSUE:+issue=$_PM_ISSUE}"
}

# _talos_pipeline_prs <list-prs json>: `<pr> <issue> <blocked>` lines.
_talos_pipeline_prs() {
  local _l="" _e
  for _e in ${TALOS_STAGE_LABELS[@]+"${TALOS_STAGE_LABELS[@]}"} ${TALOS_APPROVAL_LABELS[@]+"${TALOS_APPROVAL_LABELS[@]}"}; do
    _l="$_l${_e%%|*},"
  done
  python3 -I -c "$_TALOS_PRS_PY" "$(_talos_base_branch)" "$_l" <<< "$1"
}

# _talos_sibling <merged-issue> <pr>: bring one sibling PR's branch up to date
# with the new base. The order is the playbook's: no conflict, nothing to do; else
# pipeline-mergebase.sh (a mechanical union, it pushes), else update-branch
# (merge.auto_sync is on here), else the developer's merge-base task, which this
# verb cannot dispatch: it reports `sibling=<pr> action=developer`. conflict-files
# exists for github and github-api only; any other provider is judged by
# pr-mergeable alone, with no path list.
_talos_sibling() {
  local _n="$1" _s="$2" _via="" _r=0 _known=0
  case "$(cfg vcs.provider)" in
    github | github-api)
      _talos_cap _vcs conflict-files "$_s"
      if [ "$_RC" -eq 0 ]; then
        [ -n "$_OUT" ] || { _talos_emit sibling "$_s action=clean"; return 0; }
        _known=1
      fi ;;
  esac
  if [ "$_known" -eq 0 ]; then
    _talos_cap _vcs pr-mergeable "$_s"
    case "$_RC" in
      0) _talos_emit sibling "$_s action=clean"; return 0 ;;
      1) : ;;
      *) _talos_emit sibling "$_s action=unverified"; return 0 ;;
    esac
  fi
  if _talos_run mergebase bash "$SCRIPT_DIR/pipeline-mergebase.sh" "$_s" && [ "$_RC" -eq 0 ]; then
    _via=mergebase
  else
    _talos_run update-branch _vcs update-branch "$_s"
    [ "$_RC" -ne 0 ] || _via=update-branch
  fi
  if [ -n "$_via" ]; then
    _vcs pr-mergeable "$_s" > /dev/null || _r=$?
    [ "$_r" -ne 1 ] || _via=""
  fi
  if [ -z "$_via" ]; then
    _talos_emit sibling "$_s action=developer"
    return 0
  fi
  _talos_notify info "merge-base" "#$_n sibling PR #$_s synced with new base ($_via)" "$_n"
  _talos_emit sibling "$_s action=$_via"
}

# _talos_siblings <merged-issue> <merged-pr>: the sync of every OTHER open
# pipeline PR, in PR-number order, when merge.auto_sync is on (the default).
_talos_siblings() {
  local _prs _s _i _b
  [ "$(cfg merge.auto_sync)" = "true" ] || return 0
  _talos_cap _vcs list-prs
  if [ "$_RC" -ne 0 ] || ! _prs="$(_talos_pipeline_prs "$_OUT")"; then
    _talos_warn siblings-unlisted "issue=$1"
    return 0
  fi
  while read -r _s _i _b <&3; do
    [ -n "$_s" ] && [ "$_s" != "$2" ] || continue
    _talos_sibling "$1" "$_s"
  done 3<<< "$_prs"
}

# _talos_post_merge_run <pr> <issue> <heal 0|1> <ci-runs or empty>: the items,
# in order. Siblings (a merge, not a heal), changelog, the issue-closed comment,
# close-issue, board Done, status log, worktree remove, the notices, the merged
# and issue-closed events and the spend block.
_talos_post_merge_run() {
  local _pr="$1" _n="$2" _heal="$3" _ci="$4" _rec=0 _mk _cnt _body _sp _rc
  _PM_ISSUE="$_n"
  _mk="<!-- talos:issue-closed pr=$_pr -->"
  [ "$_heal" -eq 1 ] || _talos_siblings "$_n" "$_pr"

  if [ "$(cfg roles.changelog_fragments)" = "true" ]; then
    _talos_run changelog bash "$SCRIPT_DIR/pipeline-changelog.sh" assemble
    [ "$_RC" -eq 0 ] || _talos_warn changelog-failed "issue=$_n"
  fi

  # The marker of an earlier run (a trusted author's) means the comment, the
  # close and everything that tells someone it happened were done: skip them.
  if [ "$(cfg comments.enabled)" = "true" ]; then
    _TALOS_TRUST_SOFT=1
    _talos_trust
    _talos_cap _vcs read-comments "$_n"
    if [ "$_RC" -eq 0 ] && _cnt="$(_talos_count_marker "$_mk" "$_OUT")" && _talos_isnum "$_cnt"; then
      [ "$_cnt" -eq 0 ] || _rec=1
    else
      _talos_warn comments-unreadable "issue=$_n"
    fi
    if [ "$_rec" -eq 0 ]; then
      if _talos_render issue-closed "#$_n" "PR #$_pr" CLOSED "all stages passed" /dev/null; then
        _BODY="$_BODY"$'\n'"$_mk"
        _talos_say comment-issue "$_n" --allow-closed || _talos_warn comment-failed "issue=$_n"
      else
        _talos_warn comment-failed "issue=$_n"
      fi
    fi
  fi
  if [ "$_rec" -eq 0 ]; then
    _talos_run close-issue _vcs close-issue "$_n" "closed by PR #$_pr"
    [ "$_RC" -eq 0 ] || _talos_warn close-failed "issue=$_n"
  fi
  _talos_emit recorded "$([ "$_rec" -eq 1 ] && echo yes || echo no)"

  _talos_run board bash "$SCRIPT_DIR/pipeline-status.sh" "$_n" "Done"
  [ "$_RC" -eq 0 ] || _talos_warn board-failed "issue=$_n"

  if [ "$(cfg status.enabled)" = "true" ]; then
    _talos_run status-log bash "$SCRIPT_DIR/pipeline-status-file.sh" assemble --refresh --pr "$_pr" --issue "$_n"
    if [ "$_RC" -ne 0 ]; then
      _talos_warn status-log-failed "issue=$_n"
    else
      case "$_ERR" in *"not refreshed"*) _talos_warn status-resume-not-refreshed "issue=$_n" ;; esac
    fi
  fi

  _talos_run worktree bash "$SCRIPT_DIR/pipeline-worktree.sh" remove "$_n"
  [ "$_RC" -eq 0 ] || _talos_warn worktree-remove-failed "issue=$_n"

  [ "$_rec" -eq 0 ] || return 0
  _talos_notify orchestrator "#$_n" "all stages passed — merged PR #$_pr, issue closed" "$_n"
  _talos_notify merged "#$_n" "PR #$_pr merged" "$_n"
  _talos_notify issue-closed "#$_n" "issue resolved" "$_n"
  # pipeline-hooks.sh never fails; its one stderr line is relayed.
  _talos_run hook bash "$SCRIPT_DIR/pipeline-hooks.sh" post_stage merged orchestrator "$_n" --pr "$_pr" \
    --summary "PR #$_pr merged" ${_ci:+--ci-runs "$_ci"}
  _talos_run hook bash "$SCRIPT_DIR/pipeline-hooks.sh" post_stage issue-closed orchestrator "$_n" --pr "$_pr" \
    --summary "issue resolved"

  # The spend block (after `merged`): the --line first; the comment only with
  # comments on and spend.comment not false, and only a non-empty body, as
  # `cost` piped straight into the upsert would exit 1 on an empty one.
  _talos_run spend bash "$SCRIPT_DIR/pipeline-events.sh" cost --issue "$_n" --pr "$_pr" --line
  [ -z "$_OUT" ] || _talos_emit spend "$_OUT"
  _sp="$(cfg spend.comment)"
  if [ "$(cfg comments.enabled)" = "true" ] && [ "$_sp" != "false" ]; then
    _talos_run spend bash "$SCRIPT_DIR/pipeline-events.sh" cost --issue "$_n" --pr "$_pr" --markdown
    _body="$_OUT"
    if [ -n "$_body" ]; then
      printf '%s' "$_body" > "$_CFG_CACHE_DIR/spend"
      _talos_run spend _vcs upsert-pr-comment "$_pr" --marker spend --body-file - < "$_CFG_CACHE_DIR/spend"
      _rc="$_RC"
      # 2 is a provider without the verb: silent. 1 (a token that cannot post as
      # itself) is reported once and never retried.
      [ "$_rc" -ne 1 ] || _talos_warn spend-upsert-failed "issue=$_n"
    fi
  fi
}

# _talos_handoff <pr> <issue> <details-file>: human-merge mode (merge.auto off).
# approved.md on the PR, then the relay. The issue stays open and no post-merge
# item runs: the human's merge closes it.
_talos_handoff() {
  _PM_ISSUE="$2"
  if _talos_render approved "#$2" "PR #$1" APPROVED "all stages passed — ready for human merge" "$3"; then
    _talos_say comment-pr "$1" || _talos_warn comment-failed "issue=$2"
  else
    _talos_warn comment-failed "issue=$2"
  fi
  _talos_notify orchestrator "#$2" "all stages passed — PR #$1 ready for human merge" "$2"
}

# post-merge <pr> <issue> [--ci-runs <n>] [--heal] | --handoff [--details-file F]
_talos_post_merge() {
  [ "$#" -ge 2 ] || _talos_stop usage 2
  local _pr="$1" _n="$2" _ci="" _heal=0 _hand=0 _det=/dev/null
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --heal) _heal=1; shift ;;
      --handoff) _hand=1; shift ;;
      --ci-runs) [ "$#" -ge 2 ] || _talos_stop usage 2; _ci="$2"; shift 2 ;;
      --details-file) [ "$#" -ge 2 ] || _talos_stop usage 2; _det="$2"; shift 2 ;;
      *) _talos_stop usage 2 ;;
    esac
  done
  _talos_isnum "$_pr" && _talos_isnum "$_n" || _talos_stop usage 2
  [ -z "$_ci" ] || _talos_isnum "$_ci" || _talos_stop usage 2
  [ "$_hand" -eq 0 ] || { [ "$_heal" -eq 0 ] && [ -z "$_ci" ]; } || _talos_stop usage 2
  [ "$_det" = /dev/null ] || { [ "$_hand" -eq 1 ] && [ -r "$_det" ]; } || _talos_stop usage 2
  _talos_prepare post-merge pipeline-vcs.sh pipeline-config.sh pipeline-cfg-cache.sh pipeline-contract.sh \
                            pipeline-changelog.sh pipeline-status.sh pipeline-status-file.sh \
                            pipeline-worktree.sh pipeline-notify.sh pipeline-hooks.sh pipeline-events.sh \
                            pipeline-mergebase.sh
  . "$SCRIPT_DIR/pipeline-contract.sh"
  _TALOS_NOTE_KEY=post-merge
  if [ "$_hand" -eq 1 ]; then
    _talos_emit post_merge handoff
    _talos_handoff "$_pr" "$_n" "$_det"
  else
    _talos_emit post_merge done
    _talos_post_merge_run "$_pr" "$_n" "$_heal" "$_ci"
  fi
  _talos_flush
}

# _talos_ids <args>: every one must be an issue number (sets _IDS).
_talos_ids() {
  local _a
  _IDS=()
  for _a in "$@"; do
    _talos_isnum "$_a" || _talos_stop usage 2
    _IDS+=("$_a")
  done
}

# sweep [<issue-id>...]: Step 1 items 2 and 4-8, the ids being this run's queue.
_talos_sweep() {
  local _issues="" _k _n _pr _prs="" _list="" _healed="" _bi="" _bp="" _ki=0 _kp=0 _plan _s _i _b _e _carried
  _talos_ids "$@"
  _talos_prepare sweep pipeline-vcs.sh pipeline-config.sh pipeline-cfg-cache.sh pipeline-contract.sh \
                       pipeline-changelog.sh pipeline-status.sh pipeline-status-file.sh \
                       pipeline-worktree.sh pipeline-notify.sh pipeline-hooks.sh pipeline-events.sh \
                       pipeline-mergebase.sh
  . "$SCRIPT_DIR/pipeline-contract.sh"
  _TALOS_NOTE_KEY=sweep
  _talos_emit sweep done

  _talos_cap _vcs list-issues
  if [ "$_RC" -eq 0 ] && _list="$(python3 -I -c "$_TALOS_SWEEP_PY" heal "" <<< "$_OUT")"; then
    _issues="$_OUT"
  else
    _talos_warn issues-unlisted
    _list=""
  fi

  # 2. Heal merged-but-open issues. find-pr exit 2 is "not verified", never "no PR".
  while read -r _k _n <&3; do
    [ -n "$_n" ] || continue
    _talos_cap _vcs find-pr "$_n" merged
    case "$_RC" in
      0) : ;;
      2) _talos_warn find-pr-unverified "issue=$_n"; continue ;;
      *) _talos_warn find-pr-failed "issue=$_n"; continue ;;
    esac
    [ -n "$_OUT" ] || continue
    _pr="$(python3 -I -c 'import json, sys; print(json.loads(sys.stdin.readline())["number"])' <<< "$_OUT")" || _pr=""
    if ! _talos_isnum "$_pr"; then
      _talos_warn find-pr-failed "issue=$_n"
      continue
    fi
    _healed="${_healed:+$_healed,}$_n"
    _talos_emit heal "$_n pr=$_pr"
    _talos_post_merge_run "$_pr" "$_n" 1 ""
  done 3<<< "$_list"

  _PM_ISSUE=""

  # 4. Worktrees of issues outside this run's queue.
  _talos_run worktree bash "$SCRIPT_DIR/pipeline-worktree.sh" sweep ${_IDS[@]+"${_IDS[@]}"}
  if [ "$_RC" -ne 0 ]; then
    _talos_warn worktree-sweep-failed
  else
    _s="$(grep '^talos:worktree-sweep ' <<< "$_OUT" | tail -n 1)"
    [ -z "$_s" ] || _talos_emit worktree_sweep "$_s"
  fi

  if [ -n "$_issues" ]; then
    _plan="$(python3 -I -c "$_TALOS_SWEEP_PY" rest "$_healed" <<< "$_issues")" || _plan=""
  else
    _plan=""
  fi

  # 5. Stale blocked work: issues and open pipeline PRs labeled pipeline:blocked.
  _talos_cap _vcs list-prs
  if [ "$_RC" -eq 0 ] && _prs="$(_talos_pipeline_prs "$_OUT")"; then
    while read -r _s _i _b <&3; do
      [ "${_b:-0}" -eq 1 ] || continue
      _kp=$((_kp + 1)); _bp="${_bp:+$_bp, }PR #$_s"
    done 3<<< "$_prs"
  else
    _talos_warn prs-unlisted
  fi
  while read -r _k _n <&3; do
    [ "$_k" = blocked ] || continue
    _ki=$((_ki + 1)); _bi="${_bi:+$_bi, }#$_n"
  done 3<<< "$_plan"
  _talos_emit blocked_issues "$_ki"
  _talos_emit blocked_prs "$_kp"
  if [ $((_ki + _kp)) -gt 0 ]; then
    _talos_notify info "backlog" "$_ki blocked issues, $_kp blocked PRs awaiting human action: ${_bi}${_bi:+${_bp:+, }}${_bp}" backlog
  fi

  if [ "$(cfg roles.planner)" = "true" ]; then
    # 6. Epic auto-close: closed only when the epic's own boxes are all ticked.
    while read -r _k _n _carried <&3; do
      [ "$_k" = epic ] || continue
      _talos_cap _vcs check-epic-acceptance "$_n"
      case "$_RC" in
        0)
          _talos_run epic _vcs close-issue "$_n" "All sub-issues resolved."
          [ "$_RC" -eq 0 ] || _talos_warn epic-close-failed "issue=$_n"
          if [ "$_carried" = 1 ]; then
            _talos_run epic _vcs label-issue "$_n" --remove pipeline:epic-children-done
            [ "$_RC" -eq 0 ] || _talos_warn epic-label-failed "issue=$_n"
          fi
          _talos_emit epic "$_n action=closed" ;;
        2) _talos_warn epic-acceptance-unsupported "epic=$_n" ;;
        *)
          # The label and the comment fire once per epic; the check runs every sweep.
          if [ "$_carried" = 1 ]; then
            _talos_emit epic "$_n action=waiting"
          else
            # The unticked items are the epic body's text: a file, never argv.
            printf '%s\n' "$_OUT" > "$_CFG_CACHE_DIR/details"
            _talos_run epic _vcs label-issue "$_n" --add pipeline:epic-children-done
            [ "$_RC" -eq 0 ] || _talos_warn epic-label-failed "issue=$_n"
            if _talos_render epic-acceptance-pending "#$_n" "" "Epic acceptance pending" \
                 "all sub-issues are closed; unticked acceptance boxes remain" "$_CFG_CACHE_DIR/details" \
               && _talos_say comment-issue "$_n"; then
              :
            else
              _talos_warn epic-comment-failed "issue=$_n"
            fi
            _talos_emit epic "$_n action=pending"
          fi ;;
      esac
    done 3<<< "$_plan"

    # 7. A sub-issue whose dependencies are all closed is queued.
    while read -r _k _n <&3; do
      [ "$_k" = unblock ] || continue
      _talos_run unblock _vcs label-issue "$_n" --add pipeline:ready
      if [ "$_RC" -eq 0 ]; then _talos_emit unblocked "$_n"; else _talos_warn unblock-failed "issue=$_n"; fi
    done 3<<< "$_plan"
  fi

  # 8. Needs-owner: clear the answered items, never on an unverified trust set.
  if [ "$(cfg status.enabled)" = "true" ]; then
    _talos_run needs-owner _vcs list-needs-owner --json
    case "$_RC" in
      0)
        _e="$(python3 -I -c '
import json, sys
a = json.load(sys.stdin)
print(len(a), sum(1 for r in a if r.get("answered") == "yes"))
' <<< "$_OUT")" || _e=""
        if [[ "$_e" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
          _k="${BASH_REMATCH[1]}"; _n="${BASH_REMATCH[2]}"
          case "$_ERR" in
            *talos:marker-authors-unverified*)
              _talos_warn marker-authors-unverified
              _n=0 ;;
            *)
              if [ "$_n" -gt 0 ]; then
                _talos_run needs-owner _vcs list-needs-owner --clear-answered
                [ "$_RC" -eq 0 ] || _talos_warn needs-owner-clear-failed
              fi ;;
          esac
          _talos_emit needs_owner_pending "$((_k - _n))"
          _talos_emit needs_owner_answered "$_n"
        else
          _talos_warn needs-owner-list-failed
        fi ;;
      2) : ;;
      *) _talos_warn needs-owner-list-failed ;;
    esac
  fi
  _talos_flush
}

# summary [<issue-id>...]: Step 5 items 1, 2, 4 and 5; the ids are the issues
# processed in this run.
_talos_summary() {
  local _prs _s _i _b _keep=() _a=() _line
  _talos_ids "$@"
  _talos_prepare summary pipeline-vcs.sh pipeline-config.sh pipeline-cfg-cache.sh pipeline-contract.sh \
                         pipeline-worktree.sh pipeline-notify.sh pipeline-events.sh pipeline-status-file.sh
  . "$SCRIPT_DIR/pipeline-contract.sh"
  _TALOS_NOTE_KEY=summary
  _talos_emit summary done

  # 1. The worktrees to keep: this run's issues and every open PR's issue. With
  # the PR list unknown nothing is swept: a worktree awaiting review is not lost.
  _keep=(${_IDS[@]+"${_IDS[@]}"})
  _talos_cap _vcs list-prs
  if [ "$_RC" -eq 0 ] && _prs="$(_talos_pipeline_prs "$_OUT")"; then
    while read -r _s _i _b <&3; do
      [ -z "$_i" ] || _keep+=("$_i")
    done 3<<< "$_prs"
    _talos_run worktree bash "$SCRIPT_DIR/pipeline-worktree.sh" sweep ${_keep[@]+"${_keep[@]}"}
    if [ "$_RC" -ne 0 ]; then
      _talos_warn worktree-sweep-failed
    else
      _line="$(grep '^talos:worktree-sweep ' <<< "$_OUT" | tail -n 1)"
      [ -z "$_line" ] || _talos_emit worktree_sweep "$_line"
    fi
  else
    _talos_warn prs-unlisted
  fi

  # 2. The worktree-count warning, relayed once.
  _talos_run worktree bash "$SCRIPT_DIR/pipeline-worktree.sh" list
  _line="$(grep 'pipeline-worktree: WARNING:' <<< "$_OUT" | head -n 1)"
  if [ -n "$_line" ]; then
    _talos_emit worktree_warning "$_line"
    _talos_notify info "worktrees" "$_line" ""
  fi

  # 4. The cost table: one call, one --issue per issue.
  if [ "${#_IDS[@]}" -gt 0 ]; then
    for _i in "${_IDS[@]}"; do _a+=(--issue "$_i"); done
    _talos_run cost bash "$SCRIPT_DIR/pipeline-events.sh" cost --summary "${_a[@]}"
    if [ -n "$_OUT" ]; then
      while IFS= read -r _line || [ -n "$_line" ]; do
        _talos_emit cost "$_line"
      done <<< "$_OUT"
    fi
  fi

  # 5. The status resume block, once per run (it reads GitHub 3+N to 3+4N times).
  if [ "$(cfg status.enabled)" = "true" ]; then
    _talos_run status-refresh bash "$SCRIPT_DIR/pipeline-status-file.sh" refresh
    [ "$_RC" -eq 0 ] || _talos_warn status-refresh-failed
  fi
  _talos_flush
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
  post-merge) _talos_post_merge "$@" ;;
  sweep) _talos_sweep "$@" ;;
  summary) _talos_summary "$@" ;;
  help | -h | --help) _talos_help ;;
  "") _talos_help >&2; exit 2 ;;
  *) printf 'stop reason=unknown-verb\n'; exit 2 ;;
esac
