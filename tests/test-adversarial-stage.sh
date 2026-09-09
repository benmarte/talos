#!/usr/bin/env bash
# tests/test-adversarial-stage.sh -- optional adversarial pre-merge stage (#237).
#
# (a) Contract/known-keys/bootstrap parity: adversarial rides the same
#     generic machinery every other role/label already uses (TALOS_ROLES,
#     TALOS_APPROVAL_ROLES/LABELS, _KNOWN_CONFIG_KEYS_JSON,
#     bootstrap-labels.sh's generic array iteration) -- these three existing
#     test files already exercise that machinery end-to-end. Re-running them
#     here proves the role is wired in without duplicating their assertions.
# (b) e2e stub, tests/test-e2e-pipeline.sh style: disabled (absent) -> zero
#     adversarial dispatches, merge gate never looks at the label; enabled +
#     agents.roles.adversarial.runner: custom with a stub runner_cmd ->
#     exactly one dispatch through pipeline-agent.sh adversarial, after
#     security, and the prompt the stub receives carries the profile's
#     embedded checklist + the #237 skill list; post-approval applies
#     adversarial:approved; check-approval-sha validates it like the other
#     roles, including staleness on a scripts/ change.
set -u
. "$(dirname "$0")/helpers.sh"

# ═══════════════════════════════════════════════════════════════════════════
# (a) contract / known-keys / bootstrap parity
# ═══════════════════════════════════════════════════════════════════════════
for _t in test-contract.sh test-config-known-keys-guard.sh test-status-labels.sh; do
  if bash "$TALOS_ROOT/tests/$_t" >/dev/null 2>&1; then
    pass "$_t passes with adversarial wired into the contract"
  else
    fail "$_t passes with adversarial wired into the contract" \
      "run 'bash tests/$_t' directly for the failing assertion"
  fi
done

make_sandbox
use_stubs
install_talos

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
AGENT="$HOME/.talos/scripts/pipeline-agent.sh"
CFG="$TALOS_ROOT/scripts/pipeline-config.sh"

git config user.email "test@talos.invalid"
git config user.name "talos-test"

# ═══════════════════════════════════════════════════════════════════════════
# (b) dispatch decision: roles.adversarial gates Step 3e Phase 3
# ═══════════════════════════════════════════════════════════════════════════
DISPATCH_LOG="$SANDBOX/dispatch.log"

# Mirrors skills/pipeline/SKILL.md Step 3e Phase 2/3: security always
# dispatches, then adversarial dispatches only when roles.adversarial =
# true (default false) -- same simulate_* pattern
# tests/test-e2e-pipeline.sh already uses for the parts of the orchestrator
# playbook that are prose, not executable code.
ADV_PROMPT=""
simulate_phase2_and_3() {
  echo "dispatch:security" >> "$DISPATCH_LOG"
  local enabled
  enabled="$(bash "$CFG" roles.adversarial false)"
  if [ "$enabled" = "true" ]; then
    echo "dispatch:adversarial" >> "$DISPATCH_LOG"
    ADV_PROMPT="$(bash "$AGENT" adversarial - <<'PROMPT'
You are the Adversarial Reviewer. QA, review, and security passed PR #9 for issue #7.
PROMPT
)"
  fi
}

# ── Disabled (absent): zero adversarial dispatches ──────────────────────────
: > "$DISPATCH_LOG"
simulate_phase2_and_3
assert_eq "1" "$(grep -c '^dispatch:security$' "$DISPATCH_LOG")" \
  "roles.adversarial absent: security still dispatches"
assert_eq "0" "$(grep -c '^dispatch:adversarial$' "$DISPATCH_LOG")" \
  "roles.adversarial absent: zero adversarial dispatches"

