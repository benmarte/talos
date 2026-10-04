#!/usr/bin/env bash
# test-config-fail-closed.sh -- two #439 review items closed by #440 (epic #437):
#
#  (1) Fail closed. Once no call site passes a default, a missing, unreadable,
#      truncated or incomplete (no final sentinel, or a security row deleted)
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

# ── (1) fail closed without a usable pipeline-defaults.sh ────────────────────
# "Usable" is pipeline-defaults-check.sh: readable, complete (ends with its
# sentinel) and holding a row for every security-relevant key. Each variant
# below is a scripts dir of symlinks to the real scripts with its own copy of
# the table, damaged in one way.
SEC_KEYS="merge.forbidden_files merge.forbidden_files_replace merge.forbidden_files_allow
merge.approval_waiver_paths merge.auto markers.verify_authors markers.trusted_authors
limits.max_fix_attempts limits.max_total_dispatches limits.max_retries limits.tokens_per_issue limits.warn_at
hooks.pre_dispatch hooks.post_stage hooks.timeout_s"

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

# variant_dir NAME -- a scripts dir without a table; prints its path
variant_dir() {
  local d="$SANDBOX/variant-$1" f b
  mkdir -p "$d" || return 1
  for f in "$SCRIPTS"/*.sh; do
    b="$(basename "$f")"
    [ "$b" = "pipeline-defaults.sh" ] && continue
    ln -s "$f" "$d/$b"
  done
  printf '%s' "$d"
}

# check_closed DIR LABEL -- every security key fails closed, others degrade
check_closed() {
  local d="$1" label="$2" scope="${3:-}" key out rc
  for key in $SEC_KEYS; do
    out="$(bash "$d/pipeline-config.sh" "$key" 2>"$SANDBOX/err")"; rc=$?
    assert_eq "3" "$rc" "$label: pipeline-config.sh $key exits 3"
    assert_eq "" "$out" "$label: pipeline-config.sh $key prints nothing"
    assert_contains "$(cat "$SANDBOX/err")" "$key" "$label: the error names $key"
  done
  printf '%s\n' '{"agents": {"model": "m"}}' > "$PROJ/talos.pipeline.json"
  bash "$d/pipeline-config.sh" merge.auto >/dev/null 2>&1; rc=$?
  assert_eq "3" "$rc" "$label: a config that does not set merge.auto still exits 3 (python3 path)"
  printf '%s\n' '{"merge": {"auto": false}, "limits": {"max_fix_attempts": 4}}' > "$PROJ/talos.pipeline.json"
  assert_eq "false" "$(bash "$d/pipeline-config.sh" merge.auto 2>/dev/null)" "$label: a key the config sets is still read"
  assert_eq "4" "$(bash "$d/pipeline-config.sh" limits.max_fix_attempts 2>/dev/null)" "$label: limits.max_fix_attempts set in the config is read"
  rm -f "$PROJ/talos.pipeline.json"
  assert_eq "true" "$(bash "$d/pipeline-config.sh" merge.auto true 2>/dev/null)" "$label: an explicit caller default still answers for a security key"
  assert_contains "$(bash "$d/pipeline-config.sh" merge.auto true 2>&1 >/dev/null)" "pipeline-defaults.sh missing or unusable" "$label: the table problem is reported on stderr"
  if [ "$scope" != "all" ]; then
    out="$(bash "$d/pipeline-config.sh" board.enabled 2>/dev/null)"; rc=$?
    assert_eq "0" "$rc" "$label: a non-security key still exits 0"
    assert_eq "" "$out" "$label: a non-security key still prints nothing"
    assert_eq "reached:[]" "$(bash "$SANDBOX/probe-closed.sh" "$d" board.enabled 2>/dev/null)" \
      "$label: cfg of a non-security key degrades to empty"
  fi
  for key in merge.auto limits.max_fix_attempts hooks.pre_dispatch markers.verify_authors merge.forbidden_files limits.max_total_dispatches; do
    out="$(bash "$SANDBOX/probe-closed.sh" "$d" "$key" 2>/dev/null)"; rc=$?
    assert_eq "" "$out" "$label: cfg $key ends the script before the caller uses the value"
    assert_eq "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)" "$label: cfg $key exits non-zero (rc $rc)"
  done
  assert_eq "reached:[fallback]" "$(bash "$SANDBOX/probe-closed.sh" "$d" merge.auto default 2>/dev/null)" \
    "$label: cfg KEY default: the caller's default still answers"
}

# missing
D="$(variant_dir missing)" || exit 1
check_closed "$D" "missing table"

# present but unreadable (a root user reads mode 000, so the case cannot be set up)
D="$(variant_dir unreadable)" || exit 1
cp "$SCRIPTS/pipeline-defaults.sh" "$D/pipeline-defaults.sh" || exit 1
chmod 000 "$D/pipeline-defaults.sh" || exit 1
if [ "$(id -u)" -eq 0 ]; then
  pass "unreadable table: skipped (running as root)"
else
  check_closed "$D" "unreadable table"
fi
chmod 600 "$D/pipeline-defaults.sh"

# truncated: the first half of the file (inside the heredoc)
D="$(variant_dir truncated)" || exit 1
_lines="$(wc -l < "$SCRIPTS/pipeline-defaults.sh" | tr -d ' ')"
head -n $((_lines / 2)) "$SCRIPTS/pipeline-defaults.sh" > "$D/pipeline-defaults.sh" || exit 1
check_closed "$D" "truncated table"

# every line but the final sentinel
D="$(variant_dir nosentinel)" || exit 1
grep -v '^_TALOS_DEFAULTS_END=1$' "$SCRIPTS/pipeline-defaults.sh" > "$D/pipeline-defaults.sh" || exit 1
assert_eq "0" "$(grep -c '^_TALOS_DEFAULTS_END=1$' "$D/pipeline-defaults.sh" || true)" "the no-sentinel variant has no sentinel line"
check_closed "$D" "table without its sentinel"

# a security-relevant row deleted
D="$(variant_dir norow)" || exit 1
grep -v "^markers.verify_authors$(printf '\t')" "$SCRIPTS/pipeline-defaults.sh" > "$D/pipeline-defaults.sh" || exit 1
assert_eq "0" "$(grep -c "^markers.verify_authors$(printf '\t')" "$D/pipeline-defaults.sh" || true)" "the missing-row variant has no markers.verify_authors row"
check_closed "$D" "table missing a security row"

# the check helper itself missing: nothing can say which keys are safe
D="$(variant_dir nocheck)" || exit 1
rm -f "$D/pipeline-defaults-check.sh"
cp "$SCRIPTS/pipeline-defaults.sh" "$D/pipeline-defaults.sh" || exit 1
check_closed "$D" "check helper missing" all
out="$(bash "$D/pipeline-config.sh" board.enabled 2>/dev/null)"; rc=$?
assert_eq "3" "$rc" "check helper missing: even a non-security key fails closed (nothing can classify it)"

# an intact table: nothing changes, and no python3 is spawned without a config
PYBIN="$SANDBOX/pybin"
mkdir -p "$PYBIN" || exit 1
REAL_PY="$(command -v python3)"
PYLOG="$SANDBOX/py.log"
: > "$PYLOG"
printf '#!/bin/sh\necho spawn >> "%s"\nexec "%s" "$@"\n' "$PYLOG" "$REAL_PY" > "$PYBIN/python3"
chmod +x "$PYBIN/python3"
assert_eq "reached:[true]" "$(PATH="$PYBIN:$PATH" bash "$SANDBOX/probe-closed.sh" "$SCRIPTS" merge.auto 2>/dev/null)" "intact table: cfg merge.auto is its default"
assert_eq "reached:[3]" "$(PATH="$PYBIN:$PATH" bash "$SANDBOX/probe-closed.sh" "$SCRIPTS" limits.max_fix_attempts 2>/dev/null)" "intact table: cfg limits.max_fix_attempts is 3"
assert_eq "0" "$(wc -l < "$PYLOG" | tr -d ' ')" "intact table, no config: zero python3 spawns"
assert_eq "3" "$(PATH="$PYBIN:$PATH" bash "$SCRIPTS/pipeline-config.sh" limits.max_fix_attempts 2>/dev/null)" "intact table: pipeline-config.sh answers from the table"
assert_eq "0" "$(wc -l < "$PYLOG" | tr -d ' ')" "intact table, no config: pipeline-config.sh spawns no python3 either"

# the status-file fallback (no cfg cache, no usable table) says so instead of showing every role off
D="$(variant_dir nocache)" || exit 1
rm -f "$D/pipeline-cfg-cache.sh"
cp "$SCRIPTS/pipeline-defaults.sh" "$D/pipeline-defaults.sh" || exit 1
printf '%s' 'truncated' > "$D/pipeline-defaults.sh"
out="$(bash "$D/pipeline-status-file.sh" refresh --print 2>&1)"; rc=$?
assert_eq "1" "$rc" "status file without the cache and a usable table: exit 1"
assert_contains "$out" "defaults table unavailable" "status file without the cache and a usable table: one clear line"

finish
