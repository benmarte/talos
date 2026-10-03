#!/usr/bin/env bash
# test-config-spend-keys.sh -- covers issue #378 (sub-task 1 of epic #334):
# limits.tokens_per_issue, limits.warn_at and spend.comment are known config
# keys (no unknown-key warning), validated identically on the single-key path
# and the --dump path (fail closed to absent, one stderr line), never get a
# default injected by --dump (callers pass 0.8 / true), are ignored in the
# user-level file, and talos:spend / talos:budget are contract markers. JSON
# fixtures only (stdlib parsing, genuine on every runner).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
ERR="$SANDBOX/err.txt"
TPI="limits.tokens_per_issue"
WARN="limits.warn_at"
CMT="spend.comment"

# set_cfg <json> -- (re)write the project config.
set_cfg() { printf '%s\n' "$1" > talos.pipeline.json; }
# single <key> <default> -- single-key path; stderr lands in $ERR.
single() { bash "$CFG_SH" "$1" "$2" 2>"$ERR"; }
# dumped <key> -- the value --dump holds for <key>, or "<absent>"; stderr in $ERR.
dumped() {
  bash "$CFG_SH" --dump 2>"$ERR" | tr '\0' '\n' | awk -v k="$1" '
    NR % 2 == 1 { cur = $0; next }
    cur == k { print; found = 1 }
    END { if (!found) print "<absent>" }'
}
errlines() { wc -l < "$ERR" | tr -d ' '; }
errtext() { cat "$ERR"; }

# ---- 1: valid values -> no unknown-key warning, value readable -------------
set_cfg '{"limits": {"tokens_per_issue": 500000, "warn_at": 0.5}, "spend": {"comment": false}}'
assert_eq "500000" "$(single $TPI "")" "1: single-key tokens_per_issue"
assert_eq "0" "$(errlines)" "1: single-key: no stderr (no unknown-key warning)"
assert_eq "0.5" "$(single $WARN 0.8)" "1: single-key warn_at"
assert_eq "false" "$(single $CMT true)" "1: single-key spend.comment"
bash "$CFG_SH" --dump 2>"$ERR" >/dev/null
assert_eq "0" "$(errlines)" "1: --dump: no stderr (no unknown-key warning)"
assert_eq "500000" "$(dumped $TPI)" "1: --dump tokens_per_issue"
assert_eq "0.5" "$(dumped $WARN)" "1: --dump warn_at"
assert_eq "false" "$(dumped $CMT)" "1: --dump spend.comment"

# cfg() (per-invocation cache over --dump) answers the same.
cfg_out="$(SCRIPT_DIR="$TALOS_ROOT/scripts"; . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
  printf '%s|%s|%s' "$(cfg $TPI "")" "$(cfg $WARN 0.8)" "$(cfg $CMT true)")"
assert_eq "500000|0.5|false" "$cfg_out" "1: cfg() reads all three keys"

# ---- 2: absent -> caller defaults, --dump injects nothing ------------------
set_cfg '{"base_branch": "main"}'
assert_eq "" "$(single $TPI "")" "2: tokens_per_issue unset -> empty (guard off)"
assert_eq "0.8" "$(single $WARN 0.8)" "2: warn_at unset -> caller default 0.8"
assert_eq "true" "$(single $CMT true)" "2: spend.comment unset -> caller default true"
assert_eq "0" "$(errlines)" "2: absent keys are silent"
dump_all="$(bash "$CFG_SH" --dump 2>/dev/null | tr '\0' '\n')"
assert_not_contains "$dump_all" "limits.tokens_per_issue" "2: --dump injects no tokens_per_issue"
assert_not_contains "$dump_all" "limits.warn_at" "2: --dump injects no warn_at"
assert_not_contains "$dump_all" "spend.comment" "2: --dump injects no spend.comment"

# ---- 3: tokens_per_issue ---------------------------------------------------
for ok in 0 '"0"'; do
  set_cfg "{\"limits\": {\"tokens_per_issue\": $ok}}"
  assert_eq "" "$(single $TPI "")" "3: tokens_per_issue=$ok single-key -> default (off)"
  assert_eq "0" "$(errlines)" "3: tokens_per_issue=$ok single-key is silent"
  assert_eq "<absent>" "$(dumped $TPI)" "3: tokens_per_issue=$ok --dump omits the key"
  assert_eq "0" "$(errlines)" "3: tokens_per_issue=$ok --dump is silent"
done
for bad in '"abc"' -5 3.7 true '"3.7"' '"5; rm -rf x"'; do
  set_cfg "{\"limits\": {\"tokens_per_issue\": $bad}}"
  assert_eq "" "$(single $TPI "")" "3: tokens_per_issue=$bad single-key -> default (off)"
  assert_contains "$(errtext)" "$TPI must be a positive integer" "3: tokens_per_issue=$bad single-key warns"
  assert_eq "1" "$(errlines)" "3: tokens_per_issue=$bad single-key warns once"
  assert_eq "<absent>" "$(dumped $TPI)" "3: tokens_per_issue=$bad --dump omits the key"
  assert_contains "$(errtext)" "$TPI must be a positive integer" "3: tokens_per_issue=$bad --dump warns"
  assert_eq "1" "$(errlines)" "3: tokens_per_issue=$bad --dump warns once"
done
set_cfg '{"limits": {"tokens_per_issue": 1000000}}'
assert_eq "1000000" "$(single $TPI "")" "3: positive integer accepted (single-key)"
assert_eq "1000000" "$(dumped $TPI)" "3: positive integer accepted (--dump)"

