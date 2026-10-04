#!/usr/bin/env bash
# test-config-int-validators.sh -- every integer key of the config schema table
# is validated (#440, epic #437; follow-up to the #463 QA note that
# limits.max_fix_attempts accepted -1 from any layer).
#
# A bad value (not a number, negative, fractional, a bool, above the key's
# highest) warns on stderr, names the key, and the lookup falls back to the
# table default -- on both paths a caller can take: pipeline-config.sh KEY and
# the cached cfg() (pipeline-cfg-cache.sh, answered from --dump).
#
# Every `int` row of the table must be in exactly one bucket, so a new int key
# cannot slip in unvalidated:
#   BOUNDS    validated here by _CFG_INT_PY (key lo hi)
#   OWN       has its own validator in pipeline-config.sh (spend, evidence,
#             failover keys); tested in their own files
#   CONSUMER  the consumer already refuses or falls back with its own message
#             (issues.max_parallel #120 in test-isolation.sh, limits.max_retries
#             #194 in test-github-api.sh)
# The sandbox has its own TALOS_HOME and HOME: the real ~/.talos is never read.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
export TALOS_HOME="$SANDBOX/talos-home"
mkdir -p "$TALOS_HOME" || exit 1
PROJ="$SANDBOX/project"
mkdir -p "$PROJ" || exit 1
cd "$PROJ" || exit 1

SCRIPTS="$TALOS_ROOT/scripts"
CFG_SH="$SCRIPTS/pipeline-config.sh"
unset PIPELINE_CONFIG PIPELINE_PROJECT_NUMBER
# shellcheck disable=SC1091
. "$SCRIPTS/pipeline-defaults.sh"

BOUNDS="verify.timeout_ms:1:86400000 verify.ci_wait_s:1:86400 hooks.timeout_s:1:86400
notifications.cmd_timeout_s:1:86400 notifications.buzz_timeout_s:1:3600
status.log_days:1:999999 status.log_max:1:999999 status.resume_max_lines:1:999999
limits.max_fix_attempts:1:100 limits.max_total_dispatches:1:1000
execution.worktree_warn_threshold:0:10000 board.project_number:1:2147483647"
BOUNDS="$(printf '%s' "$BOUNDS" | tr '\n' ' ')"
OWN="limits.tokens_per_issue evidence.max_files evidence.max_mb agents.provider_down_s"
CONSUMER="issues.max_parallel limits.max_retries"

# ── Every int row is in a bucket ─────────────────────────────────────────────
_int_rows=""
while IFS= read -r _tk; do
  _talos_defaults_row "$_tk" || continue
  [ "$_TD_TYPE" = "int" ] && _int_rows="$_int_rows $_tk"
done <<EOF
$(_talos_defaults_keys)
EOF
_unbucketed=""
for _k in $_int_rows; do
  case " $BOUNDS $OWN $CONSUMER " in
    *" $_k "*|*" $_k:"*) ;;
    *) _unbucketed="$_unbucketed $_k" ;;
  esac
done
assert_eq "" "$_unbucketed" "every int row of the table has a validator, an owner or a consumer that rejects bad values"

cfg_json() { printf '%s\n' "$1" > "$PROJ/talos.pipeline.json"; }
# set KEY RAWJSON -- write {"a":{"b":RAW}} for KEY a.b
set_key() {
  python3 -I - "$1" "$2" > "$PROJ/talos.pipeline.json" <<'TALOS_PYset6Qv9Dm3Xt'
import json, sys
key, raw = sys.argv[1], sys.argv[2]
node = json.loads(raw)
for part in reversed(key.split(".")):
    node = {part: node}
print(json.dumps(node))
TALOS_PYset6Qv9Dm3Xt
}
probe() {  # KEY -> the cached cfg() value
  bash -c 'SCRIPT_DIR="$1"; . "$SCRIPT_DIR/pipeline-cfg-cache.sh"; printf "%s" "$(cfg "$2")"' _ "$SCRIPTS" "$1" 2>/dev/null
}

