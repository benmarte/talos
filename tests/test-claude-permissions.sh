#!/usr/bin/env bash
# test-claude-permissions.sh -- headless claude stages get a scoped permission
# allowlist (#580). `claude -p` cannot answer an approval prompt, so a repo with
# no allowlist of its own left every Bash call a stage needs "requires approval".
# pipeline-agent.sh now passes, for the claude runner only:
#   --allowedTools <scoped default per role> [+ agents.claude_allowed_tools]
#   --add-dir <the Talos scripts dir>   (when the stage cwd is not inside it)
#   --disallowedTools Edit/Write on that dir (the install is read-only to a stage)
#   --permission-mode <m>               only when agents.claude_permission_mode is set
# against the claude stub (argv recorded in $RUNNER_LOG). The rule grammar
# (`Bash(<prefix>:*)`, one rule per argv word, `--` before the prompt) was checked
# against the real CLI; see docs/reference.md.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs
install_talos

AGENT="$HOME/.talos/scripts/pipeline-agent.sh"
SCRIPTS="$(cd "$HOME/.talos/scripts" && pwd)"
# The stage cwd is a project dir beside the install, never a parent of it (a real
# ~/.talos is outside the repo).
mkdir -p "$SANDBOX/proj" && cd "$SANDBOX/proj" || exit 1
export RUNNER_LOG="$SANDBOX/runner.log"
ERR="$SANDBOX/agent.err"
set_cfg() { printf '%s\n' "$1" > talos.pipeline.json; }

# run_role <role>: argv of the claude stub in $ARGV, stderr in $STDERR.
run_role() {
  : > "$RUNNER_LOG"
  bash "$AGENT" "$1" "the task text" >/dev/null 2>"$ERR" </dev/null
  ARGV="$(grep '^CLAUDE ARGS' "$RUNNER_LOG" | head -n 1)"
  LOG_ALL="$(cat "$RUNNER_LOG")"
  STDERR="$(cat "$ERR")"
}
has() { assert_contains "$ARGV" "[$1]" "$2"; }
hasnt() { assert_not_contains "$ARGV" "[$1]" "$2"; }

set_cfg '{"verify": ["bash tests/test-greet.sh", "npm test"]}'

# ── validator: the base set, the verify commands, nothing that writes ────────
run_role validator
has "--allowedTools" "validator: --allowedTools is passed"
has "Read" "validator: Read"
has "Glob" "validator: Glob"
has "Grep" "validator: Grep"
has "Bash(bash scripts/pipeline-vcs.sh:*)" "validator: pipeline-vcs.sh by the relative scripts/ path"
has "Bash(bash ./scripts/pipeline-vcs.sh:*)" "validator: pipeline-vcs.sh by the ./scripts/ path"
has "Bash(bash $SCRIPTS/pipeline-vcs.sh:*)" "validator: pipeline-vcs.sh by the install dir"
has "Bash(bash ~${SCRIPTS#"$(cd "$HOME" && pwd)"}/pipeline-vcs.sh:*)" "validator: pipeline-vcs.sh by the ~/ path (an agent writes ~/.talos/scripts/...)"
has "Bash(bash scripts/talos.sh:*)" "validator: talos.sh by the relative path"
has "Bash(bash $SCRIPTS/talos.sh:*)" "validator: talos.sh by the install dir"
has "Bash(git status:*)" "validator: read-only git status"
has "Bash(git diff:*)" "validator: read-only git diff"
has "Bash(git log:*)" "validator: read-only git log"
has "Bash(git show:*)" "validator: read-only git show"
has "Bash(git rev-parse:*)" "validator: read-only git rev-parse"
has "Bash(git ls-files:*)" "validator: read-only git ls-files"
has "Bash(git branch)" "validator: git branch with no arguments only"
hasnt "Bash(git branch:*)" "validator: no prefix rule on git branch (it would allow -D)"
has "Bash(bash tests/test-greet.sh:*)" "validator: a verify command (it reproduces the issue)"
has "Bash(npm test:*)" "validator: every verify command"
hasnt "Edit" "validator: no Edit"
hasnt "Write" "validator: no Write"
hasnt "Bash(git:*)" "validator: not all of git"
has "--add-dir" "validator: --add-dir"
has "$SCRIPTS" "validator: the install dir is the --add-dir"
has "--disallowedTools" "validator: the install dir is denied to Edit and Write"
has "Edit(/$SCRIPTS/**)" "validator: Edit denied under the install dir (// absolute form)"
has "Write(/$SCRIPTS/**)" "validator: Write denied under the install dir"
hasnt "--permission-mode" "validator: no permission mode when unset"
assert_not_contains "$ARGV" "--dangerously-skip-permissions" "validator: never skips permissions"
# `--allowedTools` is variadic: the prompt must follow `--` or it is eaten as a rule.
assert_contains "$ARGV" "[--] [" "validator: the prompt follows --"
case "$LOG_ALL" in
  *"the task text]") pass "validator: the prompt is the last argument" ;;
  *) fail "validator: the prompt is the last argument" "$(printf '%s' "$LOG_ALL" | tail -c 100)" ;;
