#!/usr/bin/env bash
# test-config-mutation-754.sh -- a stage cannot change the pipeline's own config (#754).
#
# pipeline-agent.sh checksums the three resolved config files (user-level
# ${TALOS_HOME:-~/.talos}/talos.pipeline.json, the project file $PIPELINE_CONFIG or
# ./talos.pipeline.json, the repo's talos.pipeline.json) before and after the stage:
# a changed, created or removed file ends the stage with exit 78 and
# `reason=config-mutated role=<r> file=<path>` on stderr, which a Bash write
# (`sed -i`) cannot dodge. For the claude runner every role also gets Edit/Write
# deny rules on those paths. This file pins, against the claude stub:
#   AC1 a Bash-style write to the user-level config           -> 78 + the line
#   AC2 the same for the project config and the repo config   -> 78 + the line
#   AC4 `talos.sh run` turns the agent's 78 into a stop, reads no verdict
#   AC5 the built --disallowedTools holds Edit( and Write( for each existing path
#   AC8 docs.paths under .claude/ warns unless the docs role is in auto/bypass
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs
install_talos

AGENT="$HOME/.talos/scripts/pipeline-agent.sh"
export RUNNER_LOG="$SANDBOX/runner.log"
ERR="$SANDBOX/agent.err"
USER_CFG="$HOME/.talos/talos.pipeline.json"
PROJ_DIR="$SANDBOX/cfgdir"
PROJ_CFG="$PROJ_DIR/talos.pipeline.json"
REPO_CFG="$PWD/talos.pipeline.json"
mkdir -p "$PROJ_DIR"
printf '{"roles": {"pm": true}}\n' > "$USER_CFG"
printf '{}\n' > "$PROJ_CFG"
printf '{}\n' > "$REPO_CFG"
export PIPELINE_CONFIG="$PROJ_CFG"

# run_role <role>: the agent's rc in RC, stderr in STDERR, the claude argv in ARGV.
run_role() {
  : > "$RUNNER_LOG"
  bash "$AGENT" "$1" "the task text" >/dev/null 2>"$ERR" </dev/null
  RC=$?
  ARGV="$(grep '^CLAUDE ARGS' "$RUNNER_LOG" | head -n 1)"
  STDERR="$(cat "$ERR")"
}

# ── AC1 / AC2: a Bash write to a resolved config ends the stage with 78 ──────
for _t in "user:$USER_CFG" "project:$PROJ_CFG" "repo:$REPO_CFG"; do
  _name="${_t%%:*}" _file="${_t#*:}"
  # An in-place sed rewrite, in the portable form (the lint refuses sed -i).
  export STUB_CLAUDE_HOOK="sed 's/}\$/, \"x\": 1}/' '$_file' > '$_file.new' && mv '$_file.new' '$_file'"
  run_role developer
  case "$_name" in user) _ac="AC1" ;; project) _ac="AC2" ;; *) _ac="AC2" ;; esac
  assert_eq "78" "$RC" "$_ac $_name config rewritten by the stage: the agent exits 78"
  assert_contains "$STDERR" "pipeline-agent: reason=config-mutated role=developer file=$_file" \
    "$_ac $_name config: the stop line names the role and the file"
  printf '%s\n' "{}" > "$_file"
  [ "$_name" != user ] || printf '{"roles": {"pm": true}}\n' > "$USER_CFG"
done
unset STUB_CLAUDE_HOOK

# A config file the stage deletes, or creates where there was none, is a mutation too.
export STUB_CLAUDE_HOOK="rm -f '$REPO_CFG'"
run_role qa
assert_eq "78" "$RC" "AC1 a removed config file: the agent exits 78"
assert_contains "$STDERR" "role=qa file=$REPO_CFG" "AC1 a removed config file is named"
unset STUB_CLAUDE_HOOK
rm -f "$REPO_CFG"
export STUB_CLAUDE_HOOK="printf '{}\\n' > '$REPO_CFG'"
run_role qa
assert_eq "78" "$RC" "AC1 a created config file: the agent exits 78"
unset STUB_CLAUDE_HOOK
printf '{}\n' > "$REPO_CFG"

# ── AC5: every role's deny list holds Edit( and Write( for each config path ──
for _role in developer docs qa validator reviewer; do
  run_role "$_role"
  assert_contains "$ARGV" "[--disallowedTools]" "AC5 $_role: --disallowedTools is passed"
  for _f in "$USER_CFG" "$PROJ_CFG" "$REPO_CFG"; do
    assert_contains "$ARGV" "[Edit(/$_f)]" "AC5 $_role: Edit denied on $_f"
    assert_contains "$ARGV" "[Write(/$_f)]" "AC5 $_role: Write denied on $_f"
  done
