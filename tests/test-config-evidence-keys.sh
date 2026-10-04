#!/usr/bin/env bash
# test-config-evidence-keys.sh -- covers issue #405 (sub-task 1 of epic #352):
# the evidence.* config keys (enabled, command, dir, include, when, store,
# max_files, max_mb) are known keys (no unknown-key warning), validated
# identically on the single-key path and the --dump path (fail closed to absent,
# one stderr line), never get a default injected by --dump, are ignored in the
# user-level file, and talos:evidence is a contract marker. JSON fixtures only
# (stdlib parsing, genuine on every runner).
#
# Decisions pinned here (the issue left them open):
#   - max_files / max_mb: a real integer or a 1-4 digit string; 12.0, " 12 ",
#     "1_0", "+5" and bool are rejected (strict, unlike spend.*).
#   - include: a list of basename globs; a bare string, [], a non-string item
#     or ONE bad item makes the whole value absent (fail closed).
#   - dir: first component ".git" (any case, after dropping "." and empty
#     components) is rejected; so are "..", a leading "/", control characters.
#   - store: only "attach" (gh pr comment --attach; owner decision on #352).
#     There is no evidence.branch key.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
ERR="$SANDBOX/err.txt"
D200="$(printf 'd%.0s' $(seq 1 200))"
D201="$(printf 'd%.0s' $(seq 1 201))"
G64="$(printf 'g%.0s' $(seq 1 64))"
G65="$(printf 'g%.0s' $(seq 1 65))"
# json_list <n> <item> -- a JSON list of <n> copies of <item>.
json_list() { local i out="" ; for ((i = 0; i < $1; i++)); do out="$out${out:+, }\"$2\""; done; printf '[%s]' "$out"; }
CMD2000="$(printf 'x%.0s' $(seq 1 2000))"
CMD2001="$(printf 'x%.0s' $(seq 1 2001))"

# set_cfg <json> -- (re)write the project config.
set_cfg() { printf '%s\n' "$1" > talos.pipeline.json; }
# ev_cfg <key> <json-value> -- config holding evidence.<key> = value.
ev_cfg() { set_cfg "{\"evidence\": {\"$1\": $2}}"; }
# single <key> <default> -- single-key path; stderr lands in $ERR.
single() { bash "$CFG_SH" "$1" "$2" 2>"$ERR"; }
# dumped <key> -- the value --dump holds for <key> (newlines kept), or
# "<absent>"; stderr in $ERR. Split on NUL in python (values may be multiline).
dumped() {
  bash "$CFG_SH" --dump 2>"$ERR" | python3 -I -c '
import sys
parts = sys.stdin.buffer.read().split(b"\0")
d = dict(zip(parts[0::2], parts[1::2]))
k = sys.argv[1].encode()
sys.stdout.write(d[k].decode() if k in d else "<absent>")' "$1"
}
errlines() { wc -l < "$ERR" | tr -d ' '; }
errtext() { cat "$ERR"; }

# ev_ok <key> <json-value> <expected-text> <label> -- accepted silently on both
# paths, same value on both.
ev_ok() {
  ev_cfg "${1#evidence.}" "$2"
  assert_eq "$3" "$(single "$1" "DEF")" "$4: single-key"
  assert_eq "0" "$(errlines)" "$4: single-key is silent"
  assert_eq "$3" "$(dumped "$1")" "$4: --dump"
  assert_eq "0" "$(errlines)" "$4: --dump is silent"
}
# ev_bad <key> <json-value> <label> -- rejected on both paths: one warning each
# naming the key, caller default on single-key, key omitted from --dump.
ev_bad() {
  ev_cfg "${1#evidence.}" "$2"
  assert_eq "DEF" "$(single "$1" "DEF")" "$3: single-key falls back to the default"
  assert_contains "$(errtext)" "$1 must be" "$3: single-key warns"
  assert_eq "1" "$(errlines)" "$3: single-key warns once"
  assert_eq "<absent>" "$(dumped "$1")" "$3: --dump omits the key"
  assert_contains "$(errtext)" "$1 must be" "$3: --dump warns"
  assert_eq "1" "$(errlines)" "$3: --dump warns once"
}

# ---- 1: every key valid at once -> no unknown-key warning ------------------
set_cfg '{"evidence": {"enabled": true, "command": "npm run shots", "dir": "docs/shots", "include": ["*.png", "*.webm"], "when": "always", "store": "attach", "max_files": 12, "max_mb": 25}}'
bash "$CFG_SH" --dump 2>"$ERR" >/dev/null
assert_eq "0" "$(errlines)" "1: --dump: no stderr (no unknown-key warning)"
assert_eq "true" "$(single evidence.enabled false)" "1: single-key enabled"
assert_eq "0" "$(errlines)" "1: single-key: no stderr"
assert_eq "npm run shots" "$(dumped evidence.command)" "1: --dump command"
assert_eq "docs/shots" "$(dumped evidence.dir)" "1: --dump dir"
assert_eq "always" "$(dumped evidence.when)" "1: --dump when"
assert_eq "attach" "$(dumped evidence.store)" "1: --dump store"
assert_eq "12" "$(dumped evidence.max_files)" "1: --dump max_files"
assert_eq "25" "$(dumped evidence.max_mb)" "1: --dump max_mb"
assert_eq "$(printf '*.png\n*.webm')" "$(dumped evidence.include)" "1: --dump include is newline-joined"
assert_eq "$(printf '*.png\n*.webm')" "$(single evidence.include "")" "1: single-key include is newline-joined (like merge.required_checks)"

