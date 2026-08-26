#!/usr/bin/env bash
# tests/test-marker-contract.sh
# Asserts that all four review-stage agent profiles share a byte-identical
# shared Rules block after normalising role-specific tokens.
# RED (exit 1) when any profile's block is altered; GREEN (exit 0) after all
# patches applied.
#
# Non-vacuity proof: the test counts extracted lines and asserts content against
# known-present strings before comparing hashes, so four empty strings cannot
# hash equal and silently pass.
#
# Coverage (important):
#   This test checks TWO sets of profiles:
#   1. Plugin-shipped profiles in $TALOS_ROOT/agents/{reviewer,security,qa,docs}.md
#      (always checked).
#   2. Repo-level overrides in $TALOS_ROOT/.claude/agents/{reviewer,security,qa,docs}.md
#      (checked when the file exists; skipped when absent).
#   GREEN means: every profile that IS present carries the byte-identical shared
#   Rules block.  It does NOT guarantee that a profile absent from .claude/agents/
#   will remain absent — a future addition without the contract would be caught
#   on the next test run.
#
# Mutation discipline (repo-level section):
#   Mutation that makes the override assertions fail: place a
#   .claude/agents/security.md that lacks the Rules: block or contains a
#   divergent block — the corresponding assert_eq exits 1 naming the role.
set -u
. "$(dirname "$0")/helpers.sh"

AGENTS_DIR="$TALOS_ROOT/agents"
REPO_AGENTS_DIR="$TALOS_ROOT/.claude/agents"

# ── Extraction helper ─────────────────────────────────────────────────────────
# extract_rules_block <file>
# Prints every line from "^Rules:" up to (but not including) "^Final message:".
# Then normalises the two token classes that legitimately differ per role:
#   role=<value>  →  role=ROLE
#   `<label>`     →  `LABEL`  (only the label in the "does not satisfy" bullet)
extract_rules_block() {
    local file="$1"
    awk '
        /^Rules:/        { found = 1 }
        /^Final message:/ { found = 0 }
        found            { print }
    ' "$file" \
    | sed \
        -e 's/role=reviewer/role=ROLE/g' \
        -e 's/role=security/role=ROLE/g' \
        -e 's/role=qa/role=ROLE/g' \
        -e 's/role=docs/role=ROLE/g' \
        -e 's/`review:approved`/`LABEL`/g' \
        -e 's/`security:approved`/`LABEL`/g' \
        -e 's/`qa:pass`/`LABEL`/g' \
        -e 's/`docs:done`/`LABEL`/g'
}

# ── Non-vacuity checks (always expected to pass) ──────────────────────────────
# These prove the extraction is real: four empty strings would hash equal and
# silently pass the equality test; we guard against that here.

REVIEWER_BLOCK=$(extract_rules_block "$AGENTS_DIR/reviewer.md")

# 1. Block must be non-empty.
if [ -n "$REVIEWER_BLOCK" ]; then
    pass "extract_rules_block: reviewer.md yields non-empty block"
else
    fail "extract_rules_block: reviewer.md yields non-empty block" "got empty string — awk pattern broken?"
fi

# 2. Block must contain the SHA rule (proves the right section was extracted).
case "$REVIEWER_BLOCK" in
    *"40-character lowercase SHA"*)
        pass "extracted block contains SHA rule" ;;
    *)
        fail "extracted block contains SHA rule" "missing '40-character lowercase SHA' in reviewer extract" ;;
esac

# 3. Block must contain the git rev-parse prohibition.
case "$REVIEWER_BLOCK" in
    *"Do NOT use \`git rev-parse HEAD\`"*)
        pass "extracted block contains git-rev-parse prohibition" ;;
    *)
        fail "extracted block contains git-rev-parse prohibition" "missing prohibition line in reviewer extract" ;;
esac

# 4. Block must contain the check-approval-sha confirmation step.
case "$REVIEWER_BLOCK" in
    *"check-approval-sha"*)
        pass "extracted block contains check-approval-sha step" ;;
    *)
        fail "extracted block contains check-approval-sha step" "missing check-approval-sha in reviewer extract" ;;
esac

# 5. Line count >= 6 (Rules: header + at least 5 bullets even before split patch).
line_count=$(printf '%s' "$REVIEWER_BLOCK" | grep -c '^' || true)
if [ "$line_count" -ge 6 ]; then
    pass "extracted block has >= 6 lines (non-vacuous; got $line_count)"
else
    fail "extracted block has >= 6 lines" "got $line_count — too short, extraction may be broken"
fi