# Merge gate ignores the label when disabled: check-approval-sha exits 0
# with only the always-on qa:pass label present -- adversarial:approved is
# never in the labels set, so it is simply never evaluated.
_deadbeef_sha="deadbeef00000000000000000000000000000000"
out="$(STUB_PR_HEAD_SHA="$_deadbeef_sha" \
       STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]' \
       STUB_PR_COMMENTS_JSON="[{\"body\":\"<!-- talos:approval sha=${_deadbeef_sha} role=qa -->\"}]" \
       bash "$VCS" check-approval-sha 9 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "roles.adversarial absent: merge gate ignores adversarial:approved entirely"
assert_not_contains "$out" "adversarial" \
  "roles.adversarial absent: check-approval-sha output never mentions adversarial"

# ── Enabled + custom runner: exactly one dispatch, after security ──────────
cat > talos.pipeline.json <<'EOF'
{"roles": {"adversarial": true},
 "agents": {"roles": {"adversarial": {"runner": "custom", "runner_cmd": "cat"}}}}
EOF
: > "$DISPATCH_LOG"
simulate_phase2_and_3
assert_eq "1" "$(grep -c '^dispatch:adversarial$' "$DISPATCH_LOG")" \
  "roles.adversarial=true: adversarial dispatched exactly once"
assert_eq "dispatch:security
dispatch:adversarial" "$(cat "$DISPATCH_LOG")" \
  "roles.adversarial=true: adversarial dispatched after security"

# The stub runner_cmd receives the profile body + task prompt combined
# (pipeline-agent.sh's own contract) -- assert the profile's embedded
# checklist and skill list actually reached it, not just that a dispatch
# happened. Flattened (newline-collapsed) first, same as the profile
# self-containment check in tests/test-skill-names.sh, since markdown
# wrapping puts some phrases across a line break.
ADV_PROMPT_FLAT="$(printf '%s' "$ADV_PROMPT" | tr '\n' ' ' | tr -s ' ')"
assert_contains "$ADV_PROMPT_FLAT" "revert-in-mind" \
  "adversarial dispatch prompt carries embedded checklist step: revert-in-mind"
assert_contains "$ADV_PROMPT_FLAT" "3 inputs that should match" \
  "adversarial dispatch prompt carries embedded checklist step: 3 inputs that should match"
assert_contains "$ADV_PROMPT_FLAT" "secret-shaped strings" \
  "adversarial dispatch prompt carries embedded checklist step: secret-shaped strings"
assert_contains "$ADV_PROMPT_FLAT" "agent-skills:doubt-driven-development" \
  "adversarial dispatch prompt carries the #237 skill list (agent-skills)"
assert_contains "$ADV_PROMPT_FLAT" "testing-llm-gated-pipelines" \
  "adversarial dispatch prompt carries the #237 skill list (local skill)"
assert_contains "$ADV_PROMPT_FLAT" "QA, review, and security passed PR #9 for issue #7." \
  "adversarial dispatch prompt carries the task prompt appended after the profile"

# ═══════════════════════════════════════════════════════════════════════════
# post-approval applies adversarial:approved; check-approval-sha validates it
# ═══════════════════════════════════════════════════════════════════════════
_adv_sha="cafebabe00000000000000000000000000000001"

: > "$GH_LOG"
out="$(STUB_PR_HEAD_SHA="$_adv_sha" bash "$VCS" post-approval 9 adversarial 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "post-approval 9 adversarial: exits 0"
assert_contains "$(cat "$GH_LOG")" "pr edit 9 --add-label adversarial:approved" \
  "post-approval 9 adversarial: applies the adversarial:approved label"
assert_contains "$(cat "$GH_LOG")" "sha=${_adv_sha} role=adversarial" \
  "post-approval 9 adversarial: marker carries role=adversarial"

# Once applied, check-approval-sha treats adversarial:approved like every
# other role's label -- current SHA passes.
_c_adv="[{\"body\":\"<!-- talos:approval sha=${_adv_sha} role=adversarial -->\"}]"
out="$(STUB_PR_HEAD_SHA="$_adv_sha" \
       STUB_PR_LABELS_JSON='[{"name":"adversarial:approved"}]' \
       STUB_PR_COMMENTS_JSON="$_c_adv" \
       bash "$VCS" check-approval-sha 9 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "adversarial:approved at current head: check-approval-sha exits 0"
assert_contains "$out" "all approval labels are current" \
  "adversarial:approved at current head: reports current"

# Invalid role list now names adversarial too (post-approval's role guard is
# derived from the contract, same as every other role).
out_bad="$(STUB_PR_HEAD_SHA="$_adv_sha" bash "$VCS" post-approval 9 badrole 2>&1)"
assert_contains "$out_bad" "adversarial" \
  "post-approval invalid-role message names adversarial as a valid role"

# ── Staleness: a scripts/ change since the adversarial approval SHA blocks
#    the merge (hard-coded non-waivable prefix), exactly like qa/reviewer/
#    security/docs. ────────────────────────────────────────────────────────
printf 'initial\n' > feature.txt
git add feature.txt
git commit -q -m "initial"
BASE_SHA="$(git rev-parse HEAD)"
mkdir -p scripts
printf '#!/bin/bash\n# stub\n' > scripts/fake.sh
git add scripts/fake.sh
git commit -q -m "scripts: add fake helper"
HEAD_SHA="$(git rev-parse HEAD)"

_c_stale="[{\"body\":\"<!-- talos:approval sha=${BASE_SHA} role=adversarial -->\"}]"
out="$(STUB_PR_HEAD_SHA="$HEAD_SHA" \
       STUB_PR_LABELS_JSON='[{"name":"adversarial:approved"}]' \
       STUB_PR_COMMENTS_JSON="$_c_stale" \
       bash "$VCS" check-approval-sha 9 --stale-list 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "adversarial:approved stale after scripts/ change: exits 1"
assert_contains "$out" "STALE adversarial:approved" \
  "adversarial:approved stale after scripts/ change: names the stale label"
assert_contains "$out" "stale role=adversarial label=adversarial:approved" \
  "adversarial:approved stale after scripts/ change: --stale-list greppable line"

finish