for spec in $BOUNDS; do
  key="${spec%%:*}"; _r="${spec#*:}"; lo="${_r%%:*}"; hi="${_r#*:}"
  want="$(_talos_default "$key")"
  # a value that is fine passes through untouched
  good=$((lo + 1)); [ "$good" -le "$hi" ] || good="$lo"
  set_key "$key" "$good"
  assert_eq "$good" "$(bash "$CFG_SH" "$key" 2>/dev/null)" "$key: $good is accepted (pipeline-config.sh)"
  assert_eq "$good" "$(probe "$key")" "$key: $good is accepted (cfg)"
  set_key "$key" "\"$good\""
  assert_eq "$good" "$(bash "$CFG_SH" "$key" 2>/dev/null)" "$key: the string \"$good\" is accepted"
  # the edges
  set_key "$key" "$hi"
  assert_eq "$hi" "$(bash "$CFG_SH" "$key" 2>/dev/null)" "$key: the highest value $hi is accepted"
  set_key "$key" "$lo"
  assert_eq "$lo" "$(bash "$CFG_SH" "$key" 2>/dev/null)" "$key: the lowest value $lo is accepted"
  # bad values: warn naming the key, fall back to the table default
  for bad in '"abc"' '-1' '1.5' 'true' '"1; touch PWNED"' "$((hi + 1))" '""'; do
    set_key "$key" "$bad"
    _out="$(bash "$CFG_SH" "$key" 2>"$SANDBOX/err")"
    assert_eq "$want" "$_out" "$key: $bad falls back to the table default '$want'"
    assert_contains "$(cat "$SANDBOX/err")" "pipeline-config: $key must be" "$key: $bad warns and names the key"
    assert_eq "$want" "$(probe "$key")" "$key: $bad falls back to the table default through cfg() too"
  done
done
assert_file_absent "$PROJ/PWNED" "a shell metacharacter in an integer key never ran"

# ── A bad value is bad from the global layer too (the validator runs on the merge)
mkdir -p "$TALOS_HOME" || exit 1
printf '%s\n' '{"limits": {"max_fix_attempts": -1}}' > "$TALOS_HOME/talos.pipeline.json"
rm -f "$PROJ/talos.pipeline.json"
assert_eq "3" "$(bash "$CFG_SH" limits.max_fix_attempts 2>/dev/null)" "limits.max_fix_attempts: -1 from the global file falls back to 3"
printf '%s\n' '{"limits": {"max_fix_attempts": 5}}' > "$TALOS_HOME/talos.pipeline.json"
printf '%s\n' '{"limits": {"max_fix_attempts": 0}}' > "$PROJ/talos.pipeline.json"
assert_eq "3" "$(bash "$CFG_SH" limits.max_fix_attempts 2>/dev/null)" "limits.max_fix_attempts: a repo 0 is rejected, and does not reveal the global 5 (the merged value is validated)"
rm -f "$TALOS_HOME/talos.pipeline.json" "$PROJ/talos.pipeline.json"

# ── An explicit caller default still wins over the table for a bad value ────
set_key limits.max_fix_attempts '-1'
assert_eq "7" "$(bash "$CFG_SH" limits.max_fix_attempts 7 2>/dev/null)" "an explicit caller default still answers for a rejected value"

# ── The bounds above are the ones the script carries (no silent drift) ───────
_script_bounds="$(python3 -I - "$CFG_SH" <<'TALOS_PYbnd2Xr7Ls5Jw'
import ast, re, sys
src = open(sys.argv[1]).read()
m = re.search(r"_INT_KEYS = (\{.*?\n\})", src, re.S)
d = ast.literal_eval(m.group(1))
print(" ".join(sorted("%s:%d:%d" % (k, v[1], v[2]) for k, v in d.items())))
TALOS_PYbnd2Xr7Ls5Jw
)"
_test_bounds="$(printf '%s\n' $BOUNDS | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "$_test_bounds" "$_script_bounds" "the bounds this test pins are the ones pipeline-config.sh carries"

finish
