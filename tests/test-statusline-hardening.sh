#!/usr/bin/env bash
# test-statusline-hardening.sh -- the #587 security notes on talos-statusline.sh (#600):
#   AC1 a relative TALOS_HOME still yields an absolute wrapper path, and undo undoes it
#   AC2 undo prints the command it replaces or removes, control characters as ?
#   AC3 wire refuses repository scripts for the user-level settings (Step 7e)
#   AC4 the no-python3 notice cleans the scripts path
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

SL="$TALOS_ROOT/scripts/talos-statusline.sh"
CC="$SANDBOX/cc"
export CLAUDE_CONFIG_DIR="$CC"
mkdir -p "$CC"
SETTINGS="$CC/settings.json"
SCRIPTS="$SANDBOX/inst/scripts"
mkdir -p "$SCRIPTS"
cmd_of() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["statusLine"]["command"])' "$1" 2>/dev/null; }
foreign() { printf '{"statusLine": {"type": "command", "command": "%s"}}\n' "$1" > "$SETTINGS"; }

# ── AC1: a relative TALOS_HOME ───────────────────────────────────────────────
foreign "echo ORIG"
mkdir -p "$SANDBOX/relth/scripts"
OUT="$(TALOS_HOME=relth bash "$SL" wire "$SETTINGS" relth/scripts)"
assert_eq "bash $SANDBOX/relth/statusline-chain.sh" "$(cmd_of "$SETTINGS")" "AC1 a relative TALOS_HOME is written as an absolute wrapper path"
OUT="$(TALOS_HOME=relth bash "$SL" undo "$SETTINGS")"
assert_eq "echo ORIG" "$(cmd_of "$SETTINGS")" "AC1 undo with the same relative TALOS_HOME restores the original"

# ── AC2: undo names what it replaces or removes ─────────────────────────────
TH="$SANDBOX/th"
mkdir -p "$TH/scripts"
foreign "echo ORIG"
TALOS_HOME="$TH" bash "$SL" wire "$SETTINGS" "$TH/scripts" >/dev/null
OUT="$(TALOS_HOME="$TH" bash "$SL" undo "$SETTINGS")"
assert_contains "$OUT" "(it ran: bash $TH/statusline-chain.sh)" "AC2 undo with a backup prints the command it replaced"
foreign "echo ORIG"
TALOS_HOME="$TH" bash "$SL" wire "$SETTINGS" "$TH/scripts" >/dev/null
python3 -I -c '
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["statusLine"]["command"] = "bash %s ; echo \x1b[31mextra" % sys.argv[2]
json.dump(d, open(p, "w"))' "$SETTINGS" "$TH/statusline-chain.sh"
rm -f "$TH/statusline-previous.json"
OUT="$(TALOS_HOME="$TH" bash "$SL" undo "$SETTINGS")"
assert_contains "$OUT" "removed: the statusLine key (it ran: bash $TH/statusline-chain.sh ; echo ?[31mextra; no usable backup of the original)" \
  "AC2 undo with no backup prints the command it removed, control characters as ?"
assert_not_contains "$OUT" $'\x1b' "AC2 no raw control character reaches the output"

# ── AC3: Step 7e in code ─────────────────────────────────────────────────────
REPO="$SANDBOX/somerepo"
mkdir -p "$REPO/.claude/talos/scripts"
( cd "$REPO" && git init -q )
rm -f "$SETTINGS"
OUT="$(TALOS_HOME="$TH" bash "$SL" wire "$SETTINGS" "$REPO/.claude/talos/scripts")"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "AC3 repository scripts for the user-level settings: one notice line" "$OUT"
assert_contains "$OUT" "inside a git work tree" "AC3 the notice says why"
assert_file_absent "$SETTINGS" "AC3 nothing is written"
OUT="$(TALOS_HOME="$TH" bash "$SL" wire "$SETTINGS" "$TH/scripts")"
assert_eq "bash $TH/scripts/talos-status.sh --line" "$(cmd_of "$SETTINGS")" "AC3 TALOS_HOME/scripts is wired although the sandbox is a git work tree"

# ── AC4: the no-python3 notice ───────────────────────────────────────────────
NOPY="$SANDBOX/nopy"
mkdir -p "$NOPY"
for t in bash sh sed cat; do ln -sf "$(command -v "$t")" "$NOPY/$t"; done
OUT="$(env PATH="$NOPY" bash "$SL" wire "$SETTINGS" "$(printf '/tmp/x\033[2Jy')" 2>&1)"
assert_contains "$OUT" "python3 not found" "AC4 the no-python3 notice is printed"
assert_not_contains "$OUT" $'\x1b' "AC4 the scripts path in it carries no raw control character"
assert_contains "$OUT" "/tmp/x?[2Jy/talos-status.sh" "AC4 the control character prints as ?"

finish
