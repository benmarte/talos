#!/usr/bin/env bash
# tests/test-docs-149-config-examples.sh
# Verifies that the three config examples added in #149 parse correctly.
#
# Strategy: use a sentinel default (__MISS__) that cannot be a real config
# value.  If the file fails to parse, pipeline-config.sh returns the caller's
# default silently -- the sentinel makes that visible as a test failure.
#
# The test also deliberately corrupts each example and asserts the check goes
# RED, proving the sentinel approach actually catches bad config.
#
# Usage: bash tests/test-docs-149-config-examples.sh
#        (or via tests/run-tests.sh)

set -u

PASS=0
FAIL=0
SENTINEL="__MISS__"

# Resolve paths relative to this script's location.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_SH="$REPO_ROOT/scripts/pipeline-config.sh"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

ok() {
  printf 'ok: %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ] && [ "$actual" != "$SENTINEL" ]; then
    ok "$label"
  else
    fail "$label -- expected '$expected', got '$actual'"
  fi
}

assert_not_eq() {
  local label="$1" bad="$2" actual="$3"
  if [ "$actual" != "$bad" ]; then
    ok "$label (RED -- corrupted config rejected)"
  else
    fail "$label -- sentinel check passed but should have failed (got '$actual')"
  fi
}

# ── 1. issues.label_filter ────────────────────────────────────────────────────

GOOD_LABEL="$SCRATCH/label_filter_good.yml"
cat > "$GOOD_LABEL" <<'EOF'
issues:
  label_filter: "team:alice"
EOF

actual=$(PIPELINE_CONFIG="$GOOD_LABEL" bash "$CONFIG_SH" issues.label_filter "$SENTINEL")
assert_eq "label_filter: correct value from good config" "team:alice" "$actual"

# Corruption: wrong key path (issus instead of issues).
CORRUPT_LABEL="$SCRATCH/label_filter_corrupt.yml"
cat > "$CORRUPT_LABEL" <<'EOF'
issus:
  label_filter: "team:alice"
EOF

actual=$(PIPELINE_CONFIG="$CORRUPT_LABEL" bash "$CONFIG_SH" issues.label_filter "$SENTINEL")
assert_not_eq "label_filter: sentinel returned for corrupted config" "team:alice" "$actual"

# ── 2. execution.isolation ────────────────────────────────────────────────────

GOOD_ISO="$SCRATCH/isolation_good.yml"
cat > "$GOOD_ISO" <<'EOF'
execution:
  isolation: branch
EOF

actual=$(PIPELINE_CONFIG="$GOOD_ISO" bash "$CONFIG_SH" execution.isolation "$SENTINEL")
assert_eq "isolation: correct value from good config" "branch" "$actual"

# Corruption: stray character makes the YAML invalid.
CORRUPT_ISO="$SCRATCH/isolation_corrupt.yml"
cat > "$CORRUPT_ISO" <<'EOF'
execution:
  isolation: branch
  : bad_key
EOF

actual=$(PIPELINE_CONFIG="$CORRUPT_ISO" bash "$CONFIG_SH" execution.isolation "$SENTINEL")
assert_not_eq "isolation: sentinel returned for corrupted config" "branch" "$actual"

# ── 3. agents.roles.<role>.model (reviewer) ───────────────────────────────────

GOOD_MODEL="$SCRATCH/model_good.yml"
cat > "$GOOD_MODEL" <<'EOF'
agents:
  model: claude-haiku-4-5-20251001
  roles:
    reviewer:
      model: claude-opus-5
    security:
      model: claude-opus-5
EOF

actual=$(PIPELINE_CONFIG="$GOOD_MODEL" bash "$CONFIG_SH" agents.roles.reviewer.model "$SENTINEL")
assert_eq "roles.reviewer.model: correct value from good config" "claude-opus-5" "$actual"

actual=$(PIPELINE_CONFIG="$GOOD_MODEL" bash "$CONFIG_SH" agents.model "$SENTINEL")
assert_eq "agents.model: correct global default from same config" "claude-haiku-4-5-20251001" "$actual"

# Corruption: wrong key path (agents.role instead of agents.roles).
CORRUPT_MODEL="$SCRATCH/model_corrupt.yml"
cat > "$CORRUPT_MODEL" <<'EOF'
agents:
  model: claude-haiku-4-5-20251001
  role:
    reviewer:
      model: claude-opus-5
EOF

actual=$(PIPELINE_CONFIG="$CORRUPT_MODEL" bash "$CONFIG_SH" agents.roles.reviewer.model "$SENTINEL")
assert_not_eq "roles.reviewer.model: sentinel returned for corrupted config" "claude-opus-5" "$actual"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
