#!/usr/bin/env bash
# test-run-verdict-stamp-708.sh -- a reviewer/security/adversarial stage that
# stamped its approval but opened its final message with a heading (no verdict
# word) is read as approved from the PR's stamp, not stopped verdict-unreadable:
#   AC1 security: heading-first message, security:approved fresh -> done --verdict CLEAR
#   AC2 reviewer -> APPROVED, adversarial -> CLEAR the same way
#   AC3 no approval label on the PR: stops verdict-unreadable (guard)
#   AC4 label present but the stale list names the role, or a failed read: stops (guard)
#   AC5 a FINDINGS: first word wins over a fresh label (guard)
#   AC6 qa, validator and docs get no fallback (guard)
# Stubbed provider, agent and collect, as tests/test-run-repeat-stamped-671.sh.
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
cat > "$GS/pipeline-vcs.sh" <<'TALOS_vsVcsStub7Hq2Bn'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
key="$1"
printf 'vcs %s\n' "$*" >> "$d/journal"
case "$key" in list-prs | list-needs-owner | list-issues) printf '[]'; exit 0 ;; esac
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
TALOS_vsVcsStub7Hq2Bn
for s in pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-events.sh; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "$STUB_DIR/journal"\nexit 0\n' "$s" > "$GS/$s"
done
cat > "$GS/pipeline-agent.sh" <<'TALOS_vsAgentStub3Rk9Wd'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
role="$1"
cat > "$d/agent.stdin.$role"
printf 'agent %s\n' "$role" >> "$d/journal"
printf 'edited by %s\n' "$role" >> "docs-edit.md"
cat "$d/message.$role" 2>/dev/null
exit 0
TALOS_vsAgentStub3Rk9Wd
cat > "$GS/pipeline-status-file.sh" <<'TALOS_vsCollectStub5Ty4Jm'
#!/usr/bin/env bash
cat "${STUB_DIR:?}/collect.json"
TALOS_vsCollectStub5Ty4Jm
# The driver's own `done` is wrapped so the verdict it is given is journaled.
mv "$GS/talos.sh" "$GS/talos-real.sh"
cat > "$GS/talos.sh" <<'TALOS_vsDoneWrap8Xc1Pe'
#!/usr/bin/env bash
if [ "${1:-}" = done ]; then printf '%s\n' "$*" >>"${STUB_DIR:?}/journal"; fi
exec bash "$(dirname "$0")/talos-real.sh" "$@"
TALOS_vsDoneWrap8Xc1Pe

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
}
rn() { OUT="$(cd "$DRV" && TALOS_LEASE_TTL_S=1800 bash "$GS/talos.sh" run "$@" 2>"$ERR")"; RC=$?; }
done_line() { grep "^done $1 " "$STUB_DIR/journal" 2>/dev/null || true; }

# labels <label>: the PR's view-pr answer, with that approval label on it.
labels() { printf '{"number": 12, "labels": [{"name": "%s"}]}' "$1" > "$STUB_DIR/view-pr.out"; }
# heading <role>: a final message opening with a heading, no verdict word.
heading() { printf '## Review: PR #12\n\n**Verdict: approved, nothing blocking.**\n' > "$STUB_DIR/message.$1"; }

# ── AC1: security, heading-first, approval fresh ─────────────────────────────
reset security
labels security:approved
heading security
printf 0 > "$STUB_DIR/check-approval-sha.rc"
rn --max-iterations 1
assert_not_contains "$OUT $(cat "$ERR")" "verdict-unreadable" "AC1 a heading-first security message with a fresh stamp is not unreadable" "$OUT $(cat "$ERR")"
assert_contains "$(done_line security)" "--verdict CLEAR" "AC1 done security is called with --verdict CLEAR" "$(cat "$STUB_DIR/journal" 2>/dev/null)"

