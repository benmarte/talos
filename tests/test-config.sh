#!/usr/bin/env bash
# Regression tests for pipeline-config.sh — key lookup, defaults, type coercion.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"

# JSON config works without PyYAML, so it is the baseline format for tests.
cat > .claude-pipeline.json <<'EOF'
{
  "merge": {"method": "rebase"},
  "board": {"enabled": true, "project_number": 7},
  "notifications": {"slack_channel": "C0TEST", "events": ["merged", "blocked"]},
  "roles": {"qa": false}
}
EOF

assert_eq "rebase"  "$(bash "$CFG_SH" merge.method squash)"          "nested key lookup"
assert_eq "true"    "$(bash "$CFG_SH" board.enabled false)"          "bool normalised to lowercase string"
assert_eq "false"   "$(bash "$CFG_SH" roles.qa true)"                "false bool wins over default"
assert_eq "7"       "$(bash "$CFG_SH" board.project_number "")"      "numeric value"
assert_eq "C0TEST"  "$(bash "$CFG_SH" notifications.slack_channel)"  "string value, no default arg"
assert_eq "$(printf 'merged\nblocked')" "$(bash "$CFG_SH" notifications.events "")" \
  "list returned newline-separated"
assert_eq "fallback" "$(bash "$CFG_SH" no.such.key fallback)"        "missing key returns default"
assert_eq ""        "$(bash "$CFG_SH" no.such.key)"                  "missing key, no default → empty"

# PIPELINE_CONFIG env var takes priority over local files
mkdir -p elsewhere
cat > elsewhere/other.json <<'EOF'
{"merge": {"method": "merge"}}
EOF
assert_eq "merge" "$(PIPELINE_CONFIG="$SANDBOX/elsewhere/other.json" bash "$CFG_SH" merge.method squash)" \
  "PIPELINE_CONFIG env var overrides local config"

# No config anywhere → default
rm .claude-pipeline.json
assert_eq "squash" "$(bash "$CFG_SH" merge.method squash)" "no config file returns default"

# Corrupt config never crashes
echo "{ not json" > .claude-pipeline.json
assert_eq "safe" "$(bash "$CFG_SH" merge.method safe)" "corrupt config returns default"
rm .claude-pipeline.json

# YAML path (only when PyYAML is available — matches script behaviour)
if python3 -c "import yaml" 2>/dev/null; then
  cat > .claude-pipeline.yaml <<'EOF'
merge:
  method: rebase
verify:
  - npm test
  - npm run lint
EOF
  assert_eq "rebase" "$(bash "$CFG_SH" merge.method squash)" "yaml nested key"
  assert_eq "$(printf 'npm test\nnpm run lint')" "$(bash "$CFG_SH" verify "")" "yaml list"
else
  echo "  skip: PyYAML not installed — yaml cases skipped"
fi

finish
