#!/usr/bin/env bash
# test-statusline-chain.sh -- covers #585: the chain wrapper that
# scripts/talos-statusline.sh writes (~/.talos/statusline-chain.sh) runs the
# original Claude Code statusLine command and `talos-status.sh --line` side by
# side, each with the same stdin, its own timeout and its own failure.
#   AC2 the original's line, then the Talos line on the next row (Claude Code
#       prints each output line as a row); both parts get the same stdin JSON
#   AC5 a failing original or a failing/empty Talos part still yields the other
#   AC6 a hanging original does not blank the Talos line
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

INSTALL="$TALOS_ROOT/install.sh"
CHAIN="$TALOS_ROOT/scripts/talos-statusline.sh"
BASH_BIN="$(command -v bash)"
STUBBIN="$SANDBOX/stubbin"
mkdir -p "$STUBBIN"
printf '#!/bin/sh\nexit 0\n' > "$STUBBIN/claude"
chmod +x "$STUBBIN/claude"

NL=$'\n'
HOME="$SANDBOX/home"; export HOME
CC="$SANDBOX/cc"; TH="$SANDBOX/th"; SD="$SANDBOX/scripts"
mkdir -p "$HOME" "$SD"

# stub_talos BODY -- a fake talos-status.sh in $SD with the given shell body.
stub_talos() { printf '#!/bin/sh\n%s\n' "$1" > "$SD/talos-status.sh"; }
# stub_orig NAME BODY -- a fake original statusLine command $SANDBOX/NAME.
stub_orig() { printf '#!/bin/sh\n%s\n' "$2" > "$SANDBOX/$1"; chmod +x "$SANDBOX/$1"; }
# settings_cmd -- statusLine.command of $CC/settings.json.
settings_cmd() {
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["statusLine"]["command"])' "$CC/settings.json" 2>/dev/null
}
# chain_for ORIGINAL_COMMAND -- a clean settings file with that statusLine, then
# wire against the stub scripts dir; leaves the wrapper command in $CMD.
chain_for() {
  rm -rf "$CC" "$TH"; mkdir -p "$CC" "$TH"
  python3 -I -c 'import json,sys; json.dump({"statusLine": {"type": "command", "command": sys.argv[1]}}, open(sys.argv[2], "w"))' "$1" "$CC/settings.json"
  env TALOS_HOME="$TH" bash "$CHAIN" wire "$CC/settings.json" "$SD" >/dev/null 2>&1
  CMD="$(settings_cmd)"
}
# run_cmd [ENV=VAL ...] -- run $CMD as Claude Code does, JSON on stdin; GOT and RC.
run_cmd() {
  GOT="$(printf '{"session_id":"abc","transcript_path":"/x"}' | env "$@" sh -c "$CMD" 2>/dev/null)"
  RC=$?
}

# ── AC2 both parts, same stdin, original first ──────────────────────────────
stub_orig orig-ok.sh 'cat > "'"$SANDBOX"'/orig.stdin"; echo ORIG'
stub_talos 'cat > "'"$SANDBOX"'/talos.stdin"; echo TALOS'
chain_for "sh $SANDBOX/orig-ok.sh"
run_cmd
assert_eq "0" "$RC" "AC2 the chained command exits 0"
assert_eq "ORIG${NL}TALOS" "$GOT" "AC2 prints the original's line, then the Talos line on the next row"
assert_eq '{"session_id":"abc","transcript_path":"/x"}' "$(cat "$SANDBOX/orig.stdin" 2>/dev/null)" "AC2 the original got the stdin JSON"
assert_eq '{"session_id":"abc","transcript_path":"/x"}' "$(cat "$SANDBOX/talos.stdin" 2>/dev/null)" "AC2 the Talos part got the same stdin JSON"

# the real Talos line, as Claude Code runs it after an install
REPO="$SANDBOX/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
mkdir -p "$REPO/.git/talos"
printf '{"event":"developer","role":"developer","issue":4,"pr":null,"verdict":"PR_OPENED","tokens":2000,"ts":"2026-10-09T00:00:00Z"}\n' > "$REPO/.git/talos/events.jsonl"
rm -rf "$CC" "$TH"; mkdir -p "$CC"
printf '%s\n' '{"statusLine": {"type": "command", "command": "echo ORIG"}}' > "$CC/settings.json"
env PATH="$STUBBIN:$PATH" CLAUDE_CONFIG_DIR="$CC" TALOS_HOME="$TH" TALOS_AGENTS_HOME="$HOME/.agents" \
  "$BASH_BIN" "$INSTALL" --global --harness claude >/dev/null 2>&1
