#!/usr/bin/env bash
# test-config-fail-closed.sh -- two #439 review items closed by #440 (epic #437):
#
#  (1) Fail closed. Once no call site passes a default, a missing
#      scripts/pipeline-defaults.sh would make security-relevant keys read empty
#      (merge.auto, limits.*, hooks.*, the forbidden-files and approval-waiver
#      lists, markers.*_authors). They now exit non-zero instead -- from
#      pipeline-config.sh (exit 3) and from cfg() (which ends the script, also
#      from inside a $(...) subshell). Every other key keeps degrading to empty
#      with one warning, and an explicit caller default still wins.
#  (2) `pipeline-config.sh --has KEY` has its own exit code for a config file
#      that does not parse: 0 set, 1 absent, 3 unknown (parse error).
#
# The sandbox has its own TALOS_HOME and HOME: the real ~/.talos is never read.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
export TALOS_HOME="$SANDBOX/talos-home"
mkdir -p "$TALOS_HOME" || exit 1
PROJ="$SANDBOX/project"
mkdir -p "$PROJ" || exit 1
cd "$PROJ" || exit 1
unset PIPELINE_CONFIG

SCRIPTS="$TALOS_ROOT/scripts"
CFG_SH="$SCRIPTS/pipeline-config.sh"

# ── The sandbox is hermetic: nothing from a real ~/.talos can answer ─────────
assert_eq "$SANDBOX/talos-home" "$TALOS_HOME" "TALOS_HOME is the sandbox directory"
case "$HOME" in "$SANDBOX"/*) pass "HOME is inside the sandbox" ;; *) fail "HOME is inside the sandbox" "HOME=$HOME" ;; esac

# ── (2) --has: its own exit code for a parse error ───────────────────────────
printf '%s\n' '{"status": {"enabled": true}}' > talos.pipeline.json
bash "$CFG_SH" --has status.enabled; _rc=$?
assert_eq "0" "$_rc" "--has: a key that is set exits 0"
bash "$CFG_SH" --has evidence.enabled; _rc=$?
assert_eq "1" "$_rc" "--has: an absent key in a good config exits 1"
printf '%s\n' '{"status": {"enabled": ' > talos.pipeline.json
bash "$CFG_SH" --has status.enabled 2>"$SANDBOX/err"; _rc=$?
assert_eq "3" "$_rc" "--has: a config that does not parse exits 3, not 1"
assert_contains "$(cat "$SANDBOX/err")" "could not be parsed" "--has: the parse error is explained on stderr"
assert_not_contains "$(cat "$SANDBOX/err")" "enabled" "--has: the message does not echo config content"
# a key found in the layer that did parse is still set
printf '%s\n' '{"status": {"enabled": true}}' > "$TALOS_HOME/talos.pipeline.json"
bash "$CFG_SH" --has status.enabled 2>/dev/null; _rc=$?
assert_eq "0" "$_rc" "--has: a key set in the global file is found although the repo file is malformed"
bash "$CFG_SH" --has evidence.enabled 2>/dev/null; _rc=$?
assert_eq "3" "$_rc" "--has: an absent key with a malformed repo file is unknown (3)"
rm -f "$TALOS_HOME/talos.pipeline.json" "$PROJ/talos.pipeline.json"
# a malformed global file counts as well
printf '%s\n' '{"status": ' > "$TALOS_HOME/talos.pipeline.json"
printf '%s\n' '{"board": {"enabled": true}}' > "$PROJ/talos.pipeline.json"
bash "$CFG_SH" --has status.enabled 2>/dev/null; _rc=$?
assert_eq "3" "$_rc" "--has: an absent key with a malformed global file is unknown (3)"
bash "$CFG_SH" --has board.enabled 2>/dev/null; _rc=$?
assert_eq "0" "$_rc" "--has: a key set in the good repo file is still 0"
rm -f "$TALOS_HOME/talos.pipeline.json" "$PROJ/talos.pipeline.json"
bash "$CFG_SH" --has status.enabled; _rc=$?
assert_eq "1" "$_rc" "--has: no config at all exits 1"

# ── (1) fail closed without pipeline-defaults.sh ─────────────────────────────
NOTAB="$SANDBOX/no-table-scripts"
mkdir -p "$NOTAB" || exit 1
for f in "$SCRIPTS"/*.sh; do
  _b="$(basename "$f")"
  [ "$_b" = "pipeline-defaults.sh" ] && continue
  ln -s "$f" "$NOTAB/$_b"
done
NOTAB_CFG="$NOTAB/pipeline-config.sh"
SEC_KEYS="merge.forbidden_files merge.forbidden_files_replace merge.forbidden_files_allow
merge.approval_waiver_paths merge.auto markers.verify_authors markers.trusted_authors
limits.max_fix_attempts limits.max_total_dispatches limits.max_retries limits.tokens_per_issue limits.warn_at
hooks.pre_dispatch hooks.post_stage hooks.timeout_s"

for key in $SEC_KEYS; do
  _out="$(bash "$NOTAB_CFG" "$key" 2>"$SANDBOX/err")"; _rc=$?
  assert_eq "3" "$_rc" "no table, no config: $key exits 3"
  assert_eq "" "$_out" "no table, no config: $key prints nothing"
  assert_contains "$(cat "$SANDBOX/err")" "$key" "no table: the error names $key"
done
printf '%s\n' '{"agents": {"model": "m"}}' > "$PROJ/talos.pipeline.json"
bash "$NOTAB_CFG" merge.auto >/dev/null 2>&1; _rc=$?
assert_eq "3" "$_rc" "no table, a config that does not set merge.auto: exit 3 (python3 path)"
printf '%s\n' '{"merge": {"auto": false}, "limits": {"max_fix_attempts": 4}}' > "$PROJ/talos.pipeline.json"
assert_eq "false" "$(bash "$NOTAB_CFG" merge.auto 2>/dev/null)" "no table: a key the config sets is still read"
assert_eq "4" "$(bash "$NOTAB_CFG" limits.max_fix_attempts 2>/dev/null)" "no table: limits.max_fix_attempts set in the config is read"
rm -f "$PROJ/talos.pipeline.json"
assert_eq "true" "$(bash "$NOTAB_CFG" merge.auto true 2>/dev/null)" "no table: an explicit caller default still answers for a security key"
bash "$NOTAB_CFG" merge.auto true >/dev/null 2>&1; _rc=$?
assert_eq "0" "$_rc" "no table: an explicit caller default exits 0"
_out="$(bash "$NOTAB_CFG" board.enabled 2>/dev/null)"; _rc=$?
assert_eq "0" "$_rc" "no table: a non-security key still exits 0"
assert_eq "" "$_out" "no table: a non-security key still prints nothing"
assert_eq "0" "$(bash "$NOTAB_CFG" status.log_days >/dev/null 2>&1; echo $?)" "no table: status.log_days (not security-relevant) exits 0"

# cfg(): ends the script, also from inside $(...)
cat > "$SANDBOX/probe-closed.sh" <<'TALOS_PRBfc3Xw8Kn5Dz'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$1"; KEY="$2"; MODE="${3:-plain}"
. "$SCRIPT_DIR/pipeline-cfg-cache.sh"
case "$MODE" in
  default) v="$(cfg "$KEY" fallback)" ;;
  *) v="$(cfg "$KEY")" ;;
esac
echo "reached:[$v]"
TALOS_PRBfc3Xw8Kn5Dz
for key in merge.auto limits.max_fix_attempts hooks.pre_dispatch markers.verify_authors merge.forbidden_files; do
  _out="$(bash "$SANDBOX/probe-closed.sh" "$NOTAB" "$key" 2>/dev/null)"; _rc=$?
  assert_eq "" "$_out" "cfg $key without the table ends the script before the caller uses the value"
  assert_eq "1" "$([ "$_rc" -ne 0 ] && echo 1 || echo 0)" "cfg $key without the table: the script exits non-zero (rc $_rc)"
done
assert_eq "reached:[fallback]" "$(bash "$SANDBOX/probe-closed.sh" "$NOTAB" merge.auto default 2>/dev/null)" \
  "cfg KEY default without the table: the caller's default still answers"
assert_eq "reached:[]" "$(bash "$SANDBOX/probe-closed.sh" "$NOTAB" board.enabled 2>/dev/null)" \
  "cfg of a non-security key without the table degrades to empty, as before"
# with the table present, nothing changes
assert_eq "reached:[true]" "$(bash "$SANDBOX/probe-closed.sh" "$SCRIPTS" merge.auto 2>/dev/null)" "with the table, cfg merge.auto is its default"

finish
