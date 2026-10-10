#!/usr/bin/env bash
# test-install-statusline.sh -- covers #550: `install.sh --global` wires
# scripts/talos-status.sh into Claude Code's user settings (statusLine) when the
# Claude adapter runs.
#   (a) a fresh settings file gets the statusLine; the command runs and prints the line
#   (b) idempotent: a second run changes nothing
#   (c) other settings keys survive; an old Talos path is refreshed
#   (d) a statusLine that is not Talos's is chained (#585): wrapper, backup, re-run, undo,
#       --no-statusline, per-harness notices (AC1, AC3, AC4, AC7, AC8, AC9; AC2/5/6 are in test-statusline-chain.sh)
#   (e) a settings file that does not parse, or that is a symlink, is handled without damage
#   (f) the adapter skipped (--harness without claude): no settings file is written
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

INSTALL="$TALOS_ROOT/install.sh"
BASH_BIN="$(command -v bash)"
STUBBIN="$SANDBOX/stubbin"
mkdir -p "$STUBBIN"
printf '#!/bin/sh\nexit 0\n' > "$STUBBIN/claude"
chmod +x "$STUBBIN/claude"

# fresh NAME -- a clean HOME, CLAUDE_CONFIG_DIR and TALOS_HOME for one case.
fresh() {
  HOME="$SANDBOX/home-$1"; export HOME
  CC="$SANDBOX/cc-$1"; TH="$SANDBOX/th-$1"
  rm -rf "$HOME" "$CC" "$TH"
  mkdir -p "$HOME" "$CC"
}
# inst ARGS... -- OUT and RC.
inst() {
  OUT="$(env PATH="$STUBBIN:$PATH" CLAUDE_CONFIG_DIR="$CC" TALOS_HOME="$TH" TALOS_AGENTS_HOME="$HOME/.agents" \
    "$BASH_BIN" "$INSTALL" --global "$@" 2>&1)"
  RC=$?
}
# jget KEY... -- a value from $CC/settings.json (python3 -I), `<absent>` when missing.
jget() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d.get(k, "<absent>") if isinstance(d, dict) else "<absent>"
print(d if isinstance(d, str) else json.dumps(d, sort_keys=True))' "$CC/settings.json" "$@"
}

# ── (a) fresh ───────────────────────────────────────────────────────────────
fresh a
inst --harness claude
assert_eq "0" "$RC" "install exits 0"
assert_file_exists "$CC/settings.json" "a settings file is created"
assert_eq "command" "$(jget statusLine type)" "statusLine type is command"
CMD="$(jget statusLine command)"
assert_contains "$CMD" "talos-status.sh" "the command names talos-status.sh"
assert_contains "$CMD" "$TH/scripts/talos-status.sh" "the command points at the installed copy under TALOS_HOME"
assert_contains "$CMD" "--line" "the command passes --line"
assert_contains "$OUT" "statusLine" "the installer reports the status line"
assert_file_exists "$TH/scripts/talos-status.sh" "talos-status.sh is installed"
assert_file_exists "$TH/scripts/pipeline-spend-format.py" "pipeline-spend-format.py is installed next to it"

# The command runs as Claude Code runs it (through a shell, JSON on stdin).
REPO="$SANDBOX/repo-a"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
mkdir -p "$REPO/.git/talos"
printf '{"event":"developer","role":"developer","issue":4,"pr":null,"verdict":"PR_OPENED","tokens":2000,"ts":"2026-10-09T00:00:00Z"}\n' > "$REPO/.git/talos/events.jsonl"
GOT="$(cd "$REPO" && printf '{"session_id":"x"}' | sh -c "$CMD")"
assert_eq "talos #4 reviewer ●○○○ 2k" "$GOT" "the installed statusLine command prints the line"

# ── (b) idempotent ──────────────────────────────────────────────────────────
BEFORE="$(cat "$CC/settings.json")"
inst --harness claude
assert_eq "$BEFORE" "$(cat "$CC/settings.json")" "a second run leaves settings.json byte for byte the same"
assert_contains "$OUT" "already" "and says it is already wired"

# ── (c) other keys survive; an old Talos path is refreshed ──────────────────
fresh c
printf '%s\n' '{"model": "opus", "env": {"A": "1"}, "permissions": {"allow": ["Bash(ls)"]}}' > "$CC/settings.json"
inst --harness claude
assert_eq "opus" "$(jget model)" "model survives"
assert_eq '{"A": "1"}' "$(jget env)" "env survives"
assert_eq '{"allow": ["Bash(ls)"]}' "$(jget permissions)" "permissions survive"
assert_contains "$(jget statusLine command)" "talos-status.sh" "statusLine added next to them"