CMD="$(settings_cmd)"
GOT="$(cd "$REPO" && printf '{"session_id":"x"}' | sh -c "$CMD" 2>/dev/null)"
assert_eq "ORIG${NL}talos #4 reviewer ●○○○ 2k" "$GOT" "AC2 after install.sh the chained command prints the original then the real Talos line"

# an original that prints several rows keeps them, the Talos line comes last
stub_orig orig-multi.sh 'cat >/dev/null; printf "one\ntwo\n\n"'
stub_talos 'cat >/dev/null; echo TALOS'
chain_for "sh $SANDBOX/orig-multi.sh"
run_cmd
assert_eq "one${NL}two${NL}TALOS" "$GOT" "AC2 a multi-row original keeps its rows, trailing blank lines stripped, Talos last"

# ── AC5 independent failures ────────────────────────────────────────────────
stub_orig orig-fail.sh 'cat >/dev/null; echo oops >&2; exit 3'
stub_talos 'cat >/dev/null; echo TALOS'
chain_for "sh $SANDBOX/orig-fail.sh"
run_cmd
assert_eq "0" "$RC" "AC5 a failing original: exit 0"
assert_eq "TALOS" "$GOT" "AC5 a failing original still yields the Talos line"

stub_orig orig-ok2.sh 'cat >/dev/null; echo ORIG'
stub_talos 'cat >/dev/null; exit 7'
chain_for "sh $SANDBOX/orig-ok2.sh"
run_cmd
assert_eq "0" "$RC" "AC5 a failing Talos part: exit 0"
assert_eq "ORIG" "$GOT" "AC5 a failing Talos part still yields the original line"

stub_talos 'cat >/dev/null'
chain_for "sh $SANDBOX/orig-ok2.sh"
run_cmd
assert_eq "0" "$RC" "AC5 an empty Talos part: exit 0"
assert_eq "ORIG" "$GOT" "AC5 an empty Talos part still yields the original line"

stub_talos 'cat >/dev/null'
chain_for "sh $SANDBOX/orig-fail.sh"
run_cmd
assert_eq "0" "$RC" "AC5 both parts empty: exit 0"
assert_eq "" "$GOT" "AC5 both parts empty prints nothing"

# ── AC6 a hanging original ──────────────────────────────────────────────────
stub_orig orig-hang.sh 'cat >/dev/null; sleep 30; echo LATE'
stub_talos 'cat >/dev/null; echo TALOS'
chain_for "sh $SANDBOX/orig-hang.sh"
T0=$SECONDS
run_cmd TALOS_STATUSLINE_TIMEOUT_S=1
ELAPSED=$((SECONDS - T0))
assert_eq "0" "$RC" "AC6 a hanging original: exit 0"
assert_eq "TALOS" "$GOT" "AC6 a hanging original does not blank the Talos line"
if [ "$ELAPSED" -lt 5 ]; then pass "AC6 the wrapper returns within the timeout plus a margin (${ELAPSED}s)"; else fail "AC6 the wrapper returns within the timeout plus a margin (${ELAPSED}s)"; fi

# ── AC6 timeout fallbacks: no timeout/gtimeout on PATH (the macOS default) ──
MINBIN="$SANDBOX/minbin"
mkdir -p "$MINBIN"
for t in bash sh cat mktemp rm python3 sleep; do
  ln -sf "$(command -v "$t")" "$MINBIN/$t"
done
assert_eq "" "$(env PATH="$MINBIN" sh -c 'command -v timeout; command -v gtimeout' 2>/dev/null)" "AC6 the minimal PATH has no timeout or gtimeout"
stub_orig orig-ok3.sh 'cat >/dev/null; echo ORIG'
stub_talos 'cat >/dev/null; echo TALOS'
chain_for "sh $SANDBOX/orig-ok3.sh"
run_cmd PATH="$MINBIN"
assert_eq "ORIG${NL}TALOS" "$GOT" "AC6 without timeout/gtimeout both lines still print"
chain_for "sh $SANDBOX/orig-hang.sh"
T0=$SECONDS
run_cmd PATH="$MINBIN" TALOS_STATUSLINE_TIMEOUT_S=1
ELAPSED=$((SECONDS - T0))
assert_eq "TALOS" "$GOT" "AC6 without timeout/gtimeout a slow original is cut off and the Talos line shows"
if [ "$ELAPSED" -lt 5 ]; then pass "AC6 without timeout/gtimeout the wrapper returns in time (${ELAPSED}s)"; else fail "AC6 without timeout/gtimeout the wrapper returns in time (${ELAPSED}s)"; fi

