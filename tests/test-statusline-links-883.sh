#!/usr/bin/env bash
# test-statusline-links-883.sh -- covers #883: scripts/talos-status.sh --line ends
# with clickable OSC 8 `map` and `board` links, prints an idle line in a Talos repo
# with no active issue, and TALOS_STATUSLINE_LINKS=0 turns the links off.
#   AC1 map link from <TALOS_HOME>/maps/index.json (talos-map.py's locate())
#   AC2 board.url (any provider), validated
#   AC3 Azure DevOps and GitLab derive the board URL; GitHub has none
#   AC4 board.enabled false: no board part
#   AC5 no network call (gh and curl shimmed to fail)
#   AC6 the idle line; nothing outside a Talos repo
#   AC7 TALOS_STATUSLINE_LINKS=0
#   AC8 the chain wrapper passes the escapes through; failures stay silent, exit 0
#   AC9 an active issue with no map and no board.url: the line is unchanged
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

STATUS="$TALOS_ROOT/scripts/talos-status.sh"
LOG="$SANDBOX/.git/talos/events.jsonl"
ERR="$SANDBOX/err.txt"
mkdir -p "$SANDBOX/.git/talos"
NOGIT="$(mktemp -d "${TMPDIR:-/tmp}/talos-nogit.XXXXXX")" || exit 1
[ -d "$NOGIT" ] || exit 1
trap '_is_trap_owner && { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; [ -n "${NOGIT:-}" ] && rm -rf "$NOGIT"; }' EXIT

export TALOS_HOME="$SANDBOX/.talos-home"
unset COLUMNS NO_COLOR TALOS_STATUS_DEBUG TALOS_STATUSLINE_LINKS

ESC=$'\033'
NL=$'\n'
BASE="talos #7 reviewer ●○○○ 2k"

# osc URL TEXT -- the OSC 8 link, ST being ESC followed by a backslash.
osc() { printf '%s]8;;%s%s\\%s%s]8;;%s\\' "$ESC" "$1" "$ESC" "$2" "$ESC" "$ESC"; }
fileurl() { printf 'file://%s/maps/%s' "$TALOS_HOME" "$1"; }

ts_ago() { python3 -I -c 'import datetime as d,sys; print((d.datetime.now(d.timezone.utc)-d.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
active_issue() {
  printf '{"event":"developer","role":"developer","issue":7,"pr":null,"verdict":"PASS","tokens":2000,"ts":"%s"}\n' "$(ts_ago 100)" > "$LOG"
}
merged_issue() {
  active_issue
  printf '{"event":"merged","role":"orchestrator","issue":7,"pr":null,"verdict":null,"tokens":null,"ts":"%s"}\n' "$(ts_ago 10)" >> "$LOG"
}
run_status() {
  OUT="$(cd "${RUN_DIR:-$SANDBOX}" && printf '' | bash "$STATUS" "$@" 2>"$ERR")"
  RC=$?
}
set_cfg() { printf '%s\n' "$1" > "$SANDBOX/talos.pipeline.json"; }
clear_cfg() { rm -f "$SANDBOX/talos.pipeline.json"; rm -rf "$TALOS_HOME"; }
# set_map SLUG FILE [create] -- the registry entry (and the page file).
set_map() {
  mkdir -p "$TALOS_HOME/maps"
  python3 -I -c 'import json,sys; json.dump({sys.argv[1]: {"file": sys.argv[2], "updated": "x", "line": "x"}}, open(sys.argv[3], "w"))' \
    "$1" "$2" "$TALOS_HOME/maps/index.json"
  [ "${3:-create}" = create ] && : > "$TALOS_HOME/maps/$2"
  return 0
}
set_remote() { git -C "$SANDBOX" remote remove origin 2>/dev/null; git -C "$SANDBOX" remote add origin "$1"; }
reset() { clear_cfg; active_issue; set_remote git@github.com:acme/widget.git; RUN_DIR="$SANDBOX"; }

# ── AC9 an active issue, no map file, no board.url: exactly today's line ────
reset
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}}'
run_status --line
assert_eq "$BASE" "$OUT" "AC9 an active issue with no map and no board.url: the line is unchanged"
assert_not_contains "$OUT" "$ESC" "AC9 no escape sequence in that line"
clear_cfg
run_status --line
assert_eq "$BASE" "$OUT" "AC9 an active issue with no Talos config at all: the line is unchanged"

