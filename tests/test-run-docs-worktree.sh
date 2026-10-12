#!/usr/bin/env bash
# test-run-docs-worktree.sh -- `talos.sh run` in a fresh clone (#640):
#   AC7  with no worktree on the PR branch, docs runs in a new worktree of that
#        branch and the driver's checkout stays clean
#   AC8  the docs prompt carries that path; an existing worktree is reused
#   AC9  no worktree to be had: stop reason=worktree-unavailable, no docs dispatch
#   AC10 the same verdict at the same head twice ends the run; a changed head
#        between two dispatches does not
# A real origin (a bare repository) and a real pipeline-worktree.sh; the
# provider, the agent and the collect are stubs. No GitHub call, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
ERR="$SANDBOX/stderr"
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
mkdir -p "$SANDBOX/templates/prompts"
cp -R "$TALOS_ROOT/templates/prompts/." "$SANDBOX/templates/prompts/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null

# The journaling provider stub: $STUB_DIR/<verb>.out answers, <verb>.rc exits.
cat > "$GS/pipeline-vcs.sh" <<'TALOS_dwVcsStub4Rq8Ln'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
key="$1"
printf 'vcs %s\n' "$*" >> "$d/journal"
case "$key" in list-prs | list-needs-owner | list-issues) printf '[]'; exit 0 ;; esac
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
TALOS_dwVcsStub4Rq8Ln
for s in pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-events.sh; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "$STUB_DIR/journal"\nexit 0\n' "$s" > "$GS/$s"
done
# The agent stub: journals its role and working directory, edits a file there,
# answers $STUB_DIR/message.<role>; hook.<role>.<N> runs on its Nth dispatch.
cat > "$GS/pipeline-agent.sh" <<'TALOS_dwAgentStub7Kp2Vx'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
role="$1"
cat > "$d/agent.stdin.$role"
printf 'agent %s\n' "$role" >> "$d/journal"
printf '%s\n' "$PWD" >> "$d/agent.cwd"
printf 'edited by %s\n' "$role" >> "docs-edit.md"
cnt="$(grep -c "^agent $role\$" "$d/journal")"
if [ -f "$d/hook.$role.$cnt" ]; then . "$d/hook.$role.$cnt"; fi
cat "$d/message.$role" 2>/dev/null
exit 0
TALOS_dwAgentStub7Kp2Vx
cat > "$GS/pipeline-status-file.sh" <<'TALOS_dwCollectStub2Mv9'
#!/usr/bin/env bash
cat "${STUB_DIR:?}/collect.json"
TALOS_dwCollectStub2Mv9

# A bare origin with main and the PR's branch, and the driver's clone of it.
ORIGIN="$SANDBOX/origin.git"
DRV="$SANDBOX/driver"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$SANDBOX/seed" 2>/dev/null
(
  cd "$SANDBOX/seed" || exit 1
  git config user.email t@talos.invalid; git config user.name t
  git checkout -q -b main
  printf 'hello\n' > README.md; git add README.md; git commit -q -m init
  git push -q origin main
  git checkout -q -b fix/issue-9-docs
  printf 'change\n' > feature.txt; git add feature.txt; git commit -q -m feature
  git push -q origin fix/issue-9-docs
)
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$DRV" 2>/dev/null
git -C "$DRV" config user.email t@talos.invalid
git -C "$DRV" config user.name t
HEAD_A="$(git -C "$DRV" rev-parse origin/fix/issue-9-docs)"

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": false}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
  > "$PIPELINE_CONFIG"

reset() {  # $1 = the PR's collect stage
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$DRV/.git/talos-lease.ledger" "$DRV/docs-edit.md"
  printf '{"prs":[{"n":12,"issue":9,"head":"%s","owner":false,"stage":"%s"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' \
    "${HEAD_A:0:7}" "$1" > "$STUB_DIR/collect.json"
  printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:review"}], "body": "b", "state": "open"}' > "$STUB_DIR/view-issue.out"
  printf 'fix/issue-9-docs\n' > "$STUB_DIR/pr-head-ref.out"
  printf '%s\n' "$HEAD_A" > "$STUB_DIR/pr-head.out"
  printf 'README.md\n' > "$STUB_DIR/pr-files.out"
  printf 'docs updated\n' > "$STUB_DIR/message.docs"
}
rn() { OUT="$(cd "$DRV" && TALOS_LEASE_TTL_S=1800 bash "$GS/talos.sh" run "$@" 2>"$ERR")"; RC=$?; }
agents() { grep -c "^agent $1\$" "$STUB_DIR/journal" 2>/dev/null || true; }
# The physical path: pr-worktree prints what git resolves, and on macOS
# $TMPDIR is a symlink (/var -> /private/var) with a trailing slash.
WT="$(cd "$DRV" && pwd -P)/.claude/worktrees/fix-issue-9-docs"