# ── a user's own script named statusline-chain.sh is never touched (security) ─
USER_DIR="$SANDBOX/userbin"
mkdir -p "$USER_DIR"
USER_SH="$USER_DIR/statusline-chain.sh"
printf '#!/bin/sh\ncat >/dev/null\necho MINE\n' > "$USER_SH"
chmod +x "$USER_SH"
USER_BEFORE="$(cat "$USER_SH")"
stub_talos 'cat >/dev/null; echo TALOS'

# undo with no backup: not Talos's, so nothing to undo and nothing deleted
rm -rf "$CC" "$TH"; mkdir -p "$CC" "$TH"
printf '{"statusLine": {"type": "command", "command": "bash %s"}}\n' "$USER_SH" > "$CC/settings.json"
SET_BEFORE="$(cat "$CC/settings.json")"
OUT="$(env TALOS_HOME="$TH" bash "$CHAIN" undo "$CC/settings.json" 2>&1)"
assert_eq "$USER_BEFORE" "$(cat "$USER_SH" 2>/dev/null)" "SEC1 undo leaves a user's statusline-chain.sh in place"
assert_eq "$SET_BEFORE" "$(cat "$CC/settings.json")" "SEC1 undo leaves its statusLine alone"
assert_contains "$OUT" "nothing to undo" "SEC1 undo says nothing to undo"

# wire chains it as a foreign command, with a stale backup present, and never overwrites it
printf '{"command": "other"}\n' > "$TH/statusline-previous.json"
OUT="$(env TALOS_HOME="$TH" bash "$CHAIN" wire "$CC/settings.json" "$SD" 2>&1)"
assert_eq "$USER_BEFORE" "$(cat "$USER_SH" 2>/dev/null)" "SEC1 wire never overwrites a user's statusline-chain.sh"
assert_contains "$OUT" "chained" "SEC1 wire chains it as a foreign status line"
CMD="$(settings_cmd)"
run_cmd
assert_eq "MINE${NL}TALOS" "$GOT" "SEC1 the chained command runs the user's script, then the Talos line"
# and undo restores it, the user's script still there
env TALOS_HOME="$TH" bash "$CHAIN" undo "$CC/settings.json" >/dev/null 2>&1
assert_eq "bash $USER_SH" "$(settings_cmd)" "SEC1 undo restores the user's statusLine command"
assert_eq "$USER_BEFORE" "$(cat "$USER_SH" 2>/dev/null)" "SEC1 undo after a chain still leaves the user's script"

# a relative path is not the Talos wrapper either
rm -rf "$CC" "$TH"; mkdir -p "$CC" "$TH" "$SANDBOX/rel"
printf '#!/bin/sh\necho REL\n' > "$SANDBOX/rel/statusline-chain.sh"
printf '{"statusLine": {"type": "command", "command": "bash rel/statusline-chain.sh"}}\n' > "$CC/settings.json"
OUT="$(cd "$SANDBOX" && env TALOS_HOME="$TH" bash "$CHAIN" undo "$CC/settings.json" 2>&1)"
assert_file_exists "$SANDBOX/rel/statusline-chain.sh" "SEC1 undo leaves a relative-path statusline-chain.sh in place"

# ── SEC2 the wrapper holds the original command, so it is 0700 like the backup ─
chain_for "sh $SANDBOX/orig-ok3.sh"
assert_eq "700" "$(python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$TH/statusline-chain.sh")" "SEC2 the wrapper is mode 0700"
assert_eq "600" "$(python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$TH/statusline-previous.json")" "SEC2 the backup is mode 0600"

# ── SEC3 a placeholder inside the user's command is data, not a template slot ─
SD_SAVE="$SD"; SD="$SANDBOX/my scripts"
mkdir -p "$SD"
stub_talos 'cat >/dev/null; echo TALOS'
chain_for "echo @STATUS@ @ORIG@"
run_cmd
assert_eq "@STATUS@ @ORIG@${NL}TALOS" "$GOT" "SEC3 @STATUS@ and @ORIG@ in the original command stay literal"
SD="$SD_SAVE"

[ "$_FAIL" -eq 0 ] || { printf '%d failed\n' "$_FAIL" >&2; exit 1; }
printf 'test-statusline-chain: %d passed\n' "$_PASS"