# ── AC1 the map link ────────────────────────────────────────────────────────
reset
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}}'
set_map acme/widget acme-widget.html
run_status --line
assert_eq "$BASE · $(osc "$(fileurl acme-widget.html)" map)" "$OUT" "AC1 the line ends with the map as an OSC 8 link to the file URL"
assert_eq "0" "$RC" "AC1 exit 0"
assert_contains "$OUT" "${ESC}]8;;file://" "AC1 the link starts with ESC ] 8 ; ; file://"
assert_contains "$OUT" "${ESC}\\map${ESC}]8;;${ESC}\\" "AC1 the text is closed with ESC \\ (ST), not BEL"

# the entry is found from the remote when the config names no repo
reset
set_cfg '{"vcs": {"provider": "github"}}'
set_map acme/widget acme-widget.html
run_status --line
assert_eq "$BASE · $(osc "$(fileurl acme-widget.html)" map)" "$OUT" "AC1 the repo comes from the origin remote when the config has none"

# no entry, no file, a bad name, an entry for another repo
reset
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}}'
run_status --line
assert_eq "$BASE" "$OUT" "AC1 no index: no map part"
set_map acme/widget acme-widget.html nofile
run_status --line
assert_eq "$BASE" "$OUT" "AC1 an entry whose file does not exist: no map part"
set_map acme/widget "evil name.html"
run_status --line
assert_eq "$BASE" "$OUT" "AC1 a file name with a space: no map part"
set_map acme/widget "page.txt"
run_status --line
assert_eq "$BASE" "$OUT" "AC1 a file name not ending in .html: no map part"
set_map acme/widget "../escape.html" nofile
: > "$TALOS_HOME/escape.html"
run_status --line
assert_eq "$BASE" "$OUT" "AC1 a file name that climbs out of maps/: no map part"
set_map other/repo other-repo.html
run_status --line
assert_eq "$BASE" "$OUT" "AC1 an entry for another repo: no map part"

# the path is percent-encoded
reset
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}}'
SAVE_TH="$TALOS_HOME"
TALOS_HOME="$SANDBOX/th space"
export TALOS_HOME
set_map acme/widget acme-widget.html
run_status --line
assert_eq "$BASE · $(osc "file://${SANDBOX}/th%20space/maps/acme-widget.html" map)" "$OUT" "AC1 the file URL is percent-encoded"
rm -rf "$TALOS_HOME"
TALOS_HOME="$SAVE_TH"
export TALOS_HOME

# ── AC2 board.url ───────────────────────────────────────────────────────────
for prov in github gitlab azure; do
  reset
  set_cfg '{"vcs": {"provider": "'"$prov"'"}, "board": {"url": "https://example.com/b/1"}}'
  run_status --line
  assert_eq "$BASE · $(osc https://example.com/b/1 board)" "$OUT" "AC2 board.url gives the board link ($prov)"
done

reset
mkdir -p "$TALOS_HOME"
printf '%s\n' '{"board": {"url": "http://example.com/global"}}' > "$TALOS_HOME/talos.pipeline.json"
run_status --line
assert_eq "$BASE · $(osc http://example.com/global board)" "$OUT" "AC2 board.url from the global config"
set_cfg '{"board": {"url": "https://example.com/project"}}'
run_status --line
assert_eq "$BASE · $(osc https://example.com/project board)" "$OUT" "AC2 the project's board.url wins over the global one"

reset
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}, "board": {"url": "https://example.com/b/1"}}'
set_map acme/widget acme-widget.html
run_status --line
assert_eq "$BASE · $(osc "$(fileurl acme-widget.html)" map) · $(osc https://example.com/b/1 board)" "$OUT" "AC2 map first, then board"

for bad in 'ftp://example.com/b' 'javascript:alert(1)' 'https://exa mple.com' 'example.com/board' 'https://example.com/\u001b[31m' 'https://example.com/\u0007x' 'https://example.com/\u009bx' ''; do
  reset
  set_cfg '{"board": {"url": "'"$bad"'"}}'
  run_status --line
  assert_eq "$BASE" "$OUT" "AC2 board.url '$bad' is not used"
