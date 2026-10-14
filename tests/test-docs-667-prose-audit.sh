#!/usr/bin/env bash
# test-docs-667-prose-audit.sh -- the statements of the v0.19.0 prose audit (#667) match the code.
set -u
. "$(dirname "$0")/helpers.sh"

R="$TALOS_ROOT"
REF="$R/docs/reference.md"
SKP="$R/skills/pipeline/SKILL.md"
SKS="$R/skills/setup/SKILL.md"
EX="$R/talos.pipeline.json.example"

has() { grep -qF -- "$2" "$R/$1"; }
# ok <name> <file> <present|absent> <text>
ok() {
  local name="$1" f="$2" want="$3" text="$4"
  if [ "$want" = present ]; then
    if has "$f" "$text"; then pass "$name"; else fail "$name"; fi
  else
    if has "$f" "$text"; then fail "$name"; else pass "$name"; fi
  fi
}

# AC1 stage profiles describe the draft order
for f in reviewer security; do
  ok "AC1 agents/$f.md drops 'Gated behind QA pass'" agents/$f.md absent 'Gated behind QA pass'
  ok "AC1 agents/$f.md drops 'QA has passed'" agents/$f.md absent 'QA has passed'
  ok "AC1 agents/$f.md says it runs before QA on a draft PR" agents/$f.md present 'runs before QA'
done
ok "AC1 agents/docs.md drops 'Terminal stage'" agents/docs.md absent 'Terminal stage'
ok "AC1 agents/docs.md drops 'the terminal stage'" agents/docs.md absent 'the terminal stage'
ok "AC1 agents/docs.md says second in the approval order" agents/docs.md present 'second in the approval order'
for f in reviewer security docs adversarial; do
  ok "AC1 agents/$f.md drops 'QA and CI already did'" agents/$f.md absent 'QA and CI already did'
done
ok "AC1 agents/adversarial.md drops 'have already passed' for QA" agents/adversarial.md absent 'QA, review, and security have already'
ok "AC1 agents/qa.md drops 'gate on qa:pass'" agents/qa.md absent 'gate on `qa:pass`'
ok "AC1 agents/qa.md says draft stages run before QA" agents/qa.md present 'run before it'

# AC2 parallel is the LLM loop only
ok "AC2 reference drops '(parallel)' in the default order" docs/reference.md absent 'reviewer and security (parallel)'
ok "AC2 reference drops 'in parallel' in the draft order" docs/reference.md absent 'reviewer + security + adversarial in parallel'
ok "AC2 reference says parallel is only on the LLM loop" docs/reference.md present 'only on the LLM loop'
ok "AC2 README lists the draft order" README.md present 'docs, review, security, QA and a squash merge'
ok "AC2 reviewer.md drops 'security runs in parallel and'" agents/reviewer.md absent 'security runs in parallel and may have set'
ok "AC2 security.md drops 'the reviewer runs in parallel and'" agents/security.md absent 'the reviewer runs in parallel and may have'
ok "AC2 reviewer.md says parallel is the LLM loop" agents/reviewer.md present 'the LLM loop runs'
ok "AC2 security.md says parallel is the LLM loop" agents/security.md present 'the LLM loop'

# AC3 checkouts under the code driver
ok "AC3 reference drops 'One git worktree per stage and issue'" docs/reference.md absent 'One git worktree per stage and issue'
ok "AC3 reference drops the agent-* worktree claim" docs/reference.md absent 'get a Claude Code `agent-*` worktree'
ok "AC3 reference says only the LLM loop runs assert-sync" docs/reference.md present 'Only the LLM loop runs `pipeline-vcs.sh assert-sync`'
ok "AC3 reference drops 'the orchestrator runs assert-sync'" docs/reference.md absent 'the orchestrator runs `pipeline-vcs.sh assert-sync`'
ok "AC3 reference says the driver runs stages in its own checkout" docs/reference.md present "in the driver's own checkout"

# AC4 to-base, hard rule 4, install cases
ok "AC4 reference drops 'anywhere else it does nothing'" docs/reference.md absent 'anywhere else it does nothing (`kept`)'
ok "AC4 reference says a detached HEAD returns to the base" docs/reference.md present 'detached HEAD'
ok "AC4 pipeline SKILL rule 4 drops 'Every other stage'" skills/pipeline/SKILL.md absent 'Every other stage (reviewer, security, docs, QA, validator, PM) never runs'
ok "AC4 pipeline SKILL rule 4 names qa-run" skills/pipeline/SKILL.md present '`qa-run` checks out the PR'
ok "AC4 setup SKILL drops vendored install.sh case" skills/setup/SKILL.md absent 'vendored into the repo by install.sh'

