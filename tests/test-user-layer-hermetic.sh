#!/usr/bin/env bash
# Regression (#336 fix round 1): a developer's real user-level Talos config
# (~/.talos/talos.pipeline.* or $TALOS_HOME) must never leak into a test run.
# tests/test-docs-149-config-examples.sh does not call make_sandbox and failed
# on a machine whose ~/.talos set agents.roles.reviewer.model, because
# pipeline-config.sh read the ambient user-level file.
#
# The fix is in tests/helpers.sh (every test file sources it), so it also holds
# when a test file is run directly with `bash tests/<file>.sh`. These cases
# plant a hostile user-level file in an "ambient" HOME / TALOS_HOME and run
# UNSANDBOXED tests directly, exactly as a developer would.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

HOSTILE_HOME="$SANDBOX/hostile-home"
mkdir -p "$HOSTILE_HOME/.talos"
printf '%s' '{"agents":{"model":"leaked-model","roles":{"reviewer":{"model":"claude-opus-5"}}}}' \
  > "$HOSTILE_HOME/.talos/talos.pipeline.json"
HOSTILE_TH="$SANDBOX/hostile-talos-home"
mkdir -p "$HOSTILE_TH"
cp "$HOSTILE_HOME/.talos/talos.pipeline.json" "$HOSTILE_TH/"

# Empty cwd with no project config, so only a user-level file could answer.
EMPTY_CWD="$SANDBOX/empty-cwd"
mkdir -p "$EMPTY_CWD"

# A minimal UNSANDBOXED test file: sources helpers.sh, never calls make_sandbox.
PROBE="$SANDBOX/probe-test.sh"
cat > "$PROBE" <<EOF
#!/usr/bin/env bash
set -u
. "$TALOS_ROOT/tests/helpers.sh"
cd "$EMPTY_CWD"
printf '%s|%s' "\$(bash "$TALOS_ROOT/scripts/pipeline-config.sh" agents.roles.reviewer.model SENTINEL)" \
  "\$(bash "$TALOS_ROOT/scripts/pipeline-config.sh" agents.model SENTINEL)"
EOF

# Sanity: the hostile file really does leak into a bare lookup (so the cases
# below are not vacuous).
bare="$(cd "$EMPTY_CWD" && env -u TALOS_HOME HOME="$HOSTILE_HOME" bash "$TALOS_ROOT/scripts/pipeline-config.sh" agents.model SENTINEL 2>/dev/null)"
assert_eq "leaked-model" "$bare" "precondition: an ambient ~/.talos file is visible to a bare pipeline-config.sh lookup"

# 1. Ambient HOME/.talos, directly-run unsandboxed test.
got="$(env -u TALOS_HOME HOME="$HOSTILE_HOME" bash "$PROBE" 2>/dev/null)"
assert_eq "SENTINEL|SENTINEL" "$got" "directly-run unsandboxed test sees no user-level values from ambient \$HOME/.talos"

# 2. Ambient TALOS_HOME pointing at a hostile directory.
got="$(env HOME="$SANDBOX/no-such-home" TALOS_HOME="$HOSTILE_TH" bash "$PROBE" 2>/dev/null)"
assert_eq "SENTINEL|SENTINEL" "$got" "directly-run unsandboxed test sees no user-level values from an ambient \$TALOS_HOME"

# 3. The real offender, run directly under a hostile ambient HOME.
out="$(cd "$TALOS_ROOT" && env -u TALOS_HOME HOME="$HOSTILE_HOME" bash tests/test-docs-149-config-examples.sh 2>&1)"; rc=$?
assert_eq "0" "$rc" "test-docs-149-config-examples.sh passes when run directly under a hostile ambient \$HOME/.talos"
assert_eq "0" "$(printf '%s\n' "$out" | grep -c '^FAIL')" "test-docs-149-config-examples.sh reports no FAIL under a hostile ambient user-level config"

# 4. Tests that deliberately use a user-level file inside their own sandbox
#    still work: make_sandbox gives them a clean HOME and TALOS_HOME.
out="$(cd "$TALOS_ROOT" && env HOME="$HOSTILE_HOME" TALOS_HOME="$HOSTILE_TH" bash tests/test-config-user-layer.sh 2>&1)"; rc=$?
assert_eq "0" "$rc" "test-config-user-layer.sh (own sandboxed user-level file) still passes under a hostile ambient config"

# 5. Every test file goes through helpers.sh, so none can opt out of the fix.
missing=""
for f in "$TALOS_ROOT"/tests/test-*.sh; do
  grep -q 'helpers\.sh' "$f" || missing="$missing $(basename "$f")"
done
assert_eq "" "$missing" "every tests/test-*.sh sources helpers.sh (the single place the user-level lookup is made hermetic)"

finish