printf '%s\n' '{"statusLine": {"type": "command", "command": "bash '"'"'/old/checkout/scripts/talos-status.sh'"'"' --line", "padding": 1}, "model": "opus"}' > "$CC/settings.json"
inst --harness claude
assert_contains "$(jget statusLine command)" "$TH/scripts/talos-status.sh" "a Talos statusLine at an old path is pointed at the installed copy"
assert_eq "1" "$(jget statusLine padding)" "its other fields survive"
assert_eq "opus" "$(jget model)" "model still survives"

# a path with a space and a quote is quoted for the shell
fresh q
TH="$SANDBOX/th q's dir"
rm -rf "$TH"
inst --harness claude
GOT="$(cd "$REPO" && printf '{}' | sh -c "$(jget statusLine command)")"
assert_eq "talos #4 reviewer ●○○○ 2k" "$GOT" "a TALOS_HOME with a space and a quote still runs"

# ── (d) someone else's statusLine is chained, not replaced (#585) ───────────
fresh d
printf '%s\n' '{"model": "opus", "statusLine": {"type": "command", "command": "~/bin/my-line.sh", "padding": 2}}' > "$CC/settings.json"
inst --harness claude
assert_eq "0" "$RC" "AC1 install exits 0 with a foreign statusLine"
assert_file_exists "$TH/statusline-chain.sh" "AC1 the chain wrapper is written under TALOS_HOME"
if [ -x "$TH/statusline-chain.sh" ]; then pass "AC1 the chain wrapper is executable"; else fail "AC1 the chain wrapper is executable"; fi
assert_file_exists "$TH/statusline-previous.json" "AC1 the original statusLine is saved"
assert_eq '{"command": "~/bin/my-line.sh", "padding": 2, "type": "command"}' "$(python3 -I -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$TH/statusline-previous.json" 2>/dev/null)" "AC1 the saved value is the original statusLine, verbatim"
assert_contains "$(jget statusLine command)" "$TH/statusline-chain.sh" "AC1 statusLine.command runs the wrapper"
assert_eq "command" "$(jget statusLine type)" "AC1 statusLine.type survives"
assert_eq "2" "$(jget statusLine padding)" "AC1 statusLine.padding survives"
assert_eq "opus" "$(jget model)" "AC1 other settings keys survive"
# shellcheck disable=SC2088  # a literal tilde, as the user wrote it in settings.json
assert_contains "$OUT" "~/bin/my-line.sh" "AC1 the installer names the statusLine it chained"
assert_contains "$OUT" "--statusline-undo" "AC1 and says how to undo"

# ── AC3 re-run never double-wraps ───────────────────────────────────────────
BEFORE_S="$(cat "$CC/settings.json" 2>/dev/null)"
BEFORE_B="$(cat "$TH/statusline-previous.json" 2>/dev/null)"
inst --harness claude
assert_eq "0" "$RC" "AC3 re-run exits 0"
assert_eq "$BEFORE_S" "$(cat "$CC/settings.json")" "AC3 settings.json is byte-identical after a re-run"
assert_eq "$BEFORE_B" "$(cat "$TH/statusline-previous.json" 2>/dev/null)" "AC3 statusline-previous.json is byte-identical after a re-run"
WRAP="$(cat "$TH/statusline-chain.sh" 2>/dev/null)"
assert_contains "$WRAP" "my-line.sh" "AC3 the wrapper calls the original command"
assert_not_contains "$WRAP" "statusline-chain.sh" "AC3 the wrapper never calls itself"
assert_eq "1" "$(printf '%s\n' "$WRAP" | grep -c 'my-line.sh')" "AC3 the original command appears once in the wrapper"
# a different TALOS_HOME on the next install: the wrapper is refreshed in place
TH_OLD="$TH"; TH="$SANDBOX/th-d2"
rm -rf "$TH"
inst --harness claude
assert_eq "$BEFORE_S" "$(cat "$CC/settings.json")" "AC3 settings.json is unchanged when TALOS_HOME moves"
assert_contains "$(cat "$TH_OLD/statusline-chain.sh" 2>/dev/null)" "$TH/scripts/talos-status.sh" "AC3 the wrapper in place now points at the new scripts path"
assert_file_absent "$TH/statusline-chain.sh" "AC3 no second wrapper is written under the new TALOS_HOME"
assert_file_absent "$TH/statusline-previous.json" "AC3 no second backup is written under the new TALOS_HOME"
TH="$TH_OLD"

# ── AC4 --statusline-undo restores the original exactly ────────────────────
EXPECT='{"command": "~/bin/my-line.sh", "padding": 2, "type": "command"}'
inst --statusline-undo --harness claude
assert_eq "0" "$RC" "AC4 undo exits 0"
assert_eq "$EXPECT" "$(jget statusLine)" "AC4 statusLine is deep-equal to the original, extra fields included"
assert_eq "opus" "$(jget model)" "AC4 other settings keys survive the undo"
assert_file_absent "$TH/statusline-chain.sh" "AC4 the wrapper is removed"
assert_file_absent "$TH/statusline-previous.json" "AC4 the backup is removed"
BEFORE_S="$(cat "$CC/settings.json")"
inst --statusline-undo --harness claude
assert_eq "0" "$RC" "AC4 a second undo exits 0"
assert_contains "$OUT" "nothing to undo" "AC4 a second undo reports nothing to undo"
assert_eq "$BEFORE_S" "$(cat "$CC/settings.json")" "AC4 a second undo changes nothing"