done
reset
set_cfg '{"board": {"url": 7}}'
run_status --line
assert_eq "$BASE" "$OUT" "AC2 a non-string board.url is not used"

# board.url overrides a derived URL
reset
set_remote https://gitlab.example.com/grp/proj.git
set_cfg '{"vcs": {"provider": "gitlab"}, "board": {"url": "https://example.com/mine"}}'
run_status --line
assert_eq "$BASE · $(osc https://example.com/mine board)" "$OUT" "AC2 board.url overrides the derived GitLab URL"

# ── AC3 derived board URLs ──────────────────────────────────────────────────
reset
set_cfg '{"vcs": {"provider": "azure", "azure": {"org_url": "https://dev.azure.com/acme/", "project": "My Proj"}}, "board": {"azure_team": "My Team", "azure_board": "Stories/Epics"}}'
run_status --line
assert_eq "$BASE · $(osc 'https://dev.azure.com/acme/My%20Proj/_boards/board/t/My%20Team/Stories%2FEpics' board)" "$OUT" "AC3 Azure DevOps board URL, project, team and board percent-encoded"
for drop in team board; do
  reset
  if [ "$drop" = team ]; then
    set_cfg '{"vcs": {"provider": "azure", "azure": {"org_url": "https://dev.azure.com/acme", "project": "P"}}, "board": {"azure_board": "B"}}'
  else
    set_cfg '{"vcs": {"provider": "azure", "azure": {"org_url": "https://dev.azure.com/acme", "project": "P"}}, "board": {"azure_team": "T"}}'
  fi
  run_status --line
  assert_eq "$BASE" "$OUT" "AC3 Azure without board.azure_$drop: no board part"
done
reset
set_cfg '{"vcs": {"provider": "azure", "azure": {"project": "P"}}, "board": {"azure_team": "T", "azure_board": "B"}}'
run_status --line
assert_eq "$BASE" "$OUT" "AC3 Azure without vcs.azure.org_url: no board part"
reset
set_cfg '{"vcs": {"provider": "azure", "azure": {"org_url": "https://dev.azure.com/acme"}}, "board": {"azure_team": "T", "azure_board": "B"}}'
run_status --line
assert_eq "$BASE" "$OUT" "AC3 Azure without vcs.azure.project: no board part"

reset
set_remote https://tok3n:s3cret@gitlab.example.com/grp/sub/proj.git
set_cfg '{"vcs": {"provider": "gitlab"}}'
run_status --line
assert_eq "$BASE · $(osc https://gitlab.example.com/grp/sub/proj/-/boards board)" "$OUT" "AC3 GitLab board URL from the origin: subgroups kept, credentials and .git dropped"
assert_not_contains "$OUT" "s3cret" "AC3 no credential reaches the line"
set_remote git@gitlab.example.com:grp/proj.git
run_status --line
assert_eq "$BASE · $(osc https://gitlab.example.com/grp/proj/-/boards board)" "$OUT" "AC3 GitLab board URL from an ssh remote"

reset
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}}'
run_status --line
assert_eq "$BASE" "$OUT" "AC3 GitHub with no board.url: no board part"

# ── AC4 board.enabled false ─────────────────────────────────────────────────
reset
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}, "board": {"enabled": false, "url": "https://example.com/b/1"}}'
set_map acme/widget acme-widget.html
run_status --line
assert_eq "$BASE · $(osc "$(fileurl acme-widget.html)" map)" "$OUT" "AC4 board.enabled false: no board part, the map stays"

# ── AC5 no network call ─────────────────────────────────────────────────────
reset
set_cfg '{"vcs": {"provider": "gitlab"}, "board": {"enabled": true}}'
set_remote https://gitlab.example.com/grp/proj.git
set_map grp/proj grp-proj.html
run_status --line
PLAIN="$OUT"
SHIMS="$SANDBOX/shims"
mkdir -p "$SHIMS"
for t in gh curl; do
  printf '#!/bin/sh\necho ran >> "%s/%s.ran"\nexit 1\n' "$SANDBOX" "$t" > "$SHIMS/$t"
  chmod +x "$SHIMS/$t"