# ── AC2: reviewer -> APPROVED, adversarial -> CLEAR ──────────────────────────
for spec in "reviewer|review:approved|APPROVED" "adversarial|adversarial:approved|CLEAR"; do
  role="${spec%%|*}"; rest="${spec#*|}"; lbl="${rest%%|*}"; want="${rest#*|}"
  reset "$role"
  labels "$lbl"
  heading "$role"
  printf 0 > "$STUB_DIR/check-approval-sha.rc"
  rn --max-iterations 1
  assert_not_contains "$OUT $(cat "$ERR")" "verdict-unreadable" "AC2 $role: a heading-first message with a fresh stamp is not unreadable" "$OUT $(cat "$ERR")"
  assert_contains "$(done_line "$role")" "--verdict $want" "AC2 $role: done is called with --verdict $want" "$(cat "$STUB_DIR/journal" 2>/dev/null)"
done

# ── AC2 (stale list names only another role): still fresh ────────────────────
reset security
labels security:approved
heading security
printf 'stale role=docs approved=aaaaaaa head=bbbbbbb\n' > "$STUB_DIR/check-approval-sha.out"
printf 1 > "$STUB_DIR/check-approval-sha.rc"
rn --max-iterations 1
assert_contains "$(done_line security)" "--verdict CLEAR" "AC2 a stale list naming another role leaves security fresh" "$OUT $(cat "$ERR")"

# ── AC3: no approval label stops as today ────────────────────────────────────
reset security
printf '{"number": 12, "labels": []}' > "$STUB_DIR/view-pr.out"
heading security
printf 0 > "$STUB_DIR/check-approval-sha.rc"
rn --max-iterations 1
assert_contains "$OUT $(cat "$ERR")" "dispatch-failed role=security reason=verdict-unreadable" "AC3 no security:approved label stops verdict-unreadable" "$OUT $(cat "$ERR")"
assert_eq "" "$(done_line security)" "AC3 done is not called"

# ── AC4: stale, unreadable list, view-pr failure all stop ────────────────────
reset security
labels security:approved
heading security
printf 'stale role=security approved=aaaaaaa head=bbbbbbb\n' > "$STUB_DIR/check-approval-sha.out"
printf 1 > "$STUB_DIR/check-approval-sha.rc"
rn --max-iterations 1
assert_contains "$OUT $(cat "$ERR")" "dispatch-failed role=security reason=verdict-unreadable" "AC4 a stale list naming security stops verdict-unreadable" "$OUT $(cat "$ERR")"

reset security
labels security:approved
heading security
printf 1 > "$STUB_DIR/check-approval-sha.rc"
rn --max-iterations 1
assert_contains "$OUT $(cat "$ERR")" "dispatch-failed role=security reason=verdict-unreadable" "AC4 an unreadable stale list stops verdict-unreadable" "$OUT $(cat "$ERR")"

reset security
labels security:approved
heading security
printf 0 > "$STUB_DIR/check-approval-sha.rc"
printf 1 > "$STUB_DIR/view-pr.rc"
rn --max-iterations 1
assert_contains "$OUT $(cat "$ERR")" "dispatch-failed role=security reason=verdict-unreadable" "AC4 a view-pr failure stops verdict-unreadable" "$OUT $(cat "$ERR")"

# ── AC5: a verdict word wins over the label ──────────────────────────────────
reset security
labels security:approved
printf 'FINDINGS: 2\n\nsome findings\n' > "$STUB_DIR/message.security"
printf 0 > "$STUB_DIR/check-approval-sha.rc"
rn --max-iterations 1
assert_contains "$(done_line security)" "--verdict FINDINGS" "AC5 FINDINGS is read though security:approved is fresh" "$OUT $(cat "$ERR")"
assert_not_contains "$(done_line security)" "--verdict CLEAR" "AC5 the label never overrides a verdict word"

# ── AC6: qa gets no fallback ─────────────────────────────────────────────────
reset qa
labels qa:pass
heading qa
printf 0 > "$STUB_DIR/check-approval-sha.rc"
rn --max-iterations 1
assert_contains "$OUT $(cat "$ERR")" "dispatch-failed role=qa reason=verdict-unreadable" "AC6 a qa message without a verdict word stays unreadable" "$OUT $(cat "$ERR")"

finish
