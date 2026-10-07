#!/usr/bin/env bash
# test-config-golden-defaults.sh -- per-row pin of the config schema table
# (#440, epic #437). tests/fixtures/config-golden-defaults.tsv lists, for every
# key a call site relied on, the default `main` used before the call sites were
# migrated to scripts/pipeline-defaults.sh. This test runs each key with NO
# config layer setting it and compares what the table gives to that list, on
# every path a caller can take:
#
#   _talos_default KEY               the table lookup itself
#   pipeline-config.sh KEY           no config file (pure shell, no python3)
#   pipeline-config.sh KEY           a config file that does not set KEY (python3)
#   cfg KEY (pipeline-cfg-cache.sh)  the cached lookup every script uses
#
# so a wrong table default (status.log_days 30 -> 31) goes red here before it can
# change behaviour. The sandbox has its own TALOS_HOME and HOME: the developer's
# real ~/.talos is never read.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
export TALOS_HOME="$SANDBOX/talos-home"
mkdir -p "$TALOS_HOME" || exit 1
PROJ="$SANDBOX/project"
mkdir -p "$PROJ" || exit 1
cd "$PROJ" || exit 1

SCRIPTS="$TALOS_ROOT/scripts"
GOLDEN="$TALOS_ROOT/tests/fixtures/config-golden-defaults.tsv"
CFG_SH="$SCRIPTS/pipeline-config.sh"
assert_file_exists "$GOLDEN" "the golden list exists"

unset PIPELINE_CONFIG PIPELINE_REPO PIPELINE_PROJECT_NUMBER PIPELINE_BOARD_OWNER \
      PIPELINE_STATUS_FIELD PIPELINE_SLACK_CHANNEL PIPELINE_DISCORD_CHANNEL \
      PIPELINE_BUZZ_CHANNEL PIPELINE_BUZZ_RELAY

# decode: the \n of a list default is a newline on output
_dec() { printf '%s' "${1//\\n/$'\n'}"; }

# A config file that sets only a key no golden row reads, so every lookup below
# goes through python3 and the key under test is absent from every layer.
CFG_FILE="$SANDBOX/other.json"
printf '%s\n' '{"agents": {"roles": {"zzz": {"model": "m"}}}}' > "$CFG_FILE"

# One cached-lookup process answers every key: key<TAB>value lines, values
# with a newline written as \n so a line is a row.
PROBE="$SANDBOX/probe.sh"
cat > "$PROBE" <<'TALOS_PRBg7Wq2Nx4Hk9Zd'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$1"; shift
. "$SCRIPT_DIR/pipeline-cfg-cache.sh"
for k in "$@"; do
  v="$(cfg "$k")"
  printf '%s\t%s\n' "$k" "${v//$'\n'/\\n}"
done
TALOS_PRBg7Wq2Nx4Hk9Zd

# Not `IFS=$'\t' read`: a tab is whitespace to read, so an empty golden column
# would collapse and shift the fields.
_split() {
  key="${1%%$'\t'*}"; _r="${1#*$'\t'}"
  golden="${_r%%$'\t'*}"; _r="${_r#*$'\t'}"
  kind="${_r%%$'\t'*}"; sites="${_r#*$'\t'}"
}

KEYS=()
while IFS= read -r _line; do
  case "$_line" in ''|'#'*) continue ;; esac
  _split "$_line"
  KEYS+=("$key")
done < "$GOLDEN"
CACHED="$(PIPELINE_CONFIG="$CFG_FILE" bash "$PROBE" "$SCRIPTS" "${KEYS[@]}")"
CACHED_NOCFG="$(bash "$PROBE" "$SCRIPTS" "${KEYS[@]}")"

# shellcheck disable=SC1091
. "$SCRIPTS/pipeline-defaults.sh"

