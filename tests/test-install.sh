#!/usr/bin/env bash
# Regression tests for install.sh — layout, template shipping, --force semantics.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

out="$(bash "$TALOS_ROOT/install.sh" "$SANDBOX")"

for s in pipeline-config.sh pipeline-status.sh pipeline-notify.sh pipeline-vcs.sh bootstrap-labels.sh; do
  assert_file_exists ".claude/talos/scripts/$s" "installs $s"
done
[ -x ".claude/talos/scripts/pipeline-notify.sh" ] \
  && pass "scripts are executable" || fail "scripts are executable"

assert_file_exists ".claude/talos/skills/pipeline/SKILL.md" "installs orchestrator skill"

# Templates must ship — without them notifications degrade to plain text
# (regression guard for the bug fixed in e7de0d5).
n_notif="$(ls .claude/talos/templates/notifications/*.md 2>/dev/null | wc -l | tr -d ' ')"
n_cmt="$(ls .claude/talos/templates/comments/*.md 2>/dev/null | wc -l | tr -d ' ')"
src_notif="$(ls "$TALOS_ROOT"/templates/notifications/*.md | wc -l | tr -d ' ')"
src_cmt="$(ls "$TALOS_ROOT"/templates/comments/*.md | wc -l | tr -d ' ')"
assert_eq "$src_notif" "$n_notif" "all notification templates installed ($src_notif)"
assert_eq "$src_cmt"   "$n_cmt"   "all comment templates installed ($src_cmt)"

for agent in validator pm developer qa reviewer security docs planner; do
  assert_file_exists ".claude/agents/$agent.md" "installs $agent agent"
done

# Second run without --force must not overwrite
echo "LOCAL EDIT" >> .claude/talos/scripts/pipeline-notify.sh
out2="$(bash "$TALOS_ROOT/install.sh" "$SANDBOX")"
assert_contains "$out2" "skip (exists)" "re-install without --force skips existing files"
assert_contains "$(tail -1 .claude/talos/scripts/pipeline-notify.sh)" "LOCAL EDIT" \
  "local edit preserved without --force"

# --force overwrites
bash "$TALOS_ROOT/install.sh" "$SANDBOX" --force >/dev/null
assert_not_contains "$(tail -1 .claude/talos/scripts/pipeline-notify.sh)" "LOCAL EDIT" \
  "--force overwrites local edit"

# Legacy .claude/pipeline layout triggers a migration note (files untouched)
mkdir -p .claude/pipeline/scripts && echo "old" > .claude/pipeline/scripts/keep.sh
out3="$(bash "$TALOS_ROOT/install.sh" "$SANDBOX" --force)"
assert_contains "$out3" "legacy install detected" "legacy .claude/pipeline triggers migration note"
assert_file_exists ".claude/pipeline/scripts/keep.sh" "legacy dir is never deleted automatically"

# Missing target errors
if bash "$TALOS_ROOT/install.sh" "$SANDBOX/does-not-exist" >/dev/null 2>&1; then
  fail "missing target dir exits non-zero"
else
  pass "missing target dir exits non-zero"
fi

# Marketplace manifest exists in Talos source root and is valid JSON with plugins[0].name == "talos"
assert_file_exists "$TALOS_ROOT/.claude-plugin/marketplace.json" \
  ".claude-plugin/marketplace.json exists in source repo"
if python3 -c "
import json, sys
with open('$TALOS_ROOT/.claude-plugin/marketplace.json') as f:
    data = json.load(f)
assert data['plugins'][0]['name'] == 'talos', 'plugins[0].name must be talos'
" 2>/dev/null; then
  pass "marketplace.json is valid JSON with plugins[0].name == talos"
else
  fail "marketplace.json is valid JSON with plugins[0].name == talos"
fi

finish
