#!/usr/bin/env bash
# Regression tests for pipeline-config.sh — key lookup, defaults, type coercion.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"

# JSON config works without PyYAML, so it is the baseline format for tests.
cat > talos.pipeline.json <<'EOF'
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
rm talos.pipeline.json
assert_eq "squash" "$(bash "$CFG_SH" merge.method squash)" "no config file returns default"

# Corrupt config never crashes
echo "{ not json" > talos.pipeline.json
assert_eq "safe" "$(bash "$CFG_SH" merge.method safe)" "corrupt config returns default"
rm talos.pipeline.json

# YAML path (only when PyYAML is available — matches script behaviour)
if python3 -c "import yaml" 2>/dev/null; then
  cat > talos.pipeline.yml <<'EOF'
merge:
  method: rebase
verify:
  - npm test
  - npm run lint
EOF
  assert_eq "rebase" "$(bash "$CFG_SH" merge.method squash)" "yaml nested key"
  assert_eq "$(printf 'npm test\nnpm run lint')" "$(bash "$CFG_SH" verify "")" "yaml list"
  rm talos.pipeline.yml
else
  echo "  skip: PyYAML not installed — yaml cases skipped"
fi

# Legacy config names still honored; talos.* wins when both exist
cat > .claude-pipeline.json <<'EOF'
{"merge": {"method": "merge"}}
EOF
assert_eq "merge" "$(bash "$CFG_SH" merge.method squash)" "legacy .claude-pipeline.json still read"
cat > talos.pipeline.json <<'EOF'
{"merge": {"required_checks": ["test"]}}
EOF
assert_eq "ci" "$(bash "$CFG_SH" verify.qa_mode local)" \
  "verify.qa_mode defaults to ci when merge.required_checks is non-empty (#195)"

cat > talos.pipeline.json <<'EOF'
{"merge": {"required_checks": []}}
EOF
assert_eq "local" "$(bash "$CFG_SH" verify.qa_mode local)" \
  "verify.qa_mode defaults to local when merge.required_checks is empty (#195)"

rm talos.pipeline.json
assert_eq "local" "$(bash "$CFG_SH" verify.qa_mode local)" \
  "verify.qa_mode defaults to local when no config / merge.required_checks is absent (#195)"

# Fail-closed guard: an explicit verify.qa_mode: ci with an empty
# merge.required_checks list must not pass QA vacuously -- it resolves to
# local instead, with a one-line warning on stderr (#195 review finding 3).
cat > talos.pipeline.json <<'EOF'
{"merge": {"required_checks": []}, "verify": {"qa_mode": "ci"}}
EOF
qa_mode_out="$(bash "$CFG_SH" verify.qa_mode local 2>/tmp/qa_mode_stderr.$$)"
assert_eq "local" "$qa_mode_out" \
  "explicit verify.qa_mode: ci with empty required_checks falls back to local (#195)"
assert_contains "$(cat /tmp/qa_mode_stderr.$$)" "qa_mode=ci" \
  "empty-required_checks fallback prints a stderr warning naming the reason (#195)"
rm -f /tmp/qa_mode_stderr.$$
rm talos.pipeline.json

assert_eq "true" "$(bash "$CFG_SH" verify.targeted true)" \
  "verify.targeted defaults to true when unset (#195)"

cat > talos.pipeline.json <<'EOF'
{
  "merge": {"required_checks": ["test"]},
  "verify": {"commands": ["pytest -q"], "qa_mode": "local", "targeted": false, "ci_wait_s": 60}
}
EOF
assert_eq "local" "$(bash "$CFG_SH" verify.qa_mode ci)" \
  "an explicit verify.qa_mode wins over the required_checks-derived default (#195)"
assert_eq "false" "$(bash "$CFG_SH" verify.targeted true)" \
  "explicit verify.targeted: false overrides the true default (#195)"
assert_eq "60" "$(bash "$CFG_SH" verify.ci_wait_s 900)" \
  "explicit verify.ci_wait_s overrides the 900 default (#195)"
assert_eq "pytest -q" "$(bash "$CFG_SH" verify "")" \
  "verify dict form still returns its commands list for the plain verify key (#195)"
rm talos.pipeline.json

# ── verify.timeout_ms (#205): default, explicit override, non-integer rejection ──
assert_eq "600000" "$(bash "$CFG_SH" verify.timeout_ms 600000)" \
  "verify.timeout_ms defaults to 600000 when absent (#205)"

cat > talos.pipeline.json <<'EOF'
{"verify": {"timeout_ms": 120000}}
EOF
assert_eq "120000" "$(bash "$CFG_SH" verify.timeout_ms 600000)" \
  "explicit verify.timeout_ms overrides the 600000 default (#205)"
rm talos.pipeline.json

cat > talos.pipeline.json <<'EOF'
{"verify": {"timeout_ms": "soon"}}
EOF
assert_eq "600000" "$(bash "$CFG_SH" verify.timeout_ms 600000)" \
  "non-integer verify.timeout_ms falls back to the default (#205)"
timeout_ms_err="$(bash "$CFG_SH" verify.timeout_ms 600000 2>&1 >/dev/null)"
assert_contains "$timeout_ms_err" "must be a positive integer" \
  "non-integer verify.timeout_ms warns on stderr (#205)"
rm talos.pipeline.json

cat > talos.pipeline.json <<'EOF'
{"verify": {"timeout_ms": 0}}
EOF
assert_eq "600000" "$(bash "$CFG_SH" verify.timeout_ms 600000)" \
  "non-positive verify.timeout_ms falls back to the default (#205)"
rm talos.pipeline.json

cat > talos.pipeline.json <<'EOF'
{"merge": {"method": "rebase"}}
EOF
assert_eq "rebase" "$(bash "$CFG_SH" merge.method squash)" "talos.pipeline.json wins over legacy"
rm .claude-pipeline.json talos.pipeline.json

finish