esac

# ── per role ─────────────────────────────────────────────────────────────────
run_role developer
has "Edit" "developer: Edit"
has "Write" "developer: Write"
has "Bash(git:*)" "developer: git"
has "Bash(bash tests/test-greet.sh:*)" "developer: the verify commands"
has "Bash(bash scripts/pipeline-vcs.sh:*)" "developer: the base set"

run_role qa
has "Bash(bash tests/test-greet.sh:*)" "qa: the verify commands"
hasnt "Edit" "qa: no Edit"
hasnt "Write" "qa: no Write"
hasnt "Bash(git:*)" "qa: not all of git"

run_role docs
has "Edit" "docs: Edit"
has "Write" "docs: Write"
hasnt "Bash(git:*)" "docs: not all of git"
hasnt "Bash(npm test:*)" "docs: no verify commands"

for r in reviewer security pm adversarial planner; do
  run_role "$r"
  has "Bash(bash scripts/pipeline-vcs.sh:*)" "$r: the base set"
  hasnt "Edit" "$r: no Edit"
  hasnt "Bash(npm test:*)" "$r: no verify commands"
done

# ── the usage-capture variant and the text variant both carry them ───────────
set_cfg '{"agents": {"capture_usage": false}}'
run_role validator
has "--allowedTools" "text mode (capture_usage false): --allowedTools"
assert_not_contains "$ARGV" "[--output-format]" "text mode: no --output-format"
set_cfg '{}'
run_role validator
has "--output-format" "json mode: --output-format json still added"
has "--allowedTools" "json mode: --allowedTools"
has "--add-dir" "json mode: --add-dir"

# ── agents.claude_allowed_tools extends the default (role-first) ─────────────
set_cfg '{"agents": {"claude_allowed_tools": ["Bash(npm run lint:*)", "Edit(docs/**)"]}}'
run_role validator
has "Bash(npm run lint:*)" "config: agents.claude_allowed_tools is added"
has "Edit(docs/**)" "config: a path rule is added"
has "Bash(bash scripts/pipeline-vcs.sh:*)" "config: the default is still there"
set_cfg '{"agents": {"claude_allowed_tools": ["Bash(npm run lint:*)"], "roles": {"qa": {"claude_allowed_tools": ["Bash(make e2e:*)"]}}}}'
run_role qa
has "Bash(make e2e:*)" "config: agents.roles.qa.claude_allowed_tools is added for qa"
hasnt "Bash(npm run lint:*)" "config: the role list wins over the global one (role-first)"
run_role docs
has "Bash(npm run lint:*)" "config: other roles keep the global list"

# an entry that could change the command line or the rule list is dropped
set_cfg '{"agents": {"claude_allowed_tools": ["--dangerously-skip-permissions", "Bash(ok:*)", "Bash(a\nb:*)", "", "Bash(unbalanced", "Edit)(x", "Bash(a,b:*)"]}}'
run_role validator
hasnt "--dangerously-skip-permissions" "config: a flag-shaped entry is never passed"
has "Bash(ok:*)" "config: the valid entry beside the bad ones is kept"
assert_contains "$STDERR" "claude_allowed_tools" "config: a dropped entry is warned about"
assert_not_contains "$ARGV" "unbalanced" "config: an unbalanced rule is dropped"
assert_not_contains "$ARGV" "Edit)(x" "config: a mis-nested rule is dropped"
assert_not_contains "$ARGV" "Bash(a,b:*)" "config: a rule with a comma is dropped"
assert_not_contains "$ARGV" "Bash(a
b:*)" "config: a rule with a newline is dropped"

