#!/usr/bin/env bash
# test-config-parse-warn.sh -- covers issue #116: unparseable config silent failure.
#
# Section A: pipeline-vcs.sh in-process warning (one warning per invocation)
#   A1. Malformed JSON config + VCS call -> WARNING on stderr, exit 0
#   A2. No config file + VCS call -> silent (unconfigured is normal)
#   A3. Valid JSON config + VCS call -> no WARNING
#   A4. A legacy .yml config pointer -> WARNING (the config parser is JSON
#       only, #526; the loader's gate refuses such a pointer itself)
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
# The same run also supplies the exit status (the warning does not abort the run).
rc_a1=0
err_a1="$(PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" \
          STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
          bash "$VCS" read-attempt 42 2>&1 >/dev/null)" || rc_a1=$?
assert_contains "$err_a1" "WARNING" \
  "A1: malformed JSON + VCS call: WARNING on stderr (regression guard)"
assert_contains "$err_a1" "could not be parsed" \
  "A1: malformed JSON + VCS call: warning names parse failure"
assert_contains "$err_a1" "talos.pipeline.json" \
  "A1: malformed JSON + VCS call: warning names the config file"
assert_contains "$err_a1" "built-in defaults" \
  "A1: malformed JSON + VCS call: warning mentions defaults fallback"
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

# ---- A4: A legacy .yml config pointer -> WARNING ----------------------------
# The config parser is JSON only (#526): a pointer at a .yml file names a file
# the parser cannot read, so the in-process parse warning fires (the loader's
# gate refuses the pointer itself with reason=config-legacy-file, and the verb
# still degrades to defaults, exit 0).
printf 'merge:\n  method: rebase\n' > talos.pipeline.yml
rc_a4=0
err_a4="$(PIPELINE_CONFIG="$SANDBOX/talos.pipeline.yml" \
          STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
          bash "$VCS" read-attempt 42 2>&1 >/dev/null)" || rc_a4=$?
assert_contains "$err_a4" "WARNING" \
  "A4: a .yml config pointer + VCS call: parse WARNING fires (JSON-only parser)"
assert_contains "$err_a4" "could not be parsed" \
  "A4: a .yml config pointer: warning names parse failure"
assert_contains "$err_a4" "talos.pipeline.yml" \
  "A4: a .yml config pointer: warning names the file"
assert_eq "0" "$rc_a4" "A4: a .yml config pointer: the verb still exits 0"
rm talos.pipeline.yml

# ---- A5: Suppression resistance ---------------------------------------------
# Pre-create /tmp/talos-cfg-parse-warn-<N> for every PID the run below can get:
# PIDs are handed out sequentially (wrapping at 99999), so the window just above
# this shell's own PID covers the next few thousand processes -- creating the whole
# PID space cost ~7 s of system time for a mechanism no script carries any more.
# Under the old file-based sentinel mechanism this would suppress the warning.
# Under the new in-process mechanism the warning must still fire.
# Mutation label: sentinel-based -- reverting to that mechanism makes this RED.
echo "{ not json" > talos.pipeline.json
_sentinels() {  # create|remove
  python3 -I -c "
import os, sys
base = int(sys.argv[2])
for i in range(base - 20, base + 3000):
    p = '/tmp/talos-cfg-parse-warn-' + str((i - 1) % 99999 + 1)
    try:
        if sys.argv[1] == 'create':
            os.close(os.open(p, os.O_CREAT | os.O_WRONLY))
        else:
            os.unlink(p)
    except OSError:
        pass
" "$1" "$$" 2>/dev/null || true
}
_sentinels create
err_a5="$(PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" \
          STUB_ISSUE_COMMENTS_JSON="$_attempt_json" \
          bash "$VCS" read-attempt 42 2>&1 >/dev/null)"
assert_contains "$err_a5" "WARNING" \
  "A5(suppression): WARNING fires even after all /tmp/talos-cfg-parse-warn-* pre-created [mutation: sentinel-based]"
_sentinels remove
rm talos.pipeline.json

# =========================================================================
# SECTION B: pipeline-config.sh direct invocations (silent degradation)
# =========================================================================