# undo of a Talos direct wiring removes the key and keeps the rest
fresh u
printf '%s\n' '{"model": "opus"}' > "$CC/settings.json"
inst --harness claude
inst --statusline-undo --harness claude
assert_eq "<absent>" "$(jget statusLine)" "AC4 undo of the direct Talos wiring removes the statusLine key"
assert_eq "opus" "$(jget model)" "AC4 and keeps the other keys"

# ── AC7 starting states ─────────────────────────────────────────────────────
fresh n
printf '%s\n' '{"statusLine": {"type": "static", "text": "hello"}, "model": "opus"}' > "$CC/settings.json"
BEFORE_S="$(cat "$CC/settings.json")"
inst --harness claude
assert_eq "$BEFORE_S" "$(cat "$CC/settings.json")" "AC7 a statusLine with no command is left unchanged"
assert_contains "$OUT" "statusLine" "AC7 and the installer says so"
assert_file_absent "$TH/statusline-chain.sh" "AC7 no wrapper for a statusLine with no command"

# a foreign command that merely mentions talos-status.sh is still foreign
fresh m
printf '%s\n' '{"statusLine": {"type": "command", "command": "my-own.sh --with talos-status.sh"}}' > "$CC/settings.json"
inst --harness claude
assert_file_exists "$TH/statusline-chain.sh" "AC7 a foreign command that mentions talos-status.sh is chained, not overwritten"

# ── AC8 --no-statusline ─────────────────────────────────────────────────────
fresh k
printf '%s\n' '{"statusLine": {"type": "command", "command": "~/bin/my-line.sh"}}' > "$CC/settings.json"
BEFORE_S="$(cat "$CC/settings.json")"
inst --harness claude --no-statusline
assert_eq "0" "$RC" "AC8 --no-statusline exits 0"
assert_eq "$BEFORE_S" "$(cat "$CC/settings.json")" "AC8 settings.json is not changed"
assert_file_absent "$TH/statusline-chain.sh" "AC8 no wrapper is written"
assert_file_absent "$TH/statusline-previous.json" "AC8 no backup is written"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c -i 'status line.*--no-statusline\|--no-statusline.*status line')" "AC8 one skip line names --no-statusline"
fresh k2
inst --harness claude --no-statusline
assert_file_absent "$CC/settings.json" "AC8 with no statusLine, no settings.json is written either"

# ── AC9 other harnesses ─────────────────────────────────────────────────────
fresh h
inst --harness codex,pi
assert_eq "0" "$RC" "AC9 a non-claude harness list exits 0"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'not supported by codex')" "AC9 one not-supported line for codex"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'not supported by pi')" "AC9 one not-supported line for pi"
assert_contains "$OUT" "$TH/scripts/talos-status.sh --line" "AC9 the manual command is printed"
assert_eq "" "$(ls -A "$CC")" "AC9 nothing is written under the Claude config dir without claude"

# ── (e) unreadable / symlinked settings ─────────────────────────────────────
fresh e
printf '%s' '{not json' > "$CC/settings.json"
inst --harness claude
assert_eq "0" "$RC" "unparseable settings: the install still succeeds"
assert_eq "{not json" "$(cat "$CC/settings.json")" "unparseable settings are left as they were"
assert_contains "$OUT" "settings.json" "and the installer says why nothing was wired"

fresh s
mkdir -p "$SANDBOX/dotfiles"
printf '%s\n' '{"model": "sonnet"}' > "$SANDBOX/dotfiles/settings.json"
ln -s "$SANDBOX/dotfiles/settings.json" "$CC/settings.json"
inst --harness claude
if [ -L "$CC/settings.json" ]; then pass "a symlinked settings.json is still a symlink"; else fail "a symlinked settings.json is still a symlink"; fi
assert_contains "$(cat "$SANDBOX/dotfiles/settings.json")" "talos-status.sh" "the real file behind the link got the statusLine"
assert_contains "$(cat "$SANDBOX/dotfiles/settings.json")" "sonnet" "and kept its other keys"

# ── (f) adapter skipped ─────────────────────────────────────────────────────
fresh f
inst --harness codex
assert_file_absent "$CC/settings.json" "no Claude adapter: no settings.json is written"

[ "$_FAIL" -eq 0 ] || { printf '%d failed\n' "$_FAIL" >&2; exit 1; }
printf 'test-install-statusline: %d passed\n' "$_PASS"