# ── agents.claude_permission_mode: explicit opt-in ───────────────────────────
set_cfg '{"agents": {"claude_permission_mode": "bypassPermissions"}}'
run_role developer
has "--permission-mode" "mode: --permission-mode is passed when set"
has "bypassPermissions" "mode: with the configured value"
set_cfg '{"agents": {"claude_permission_mode": "acceptEdits", "roles": {"docs": {"claude_permission_mode": "dontAsk"}}}}'
run_role docs
has "dontAsk" "mode: the role value wins"
run_role developer
has "acceptEdits" "mode: other roles use the global value"
set_cfg '{"agents": {"claude_permission_mode": "yolo"}}'
run_role developer
hasnt "--permission-mode" "mode: an unknown mode is not passed"
assert_contains "$STDERR" "claude_permission_mode" "mode: an unknown mode is warned about"
set_cfg '{"agents": {"claude_permission_mode": "--dangerously-skip-permissions"}}'
run_role developer
assert_not_contains "$ARGV" "--dangerously-skip-permissions" "mode: a flag-shaped mode is never passed"

# ── verify commands: only what a prefix rule can say safely ──────────────────
set_cfg '{"verify": ["make test && wipe it", "echo $(id)", "x*", "bash -c \"a\"", "cat `id`", "a;b", "a|b", "a>b", "(sub)", "back\\slash", "good --flag value", "bash tests/run-tests.sh --quiet", "npm run test:unit"]}'
run_role developer
has "Bash(good --flag value:*)" "verify: a plain command is mapped"
has "Bash(bash tests/run-tests.sh --quiet:*)" "verify: a command with flags is mapped"
has "Bash(npm run test:unit:*)" "verify: a colon inside the command is kept"
for bad in 'wipe it' '$(id)' 'x*' 'bash -c' '`id`' 'a;b' 'a|b' 'a>b' '(sub)' 'back\slash'; do
  assert_not_contains "$ARGV" "$bad" "verify: '$bad' never reaches the rule list"
done
assert_contains "$STDERR" "verify" "verify: skipped commands are warned about"
assert_not_contains "$STDERR" "wipe it" "verify: the warning does not echo the command text"
# nothing that came from verify may begin with '-' after --allowedTools (flag injection)
set_cfg '{"verify": ["--dangerously-skip-permissions", "-x"]}'
run_role developer
assert_not_contains "$ARGV" "--dangerously-skip-permissions" "verify: a flag-shaped command is skipped"
assert_not_contains "$ARGV" "[Bash(--" "verify: no rule begins with a flag"

# ── an explicit --allowedTools / skip flag in runner_args wins ───────────────
set_cfg '{"agents": {"runner_args": ["--allowedTools", "Bash(mine:*)"]}}'
run_role developer
assert_contains "$ARGV" "[Bash(mine:*)]" "runner_args: the owner's --allowedTools is passed"
assert_not_contains "$ARGV" "Bash(bash scripts/pipeline-vcs.sh:*)" "runner_args: the default allowlist is not added on top"
set_cfg '{"agents": {"runner_args": ["--dangerously-skip-permissions"], "claude_permission_mode": "plan"}}'
run_role developer
assert_not_contains "$ARGV" "--allowedTools" "runner_args: skip-permissions leaves no allowlist to add"
assert_not_contains "$ARGV" "--permission-mode" "runner_args: and no second permission mode"
set_cfg '{"agents": {"runner_args": ["--permission-mode", "plan"], "claude_permission_mode": "dontAsk"}}'
run_role developer
assert_not_contains "$ARGV" "[dontAsk]" "runner_args: the owner's --permission-mode is the one that counts"

# ── other runners are untouched ──────────────────────────────────────────────
set_cfg '{"agents": {"runner": "codex"}}'
: > "$RUNNER_LOG"
bash "$AGENT" developer "x" >/dev/null 2>&1 </dev/null
assert_not_contains "$(cat "$RUNNER_LOG")" "--allowedTools" "codex: no claude flags"

# ── cwd inside the scripts dir (Talos developing itself): no --add-dir ───────
set_cfg '{}'
mkdir -p "$SANDBOX/self"
cp -R "$HOME/.talos/scripts" "$SANDBOX/self/scripts"
: > "$RUNNER_LOG"
( cd "$SANDBOX/self/scripts" && bash "$SANDBOX/self/scripts/pipeline-agent.sh" validator "x" >/dev/null 2>&1 </dev/null )
ARGV="$(grep '^CLAUDE ARGS' "$RUNNER_LOG" | head -n 1)"
hasnt "--add-dir" "self-hosting: no --add-dir when the scripts are inside the cwd"
hasnt "--disallowedTools" "self-hosting: and nothing is denied"

finish