# ---- B1: Malformed JSON -> returns default silently, exit 0 ----------------
echo "{ not json" > talos.pipeline.json
rc_b1=0
stdout_b1="$(PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" bash "$CFG_SH" merge.method safe 2>"$SANDBOX/err_b1")" || rc_b1=$?
err_b1="$(cat "$SANDBOX/err_b1")"
assert_eq "0"    "$rc_b1"     "B1: malformed JSON direct: exits 0"
assert_eq "safe" "$stdout_b1" "B1: malformed JSON direct: returns default on stdout"
assert_not_contains "$err_b1" "WARNING" \
  "B1: malformed JSON direct: pipeline-config.sh itself emits no WARNING (warning lives in pipeline-vcs.sh)"
rm talos.pipeline.json

# ---- B2: No config -> returns default silently, exit 0 ---------------------
rc_b2=0
stdout_b2="$(bash "$CFG_SH" merge.method squash 2>/dev/null)" || rc_b2=$?
assert_eq "0"       "$rc_b2"     "B2: no config direct: exits 0"
assert_eq "squash"  "$stdout_b2" "B2: no config direct: default returned silently"

# ---- B3: Valid JSON -> parsed value on stdout, exit 0 ----------------------
printf '{"merge":{"method":"rebase"}}' > talos.pipeline.json
rc_b3=0
stdout_b3="$(PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" bash "$CFG_SH" merge.method squash 2>/dev/null)" || rc_b3=$?
assert_eq "0"       "$rc_b3"     "B3: valid JSON direct: exits 0"
assert_eq "rebase"  "$stdout_b3" "B3: valid JSON direct: value parsed correctly"
rm talos.pipeline.json

# =========================================================================
# SECTION C: marker-authors-unverified cause-naming in pipeline-vcs.sh
# =========================================================================
# GitHub answers GET /user or refuses it, so an unresolved identity cannot
# happen through an adapter any more; the shared reader is driven directly.
# With no trusted_authors and no resolved identity the author check is off and
# marker-authors-unverified fires. When TALOS_CFG points to a broken config:
# "could not be parsed" text. With no config: "author check skipped" (unchanged).
_shared_src="$(awk '/^_github\(\) \{/{exit} /^_vcs_shared_read_attempt\(\) \{/{flag=1} flag{print}' "$VCS")"
eval "$_shared_src"
SCRIPT_DIR="$TALOS_ROOT/scripts"
cfg() { bash "$CFG_SH" "$@"; }
_attempt_comments='{"comments":[{"body":"verdict record\n<!-- talos:attempt stage=developer count=1 total=1 -->","author":{"login":"bot"}}]}'

# ---- C1: Broken config -> warning names parse-failure cause ----------------
echo "{ not json" > broken.json
out_c1="$(printf '%s' "$_attempt_comments" | TRUSTED_AUTHORS='' VERIFY_AUTHORS=true CURRENT_USER='' TALOS_CFG="$SANDBOX/broken.json" \
           _vcs_shared_read_attempt 2>&1)"
assert_contains "$out_c1" "marker-authors-unverified" \
  "C1: broken config: talos:marker-authors-unverified emitted"
assert_contains "$out_c1" "could not be parsed" \
  "C1: broken config: warning names config-parse cause (regression guard #116)"
assert_not_contains "$out_c1" "author check skipped" \
  "C1: broken config: old 'author check skipped' text not emitted when config broken"
rm broken.json

# ---- C2: No config -> existing text unchanged ------------------------------
out_c2="$(printf '%s' "$_attempt_comments" | TRUSTED_AUTHORS='' VERIFY_AUTHORS=true CURRENT_USER='' TALOS_CFG='' \
           _vcs_shared_read_attempt 2>&1)"
assert_contains "$out_c2" "marker-authors-unverified" \
  "C2: no config: talos:marker-authors-unverified emitted"
assert_contains "$out_c2" "author check skipped" \
  "C2: no config: existing 'author check skipped' text unchanged"
assert_not_contains "$out_c2" "could not be parsed" \
  "C2: no config: no parse-failure text when config absent"

finish