done
OUT="$(cd "$SANDBOX" && printf '' | env PATH="$SHIMS:$PATH" bash "$STATUS" --line 2>/dev/null)"
assert_contains "$PLAIN" "${ESC}]8;;" "AC5 the baseline run has links"
assert_eq "$PLAIN" "$OUT" "AC5 the output is the same with gh and curl shimmed to fail"
assert_file_absent "$SANDBOX/gh.ran" "AC5 gh did not run"
assert_file_absent "$SANDBOX/curl.ran" "AC5 curl did not run"
# the idle line too
rm -f "$LOG"
OUT="$(cd "$SANDBOX" && printf '' | env PATH="$SHIMS:$PATH" bash "$STATUS" --line 2>/dev/null)"
assert_file_absent "$SANDBOX/gh.ran" "AC5 gh did not run (idle line)"
assert_file_absent "$SANDBOX/curl.ran" "AC5 curl did not run (idle line)"

# ── AC6 the idle line ───────────────────────────────────────────────────────
reset
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}, "board": {"url": "https://example.com/b/1"}}'
set_map acme/widget acme-widget.html
IDLE="talos idle · $(osc "$(fileurl acme-widget.html)" map) · $(osc https://example.com/b/1 board)"
rm -f "$LOG"
run_status --line
assert_eq "$IDLE" "$OUT" "AC6 no log: the idle line with the links"
assert_eq "0" "$RC" "AC6 exit 0"
: > "$LOG"
run_status --line
assert_eq "$IDLE" "$OUT" "AC6 an empty log: the idle line"
merged_issue
run_status --line
assert_eq "$IDLE" "$OUT" "AC6 only a merged issue: the idle line"
active_issue
set_cfg '{"events": {"path": "../outside.jsonl"}, "vcs": {"provider": "github", "repo": "acme/widget"}, "board": {"url": "https://example.com/b/1"}}'
run_status --line
assert_eq "$IDLE" "$OUT" "AC6 an events.path that leaves the common dir: the idle line"
# a Talos config with no link source: just `talos idle`
reset
set_cfg '{}'
rm -f "$LOG"
run_status --line
assert_eq "talos idle" "$OUT" "AC6 a Talos config and nothing to link: talos idle"
# a global config alone counts
reset
mkdir -p "$TALOS_HOME"
printf '%s\n' '{}' > "$TALOS_HOME/talos.pipeline.json"
rm -f "$LOG"
run_status --line
assert_eq "talos idle" "$OUT" "AC6 a config in TALOS_HOME is a Talos config"
# no Talos config: nothing
reset
rm -f "$LOG"
run_status --line
assert_eq "" "$OUT" "AC6 no Talos config, no log: nothing"
: > "$LOG"
run_status --line
assert_eq "" "$OUT" "AC6 no Talos config, empty log: nothing"
merged_issue
run_status --line
assert_eq "" "$OUT" "AC6 no Talos config, merged issue: nothing"
# not a git repo
mkdir -p "$TALOS_HOME"
printf '%s\n' '{}' > "$TALOS_HOME/talos.pipeline.json"
RUN_DIR="$NOGIT"
run_status --line
assert_eq "" "$OUT" "AC6 outside a git repo: nothing"
assert_eq "0" "$RC" "AC6 outside a git repo: exit 0"

# ── AC7 TALOS_STATUSLINE_LINKS=0 ────────────────────────────────────────────
reset
set_cfg '{"vcs": {"provider": "github", "repo": "acme/widget"}, "board": {"url": "https://example.com/b/1"}}'
set_map acme/widget acme-widget.html
TALOS_STATUSLINE_LINKS=0 run_status --line
assert_eq "$BASE" "$OUT" "AC7 links off: the issue line as before, no link parts"
assert_not_contains "$OUT" "$ESC" "AC7 links off: no ESC byte"
rm -f "$LOG"
TALOS_STATUSLINE_LINKS=0 run_status --line
assert_eq "talos idle" "$OUT" "AC7 links off: the idle line is just talos idle"
for v in 1 '' yes 00; do
  TALOS_STATUSLINE_LINKS="$v" run_status --line
  assert_eq "$IDLE" "$OUT" "AC7 TALOS_STATUSLINE_LINKS='$v' shows the links"
done

