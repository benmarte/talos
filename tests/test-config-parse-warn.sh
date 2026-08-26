#!/usr/bin/env bash
# test-config-parse-warn.sh — covers issue #116: unparseable config silent failure.
#
# Section A: pipeline-config.sh warning mechanism
#   A1. Malformed JSON config → WARNING on stderr, default returned, exit 0
#   A2. No config file → silent (unconfigured is normal)
#   A3. Valid JSON config → no warning, values parsed correctly
#   A4. Dedup: two cfg calls same broken config, same invocation → exactly one WARNING
#   A5. YAML config with PyYAML → no warning (skipped when PyYAML absent)
#
# Section B: marker-authors-unverified cause-naming in pipeline-vcs.sh
#   B1. read-attempt, broken config → "could not be parsed" text
#   B2. read-attempt, no config → "author check skipped" text (existing, unchanged)
#   B3. regression: old code emits no WARNING at all → test is RED on pre-fix code
#
# Every assertion must fail (RED) without the fix and pass (GREEN) with it.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ═════════════════════════════════════════════════════════════════════════════
# SECTION A: pipeline-config.sh WARNING mechanism
# ═════════════════════════════════════════════════════════════════════════════

# All cfg calls from this test script have PPID = $$; clean up sentinel before
# each test that checks warning presence to prevent bleed-through.
_sentinel="/tmp/talos-cfg-parse-warn-$$"

# ── A1: Malformed JSON config ─────────────────────────────────────────────────
echo "{ not json" > talos.pipeline.json
rm -f "$_sentinel"
err_a1="$(bash "$CFG_SH" merge.method safe 2>&1 >/dev/null)"; rc_a1=$?
stdout_a1="$(bash "$CFG_SH" merge.method safe 2>/dev/null)"
assert_eq "0"    "$rc_a1"     "A1: malformed JSON: exits 0"
assert_eq "safe" "$stdout_a1" "A1: malformed JSON: returns default on stdout"
assert_contains "$err_a1" "WARNING"          "A1: malformed JSON: WARNING on stderr (regression guard)"
assert_contains "$err_a1" "could not be parsed" "A1: malformed JSON: warning names parse failure"
assert_contains "$err_a1" "talos.pipeline.json" "A1: malformed JSON: warning names the config file"
assert_contains "$err_a1" "built-in defaults"   "A1: malformed JSON: warning mentions defaults fallback"
rm talos.pipeline.json

# ── A2: No config file → silent ───────────────────────────────────────────────
rm -f "$_sentinel"
err_a2="$(bash "$CFG_SH" merge.method squash 2>&1 >/dev/null)"
assert_eq "" "$err_a2" "A2: no config file: no WARNING (unconfigured is normal)"
assert_eq "squash" "$(bash "$CFG_SH" merge.method squash 2>/dev/null)" \
  "A2: no config file: default returned silently"

# ── A3: Valid JSON → no warning ───────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"merge":{"method":"rebase"}}
EOF
rm -f "$_sentinel"
err_a3="$(bash "$CFG_SH" merge.method squash 2>&1 >/dev/null)"
assert_eq "" "$err_a3" "A3: valid JSON: no WARNING"
assert_eq "rebase" "$(bash "$CFG_SH" merge.method squash 2>/dev/null)" \
  "A3: valid JSON: values parsed correctly"
rm talos.pipeline.json

# ── A4: Dedup — two cfg calls, same broken config, same PPID → one WARNING ───
# Wrap in a bash -c subshell so both cfg calls share the same parent PID.
# First call: sentinel absent → warns + creates sentinel.
# Second call: sentinel present → stays silent.
# OLD code: no warning mechanism at all → 0 warnings → RED.
# NEW code: one warning (dedup works) → GREEN.
echo "{ not json" > talos.pipeline.json
warn_a4="$(bash -c '
  bash "$1" merge.method safe 2>&1 1>/dev/null
  bash "$1" board.enabled false 2>&1 1>/dev/null
' -- "$CFG_SH" | grep -c "WARNING" 2>/dev/null || echo 0)"
assert_eq "1" "$warn_a4" "A4: dedup: two cfg calls with same broken config → exactly one WARNING"
rm talos.pipeline.json

# ── A5: YAML config with PyYAML → no warning (conditional on PyYAML) ─────────
if python3 -c "import yaml" 2>/dev/null; then
  cat > talos.pipeline.yml <<'EOF'
merge:
  method: rebase
EOF
  rm -f "$_sentinel"
  err_a5="$(bash "$CFG_SH" merge.method squash 2>&1 >/dev/null)"
  assert_eq "" "$err_a5" "A5: valid YAML + PyYAML: no WARNING"
  assert_eq "rebase" "$(bash "$CFG_SH" merge.method squash 2>/dev/null)" \
    "A5: valid YAML + PyYAML: values parsed correctly"
  rm talos.pipeline.yml
else
  pass "A5: valid YAML (PyYAML absent — skipped)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SECTION B: marker-authors-unverified cause-naming in pipeline-vcs.sh
# ═════════════════════════════════════════════════════════════════════════════
# Trigger path: read-attempt finds a talos:attempt marker, trusted_authors is
# empty → author_check_active = False → marker-authors-unverified fires.
# When TALOS_CFG points to a broken config: "could not be parsed" text.
# When TALOS_CFG is empty (no config): "author check skipped" text (unchanged).

# Attempt marker comment — last non-whitespace line IS the marker.
_attempt_json="$(printf '[{"body":"verdict record\\n<!-- talos:attempt stage=developer count=1 total=1 -->","author":{"login":"bot"}}]')"

# ── B1: Broken config → warning names parse-failure cause ─────────────────────
# Capture BOTH stdout (talos:marker-authors-unverified tag) and stderr (human text).
echo "{ not json" > broken.json
out_b1="$(PIPELINE_CONFIG="$SANDBOX/broken.json" \
           STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
           bash "$VCS" read-attempt 42 2>&1)"
assert_contains "$out_b1" "marker-authors-unverified" \
  "B1: broken config: talos:marker-authors-unverified emitted"
assert_contains "$out_b1" "could not be parsed" \
  "B1: broken config: warning names config-parse cause (regression guard #116)"
assert_not_contains "$out_b1" "author check skipped" \
  "B1: broken config: old 'author check skipped' text not emitted when config broken"
rm broken.json

# ── B2: No config → existing text unchanged ───────────────────────────────────
# No PIPELINE_CONFIG, no standard config files in sandbox (make_sandbox gives clean dir).
out_b2="$(STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
           bash "$VCS" read-attempt 42 2>&1)"
assert_contains "$out_b2" "marker-authors-unverified" \
  "B2: no config: talos:marker-authors-unverified emitted"
assert_contains "$out_b2" "author check skipped" \
  "B2: no config: existing 'author check skipped' text unchanged"
assert_not_contains "$out_b2" "could not be parsed" \
  "B2: no config: no parse-failure text when config absent"

finish
