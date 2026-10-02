#!/usr/bin/env bash
# test-config-status-keys.sh -- covers issue #343 (sub-task of epic #333):
# the nine status.* config keys for the built-in status file are known keys
# (no unknown-key warning), default correctly when absent, and the three
# numeric ones share the positive-integer validation on BOTH the single-key
# path and the --dump path. JSON fixtures only (stdlib parsing, genuine on
# every runner; see test-config-unknown-keys.sh).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"

# ---- 1: all nine keys set -> no unknown-key warning on either path ---------
cat > talos.pipeline.json <<'EOF'
{"status": {"enabled": true, "file": "S.md", "log_heading": "## L",
  "resume_heading": "## R", "fragments_dir": "docs/status.d",
  "archive_dir": "status/archive", "log_days": 30, "log_max": 50,
  "resume_max_lines": 40}}
EOF
err1="$(bash "$CFG_SH" status.file X 2>&1 1>/dev/null)"
assert_eq "" "$err1" "1: single-key path: no stderr (no unknown-key warning)"
err1d="$(bash "$CFG_SH" --dump 2>&1 1>/dev/null)"
assert_eq "" "$err1d" "1: --dump path: no stderr (no unknown-key warning)"
assert_eq "S.md" "$(bash "$CFG_SH" status.file X 2>/dev/null)" "1: configured value is returned"
rm talos.pipeline.json

# ---- 2: no status block -> caller defaults come back -----------------------
cat > talos.pipeline.json <<'EOF'
{"base_branch": "main"}
EOF
assert_eq "false" "$(bash "$CFG_SH" status.enabled false 2>/dev/null)" "2: status.enabled default"
assert_eq "docs/status.d" "$(bash "$CFG_SH" status.fragments_dir docs/status.d 2>/dev/null)" "2: status.fragments_dir default"
rm talos.pipeline.json

# ---- 3: positive-integer validation, both paths ----------------------------
for name in log_days log_max resume_max_lines; do
  key="status.$name"
  for bad in '"abc"' 0 -5; do
    printf '{"status": {"%s": %s}}\n' "$name" "$bad" > talos.pipeline.json
    out="$(bash "$CFG_SH" "$key" 99 2>err.txt)"
    err="$(cat err.txt)"
    assert_eq "99" "$out" "3: $key=$bad single-key prints the caller default"
    assert_contains "$err" "$key must be a positive integer" "3: $key=$bad single-key warns"
    assert_eq "1" "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" "3: $key=$bad single-key warns once"
    dump="$(bash "$CFG_SH" --dump 2>err.txt)"
    err="$(cat err.txt)"
    assert_not_contains "$dump" "$key" "3: $key=$bad --dump omits the key (caller default applies)"
    assert_contains "$err" "$key must be a positive integer" "3: $key=$bad --dump warns"
  done
  printf '{"status": {"%s": 7}}\n' "$name" > talos.pipeline.json
  assert_eq "7" "$(bash "$CFG_SH" "$key" 99 2>/dev/null)" "3: $key=7 is accepted"
  rm talos.pipeline.json
done

finish
