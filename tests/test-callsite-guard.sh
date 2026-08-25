#!/usr/bin/env bash
# test-callsite-guard.sh — verify that the canonical comment-issue and comment-pr
# lines in skills/pipeline/SKILL.md carry explicit || { } guards (issue #83).
#
# Covers 1 [test] acceptance criterion:
#   The canonical capture forms each include an explicit || { ... } guard —
#   verifiable by grep: lines with comment-issue or comment-pr that also have || {
#   must number at least 2 (one per verb).
set -u
. "$(dirname "$0")/helpers.sh"

SKILL="$TALOS_ROOT/skills/pipeline/SKILL.md"

# ── Canonical guard presence ─────────────────────────────────────────────────
# Both canonical COMMENT_URL capture forms must carry an explicit || { guard.
# If someone removes a guard this test goes RED — that is intentional.

count=$(grep '|| {' "$SKILL" | grep -c 'comment-issue\|comment-pr')
assert_eq "2" "$count" \
  "SKILL.md canonical comment lines carry || { guards (expected 2, one per verb)"

# Spot-check: the comment-issue guard line contains the expected verb
assert_contains \
  "$(grep '|| {' "$SKILL" | grep 'comment-issue')" \
  "comment-issue" \
  "SKILL.md comment-issue canonical line has || { guard"

# Spot-check: the comment-pr guard line contains the expected verb
assert_contains \
  "$(grep '|| {' "$SKILL" | grep 'comment-pr')" \
  "comment-pr" \
  "SKILL.md comment-pr canonical line has || { guard"

finish
