#!/usr/bin/env bash
# test-install-statusline.sh -- covers #550: `install.sh --global` wires
# scripts/talos-status.sh into Claude Code's user settings (statusLine) when the
# Claude adapter runs.
#   (a) a fresh settings file gets the statusLine; the command runs and prints the line
#   (b) idempotent: a second run changes nothing
#   (c) other settings keys survive; an old Talos path is refreshed
#   (d) a statusLine that is not Talos's is never touched: the installer says how to chain
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

# ── (d) someone else's statusLine is never touched ──────────────────────────
fresh d
printf '%s\n' '{"statusLine": {"type": "command", "command": "~/bin/my-line.sh"}}' > "$CC/settings.json"
BEFORE="$(cat "$CC/settings.json")"
inst --harness claude
assert_eq "$BEFORE" "$(cat "$CC/settings.json")" "an existing statusLine leaves settings.json untouched"
assert_contains "$OUT" "~/bin/my-line.sh" "the installer names the statusLine it found"
assert_contains "$OUT" "talos-status.sh" "and tells how to chain the Talos line"
assert_contains "$OUT" "--line" "with the --line command"

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
