#!/usr/bin/env bash
# test-install-atomic-copy.sh -- covers #977: install.sh copies each file to a
# temp file in the destination directory and renames it over the destination,
# so a reinstall is safe while a Talos script is running.
#   AC1 a file open for reading before the install keeps its old content; a fresh read gives the new
#   AC2 a failed copy (unreadable source) leaves the destination byte-identical and no temp file behind
#   AC3 no temp file is left in ~/.talos/scripts after a successful install
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

TALOS_ROOT="${TALOS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

_make_src() {
  local src="$1"
  mkdir -p "$src"
  cp "$TALOS_ROOT/install.sh" "$src/install.sh"
  cp -R "$TALOS_ROOT/scripts" "$TALOS_ROOT/agents" "$TALOS_ROOT/templates" "$TALOS_ROOT/skills" "$src/"
}

_install() {
  local src="$1" home="$2"
  env -u TALOS_HOME HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" \
    bash "$src/install.sh" --global --no-agent-skills --no-statusline 2>&1
}

SRC="$SANDBOX/src"
H="$SANDBOX/home"
mkdir -p "$H"
_make_src "$SRC"
SCRIPT="pipeline-atomic-fixture.sh"
T="$H/.talos/scripts"
printf '#!/usr/bin/env bash\n# marker-old-977\n' > "$SRC/scripts/$SCRIPT"
_install "$SRC" "$H" >/dev/null
old_content="$(cat "$T/$SCRIPT")"
assert_contains "$old_content" "marker-old-977" "fixture: the first install ships the old marker"

# ── AC1: an open handle keeps the old bytes across a reinstall ───────────────
exec 3< "$T/$SCRIPT"
sed 's/marker-old-977/marker-new-977/' "$SRC/scripts/$SCRIPT" > "$SANDBOX/new-script" \
  && cp "$SANDBOX/new-script" "$SRC/scripts/$SCRIPT"
_install "$SRC" "$H" >/dev/null
through_handle="$(cat <&3)"
exec 3<&-
assert_eq "$old_content" "$through_handle" "AC1 a file open before the install still reads its old content"
fresh="$(cat "$T/$SCRIPT")"
assert_contains "$fresh" "marker-new-977" "AC1 a fresh read of the path gives the new content"
assert_not_contains "$fresh" "marker-old-977" "AC1 the fresh read has no old content"

# ── AC3: no temp file left after a successful install ────────────────────────
want="$(cd "$SRC/scripts" && ls -A | LC_ALL=C sort)"
got="$(cd "$T" && ls -A | LC_ALL=C sort)"
assert_eq "$want" "$got" "AC3 ~/.talos/scripts holds exactly the shipped files, no temp file"

# ── AC2: a failed copy leaves the destination and the directory untouched ────
if [ "$(id -u)" = "0" ]; then
  pass "AC2 skipped as root (an unreadable file is still readable)"
else
  printf '\n# marker-third-977\n' >> "$SRC/scripts/$SCRIPT"
  chmod 000 "$SRC/scripts/$SCRIPT"
  before="$(cat "$T/$SCRIPT")"
  _install "$SRC" "$H" >/dev/null 2>&1
  rc=$?
  chmod 644 "$SRC/scripts/$SCRIPT"
  [ "$rc" != "0" ] && pass "AC2 control: the install with an unreadable source fails" \
    || fail "AC2 control: the install with an unreadable source fails"
  after="$(cat "$T/$SCRIPT")"
  assert_eq "$before" "$after" "AC2 a failed copy leaves the destination byte-identical"
  got="$(cd "$T" && ls -A | LC_ALL=C sort)"
  assert_eq "$want" "$got" "AC2 a failed copy leaves no temp file in the destination directory"
fi

finish
