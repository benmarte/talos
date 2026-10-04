#!/usr/bin/env bash
# AC8 (#336): `install.sh --global` stays non-interactive, never touches an
# existing user-level config, and prints one hint line pointing at the setup
# wizard when no user-level model keys exist.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

USER_DIR="$HOME/.talos"
USER_CFG="$USER_DIR/talos.pipeline.json"
HINT="no model set in a user-level Talos config"

install_out() { bash "$TALOS_ROOT/install.sh" --global --no-agent-skills </dev/null 2>&1; }
count_hint() { printf '%s\n' "$1" | grep -c "$HINT"; }

# 1. No user-level file at all -> hint, exactly once, naming the setup skill.
out="$(install_out)"
assert_eq "1" "$(count_hint "$out")" "AC8: hint printed once when no user-level config exists"
assert_contains "$(printf '%s\n' "$out" | grep "$HINT")" "/talos:setup" "AC8: hint points at the setup wizard"
assert_file_absent "$USER_CFG" "AC8: install --global does not create a user-level config"

# 2. User-level file without model keys -> hint, file byte-identical.
printf '%s' '{"agents": {"effort": "high"}}' > "$USER_CFG"
before="$(cksum < "$USER_CFG")"
out="$(install_out)"
assert_eq "1" "$(count_hint "$out")" "AC8: hint printed when the user-level file has no model keys"
assert_eq "$before" "$(cksum < "$USER_CFG")" "AC8: existing user-level file is byte-identical after install --global"

# 3. User-level file with agents.model -> no hint, byte-identical.
printf '%s' '{"agents": {"model": "sonnet"}}' > "$USER_CFG"
before="$(cksum < "$USER_CFG")"
out="$(install_out)"
assert_eq "0" "$(count_hint "$out")" "AC8: no hint when the user-level file sets agents.model"
assert_eq "$before" "$(cksum < "$USER_CFG")" "AC8: file with model keys is byte-identical after install --global"

# 4. A per-role model alone also counts.
printf '%s' '{"agents": {"roles": {"qa": {"model": "haiku"}}}}' > "$USER_CFG"
out="$(install_out)"
assert_eq "0" "$(count_hint "$out")" "AC8: no hint when only agents.roles.<role>.model is set"

# 5. A YAML user-level file counts too.
rm -f "$USER_CFG"
printf 'agents:\n  model: sonnet\n' > "$USER_DIR/talos.pipeline.yml"
before="$(cksum < "$USER_DIR/talos.pipeline.yml")"
out="$(install_out)"
assert_eq "0" "$(count_hint "$out")" "AC8: no hint for a user-level .yml with agents.model"
assert_eq "$before" "$(cksum < "$USER_DIR/talos.pipeline.yml")" "AC8: user-level .yml is byte-identical after install --global"
rm -f "$USER_DIR/talos.pipeline.yml"

# 6. $TALOS_HOME is honoured when looking for the user-level file.
mkdir -p "$SANDBOX/alt"
printf '%s' '{"agents": {"model": "opus"}}' > "$SANDBOX/alt/talos.pipeline.json"
out="$(TALOS_HOME="$SANDBOX/alt" bash "$TALOS_ROOT/install.sh" --global --no-agent-skills </dev/null 2>&1)"
assert_eq "0" "$(count_hint "$out")" "AC8: \$TALOS_HOME user-level config with a model suppresses the hint"

# 7. A project config in the cwd does not stand in for the user-level file.
rm -rf "${USER_DIR:?}/talos.pipeline.json" "${SANDBOX:?}/alt"
printf '%s' '{"agents": {"model": "haiku"}}' > "$SANDBOX/talos.pipeline.json"
out="$(install_out)"
assert_eq "1" "$(count_hint "$out")" "AC8: a repo-level model does not suppress the user-level hint"

finish
