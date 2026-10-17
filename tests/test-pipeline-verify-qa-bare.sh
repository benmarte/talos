#!/usr/bin/env bash
# test-pipeline-verify-qa-bare.sh — pipeline-verify.sh refuses a bare
# (no `-- <cmd>`) call from the QA stage (#778): the bare form runs the whole
# verify: list, which cannot finish inside verify.timeout_ms. `--all` is the
# explicit opt-in the pre-CI gate uses.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

VERIFY_SH="$TALOS_ROOT/scripts/pipeline-verify.sh"

WT_DIR="$SANDBOX/wt"
mkdir -p "$WT_DIR"
LOG="$SANDBOX/verify-order.log"
cat > "$WT_DIR/talos.pipeline.json" <<EOF
{"verify": ["echo one >> $LOG", "echo two >> $LOG && exit 7", "echo three >> $LOG"]}
EOF

# run_verify <env-role|-> <args...>: runs the wrapper in the fixture repo with
# TALOS_ROLE set from the first argument ("-" leaves it unset); sets out/rc.
run_verify() {
  local role="$1"; shift
  : > "$LOG"
  if [ "$role" = "-" ]; then
    out="$(cd "$WT_DIR" && env -u TALOS_ROLE bash "$VERIFY_SH" --issue 778 --worktree "$WT_DIR" "$@" 2>&1)"
  else
    out="$(cd "$WT_DIR" && TALOS_ROLE="$role" bash "$VERIFY_SH" --issue 778 --worktree "$WT_DIR" "$@" 2>&1)"
  fi
  rc=$?
}

# AC1: QA role (env or --role), no command, no --all: exit 2, nothing ran.
run_verify qa
assert_eq "2" "$rc" "AC1 env TALOS_ROLE=qa with no command exits 2"
assert_eq "" "$(cat "$LOG")" "AC1 env role: no verify command was executed"
run_verify - --role qa
assert_eq "2" "$rc" "AC1 --role qa with no command exits 2"
assert_eq "" "$(cat "$LOG")" "AC1 --role qa: no verify command was executed"

# AC2: one-line hint naming the targeted form.
hint="bash tests/run-tests.sh --changed origin/<base> --strict"
run_verify qa
assert_contains "$out" "$hint" "AC2 the refusal names the targeted form"
hint_line="$(printf '%s\n' "$out" | grep -F "$hint" | wc -l | tr -d ' ')"
assert_eq "1" "$hint_line" "AC2 the hint is one line"

# AC3: QA role with a command runs it; its exit code is the wrapper's.
run_verify qa -- bash -c 'echo ran-targeted; exit 5'
assert_eq "5" "$rc" "AC3 qa with a command: wrapper exit code is the command's"
assert_contains "$out" "ran-targeted" "AC3 qa with a command: the command ran"
assert_eq "" "$(cat "$LOG")" "AC3 qa with a command: verify.commands did not run"

# AC4: no role, no command: verify.commands run in order, stop at first failure.
run_verify -
assert_eq "7" "$rc" "AC4 no role, no command: propagates the failing verify exit code"
assert_contains "$(cat "$LOG")" "one" "AC4 first verify command ran"
assert_contains "$(cat "$LOG")" "two" "AC4 second (failing) verify command ran"
assert_not_contains "$(cat "$LOG")" "three" "AC4 stops at the first failure"

# AC5: qa + --all runs verify.commands; --all with a command is a usage error.
run_verify qa --all
assert_eq "7" "$rc" "AC5 qa with --all runs verify.commands and propagates the failure"
assert_contains "$(cat "$LOG")" "two" "AC5 qa with --all: verify commands ran"
assert_not_contains "$(cat "$LOG")" "three" "AC5 qa with --all: stops at the first failure"
run_verify qa --all -- bash -c 'echo should-not-run'
assert_eq "2" "$rc" "AC5 --all with a command is a usage error (exit 2)"
assert_not_contains "$out" "should-not-run" "AC5 --all with a command: the command did not run"

# AC6: pre-CI gate text (talos.sh and qa.md) tells QA to use --all.
talos_src="$(cat "$TALOS_ROOT/scripts/talos.sh")"
qa_md="$(cat "$TALOS_ROOT/agents/qa.md")"
assert_contains "$talos_src" "pipeline-verify.sh --all" "AC6 talos.sh QA_GATE_STEP tells QA to run pipeline-verify.sh --all"
pre_ci="$(printf '%s\n' "$qa_md" | grep -A4 -F '**Pre-CI gate:**')"
assert_contains "$pre_ci" "pipeline-verify.sh --all" "AC6 qa.md Pre-CI gate paragraph says pipeline-verify.sh --all"

# AC7: qa.md step 2 shows the whole targeted command on one line and says
# the bare form is refused.
assert_contains "$qa_md" 'bash scripts/pipeline-verify.sh --issue <issue-n> --worktree <worktree-path> -- bash tests/run-tests.sh --changed origin/<base-branch> --strict' \
  "AC7 qa.md shows the whole targeted command on one line"
assert_contains "$qa_md" "bare form is refused" "AC7 qa.md says the bare form is refused"

finish
