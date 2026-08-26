#!/usr/bin/env bash
# test-config-parse-warn.sh -- covers issue #116: unparseable config silent failure.
#
# Section A: pipeline-vcs.sh in-process warning (one warning per invocation)
#   A1. Malformed JSON config + VCS call -> WARNING on stderr, exit 0
#   A2. No config file + VCS call -> silent (unconfigured is normal)
#   A3. Valid JSON config + VCS call -> no WARNING
#   A4. YAML config with PyYAML + VCS call -> no WARNING (skipped when PyYAML absent)
#   A5. Suppression: pre-creating /tmp/talos-cfg-parse-warn-* for ALL PIDs does NOT
#       suppress the warning [mutation: sentinel-based -- if the mechanism reverts to
#       writing/reading /tmp/talos-cfg-parse-warn-<PID>, this test goes RED]
#
# Section B: pipeline-config.sh invoked directly (degrades sensibly -- silent)
#   B1. Malformed JSON -> default returned on stdout, exit 0, NO warning on stderr
#   B2. No config -> default returned on stdout, exit 0, silent
#   B3. Valid JSON -> parsed value on stdout, exit 0
#
# Section C: marker-authors-unverified cause-naming in pipeline-vcs.sh
#   C1. read-attempt, broken config -> "could not be parsed" text
#   C2. read-attempt, no config -> "author check skipped" text (existing, unchanged)
#   C3. regression: old code emits no WARNING at all -> test is RED on pre-fix code
#
# Every assertion that is a regression guard must fail (RED) on the pre-fix code.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# A shared attempt-marker comment for Section C tests.
_attempt_json="$(printf '[{"body":"verdict record\\n<!-- talos:attempt stage=developer count=1 total=1 -->","author":{"login":"bot"}}]')"

# =========================================================================
# SECTION A: pipeline-vcs.sh in-process warning
# =========================================================================

# ---- A1: Malformed JSON + VCS call -> WARNING on stderr, exit 0 -----------
echo "{ not json" > talos.pipeline.json
# Capture stderr only; stdout goes to /dev/null.
err_a1="$(PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" \
          STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
          bash "$VCS" read-attempt 42 2>&1 >/dev/null)"
assert_contains "$err_a1" "WARNING" \
  "A1: malformed JSON + VCS call: WARNING on stderr (regression guard)"
assert_contains "$err_a1" "could not be parsed" \
  "A1: malformed JSON + VCS call: warning names parse failure"
assert_contains "$err_a1" "talos.pipeline.json" \
  "A1: malformed JSON + VCS call: warning names the config file"
assert_contains "$err_a1" "built-in defaults" \
  "A1: malformed JSON + VCS call: warning mentions defaults fallback"
# Confirm the verb itself exits 0 (warning does not abort the run).
rc_a1=0
PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" \
  STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
  bash "$VCS" read-attempt 42 >/dev/null 2>/dev/null || rc_a1=$?
assert_eq "0" "$rc_a1" "A1: malformed JSON + VCS call: exits 0"
rm talos.pipeline.json

# ---- A2: No config + VCS call -> silent ------------------------------------
err_a2="$(STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
          bash "$VCS" read-attempt 42 2>&1 >/dev/null)"
assert_not_contains "$err_a2" "WARNING" \
  "A2: no config + VCS call: no WARNING (unconfigured is normal)"

# ---- A3: Valid JSON + VCS call -> no WARNING --------------------------------
printf '{"merge":{"method":"rebase"}}' > talos.pipeline.json
err_a3="$(PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" \
          STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
          bash "$VCS" read-attempt 42 2>&1 >/dev/null)"
assert_not_contains "$err_a3" "WARNING" \
  "A3: valid JSON + VCS call: no WARNING"
rm talos.pipeline.json

# ---- A4: Valid YAML + PyYAML -> no WARNING (skipped when PyYAML absent) -----
if python3 -c "import yaml" 2>/dev/null; then
  printf 'merge:\n  method: rebase\n' > talos.pipeline.yml
  err_a4="$(PIPELINE_CONFIG="$SANDBOX/talos.pipeline.yml" \
            STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
            bash "$VCS" read-attempt 42 2>&1 >/dev/null)"
  assert_not_contains "$err_a4" "WARNING" \
    "A4: valid YAML + PyYAML + VCS call: no WARNING"
  rm talos.pipeline.yml
else
  pass "A4: valid YAML (PyYAML absent -- skipped)"
fi

# ---- A5: Suppression resistance ---------------------------------------------
# Pre-create /tmp/talos-cfg-parse-warn-<N> for the entire PID space.
# Under the old file-based sentinel mechanism this would suppress the warning.
# Under the new in-process mechanism the warning must still fire.
# Mutation label: sentinel-based -- reverting to that mechanism makes this RED.
echo "{ not json" > talos.pipeline.json
python3 -c "
import pathlib, sys
for i in range(1, 100000):
    try:
        pathlib.Path('/tmp/talos-cfg-parse-warn-' + str(i)).touch()
    except Exception:
        pass
" 2>/dev/null || true
err_a5="$(PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" \
          STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
          bash "$VCS" read-attempt 42 2>&1 >/dev/null)"
