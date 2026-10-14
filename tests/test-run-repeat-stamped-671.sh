#!/usr/bin/env bash
# test-run-repeat-stamped-671.sh -- the docs prompt names the issue, and the
# #640 repeat check lets a run go on when the role's approval is stamped at the head:
#   AC1 the docs prompt contains `issue #<n>`, no `{{ISSUE}}` left
#   AC2 docs: same verdict at the same head with docs:done fresh does not stop
#   AC3 the same for reviewer, security and adversarial
#   AC4 a stale approval, or an unreadable stale list, still stops
# Stubbed provider, agent and collect, as tests/test-run-docs-worktree.sh.
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
cat > "$GS/pipeline-vcs.sh" <<'TALOS_rsVcsStub9Qx3Lm'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
key="$1"
printf 'vcs %s\n' "$*" >> "$d/journal"
case "$key" in list-prs | list-needs-owner | list-issues) printf '[]'; exit 0 ;; esac
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
TALOS_rsVcsStub9Qx3Lm
for s in pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-events.sh; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "$STUB_DIR/journal"\nexit 0\n' "$s" > "$GS/$s"
done
cat > "$GS/pipeline-agent.sh" <<'TALOS_rsAgentStub4Wz8Kd'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
role="$1"
cat > "$d/agent.stdin.$role"
printf 'agent %s\n' "$role" >> "$d/journal"
printf 'edited by %s\n' "$role" >> "docs-edit.md"
cat "$d/message.$role" 2>/dev/null
exit 0
TALOS_rsAgentStub4Wz8Kd
cat > "$GS/pipeline-status-file.sh" <<'TALOS_rsCollectStub6Pn1Hy'
#!/usr/bin/env bash
cat "${STUB_DIR:?}/collect.json"
TALOS_rsCollectStub6Pn1Hy

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
printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true, "adversarial": true}, "pr": {"draft": false}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
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

# labels <label>: the PR's view-pr answer, with that approval label on it.
labels() { printf '{"number": 12, "labels": [{"name": "%s"}]}' "$1" > "$STUB_DIR/view-pr.out"; }

# ── AC1: the docs prompt names the issue ─────────────────────────────────────
reset docs
rn --max-iterations 1
assert_contains "$(cat "$STUB_DIR/agent.stdin.docs" 2>/dev/null)" "issue #9" "AC1 the docs prompt names the issue" "$OUT $(cat "$ERR")"
assert_not_contains "$(cat "$STUB_DIR/agent.stdin.docs" 2>/dev/null)" "{{ISSUE}}" "AC1 no {{ISSUE}} is left unrendered"

# ── AC2: docs, approval fresh at the head ────────────────────────────────────
reset docs
labels docs:done
printf 0 > "$STUB_DIR/check-approval-sha.rc"
rn --max-iterations 3
assert_not_contains "$OUT" "same-verdict-same-head" "AC2 docs: a repeat with docs:done fresh at the head does not stop" "$OUT $(cat "$ERR")"
assert_eq "3" "$(agents docs)" "AC2 docs: the run goes on" "$OUT"

# ── AC3: the same for reviewer, security, adversarial ────────────────────────
for spec in "reviewer|review:approved|APPROVED: ok" "security|security:approved|CLEAR: none" "adversarial|adversarial:approved|CLEAR: none"; do
  role="${spec%%|*}"; rest="${spec#*|}"; lbl="${rest%%|*}"; msg="${rest#*|}"
  reset "$role"
  labels "$lbl"
  printf '%s\n' "$msg" > "$STUB_DIR/message.$role"
  printf 0 > "$STUB_DIR/check-approval-sha.rc"
  rn --max-iterations 3
  assert_not_contains "$OUT" "same-verdict-same-head" "AC3 $role: a repeat with its approval fresh does not stop" "$OUT $(cat "$ERR")"
  assert_eq "3" "$(agents "$role")" "AC3 $role: the run goes on" "$OUT"
done

# ── AC4: stale or unreadable still stops ─────────────────────────────────────
reset docs
labels docs:done
printf 'stale role=docs approved=aaaaaaa head=bbbbbbb\n' > "$STUB_DIR/check-approval-sha.out"
printf 1 > "$STUB_DIR/check-approval-sha.rc"
rn --max-iterations 5
assert_contains "$OUT" "stop reason=same-verdict-same-head role=docs pr=12" "AC4 a stale docs approval still stops" "$OUT $(cat "$ERR")"
assert_eq "2" "$(agents docs)" "AC4 stale: two dispatches"

reset docs
labels docs:done
printf 1 > "$STUB_DIR/check-approval-sha.rc"
rn --max-iterations 5
assert_contains "$OUT" "stop reason=same-verdict-same-head role=docs pr=12" "AC4 an unreadable stale list still stops" "$OUT $(cat "$ERR")"

finish
