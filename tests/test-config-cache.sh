#!/usr/bin/env bash
# Regression tests for the per-invocation config cache (#169): cfg() used to
# shell out to pipeline-config.sh (one python3 spawn) on every call; it now
# dumps the whole config once per script invocation and answers subsequent
# lookups from that cache.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

cat > talos.pipeline.json <<'EOF'
{"merge": {"method": "squash"}}
EOF

# ── AC1: a verb that previously spawned N pipeline-config.sh processes now ──
# spawns at most 1 ───────────────────────────────────────────────────────────
# pipeline-vcs.sh's config block (PROVIDER/REPO/BASE_BRANCH/MERGE_METHOD/
# AZURE_ORG/AZURE_PROJECT/FILE_PATH) alone calls cfg() 7 times, unconditionally,
# before any verb runs -- before the fix that was 7 python3 spawns; after the
# fix it must be exactly 1 (the --dump call). Wrap pipeline-config.sh itself
# with a logging shim (every real pipeline-config.sh invocation is exactly one
# python3 spawn) via a scripts dir of symlinks so pipeline-vcs.sh's own
# SCRIPT_DIR-relative "$SCRIPT_DIR/pipeline-config.sh" resolves to the shim.
WRAP="$SANDBOX/wrapped-scripts"
mkdir -p "$WRAP"
for f in "$TALOS_ROOT"/scripts/*.sh; do
  base="$(basename "$f")"
  [ "$base" = "pipeline-config.sh" ] && continue
  ln -s "$f" "$WRAP/$base"
done
cp "$TALOS_ROOT/scripts/pipeline-config.sh" "$WRAP/pipeline-config.real.sh"
chmod +x "$WRAP/pipeline-config.real.sh"
CFG_CALL_LOG="$SANDBOX/cfgsh-calls.log"
: > "$CFG_CALL_LOG"
cat > "$WRAP/pipeline-config.sh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CFG_CALL_LOG"
exec "$WRAP/pipeline-config.real.sh" "\$@"
SHIM
chmod +x "$WRAP/pipeline-config.sh"

bash "$WRAP/pipeline-vcs.sh" view-issue 1 >/dev/null 2>&1
_calls="$(wc -l < "$CFG_CALL_LOG" | tr -d ' ')"
assert_eq "1" "$_calls" \
  "view-issue (7+ cfg() call sites before verb dispatch) spawns pipeline-config.sh exactly once (#169 AC1)"
_first_call="$(head -n1 "$CFG_CALL_LOG")"
assert_eq "--dump" "$_first_call" "the single spawn is the --dump call, not a per-key lookup (#169)"

# ── AC3: a config edit made mid-invocation is NOT picked up ─────────────────
cat > "$SANDBOX/probe-mid-edit.sh" <<'PROBE'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$1"
. "$SCRIPT_DIR/pipeline-cfg-cache.sh"
first="$(cfg merge.method "")"
cat > talos.pipeline.json <<'EOF2'
{"merge": {"method": "rebase"}}
EOF2
second="$(cfg merge.method "")"
printf '%s\n%s\n' "$first" "$second"
PROBE
_out="$(bash "$SANDBOX/probe-mid-edit.sh" "$TALOS_ROOT/scripts")"
_first="$(printf '%s\n' "$_out" | sed -n '1p')"
_second="$(printf '%s\n' "$_out" | sed -n '2p')"
assert_eq "squash" "$_first" "first cfg() call in an invocation sees the config on disk at load time (#169)"
assert_eq "squash" "$_second" \
  "a config edit made mid-invocation is not picked up by a later cfg() call in the same process (#169 AC3)"

# ── AC3 converse: a fresh invocation always re-dumps and sees the edit ──────
cat > talos.pipeline.json <<'EOF'
{"merge": {"method": "squash"}}
EOF
cat > "$SANDBOX/probe-single.sh" <<'PROBE'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$1"
. "$SCRIPT_DIR/pipeline-cfg-cache.sh"
cfg merge.method ""
PROBE
_run1="$(bash "$SANDBOX/probe-single.sh" "$TALOS_ROOT/scripts")"
cat > talos.pipeline.json <<'EOF'
{"merge": {"method": "rebase"}}
EOF
_run2="$(bash "$SANDBOX/probe-single.sh" "$TALOS_ROOT/scripts")"
assert_eq "squash" "$_run1" "first (pre-edit) invocation reads the original value (#169)"
assert_eq "rebase" "$_run2" \
  "a new script invocation re-dumps the config and sees an edit made between invocations (#169)"

# ── Cache temp file is removed on exit, including on error ──────────────────
cat > "$SANDBOX/probe-normal-exit.sh" <<'PROBE'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$1"
. "$SCRIPT_DIR/pipeline-cfg-cache.sh"
cfg merge.method "" >/dev/null
printf '%s' "$_CFG_CACHE_FILE"
PROBE
_cap_normal="$(bash "$SANDBOX/probe-normal-exit.sh" "$TALOS_ROOT/scripts")"
assert_eq "0" "$( [ -e "$_cap_normal" ] && echo 1 || echo 0 )" \
  "config cache temp file is removed on normal exit (#169)"

cat > "$SANDBOX/probe-error-exit.sh" <<'PROBE'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$1"
CAPTURE_TO="$2"
. "$SCRIPT_DIR/pipeline-cfg-cache.sh"
cfg merge.method "" >/dev/null
printf '%s' "$_CFG_CACHE_FILE" > "$CAPTURE_TO"
exit 1
PROBE
_errcap="$SANDBOX/errcap.txt"
bash "$SANDBOX/probe-error-exit.sh" "$TALOS_ROOT/scripts" "$_errcap" || true
_cap_error="$(cat "$_errcap")"
assert_eq "0" "$( [ -e "$_cap_error" ] && echo 1 || echo 0 )" \
  "config cache temp file is removed even when the script exits non-zero (#169)"

# ── Existing composable-trap consumer (post-approval's own tempfile) is ─────
# still cleaned up alongside the config cache -- proves the two EXIT hooks
# compose instead of one clobbering the other (#169).
cat > "$SANDBOX/probe-two-hooks.sh" <<'PROBE'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$1"
CAPTURE_TO="$2"
. "$SCRIPT_DIR/pipeline-cfg-cache.sh"
cfg merge.method "" >/dev/null
_other_tmp="$(mktemp)"
_talos_on_exit "rm -f \"$_other_tmp\""
printf '%s\n%s\n' "$_CFG_CACHE_FILE" "$_other_tmp" > "$CAPTURE_TO"
PROBE
_two_cap="$SANDBOX/twocap.txt"
bash "$SANDBOX/probe-two-hooks.sh" "$TALOS_ROOT/scripts" "$_two_cap"
_two_cfg="$(sed -n '1p' "$_two_cap")"
_two_other="$(sed -n '2p' "$_two_cap")"
assert_eq "0" "$( [ -e "$_two_cfg" ] && echo 1 || echo 0 )" \
  "config cache cleanup still runs when another site also registers an exit hook (#169)"
assert_eq "0" "$( [ -e "$_two_other" ] && echo 1 || echo 0 )" \
  "a second site's own exit hook (e.g. post-approval's tempfile) also runs -- hooks compose, not clobber (#169)"

# ── Missing-helper fallback: a partial install/sync that has every script ───
# except pipeline-cfg-cache.sh must not silently lose cfg() (#169 review
# finding on PR #213). Reuse the AC1 WRAP dir but drop the cache-helper
# symlink to simulate the helper being absent from $SCRIPT_DIR.
WRAP_NO_HELPER="$SANDBOX/wrapped-no-helper"
mkdir -p "$WRAP_NO_HELPER"
for f in "$TALOS_ROOT"/scripts/*.sh; do
  base="$(basename "$f")"
  [ "$base" = "pipeline-cfg-cache.sh" ] && continue
  ln -s "$f" "$WRAP_NO_HELPER/$base"
done
cat > talos.pipeline.json <<'EOF'
{"merge": {"method": "squash"}}
EOF
_nh_stderr="$SANDBOX/no-helper.stderr"
_nh_stdout="$(bash "$WRAP_NO_HELPER/pipeline-vcs.sh" --dry-run merge-pr 9 2>"$_nh_stderr")"
assert_contains "$_nh_stdout" "--squash" \
  "cfg() still resolves merge.method correctly when pipeline-cfg-cache.sh is missing (#169 fallback)"
_nh_warn_count="$(grep -c "^pipeline: config cache helper missing, falling back to per-call parsing$" "$_nh_stderr")"
assert_eq "1" "$_nh_warn_count" \
  "missing-helper fallback prints exactly one stderr warning (#169 fallback)"

finish
