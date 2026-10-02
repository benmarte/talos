#!/usr/bin/env bash
# AC13 (#336): skills/pipeline/SKILL.md's per-role model block carries the
# alias rule (map a full ID to its family alias when the Agent tool accepts only
# aliases), no longer passes full IDs in its examples, and describes the layered
# resolution (role key, agents.model, session model; project over user-level).
set -u
. "$(dirname "$0")/helpers.sh"

SKILL_MD="$TALOS_ROOT/skills/pipeline/SKILL.md"
block="$(sed -n '/Per-role model selection (native path/,/Per-role effort selection (native path/p' "$SKILL_MD")"
if [ -z "$block" ]; then
  fail "SKILL.md carries a Per-role model selection block" "block not found"
else
  pass "SKILL.md carries a Per-role model selection block"
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

restamp="$(grep -n '^- Model: resolve `agents.roles.<role>.restamp_model`' "$SKILL_MD")"
assert_contains "$restamp" "user-level" "re-stamp model bullet: chain is evaluated on the layered config"

finish
