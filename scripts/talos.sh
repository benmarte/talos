#!/usr/bin/env bash
# talos.sh -- the orchestrator's one entry point (#465, slice 1 of epic #422).
#
# Usage: talos.sh env
#        talos.sh help
#
# One script with verbs; each later slice adds a verb and deletes the playbook
# prose it replaces. This slice adds `env`.
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
# joined by the two characters \n. Every value is config or script text, so it is
# sanitised in one python3 -I pass: a control character, DEL and a C1 control
# print as \xNN, an invalid UTF-8 byte as \xNN, and a value over 8192 characters
# is cut (with `warn reason=value-truncated key=<KEY>`). Free text never travels
# on argv: values go to the sanitiser on stdin, a file carries them there.
# A child's stderr line (config, draft or evidence warning, an isolation error)
# is passed through on stderr, unchanged.
#
# env-reasons: scripts-missing python-missing scratch-unavailable config-unreadable isolation-invalid usage unknown-verb resolve-failed effort-check-failed draft-resolve-failed value-truncated
#   stop: scripts-missing python-missing scratch-unavailable config-unreadable
#         isolation-invalid usage unknown-verb
#   warn: resolve-failed effort-check-failed draft-resolve-failed value-truncated
#
# Exit codes: 0 ok, 1 a `stop` (env), 2 usage.
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
# `KEY=value`. Runs as `python3 -I` with the program on argv and the data on stdin.
_TALOS_SANITISER='
import re, sys
CAP = 8192
KEY = re.compile(r"[A-Za-z][A-Za-z0-9_.]*\Z")
parts = sys.stdin.buffer.read().split(b"\0")
if parts and parts[-1] == b"":
    parts.pop()
def esc(s):
    return "".join(
        "\\x%02x" % ord(c) if ord(c) < 32 or 0x7F <= ord(c) <= 0x9F or ord(c) in (0x2028, 0x2029) else c
        for c in s)
out = []
warns = []
for i in range(0, len(parts) - 1, 2):
    key = parts[i].decode("ascii", "replace")
    if not KEY.match(key):
        continue
    val = parts[i + 1].decode("utf-8", "backslashreplace")
    if len(val) > CAP:
        val = val[:CAP]
        warns.append("warn reason=value-truncated key=" + key)
    val = esc(val)
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

_talos_help() {
  cat <<'HELP'
usage: talos.sh <verb>
verbs:
  env    print every Step 0 setting, PR_DRAFT, the evidence line and the
         per-role runner/model/effort as sanitised KEY=value lines
  help   this text
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

  local _f
  for _f in pipeline-config.sh pipeline-cfg-cache.sh pipeline-agent.sh pipeline-draft-check.sh \
            pipeline-evidence.sh pipeline-isolation.sh; do
    [ -f "$SCRIPT_DIR/$_f" ] || _talos_stop scripts-missing
  done
  command -v python3 >/dev/null 2>&1 || _talos_stop python-missing

  # pipeline-cfg-cache.sh gives every cfg call below the one resolved dump (one
  # python3 spawn, none without a config file) and removes its scratch dir on
  # exit; the buffer file lives in that dir.
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
  if [ -z "${_CFG_CACHE_DIR:-}" ] || [ ! -d "$_CFG_CACHE_DIR" ]; then
    _talos_stop scratch-unavailable
  fi
  _TALOS_OUT="$_CFG_CACHE_DIR/env.pairs"
  : > "$_TALOS_OUT" || _talos_stop scratch-unavailable

  # Prime the cache here instead of on the first cfg call, to see the exit code.
  if "$SCRIPT_DIR/pipeline-config.sh" --dump > "$_CFG_CACHE_FILE"; then
    : > "$_CFG_CACHE_DONE"
  else
    _talos_stop config-unreadable
  fi

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
    # The two characters \n, the config table's list convention.
    if [ "$_kind" = "l" ]; then
      _val="$(printf '%s' "$_val" | awk 'BEGIN { ORS = "" } NR > 1 { printf "\\n" } { print }')"
    fi
    _talos_emit "$_var" "$_val"
  done <<EOF
$(_talos_env_table)
EOF

  # PR_DRAFT: pipeline-draft-check.sh is the one resolver (#435). Its stderr
  # warning line passes through.
  _val="$(bash "$SCRIPT_DIR/pipeline-draft-check.sh" resolve)"
  case "$_val" in
    true | false) : ;;
    *)
      _talos_emit warn "reason=draft-resolve-failed"
      _val="false"
      ;;
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

verb="${1:-}"
[ "$#" -eq 0 ] || shift

case "$verb" in
  env) _talos_env "$@" ;;
  help | -h | --help) _talos_help ;;
  "") _talos_help >&2; exit 2 ;;
  *) printf 'stop reason=unknown-verb\n'; exit 2 ;;
esac
