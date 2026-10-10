#!/usr/bin/env bash
# AC13 (#336, #547): the playbook's per-role model rule carries the alias rule
# (map a full ID to its family alias when the Agent tool accepts only aliases),
# passes no full IDs in its examples, and describes the layered resolution (role
# key, agents.model, session model; project over user-level). The one-line rule
# sits in the core's Spawning paragraph; the full statement is the "Native path
# detail" paragraph of skills/pipeline/refs/harness.md.
set -u
. "$(dirname "$0")/helpers.sh"

SKILL_MD="$TALOS_ROOT/skills/pipeline/SKILL.md"
HARNESS="$TALOS_ROOT/skills/pipeline/refs/harness.md"

core="$(sed -n '/^\*\*Spawning (native path/,/^---$/p' "$SKILL_MD" | tr '\n' ' ' | tr -s ' ')"
if [ -z "$core" ]; then
  fail "SKILL.md carries a Spawning paragraph" "paragraph not found"
else
  pass "SKILL.md carries a Spawning paragraph"
fi
assert_contains "$core" "only aliases" "core: covers a harness whose Agent tool accepts only aliases"
assert_contains "$core" "family alias" "core: maps a full ID to its family alias"
assert_contains "$core" "opus" "core: names the opus alias"
assert_contains "$core" "sonnet" "core: names the sonnet alias"
assert_contains "$core" "haiku" "core: names the haiku alias"
assert_contains "$core" "session model" "core: unset means the session model is inherited"
assert_contains "$core" "ref=harness" "core: points a non-native role at the harness ref"

block="$(sed -n '/^\*\*Native path detail\./p' "$HARNESS")"
if [ -z "$block" ]; then
  fail "harness ref carries a Native path detail paragraph" "paragraph not found"
else
  pass "harness ref carries a Native path detail paragraph"
fi
flat="$(printf '%s' "$block" | tr '\n' ' ' | tr -s ' ')"

assert_contains "$flat" "only aliases" "model block: covers a harness whose Agent tool accepts only aliases"
assert_contains "$flat" "family alias" "model block: maps a full ID to its family alias"
assert_contains "$flat" "opus" "model block: names the opus alias"
assert_contains "$flat" "sonnet" "model block: names the sonnet alias"
assert_contains "$flat" "haiku" "model block: names the haiku alias"
assert_contains "$flat" "config value itself is never rewritten" "model block: config values pass through unchanged"
assert_not_contains "$flat" "claude-haiku-4-5-20251001" "model block: examples no longer pass a full haiku ID"
assert_not_contains "$flat" "claude-opus-5" "model block: examples no longer pass a full opus ID"
assert_contains "$flat" "user-level" "model block: names the user-level config layer"
assert_contains "$flat" "project config wins" "model block: project config wins over the user-level layer"
assert_contains "$flat" "session model" "model block: unset means the session model is inherited"
assert_contains "$flat" "no \`model:\` line" "model block: states the agent files carry no model: line"
assert_contains "$flat" "--resolve-all" "model block: points at --resolve-all to see the routing"
assert_not_contains "$flat" "(current behaviour)" "model block: dropped the stale 'current behaviour' wording"

restamp="$(grep -n '^- Model:' "$TALOS_ROOT/skills/pipeline/refs/restamp.md")"
assert_contains "$restamp" "restamp_model" "re-stamp model bullet: names the restamp_model chain"
assert_contains "$restamp" "user-level" "re-stamp model bullet: chain is evaluated on the layered config"

finish