# cfg() (per-invocation cache over --dump) answers the same.
cfg_out="$(SCRIPT_DIR="$TALOS_ROOT/scripts"; . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
  printf '%s|%s' "$(cfg evidence.enabled false)" "$(cfg evidence.max_mb 25)")"
assert_eq "true|25" "$cfg_out" "1: cfg() reads the keys"

# ---- 2: absent -> caller defaults, --dump injects nothing ------------------
set_cfg '{"base_branch": "main"}'
for k in enabled command dir include when store max_files max_mb; do
  assert_eq "DEF" "$(single evidence.$k DEF)" "2: evidence.$k unset -> caller default"
  assert_eq "0" "$(errlines)" "2: evidence.$k unset is silent"
done
dump_all="$(bash "$CFG_SH" --dump 2>/dev/null | tr '\0' '\n')"
assert_not_contains "$dump_all" "evidence" "2: --dump injects no evidence key"
set_cfg '{"evidence": {}}'
assert_not_contains "$(bash "$CFG_SH" --dump 2>/dev/null | tr '\0' '\n')" "evidence" "2: empty block injects nothing"

# ---- 3: enabled is a strict bool -------------------------------------------
ev_ok evidence.enabled true true "3: enabled=true"
ev_ok evidence.enabled false false "3: enabled=false"
for bad in '"true"' '"yes"' 1 0 '"false"' '[]'; do
  ev_bad evidence.enabled "$bad" "3: enabled=$bad"
done

