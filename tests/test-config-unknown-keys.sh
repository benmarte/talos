#!/usr/bin/env bash
# test-config-unknown-keys.sh -- covers issue #176: pipeline-config.sh warns
# on unknown talos.pipeline.* config keys (typos) instead of silently
# ignoring them and running with defaults.
#
# JSON fixtures are used for every assertion that needs a real warning to
# fire: JSON parsing is stdlib (json.load), so these assertions are genuine
# on every CI runner, including macOS runners that do not ship PyYAML (see
# tests/test-config-parse-warn.sh A6 and tests/test-docs-149-config-examples.sh
# for the same convention). A YAML fixture would silently degrade to an
# empty config there -- json.load() raises on YAML syntax, which the
# outer "unparseable config" catch-all in pipeline-config.sh turns into
# cfg = {}, so no keys are ever seen and the warning never fires. A
# PyYAML-gated supplementary case (9) keeps the YAML code path covered
# where PyYAML is actually available.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"

HAVE_YAML=false
python3 -c "import yaml" 2>/dev/null && HAVE_YAML=true

# ---- 1: top-level typo warns with a nearest-match suggestion ---------------
cat > talos.pipeline.json <<'EOF'
{"limts": {"max_fix_attempts": 3}}
EOF
err1="$(bash "$CFG_SH" --dump 2>&1 1>/dev/null)"
assert_contains "$err1" "unknown config key 'limts.max_fix_attempts'" \
  "1: typo key warns"
assert_contains "$err1" "did you mean 'limits.max_fix_attempts'?" \
  "1: typo key suggests nearest match"
rm talos.pipeline.json

# ---- 2: nested typo under a dynamic role key warns -------------------------
cat > talos.pipeline.json <<'EOF'
{"agents": {"roles": {"developer": {"modle": "claude-haiku"}}}}
EOF
err2="$(bash "$CFG_SH" --dump 2>&1 1>/dev/null)"
assert_contains "$err2" "unknown config key 'agents.roles.developer.modle'" \
  "2: nested typo under dynamic role key warns"
assert_contains "$err2" "did you mean 'agents.roles.developer.model'?" \
  "2: nested typo suggests the correctly-spelled wildcard key"
rm talos.pipeline.json

# ---- 3: a valid wildcard key does not warn ---------------------------------
cat > talos.pipeline.json <<'EOF'
{"agents": {"roles": {"qa": {"model": "claude-haiku"}}}}
EOF
err3="$(bash "$CFG_SH" --dump 2>&1 1>/dev/null)"
assert_eq "" "$err3" "3: valid wildcard key (agents.roles.qa.model) does not warn"
rm talos.pipeline.json

# ---- 4: both example configs produce zero warnings -------------------------
if $HAVE_YAML; then
  cp "$TALOS_ROOT/talos.pipeline.yml.example" talos.pipeline.yml
  err4="$(bash "$CFG_SH" --dump 2>&1 1>/dev/null)"
  assert_eq "" "$err4" "4: talos.pipeline.yml.example produces zero warnings"
  rm talos.pipeline.yml
else
  pass "4: talos.pipeline.yml.example produces zero warnings (PyYAML absent -- skipped)"
fi

cp "$TALOS_ROOT/talos.pipeline.json.example" talos.pipeline.json
err5="$(bash "$CFG_SH" --dump 2>&1 1>/dev/null)"
assert_eq "" "$err5" "4: talos.pipeline.json.example produces zero warnings"
rm talos.pipeline.json

# ---- 5: _note key is ignored ------------------------------------------------
cat > talos.pipeline.json <<'EOF'
{"_note": "top-level note, describes commented-out keys", "merge": {"method": "squash"}}
EOF
err6="$(bash "$CFG_SH" --dump 2>&1 1>/dev/null)"
assert_eq "" "$err6" "5: _note key is ignored"
rm talos.pipeline.json

# ---- 6: warning appears exactly once for a --dump invocation ---------------
cat > talos.pipeline.json <<'EOF'
{"limts": {"max_fix_attempts": 3}}
EOF
err7="$(bash "$CFG_SH" --dump 2>&1 1>/dev/null)"
_count="$(printf '%s\n' "$err7" | grep -c "unknown config key 'limts.max_fix_attempts'")"
assert_eq "1" "$_count" "6: warning appears exactly once per --dump invocation"
rm talos.pipeline.json

# ---- 7: stdout is byte-identical with and without the typo ------------------
# (the value output is the default either way, since the typo does not set
# the correctly-spelled key)
cat > talos.pipeline.json <<'EOF'
{"base_branch": "main"}
EOF
out_no_typo="$(bash "$CFG_SH" limits.max_fix_attempts 5 2>/dev/null)"
rm talos.pipeline.json

cat > talos.pipeline.json <<'EOF'
{"base_branch": "main", "limts": {"max_fix_attempts": 3}}
EOF
out_typo="$(bash "$CFG_SH" limits.max_fix_attempts 5 2>/dev/null)"
assert_eq "$out_no_typo" "$out_typo" \
  "7: stdout byte-identical with and without a typo key present"
rm talos.pipeline.json

# ---- 8: TALOS_CONFIG_STRICT_KEYS=0 silences the warning ---------------------
cat > talos.pipeline.json <<'EOF'
{"limts": {"max_fix_attempts": 3}}
EOF
err8="$(TALOS_CONFIG_STRICT_KEYS=0 bash "$CFG_SH" --dump 2>&1 1>/dev/null)"
assert_eq "" "$err8" "8: TALOS_CONFIG_STRICT_KEYS=0 silences the warning"
rm talos.pipeline.json

# ---- 9: single-key path (direct, non-cached invocation) also warns ---------
# (it parses the file independently -- covers the "both paths" requirement)
cat > talos.pipeline.json <<'EOF'
{"limts": {"max_fix_attempts": 3}}
EOF
err9="$(bash "$CFG_SH" merge.method squash 2>&1 1>/dev/null)"
assert_contains "$err9" "unknown config key 'limts.max_fix_attempts'" \
  "9: single-key (direct) path also warns on an unknown key"
rm talos.pipeline.json

# ---- 9-yaml: YAML fixture also warns (only when PyYAML is available) -------
# Covers the same typo through the YAML parsing branch, so the YAML code
# path stays under test wherever PyYAML happens to be installed.
if $HAVE_YAML; then
  cat > talos.pipeline.yml <<'EOF'
limts:
  max_fix_attempts: 3
EOF
  err9y="$(bash "$CFG_SH" --dump 2>&1 1>/dev/null)"
  assert_contains "$err9y" "unknown config key 'limts.max_fix_attempts'" \
    "9-yaml: YAML fixture also warns on an unknown key (PyYAML present)"
  rm talos.pipeline.yml
else
  pass "9-yaml: YAML fixture also warns on an unknown key (PyYAML absent -- skipped)"
fi

# ---- 10: known top-level and merge.* keys never warn ------------------------
cat > talos.pipeline.json <<'EOF'
{
  "base_branch": "dev",
  "vcs": {"provider": "github"},
  "merge": {"auto": true, "method": "squash", "forbidden_files_allow": [".env.example"]},
  "issues": {"label_filter": "pipeline:ready"},
  "notifications": {"buzz_relay": ""}
}
EOF
err10="$(bash "$CFG_SH" --dump 2>&1 1>/dev/null)"
assert_eq "" "$err10" "10: a config using only known keys produces zero warnings"
rm talos.pipeline.json

finish