# ── AC7: a new worktree of the PR branch ─────────────────────────────────────
reset docs
rn --max-iterations 1
assert_eq "1" "$(agents docs)" "AC7 the docs agent is dispatched" "$OUT $(cat "$ERR")"
assert_eq "$WT" "$(head -n 1 "$STUB_DIR/agent.cwd" 2>/dev/null)" "AC7 it runs in a worktree of the PR's head branch"
assert_eq "fix/issue-9-docs" "$(git -C "$WT" symbolic-ref -q --short HEAD 2>/dev/null)" "AC7 that worktree is on the PR's head branch"
assert_eq "$HEAD_A" "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" "AC7 ...at the PR's head commit"
assert_file_exists "$WT/docs-edit.md" "AC7 the docs edit lands in the PR worktree"
assert_file_absent "$DRV/docs-edit.md" "AC7 the driver's checkout gets no edit"
assert_eq "" "$(git -C "$DRV" status --porcelain)" "AC7 the driver's checkout stays clean"
assert_eq "main" "$(git -C "$DRV" symbolic-ref -q --short HEAD)" "AC7 the driver's checkout stays on its branch"

# ── AC8: the prompt names it; an existing worktree is reused ─────────────────
assert_contains "$(cat "$STUB_DIR/agent.stdin.docs" 2>/dev/null)" "$WT" "AC8 the docs prompt carries the worktree's absolute path"
assert_not_contains "$(cat "$STUB_DIR/agent.stdin.docs" 2>/dev/null)" "ABSOLUTE_PATH" "AC8 no placeholder is left for the agent to fill"
reset docs
rn --max-iterations 1
assert_eq "$WT" "$(head -n 1 "$STUB_DIR/agent.cwd" 2>/dev/null)" "AC8 a second run reuses the existing worktree"
assert_eq "2" "$(grep -c 'edited by docs' "$WT/docs-edit.md" 2>/dev/null)" "AC8 ...the same one, not a re-created copy"
assert_eq "1" "$(git -C "$DRV" worktree list --porcelain | grep -c '^branch refs/heads/fix/issue-9-docs$')" "AC8 one worktree holds the branch"
git -C "$DRV" worktree remove --force "$WT"
git -C "$DRV" branch -q -D fix/issue-9-docs

# ── AC9: no worktree to be had ───────────────────────────────────────────────
reset docs
printf 1 > "$STUB_DIR/pr-head-ref.rc"
rm -f "$STUB_DIR/pr-head-ref.out"
rn --max-iterations 1
assert_contains "$OUT" "stop reason=worktree-unavailable role=docs" "AC9 an unreadable head branch stops the run with one line" "$OUT $(cat "$ERR")"
assert_eq "0" "$(agents docs)" "AC9 ...and no docs agent is dispatched"
assert_eq "" "$(git -C "$DRV" status --porcelain)" "AC9 the driver's checkout is untouched"
reset docs
printf 'fix/issue-9-gone\n' > "$STUB_DIR/pr-head-ref.out"
rn --max-iterations 1
assert_contains "$OUT" "stop reason=worktree-unavailable role=docs" "AC9 a head branch origin does not have stops the run"
assert_eq "0" "$(agents docs)" "AC9 ...with no docs dispatch"

# ── AC10: the same verdict at the same head twice ────────────────────────────
reset docs
rn --max-iterations 5
assert_eq "2" "$(agents docs)" "AC10 docs: a second dispatch at the same head with the same verdict is the last" "$OUT $(cat "$ERR")"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c '^stop ')" "AC10 docs: one stop line"
assert_contains "$OUT" "stop reason=same-verdict-same-head role=docs pr=12" "AC10 docs: the stop names the reason, the role and the PR"
assert_eq "0" "$RC" "AC10 docs: the stop is a clean end (exit 0)"

reset docs
printf 'printf "%%s\\n" "%s" > "$d/pr-head.out"\n' "$(printf 'b%.0s' $(seq 40))" > "$STUB_DIR/hook.docs.2"
rn --max-iterations 5
assert_eq "3" "$(agents docs)" "AC10 docs: a changed head between two dispatches does not stop; the next repeat does" "$OUT"
assert_contains "$OUT" "stop reason=same-verdict-same-head role=docs pr=12" "AC10 docs: ...and then the run stops on it"

reset reviewer
printf 'APPROVED: looks good\n' > "$STUB_DIR/message.reviewer"
rn --max-iterations 5
assert_eq "2" "$(agents reviewer)" "AC10 reviewer: two dispatches at the same head with the same verdict, no third" "$OUT $(cat "$ERR")"
assert_contains "$OUT" "stop reason=same-verdict-same-head role=reviewer pr=12" "AC10 reviewer: one stop line names it"

reset security
printf 'CLEAR: no findings\n' > "$STUB_DIR/message.security"
rn --max-iterations 5
assert_eq "2" "$(agents security)" "AC10 security: two dispatches at the same head with the same verdict, no third" "$OUT $(cat "$ERR")"
assert_contains "$OUT" "stop reason=same-verdict-same-head role=security pr=12" "AC10 security: one stop line names it"

finish