assert_contains "$err_a5" "WARNING" \
  "A5(suppression): WARNING fires even after all /tmp/talos-cfg-parse-warn-* pre-created [mutation: sentinel-based]"
# Cleanup sentinel files.
python3 -c "
import pathlib
for i in range(1, 100000):
    try:
        pathlib.Path('/tmp/talos-cfg-parse-warn-' + str(i)).unlink()
    except Exception:
        pass
" 2>/dev/null || true
rm talos.pipeline.json

# ---- A6: YAML config + PyYAML simulated absent -> WARNING fires -------------
# Pins the PyYAML-absent degraded path against regression so CI (which now
# installs PyYAML) does not permanently lose coverage of this code path.
# Without this test, a future regression in the json-fallback silently ships.
printf 'merge:\n  method: rebase\n' > talos.pipeline.yml
# Shadow 'yaml' with a stub module that raises ImportError on import.
_fake_py="$SANDBOX/fake_yaml_modules"
mkdir -p "$_fake_py"
printf 'raise ImportError("yaml absent (simulated for test A6)")\n' > "$_fake_py/yaml.py"
err_a6="$(PIPELINE_CONFIG="$SANDBOX/talos.pipeline.yml" \
          STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
          PYTHONPATH="$_fake_py" \
          bash "$VCS" read-attempt 42 2>&1 >/dev/null)"
assert_contains "$err_a6" "WARNING" \
  "A6(pyyaml-absent): YAML config without PyYAML triggers WARNING"
assert_contains "$err_a6" "talos.pipeline.yml" \
  "A6(pyyaml-absent): warning names the YAML config file"
rm -rf "$_fake_py"
rm talos.pipeline.yml

# =========================================================================
# SECTION B: pipeline-config.sh direct invocations (silent degradation)
# =========================================================================

# ---- B1: Malformed JSON -> returns default silently, exit 0 ----------------
echo "{ not json" > talos.pipeline.json
stdout_b1="$(PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" bash "$CFG_SH" merge.method safe 2>/dev/null)"
rc_b1=0
PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" bash "$CFG_SH" merge.method safe >/dev/null 2>/dev/null || rc_b1=$?
err_b1="$(PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" bash "$CFG_SH" merge.method safe 2>&1 >/dev/null)"
assert_eq "0"    "$rc_b1"     "B1: malformed JSON direct: exits 0"
assert_eq "safe" "$stdout_b1" "B1: malformed JSON direct: returns default on stdout"
assert_not_contains "$err_b1" "WARNING" \
  "B1: malformed JSON direct: pipeline-config.sh itself emits no WARNING (warning lives in pipeline-vcs.sh)"
rm talos.pipeline.json

# ---- B2: No config -> returns default silently, exit 0 ---------------------
stdout_b2="$(bash "$CFG_SH" merge.method squash 2>/dev/null)"
rc_b2=0
bash "$CFG_SH" merge.method squash >/dev/null 2>/dev/null || rc_b2=$?
assert_eq "0"       "$rc_b2"     "B2: no config direct: exits 0"
assert_eq "squash"  "$stdout_b2" "B2: no config direct: default returned silently"

# ---- B3: Valid JSON -> parsed value on stdout, exit 0 ----------------------
printf '{"merge":{"method":"rebase"}}' > talos.pipeline.json
stdout_b3="$(PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" bash "$CFG_SH" merge.method squash 2>/dev/null)"
rc_b3=0
PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" bash "$CFG_SH" merge.method squash >/dev/null 2>/dev/null || rc_b3=$?
assert_eq "0"       "$rc_b3"     "B3: valid JSON direct: exits 0"
assert_eq "rebase"  "$stdout_b3" "B3: valid JSON direct: value parsed correctly"
rm talos.pipeline.json

# =========================================================================
# SECTION C: marker-authors-unverified cause-naming in pipeline-vcs.sh
# =========================================================================
# Trigger path: read-attempt finds a talos:attempt marker, trusted_authors is
# empty -> author_check_active = False -> marker-authors-unverified fires.
# When TALOS_CFG points to a broken config: "could not be parsed" text.
# When TALOS_CFG is empty (no config): "author check skipped" text (unchanged).

# ---- C1: Broken config -> warning names parse-failure cause ----------------
echo "{ not json" > broken.json
out_c1="$(PIPELINE_CONFIG="$SANDBOX/broken.json" \
           STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
           bash "$VCS" read-attempt 42 2>&1)"
assert_contains "$out_c1" "marker-authors-unverified" \
  "C1: broken config: talos:marker-authors-unverified emitted"
assert_contains "$out_c1" "could not be parsed" \
  "C1: broken config: warning names config-parse cause (regression guard #116)"
assert_not_contains "$out_c1" "author check skipped" \
  "C1: broken config: old 'author check skipped' text not emitted when config broken"
rm broken.json

# ---- C2: No config -> existing text unchanged ------------------------------
out_c2="$(STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
           bash "$VCS" read-attempt 42 2>&1)"
assert_contains "$out_c2" "marker-authors-unverified" \
  "C2: no config: talos:marker-authors-unverified emitted"
assert_contains "$out_c2" "author check skipped" \
  "C2: no config: existing 'author check skipped' text unchanged"
assert_not_contains "$out_c2" "could not be parsed" \
  "C2: no config: no parse-failure text when config absent"

finish
