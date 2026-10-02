#!/usr/bin/env bash
# AC8 (#336): skills/pipeline-setup/SKILL.md asks how models are assigned
# (one model for every role / per role / leave unset), writes the answer to the
# user-level Talos config by default, shows the current routing when one
# exists (keep / change / override for this repo only) and never overwrites an
# existing user-level file without showing the diff and getting a yes.
# Pins the skill text, in the style of test-per-role-effort-skill.sh.
set -u
. "$(dirname "$0")/helpers.sh"

SETUP_MD="$TALOS_ROOT/skills/pipeline-setup/SKILL.md"

section="$(sed -n '/^## Step 6c/,/^## Step 7/p' "$SETUP_MD")"
if [ -z "$section" ]; then
  fail "setup skill carries a Step 6c model section" "section not found"
else
  pass "setup skill carries a Step 6c model section"
fi
flat="$(printf '%s' "$section" | tr '\n' ' ' | tr -s ' ')"

# The question and its three answers
assert_contains "$flat" "One model for every role" "6c offers: one model for every role"
assert_contains "$flat" "agents.model" "6c: the one-model answer writes agents.model"
assert_contains "$flat" "Per role" "6c offers: per role"
assert_contains "$flat" "agents.roles.<role>.model" "6c: the per-role answer writes agents.roles.<role>.model"
assert_contains "$flat" "roles enabled in this setup" "6c: per-role walks only the roles enabled in this setup"
assert_contains "$flat" "fallback" "6c: per-role keeps agents.model as the fallback for the rest"
assert_contains "$flat" "Leave unset" "6c offers: leave unset"
assert_contains "$flat" "inherits the session model" "6c: unset means every role inherits the session model"
assert_contains "$flat" "writes nothing" "6c: leave unset writes nothing"
assert_contains "$flat" "opus, sonnet or haiku" "6c names the aliases"
assert_contains "$flat" "full model ID" "6c allows a full model ID"

# Where it is written
assert_contains "$flat" '${TALOS_HOME:-$HOME/.talos}' "6c: default destination is the user-level directory"
assert_contains "$flat" "applies to every repo" "6c: explains the user-level file applies to every repo"

# Existing routing
assert_contains "$flat" "pipeline-agent.sh --resolve-all" "6c shows the --resolve-all table when a routing exists"
assert_contains "$flat" "Keep" "6c existing routing: keep"
assert_contains "$flat" "Change" "6c existing routing: change"
assert_contains "$flat" "Override for this repo only" "6c existing routing: override for this repo only"
assert_contains "$flat" "default" "6c marks keep as the default"

# Never overwrite silently
assert_contains "$flat" "diff" "6c shows a diff before changing an existing user-level file"
assert_contains "$flat" "explicit yes" "6c requires an explicit yes before writing an existing user-level file"
assert_contains "$flat" "Never overwrite" "6c states the never-overwrite rule"

# Step 7 picks up a per-repo override
step7="$(sed -n '/^## Step 7/,/^## Step 8 /p' "$SETUP_MD")"
assert_contains "$step7" "Step 6c" "Step 7 refers back to Step 6c for a per-repo model override"

finish
