#!/usr/bin/env bash
# tests/test-docs-149-config-examples.sh
# Verifies that the three config examples added in #149 parse correctly.
#
# Strategy: use a sentinel default (__MISS__) that cannot be a real config
# value.  If the file fails to parse, pipeline-config.sh returns the caller's
# default silently -- the sentinel makes that visible as a test failure.
#
# Platform convention (same as test-config.sh): YAML assertions run only when
# PyYAML is available.  JSON equivalents of every example always run, so the
# key paths and documented values are verified on every platform including
# macOS CI where PyYAML is absent.
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

HAVE_YAML=false
python3 -c "import yaml" 2>/dev/null && HAVE_YAML=true

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
# JSON (always runs)

GOOD_LABEL_JSON="$SCRATCH/label_filter_good.json"
cat > "$GOOD_LABEL_JSON" <<'EOF'
{"issues": {"label_filter": "team:alice"}}
EOF

actual=$(PIPELINE_CONFIG="$GOOD_LABEL_JSON" bash "$CONFIG_SH" issues.label_filter "$SENTINEL")
assert_eq "label_filter/json: correct value from good config" "team:alice" "$actual"

# Corruption: wrong key path (issus instead of issues).
CORRUPT_LABEL_JSON="$SCRATCH/label_filter_corrupt.json"
cat > "$CORRUPT_LABEL_JSON" <<'EOF'
{"issus": {"label_filter": "team:alice"}}
EOF

actual=$(PIPELINE_CONFIG="$CORRUPT_LABEL_JSON" bash "$CONFIG_SH" issues.label_filter "$SENTINEL")
assert_not_eq "label_filter/json: sentinel returned for corrupted config" "team:alice" "$actual"

# YAML (only when PyYAML is available -- matches pipeline-config.sh behaviour)
if $HAVE_YAML; then
  GOOD_LABEL_YML="$SCRATCH/label_filter_good.yml"
  cat > "$GOOD_LABEL_YML" <<'EOF'
issues:
  label_filter: "team:alice"
EOF
  actual=$(PIPELINE_CONFIG="$GOOD_LABEL_YML" bash "$CONFIG_SH" issues.label_filter "$SENTINEL")
  assert_eq "label_filter/yaml: correct value from good config" "team:alice" "$actual"

  CORRUPT_LABEL_YML="$SCRATCH/label_filter_corrupt.yml"
  cat > "$CORRUPT_LABEL_YML" <<'EOF'
issus:
  label_filter: "team:alice"
EOF
  actual=$(PIPELINE_CONFIG="$CORRUPT_LABEL_YML" bash "$CONFIG_SH" issues.label_filter "$SENTINEL")
  assert_not_eq "label_filter/yaml: sentinel returned for corrupted config" "team:alice" "$actual"
else
  printf 'skip: label_filter/yaml -- PyYAML not available\n'
fi

# ── 2. execution.isolation ────────────────────────────────────────────────────
# JSON (always runs)

GOOD_ISO_JSON="$SCRATCH/isolation_good.json"
cat > "$GOOD_ISO_JSON" <<'EOF'
{"execution": {"isolation": "branch"}}
EOF

actual=$(PIPELINE_CONFIG="$GOOD_ISO_JSON" bash "$CONFIG_SH" execution.isolation "$SENTINEL")
assert_eq "isolation/json: correct value from good config" "branch" "$actual"

# Corruption: wrong key path (executon instead of execution).
CORRUPT_ISO_JSON="$SCRATCH/isolation_corrupt.json"
cat > "$CORRUPT_ISO_JSON" <<'EOF'
{"executon": {"isolation": "branch"}}
EOF

actual=$(PIPELINE_CONFIG="$CORRUPT_ISO_JSON" bash "$CONFIG_SH" execution.isolation "$SENTINEL")
assert_not_eq "isolation/json: sentinel returned for corrupted config" "branch" "$actual"

# YAML (only when PyYAML is available)
if $HAVE_YAML; then
  GOOD_ISO_YML="$SCRATCH/isolation_good.yml"
  cat > "$GOOD_ISO_YML" <<'EOF'