# ── AC8 the chain wrapper, and failures that stay silent ────────────────────
CHAIN="$TALOS_ROOT/scripts/talos-statusline.sh"
CC="$SANDBOX/cc"
TH="$SANDBOX/th-chain"
SD="$TALOS_ROOT/scripts"
mkdir -p "$CC" "$TH"
printf '%s\n' '{"statusLine": {"type": "command", "command": "echo ORIG"}}' > "$CC/settings.json"
env TALOS_HOME="$TH" bash "$CHAIN" wire "$CC/settings.json" "$SD" >/dev/null 2>&1
CMD="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["statusLine"]["command"])' "$CC/settings.json" 2>/dev/null)"
assert_contains "$CMD" "statusline-chain.sh" "AC8 the wrapper is wired"

# chain_vs_direct LABEL -- the wrapper's last row is byte-identical to the script alone.
chain_vs_direct() {
  local direct chain rc
  direct="$(cd "$SANDBOX" && printf '{"session_id":"x"}' | env TALOS_HOME="$TH" bash "$STATUS" --line 2>/dev/null)"
  chain="$(cd "$SANDBOX" && printf '{"session_id":"x"}' | env TALOS_HOME="$TH" sh -c "$CMD" 2>/dev/null)"
  rc=$?
  assert_eq "0" "$rc" "AC8 $1: the chained command exits 0"
  assert_eq "ORIG${NL}${direct}" "$chain" "AC8 $1: the Talos row reaches stdout byte-identical to talos-status.sh --line"
  CHAIN_DIRECT="$direct"
}

reset
printf '%s\n' '{"vcs": {"provider": "github", "repo": "acme/widget"}, "board": {"url": "https://example.com/b/1"}}' > "$SANDBOX/talos.pipeline.json"
mkdir -p "$TH/maps"
printf '%s\n' '{"acme/widget": {"file": "acme-widget.html"}}' > "$TH/maps/index.json"
: > "$TH/maps/acme-widget.html"
chain_vs_direct "links"
assert_contains "$CHAIN_DIRECT" "${ESC}]8;;file://$TH/maps/acme-widget.html${ESC}\\map" "AC8 the line under test carries the map link"
assert_contains "$CHAIN_DIRECT" "${ESC}]8;;https://example.com/b/1${ESC}\\board" "AC8 the line under test carries the board link"

# a malformed index, a malformed config, an unreadable remote: the rest of the line prints
printf '%s\n' '{not json' > "$TH/maps/index.json"
chain_vs_direct "malformed index"
assert_contains "$CHAIN_DIRECT" "$BASE" "AC8 a malformed index: the line still prints"
assert_not_contains "$CHAIN_DIRECT" "map" "AC8 a malformed index: no map part"
printf '%s\n' '[1, 2' > "$SANDBOX/talos.pipeline.json"
chain_vs_direct "malformed config"
assert_eq "$BASE" "$CHAIN_DIRECT" "AC8 a malformed config: the issue line, no links"
printf '%s\n' '{"vcs": {"provider": "gitlab"}}' > "$SANDBOX/talos.pipeline.json"
git -C "$SANDBOX" remote remove origin
chain_vs_direct "no remote"
assert_eq "$BASE" "$CHAIN_DIRECT" "AC8 no origin remote: the issue line, no links"
set_remote 'not a url at all'
chain_vs_direct "garbage remote"
assert_eq "$BASE" "$CHAIN_DIRECT" "AC8 a garbage remote: the issue line, no links"
printf '%s\n' '{"vcs": {"provider": 5, "azure": 3}, "board": 4, "repo": []}' > "$SANDBOX/talos.pipeline.json"
chain_vs_direct "wrong-typed config"
assert_eq "$BASE" "$CHAIN_DIRECT" "AC8 wrong-typed config values: the issue line, no links"
mkdir -p "$TH/maps/index.json.d"
rm -f "$TH/maps/index.json"
ln -s "$TH/maps/index.json.d" "$TH/maps/index.json"
chain_vs_direct "index is a directory"
assert_eq "$BASE" "$CHAIN_DIRECT" "AC8 an index that is a directory: the issue line, no links"

[ "$_FAIL" -eq 0 ] || { printf '%d failed\n' "$_FAIL" >&2; exit 1; }
printf 'test-statusline-links-883: %d passed\n' "$_PASS"