n_rows=0
while IFS= read -r _line; do
  case "$_line" in ''|'#'*) continue ;; esac
  _split "$_line"
  n_rows=$((n_rows + 1))
  want="$(_dec "$golden")"
  case "$kind" in
    table|empty)
      assert_eq "$want" "$(_talos_default "$key")" "$key: table default is the golden value ($sites)"
      assert_eq "$want" "$(bash "$CFG_SH" "$key" 2>/dev/null)" "$key: no config file prints the golden value"
      assert_eq "$want" "$(PIPELINE_CONFIG="$CFG_FILE" bash "$CFG_SH" "$key" 2>/dev/null)" \
        "$key: a config that does not set it prints the golden value"
      assert_eq "$golden" "$(printf '%s\n' "$CACHED" | awk -F'\t' -v k="$key" '$1 == k { print $2 }')" \
        "$key: cfg() with a config that does not set it prints the golden value"
      assert_eq "$golden" "$(printf '%s\n' "$CACHED_NOCFG" | awk -F'\t' -v k="$key" '$1 == k { print $2 }')" \
        "$key: cfg() with no config prints the golden value"
      ;;
    equiv)
      # merge.forbidden_files_replace: main passed "" and the table says false.
      # The only consumer compares the value with the word true, so the two are
      # the same behaviour. Pin that: no other test of the value exists.
      assert_eq "false" "$(_talos_default "$key")" "$key: table default is false"
      _uses="$(grep -c '"\$REPLACE"' "$SCRIPTS/pipeline-vcs.sh")"
      _true_uses="$(grep -c '"\$REPLACE" = "true"' "$SCRIPTS/pipeline-vcs.sh")"
      assert_eq "$_uses" "$_true_uses" "$key: every read of REPLACE tests for the word true, so '' and false behave alike"
      ;;
    explicit)
      # comments.header: pipeline-events.sh passes its own value on purpose
      # (no header when the key is unset). Behaviour pinned below.
      ;;
    *) fail "$key: unknown kind '$kind'" ;;
  esac
done < "$GOLDEN"
assert_eq "1" "$([ "$n_rows" -ge 100 ] && echo 1 || echo 0)" "the golden list has its rows ($n_rows)"

# ── Every table row with a default is pinned ─────────────────────────────────
_unpinned=""
while IFS= read -r tk; do
  case "$tk" in *'*'*) continue ;; esac
  _talos_defaults_row "$tk" || continue
  [ -n "$_TD_DEFAULT" ] || continue
  [ "$_TD_DERIVED" = "derived" ] && continue
  grep -q "^${tk//./\\.}	" "$GOLDEN" || _unpinned="$_unpinned $tk"
done <<EOF
$(_talos_defaults_keys)
EOF
assert_eq "" "$_unpinned" "every table row with a default has a golden row"

# ── pipeline-evidence.sh keeps its own safety-net fallbacks for evidence.dir,
# evidence.max_files, evidence.max_mb and verify.timeout_ms (variables and a
# first argument, not config-call literals). They must equal the table. ────────
_ev="$SCRIPTS/pipeline-evidence.sh"
assert_eq ".talos/evidence" "$(sed -n 's/^_EVIDENCE_DEFAULT_DIR="\(.*\)"$/\1/p' "$_ev")" "evidence.dir fallback equals the table"
assert_eq "$(_talos_default evidence.dir)" "$(sed -n 's/^_EVIDENCE_DEFAULT_DIR="\(.*\)"$/\1/p' "$_ev")" "evidence.dir fallback is the table default"
assert_eq "$(_talos_default evidence.max_files)" "$(sed -n 's/^_EVIDENCE_DEFAULT_MAX_FILES=\([0-9]*\)$/\1/p' "$_ev")" "evidence.max_files fallback is the table default"
assert_eq "$(_talos_default evidence.max_mb)" "$(sed -n 's/^_EVIDENCE_DEFAULT_MAX_MB=\([0-9]*\)$/\1/p' "$_ev")" "evidence.max_mb fallback is the table default"
assert_eq "$(_talos_default verify.timeout_ms)" "$(sed -n 's/.*_digits_or \([0-9]*\) "\$(cfg verify.timeout_ms)".*/\1/p' "$_ev")" "verify.timeout_ms fallback is the table default"

# ── comments.header: the events spend report keeps its no-header behaviour ───
mkdir -p "$SANDBOX/.git/talos" || exit 1
printf '%s\n' '{"event":"developer","role":"developer","issue":7,"pr":9,"verdict":"PASS","model":"sonnet","tokens":1000,"tool_uses":1,"duration_s":10,"ts":"2026-10-03T00:00:00Z"}' > "$SANDBOX/.git/talos/events.jsonl"
_first="$(bash "$SCRIPTS/pipeline-events.sh" cost --issue 7 --pr 9 --markdown 2>/dev/null | sed -n 1p)"
assert_eq "### Token spend — #7" "$_first" "comments.header unset: the spend report starts at its heading (no header line)"
printf '%s\n' '{"comments": {"header": "**Agent:** {role} (x)"}}' > "$PROJ/talos.pipeline.json"
_first="$(bash "$SCRIPTS/pipeline-events.sh" cost --issue 7 --pr 9 --markdown 2>/dev/null | sed -n 1p)"
assert_eq "**Agent:** orchestrator (x)" "$_first" "comments.header set: the spend report starts with it"
rm -f "${PROJ:?}/talos.pipeline.json"

finish