# ── Hash equality: all four profiles must agree ───────────────────────────────
REVIEWER_BLOCK=$(extract_rules_block "$AGENTS_DIR/reviewer.md")
SECURITY_BLOCK=$(extract_rules_block "$AGENTS_DIR/security.md")
QA_BLOCK=$(extract_rules_block "$AGENTS_DIR/qa.md")
DOCS_BLOCK=$(extract_rules_block "$AGENTS_DIR/docs.md")

REVIEWER_HASH=$(printf '%s' "$REVIEWER_BLOCK" | sha256sum | awk '{print $1}')
SECURITY_HASH=$(printf '%s' "$SECURITY_BLOCK" | sha256sum | awk '{print $1}')
QA_HASH=$(printf '%s' "$QA_BLOCK" | sha256sum | awk '{print $1}')
DOCS_HASH=$(printf '%s' "$DOCS_BLOCK" | sha256sum | awk '{print $1}')

# Print hashes for transparency.
printf '  reviewer: %s\n' "$REVIEWER_HASH"
printf '  security: %s\n' "$SECURITY_HASH"
printf '  qa:       %s\n' "$QA_HASH"
printf '  docs:     %s\n' "$DOCS_HASH"

assert_eq "$REVIEWER_HASH" "$SECURITY_HASH" \
    "reviewer == security Rules block (byte-identical after normalisation)"
assert_eq "$REVIEWER_HASH" "$QA_HASH" \
    "reviewer == qa Rules block (byte-identical after normalisation)"
assert_eq "$REVIEWER_HASH" "$DOCS_HASH" \
    "reviewer == docs Rules block (byte-identical after normalisation)"

# ── Diff on failure (informational) ──────────────────────────────────────────
# Only runs if there was at least one hash mismatch above, to show exactly
# where the blocks differ.
if [ "$REVIEWER_HASH" != "$SECURITY_HASH" ] || \
   [ "$REVIEWER_HASH" != "$QA_HASH" ]       || \
   [ "$REVIEWER_HASH" != "$DOCS_HASH" ]; then
    SCRATCHPAD="${TMPDIR:-/tmp}"
    printf '%s' "$REVIEWER_BLOCK" > "$SCRATCHPAD/rules_reviewer.txt"
    printf '%s' "$SECURITY_BLOCK" > "$SCRATCHPAD/rules_security.txt"
    printf '%s' "$QA_BLOCK"       > "$SCRATCHPAD/rules_qa.txt"
    printf '%s' "$DOCS_BLOCK"     > "$SCRATCHPAD/rules_docs.txt"
    for other in security qa docs; do
        if [ "$(cat "$SCRATCHPAD/rules_${other}.txt" | sha256sum | awk '{print $1}')" \
             != "$REVIEWER_HASH" ]; then
            printf '\n  --- diff reviewer vs %s ---\n' "$other"
            diff "$SCRATCHPAD/rules_reviewer.txt" "$SCRATCHPAD/rules_${other}.txt" || true
        fi
    done
fi

# ── Repo-level override check ─────────────────────────────────────────────────
# When a consumer repo places .claude/agents/<role>.md, that file wins over the
# plugin-shipped copy (SKILL.md line 24).  The shipped Rules block is the
# canonical contract; every override must carry it byte-identically.
#
# Logic: iterate the four review roles.  If no override file exists, skip with a
# pass (no drift possible).  If the override exists but has no Rules: block, fail
# loudly — the most likely mistake is copying a minimal profile.  If the block
# exists, compare its hash against the canonical shipped hash.
#
# Mutation: remove this section → a bad .claude/agents/security.md passes silently.
_canonical_hash="$REVIEWER_HASH"
for _role in reviewer security qa docs; do
    _override="$REPO_AGENTS_DIR/$_role.md"
    if [ ! -f "$_override" ]; then
        pass "repo-level override absent: .claude/agents/$_role.md — skipped (no drift possible)"
        continue
    fi
    # Override exists — extract its Rules block.
    _override_block="$(extract_rules_block "$_override")"
    if [ -z "$_override_block" ]; then
        fail "repo-level override .claude/agents/$_role.md: Rules block present" \
             "Rules: block missing in override — the shared contract is absent; add it or the gate will reject stamps"
        continue
    fi
    _override_hash="$(printf '%s' "$_override_block" | sha256sum | awk '{print $1}')"
    assert_eq "$_canonical_hash" "$_override_hash" \
        "repo-level .claude/agents/$_role.md == shipped agents/$_role.md Rules block (byte-identical after normalisation)"
done

finish