execution:
  isolation: branch
EOF
  actual=$(PIPELINE_CONFIG="$GOOD_ISO_YML" bash "$CONFIG_SH" execution.isolation "$SENTINEL")
  assert_eq "isolation/yaml: correct value from good config" "branch" "$actual"

  CORRUPT_ISO_YML="$SCRATCH/isolation_corrupt.yml"
  cat > "$CORRUPT_ISO_YML" <<'EOF'
execution:
  isolation: branch
  : bad_key
EOF
  actual=$(PIPELINE_CONFIG="$CORRUPT_ISO_YML" bash "$CONFIG_SH" execution.isolation "$SENTINEL")
  assert_not_eq "isolation/yaml: sentinel returned for corrupted config" "branch" "$actual"
else
  printf 'skip: isolation/yaml -- PyYAML not available\n'
fi

# ── 3. agents.roles.<role>.model ─────────────────────────────────────────────
# JSON (always runs)

GOOD_MODEL_JSON="$SCRATCH/model_good.json"
cat > "$GOOD_MODEL_JSON" <<'EOF'
{
  "agents": {
    "model": "claude-haiku-4-5-20251001",
    "roles": {
      "reviewer": {"model": "claude-opus-5"},
      "security": {"model": "claude-opus-5"}
    }
  }
}
EOF

actual=$(PIPELINE_CONFIG="$GOOD_MODEL_JSON" bash "$CONFIG_SH" agents.roles.reviewer.model "$SENTINEL")
assert_eq "roles.reviewer.model/json: correct value from good config" "claude-opus-5" "$actual"

actual=$(PIPELINE_CONFIG="$GOOD_MODEL_JSON" bash "$CONFIG_SH" agents.model "$SENTINEL")
assert_eq "agents.model/json: correct global default from same config" "claude-haiku-4-5-20251001" "$actual"

# Corruption: wrong key path (agents.role instead of agents.roles).
CORRUPT_MODEL_JSON="$SCRATCH/model_corrupt.json"
cat > "$CORRUPT_MODEL_JSON" <<'EOF'
{
  "agents": {
    "model": "claude-haiku-4-5-20251001",
    "role": {"reviewer": {"model": "claude-opus-5"}}
  }
}
EOF

actual=$(PIPELINE_CONFIG="$CORRUPT_MODEL_JSON" bash "$CONFIG_SH" agents.roles.reviewer.model "$SENTINEL")
assert_not_eq "roles.reviewer.model/json: sentinel returned for corrupted config" "claude-opus-5" "$actual"

# YAML (only when PyYAML is available)
if $HAVE_YAML; then
  GOOD_MODEL_YML="$SCRATCH/model_good.yml"
  cat > "$GOOD_MODEL_YML" <<'EOF'
agents:
  model: claude-haiku-4-5-20251001
  roles:
    reviewer:
      model: claude-opus-5
    security:
      model: claude-opus-5
EOF
  actual=$(PIPELINE_CONFIG="$GOOD_MODEL_YML" bash "$CONFIG_SH" agents.roles.reviewer.model "$SENTINEL")
  assert_eq "roles.reviewer.model/yaml: correct value from good config" "claude-opus-5" "$actual"

  actual=$(PIPELINE_CONFIG="$GOOD_MODEL_YML" bash "$CONFIG_SH" agents.model "$SENTINEL")
  assert_eq "agents.model/yaml: correct global default from same config" "claude-haiku-4-5-20251001" "$actual"

  CORRUPT_MODEL_YML="$SCRATCH/model_corrupt.yml"
  cat > "$CORRUPT_MODEL_YML" <<'EOF'
agents:
  model: claude-haiku-4-5-20251001
  role:
    reviewer:
      model: claude-opus-5
EOF
  actual=$(PIPELINE_CONFIG="$CORRUPT_MODEL_YML" bash "$CONFIG_SH" agents.roles.reviewer.model "$SENTINEL")
  assert_not_eq "roles.reviewer.model/yaml: sentinel returned for corrupted config" "claude-opus-5" "$actual"
else
  printf 'skip: agents.roles/yaml -- PyYAML not available\n'
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