# ---- 4: warn_at ------------------------------------------------------------
for ok in 0.8 0.01 1 1.0 '"0.5"'; do
  set_cfg "{\"limits\": {\"warn_at\": $ok}}"
  single_out="$(single $WARN 0.8)"
  assert_eq "0" "$(errlines)" "4: warn_at=$ok single-key accepted silently"
  assert_eq "$single_out" "$(dumped $WARN)" "4: warn_at=$ok single-key and --dump agree"
done
set_cfg '{"limits": {"warn_at": 1}}'
assert_eq "1.0" "$(single $WARN 0.8)" "4: integer 1 is accepted (normalised to 1.0)"
for bad in 0 0.0 -0.5 1.5 2 '"abc"' true false '"nan"' '"inf"' '"0.5; rm -rf x"'; do
  set_cfg "{\"limits\": {\"warn_at\": $bad}}"
  assert_eq "0.8" "$(single $WARN 0.8)" "4: warn_at=$bad single-key falls back to 0.8"
  assert_contains "$(errtext)" "$WARN must be a number" "4: warn_at=$bad single-key warns"
  assert_eq "1" "$(errlines)" "4: warn_at=$bad single-key warns once"
  assert_eq "<absent>" "$(dumped $WARN)" "4: warn_at=$bad --dump omits the key"
  assert_contains "$(errtext)" "$WARN must be a number" "4: warn_at=$bad --dump warns"
  assert_eq "1" "$(errlines)" "4: warn_at=$bad --dump warns once"
done

# ---- 5: spend.comment ------------------------------------------------------
for ok in true false; do
  set_cfg "{\"spend\": {\"comment\": $ok}}"
  assert_eq "$ok" "$(single $CMT true)" "5: spend.comment=$ok single-key"
  assert_eq "0" "$(errlines)" "5: spend.comment=$ok single-key is silent"
  assert_eq "$ok" "$(dumped $CMT)" "5: spend.comment=$ok --dump"
done
for bad in '"yes"' 1 0 '"maybe"' '"true; rm -rf x"'; do
  set_cfg "{\"spend\": {\"comment\": $bad}}"
  assert_eq "true" "$(single $CMT true)" "5: spend.comment=$bad single-key falls back to true"
  assert_contains "$(errtext)" "$CMT must be true or false" "5: spend.comment=$bad single-key warns"
  assert_eq "1" "$(errlines)" "5: spend.comment=$bad single-key warns once"
  assert_eq "<absent>" "$(dumped $CMT)" "5: spend.comment=$bad --dump omits the key"
  assert_contains "$(errtext)" "$CMT must be true or false" "5: spend.comment=$bad --dump warns"
  assert_eq "1" "$(errlines)" "5: spend.comment=$bad --dump warns once"
done

# ---- 6: --dump on a fixture with none of the keys is unchanged -------------
# Pre-computed from main (e662932), see the expected string below: the dump
# carries the keys present plus verify.qa_mode's derived default, and nothing
# for the three new keys.
set_cfg '{"base_branch": "main", "limits": {"max_fix_attempts": 3}}'
bash "$CFG_SH" --dump 2>/dev/null | tr '\0' '\n' > "$SANDBOX/dump-now.txt"
printf 'base_branch\nmain\nlimits.max_fix_attempts\n3\nverify.qa_mode\nlocal\n' > "$SANDBOX/dump-main.txt"
if cmp -s "$SANDBOX/dump-main.txt" "$SANDBOX/dump-now.txt"; then
  pass "6: --dump without the new keys is byte-identical to main"
else
  fail "6: --dump without the new keys is byte-identical to main" "$(cat "$SANDBOX/dump-now.txt")"
fi

# ---- 7: user-level file does not layer the new keys ------------------------
case "$HOME" in
  "$SANDBOX"/*) ;;
  *) echo "FATAL: HOME is outside the sandbox" >&2; exit 1 ;;
esac
USER_DIR="$HOME/.talos"
mkdir -p "$USER_DIR"
printf '%s\n' '{"limits": {"tokens_per_issue": 5, "warn_at": 0.3}, "spend": {"comment": false}}' > "$USER_DIR/talos.pipeline.json"
rm -f talos.pipeline.json
assert_eq "" "$(single $TPI "")" "7: user-level tokens_per_issue ignored (single-key)"
assert_eq "0.8" "$(single $WARN 0.8)" "7: user-level warn_at ignored (single-key)"
assert_eq "true" "$(single $CMT true)" "7: user-level spend.comment ignored (single-key)"
set_cfg '{"base_branch": "main"}'
dump_all="$(bash "$CFG_SH" --dump 2>/dev/null | tr '\0' '\n')"
assert_not_contains "$dump_all" "tokens_per_issue" "7: user-level tokens_per_issue absent from --dump"
assert_not_contains "$dump_all" "warn_at" "7: user-level warn_at absent from --dump"
assert_not_contains "$dump_all" "spend.comment" "7: user-level spend.comment absent from --dump"
rm -rf "$USER_DIR"

# ---- 8: contract markers ---------------------------------------------------
contract="$(. "$TALOS_ROOT/scripts/pipeline-contract.sh"; printf '%s\n' "${TALOS_MARKERS[@]}")"
assert_contains "$contract" "talos:spend" "8: talos:spend is a TALOS_MARKERS member"
assert_contains "$contract" "talos:budget" "8: talos:budget is a TALOS_MARKERS member"

finish