# AC5 stops, exit codes, labels
ok "AC5 reference drops 'The playbook sets pipeline:blocked' for exit 69" docs/reference.md absent 'The playbook sets `pipeline:blocked` and runs no fix round'
ok "AC5 reference says provider-failed sets no label and a re-run resumes" docs/reference.md present 'sets no label'
r="$(grep -F -- 'A stage whose final message starts with `BLOCKED:' "$REF" | head -n 1)"
case "$r" in
  *reason=spec-unusable*) pass "AC5 BLOCKED paragraph names QA's spec-unusable stop" ;;
  *) fail "AC5 BLOCKED paragraph names QA's spec-unusable stop" ;;
esac
ok "AC5 reference drops 'A stop or ask-owner wait exits 0'" docs/reference.md absent 'A stop or ask-owner wait exits 0; an unreadable state exits 1'
ok "AC5 reference drops 'after the stage it is on'" docs/reference.md absent 'after the stage it is on'
ok "AC5 reference says --stop is read at the top of a pass" docs/reference.md present 'top of a pass'
ok "AC5 reference drops 'are skipped' for pipeline:blocked" docs/reference.md absent '(default `pipeline:blocked`, `wontfix`) are skipped'
r="$(grep -F -- '| `action=wait reason=owner' "$REF" | head -n 1)"
if [ -n "$r" ]; then pass "AC5 stop-reasons table has action=wait reason=owner"
else fail "AC5 stop-reasons table has action=wait reason=owner"; fi
ok "AC5 reference drops 'QA is not dispatched into a CONFLICTING PR'" docs/reference.md absent 'QA is not dispatched into a `CONFLICTING` PR'
ok "AC5 reference says qa-run refuses a CONFLICTING PR" docs/reference.md present '`qa-run` refuses'

# AC6 spec-unusable row, planner
r="$(grep -F -- '`stop reason=spec-unusable' "$SKP" | head -n 1)"
case "$r" in
  *.talos/run.err*) pass "AC6 spec-unusable row names .talos/run.err" ;;
  *) fail "AC6 spec-unusable row names .talos/run.err" ;;
esac
ok "AC6 spec-unusable row names placement" skills/pipeline/SKILL.md present 'pipeline-criteria.sh placement <N>'
ok "AC6 planner ref drops 'Then done planner'" skills/pipeline/refs/planner.md absent 'Then `done planner`'

# AC7 re-stamps and the docs gate
ok "AC7 reference drops 'A role that already approved gets a re-stamp'" docs/reference.md absent 'A role that already approved gets a re-stamp'
ok "AC7 reference says only docs gets the restamp shape" docs/reference.md present 'only docs gets `--shape restamp`'
ok "AC7 setup SKILL drops the CHANGELOG + README coverage rule" skills/setup/SKILL.md absent "when the developer's diff already covers CHANGELOG"
ok "AC7 setup SKILL describes docs-gate" skills/setup/SKILL.md present 'touches none of README.md'
ok "AC7 example _note drops the CHANGELOG coverage rule" talos.pipeline.json.example absent 'already cover CHANGELOG.md + README/docs'
ok "AC7 example _note describes docs-gate" talos.pipeline.json.example present 'touches none of README.md'

# AC8 post-merge and usage
ok "AC8 pipeline SKILL drops the changelog assemble" skills/pipeline/SKILL.md absent 'changelog assemble'
ok "AC8 llm-loop-merge drops the changelog assemble" skills/pipeline/refs/llm-loop-merge.md absent 'changelog assemble'
ok "AC8 llm-loop-merge drops the [skip ci] commit" skills/pipeline/refs/llm-loop-merge.md absent '[skip ci]'
ok "AC8 harness ref drops 'no input/output split, no model'" skills/pipeline/refs/harness.md absent 'no input/output split, no model'
ok "AC8 harness ref says only dollar cost is unrecorded" skills/pipeline/refs/harness.md present 'only dollar cost'

# AC9 config, board and README claims
ok "AC9 README drops 'and a token budget guard'" README.md absent 'and a token budget guard'
ok "AC9 README says the budget guard is opt-in" README.md present 'opt-in token budget guard'
ok "AC9 example drops 'Entries are runner names only'" talos.pipeline.json.example absent 'Entries are runner names only'
ok "AC9 example says a failover entry may be a profile name" talos.pipeline.json.example present 'may be a profile name'
ok "AC9 setup SKILL drops 'Only agents.* keys are read'" skills/setup/SKILL.md absent 'Only `agents.*` keys are read from that file'
ok "AC9 reference drops 'conventional and never set'" docs/reference.md absent 'conventional and never set'
ok "AC9 reference says five options" docs/reference.md present 'five options'
for ev in pm adversarial; do
  if grep -qxF -- "- $ev" "$SKS"; then pass "AC9 setup SKILL role events list has $ev"
  else fail "AC9 setup SKILL role events list has $ev"; fi
done
ok "AC9 setup SKILL drops the example-file events pointer" skills/setup/SKILL.md absent 'see talos.pipeline.json.example for the full list'
ok "AC9 setup SKILL drops the config-template status_map pointer" skills/setup/SKILL.md absent 'example in the config template above'

finish