# ---- 4: when / store are enums (table-driven; adding attach = one word) ----
ENUMS=("evidence.when|user-facing always" "evidence.store|attach")
for row in "${ENUMS[@]}"; do
  ekey="${row%%|*}"
  for v in ${row#*|}; do
    ev_ok "$ekey" "\"$v\"" "$v" "4: $ekey=$v"
  done
  for bad in '""' '"ALWAYS"' '"Attach"' '"nope"' '" always"' '"always\n"' '"attach\n"' 1 true '["attach"]' '"attach; rm -rf x"'; do
    ev_bad "$ekey" "$bad" "4: $ekey=$bad"
  done
done

# ---- 5: max_files / max_mb: integer 1..100, strict -------------------------
for ekey in evidence.max_files evidence.max_mb; do
  for ok in 1 12 100 '"7"' '"100"'; do
    ev_ok "$ekey" "$ok" "$(printf '%s' "$ok" | tr -d '"')" "5: $ekey=$ok"
  done
  for bad in 0 -1 101 1000 12.0 12.5 true false '" 12 "' '"1_0"' '"+5"' '"abc"' '""' '"0"' '"101"' '"12\n"' '"12.0"' '"0x10"' '"99999"' '[]' '"5; rm -rf x"'; do
    ev_bad "$ekey" "$bad" "5: $ekey=$bad"
  done
done

# ---- 6: dir ----------------------------------------------------------------
for ok in "docs/shots" "evidence" "a/b/c" "./shots" ".talos/evidence" "test-results/qa" ".github/x" "a..b" "gitx/y" ".gitignore.d" "$D200"; do
  ev_ok evidence.dir "\"$ok\"" "$ok" "6: dir=${ok:0:20}"
done
for bad in '""' '"."' '"./"' '"/"' '"/abs"' '"/etc"' '".."' '"../x"' '"a/../b"' '"a/.."' '"a/./../b"' \
           '".git"' '".git/x"' '".GIT/x"' '".Git"' '"./.git/x"' '".//.git/x"' '"./.git"' \
           '"a/.git/x"' '"a/b/.GIT"' '"a/./.git"' \
           '"my shots"' '"-delete"' '"*"' '"!x"' '"#x"' '"[ab]"' '"a;b"' '"$HOME"' '"a b"' '"a$(x)"' '"a`x`"' '"a|b"' '"a&b"' '"a>b"' '"~"' \
           '"a\\b"' '"a\nb"' '"a\tb"' '"a\u0000b"' '"a\u007fb"' '"a\u001bb"' '"shots\n"' "\"$D201\"" 5 true '["a"]'; do
  ev_bad evidence.dir "$bad" "6: dir=${bad:0:30}"
done

# ---- 7: there is no evidence.branch (owner decision on #352: gh --attach only)
# store accepts only "attach"; the old "branch" / "pr" values are invalid.
for bad in '"branch"' '"pr"'; do
  ev_bad evidence.store "$bad" "7: store=$bad is no longer valid"
done
# evidence.branch is not a known key any more: the unknown-key check names it.
set_cfg '{"evidence": {"branch": "talos-evidence"}}'
bash "$CFG_SH" --dump 2>"$ERR" >/dev/null
assert_contains "$(errtext)" "unknown config key 'evidence.branch'" "7: evidence.branch is an unknown key"

# ---- 8: include ------------------------------------------------------------
ev_ok evidence.include '["*.png"]' "*.png" "8: one glob"
ev_ok evidence.include '["*.png", "shot-?.webm", "a_b.c-d"]' "$(printf '*.png\nshot-?.webm\na_b.c-d')" "8: several globs"
# The whole value reads as absent (fail closed) for each of these:
for bad in '"*.png"' '[]' '[""]' '[1]' '[null]' '[["a"]]' '["*.png", "a/b.png"]' '["*.png", "../x"]' \
           '["a.png\n"]' '["a b.png"]' '["*.png", 5]' '["*.png", ""]' '["a;b"]' '["$(x)"]' '["*.png", "/etc"]' \
           "[\"$G65\"]" "$(json_list 21 a.png)" 5 true; do
  ev_bad evidence.include "$bad" "8: include=${bad:0:30}"
done
# Bounds: exactly 20 items and exactly 64 characters are accepted.
ev_ok evidence.include "$(json_list 20 a.png)" "$(for _i in $(seq 1 20); do echo a.png; done)" "8: 20 items"
ev_ok evidence.include "[\"$G64\"]" "$G64" "8: 64-character item"

# ---- 9: command ------------------------------------------------------------
ev_ok evidence.command '"npm run shots -- --out \"$DIR\""' 'npm run shots -- --out "$DIR"' "9: ordinary command"
ev_ok evidence.command "\"$CMD2000\"" "$CMD2000" "9: exactly 2000 chars"
for bad in "\"$CMD2001\"" '"a\u0000b"' 5 true '["a"]'; do
  ev_bad evidence.command "$bad" "9: command=${bad:0:20}"
done

# ---- 10: invalid values do not disturb the other keys ----------------------
set_cfg '{"evidence": {"enabled": true, "max_mb": 500, "dir": "docs/shots"}}'
assert_eq "true" "$(dumped evidence.enabled)" "10: a valid sibling survives (enabled)"
assert_eq "docs/shots" "$(dumped evidence.dir)" "10: a valid sibling survives (dir)"
assert_eq "<absent>" "$(dumped evidence.max_mb)" "10: only the bad key is dropped"

# ---- 11: --dump without the keys is unchanged ------------------------------
set_cfg '{"base_branch": "main", "limits": {"max_fix_attempts": 3}}'
bash "$CFG_SH" --dump 2>/dev/null | tr '\0' '\n' > "$SANDBOX/dump-now.txt"
printf 'base_branch\nmain\nlimits.max_fix_attempts\n3\nverify.qa_mode\nlocal\n' > "$SANDBOX/dump-main.txt"
if cmp -s "$SANDBOX/dump-main.txt" "$SANDBOX/dump-now.txt"; then
  pass "11: --dump without evidence keys is byte-identical to main"
else
  fail "11: --dump without evidence keys is byte-identical to main" "$(cat "$SANDBOX/dump-now.txt")"
fi

# ---- 12: the user-level (global) file layers the keys (#441) ---------------
case "$HOME" in
  "$SANDBOX"/*) ;;
  *) echo "FATAL: HOME is outside the sandbox" >&2; exit 1 ;;
esac
USER_DIR="$HOME/.talos"
mkdir -p "$USER_DIR"
printf '%s\n' '{"evidence": {"enabled": true, "max_files": 3, "include": ["*.png"], "command": "make shots"}}' > "$USER_DIR/talos.pipeline.json"
rm -f talos.pipeline.json
assert_eq "true" "$(single evidence.enabled DEF)" "12: user-level enabled applies (single-key)"
assert_eq "3" "$(single evidence.max_files DEF)" "12: user-level max_files applies (single-key)"
assert_eq "*.png" "$(single evidence.include DEF)" "12: user-level include applies (single-key)"
assert_eq "DEF" "$(single evidence.command DEF)" "12: evidence.command is repo-only: the user-level value is dropped"
set_cfg '{"base_branch": "main"}'
_dump12="$(bash "$CFG_SH" --dump 2>/dev/null | tr '\0' '\n')"
assert_contains "$_dump12" "evidence.max_files" "12: user-level evidence keys present in --dump"
assert_not_contains "$_dump12" "evidence.command" "12: the repo-only evidence.command is absent from --dump"
rm -rf "$USER_DIR"

# ---- 13: contract marker ---------------------------------------------------
contract="$(. "$TALOS_ROOT/scripts/pipeline-contract.sh"; printf '%s\n' "${TALOS_MARKERS[@]}")"
assert_contains "$contract" "talos:evidence" "13: talos:evidence is a TALOS_MARKERS member"

# ---- 14: the examples show the block, disabled -----------------------------
assert_contains "$(cat "$TALOS_ROOT/talos.pipeline.yml.example")" "#   enabled: false" "14: YAML example shows evidence.enabled: false commented out"
for k in enabled command dir include when store max_files max_mb; do
  assert_contains "$(cat "$TALOS_ROOT/talos.pipeline.json.example")" "evidence.$k" "14: JSON example _note names evidence.$k"
done

finish