done
# A config file that does not exist gets no rule: only existing resolved paths do.
rm -f "$REPO_CFG"
run_role developer
assert_not_contains "$ARGV" "Edit(/$REPO_CFG)" "AC5 a missing repo config gets no deny rule"
printf '{}\n' > "$REPO_CFG"

# ── AC8: docs.paths under .claude/ needs the docs role in auto or bypass ─────
set_proj() { printf '%s\n' "$1" > "$PROJ_CFG"; }
set_proj '{"docs": {"paths": [".claude/docs/**"]}}'
run_role docs
assert_contains "$STDERR" "pipeline-agent: [warn]" "AC8 docs.paths under .claude/ without auto: a warning"
assert_contains "$STDERR" "claude_permission_mode: auto" "AC8 the warning names claude_permission_mode: auto"
assert_not_contains "$STDERR" ".claude/docs/**" "AC8 the warning carries no entry text"
set_proj '{"agents": {"claude_permission_mode": "acceptEdits"}, "docs": {"paths": ["./.claude/docs/**"]}}'
run_role docs
assert_contains "$STDERR" "claude_permission_mode: auto" "AC8 a ./.claude/ entry under acceptEdits warns"
set_proj '{"agents": {"claude_permission_mode": "auto"}, "docs": {"paths": [".claude/docs/**"]}}'
run_role docs
assert_not_contains "$STDERR" "claude_permission_mode: auto" "AC8 the docs role in auto: no warning"
set_proj '{"agents": {"claude_permission_mode": "bypassPermissions"}, "docs": {"paths": [".claude/docs/**"]}}'
run_role docs
assert_not_contains "$STDERR" "claude_permission_mode: auto" "AC8 the docs role in bypassPermissions: no warning"
set_proj '{"agents": {"claude_permission_mode": "acceptEdits", "roles": {"docs": {"claude_permission_mode": "auto"}}}, "docs": {"paths": [".claude/docs/**"]}}'
run_role docs
assert_not_contains "$STDERR" "claude_permission_mode: auto" "AC8 a docs role override in auto: no warning"
set_proj '{"docs": {"paths": [".claude/docs/**"]}}'
run_role developer
assert_not_contains "$STDERR" "claude_permission_mode: auto" "AC8 only the docs role warns"
set_proj '{}'
run_role docs
assert_not_contains "$STDERR" "claude_permission_mode: auto" "AC8 the default docs.paths: no warning"
set_proj '{"docs": {"paths": ["docs/*"]}}'
run_role docs
assert_not_contains "$STDERR" "claude_permission_mode: auto" "AC8 docs.paths outside .claude/: no warning"

# ── AC4: talos.sh run turns the agent's 78 into a stop and reads no verdict ──
unset PIPELINE_CONFIG
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR" "$SANDBOX/templates/prompts"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cp -R "$TALOS_ROOT/templates/prompts/." "$SANDBOX/templates/prompts/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="$1"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
if [ "$key" = "list-prs" ] || [ "$key" = "list-needs-owner" ] || [ "$key" = "list-issues" ]; then printf "[]"; exit 0; fi
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; elif [ -f "$d/$key.${2:-}" ]; then cat "$d/$key.${2:-}"; fi
exit 0
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
cat > "$GS/pipeline-agent.sh" <<'TALOS_stubagentM4q9ZkTw2Vb'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
cat > /dev/null
printf "agent %s\n" "$1" >> "$d/journal"
printf 'CONFIRMED: would be fine\n'
printf 'pipeline-agent: reason=config-mutated role=%s file=/home/x/.talos/talos.pipeline.json\n' "$1" >&2
exit 78
TALOS_stubagentM4q9ZkTw2Vb
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusP7xHn3Rc8Ld'
#!/usr/bin/env bash
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [9], "held": [], "owners": [], "capped": []}'
TALOS_stubstatusP7xHn3Rc8Ld
printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' > "$SANDBOX/talos.pipeline.json"
printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "body", "state": "open"}' \
  > "$STUB_DIR/view-issue.9"
OUT="$(TALOS_LEASE_TTL_S=1 TALOS_NOW=1000 bash "$GS/talos.sh" run --issue 9 --max-iterations 1 2>"$ERR")"
RC=$?
assert_eq "1" "$RC" "AC4 run: the agent's 78 ends the run with exit 1"
assert_contains "$OUT" "stop reason=config-mutated role=validator file=/home/x/.talos/talos.pipeline.json" \
  "AC4 run: the stop line names the reason, the role and the file"
assert_not_contains "$OUT" "dispatch-failed" "AC4 run: 78 is not a generic dispatch failure"
assert_not_contains "$(cat "$STUB_DIR/journal")" "hooks post_stage" "AC4 run: no verdict was read or recorded"
assert_not_contains "$(cat "$STUB_DIR/journal")" "label-issue" "AC4 run: no label changed"

finish
