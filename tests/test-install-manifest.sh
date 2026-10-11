#!/usr/bin/env bash
# test-install-manifest.sh -- covers #579: `install.sh --global` writes
# <talos home>/.install-manifest and, on the next run, removes the files the
# previous manifest lists under scripts/, templates/ and skills/<cmd>/refs/
# that the source no longer ships. A user's own files there are never listed,
# so they survive.
#   AC1 a dropped scripts/*.sh and scripts/*.py are removed
#   AC2 a dropped templates/<dir>/ file and skills/<cmd>/refs/*.md are removed
#   AC3 user-added files in the same directories survive
#   AC4 the manifest lists exactly the installed files of the three trees
#   AC5 no previous manifest: nothing is removed
#   AC6 a manifest entry that is absolute, has `..` or is outside the trees is ignored
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

TALOS_ROOT="${TALOS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# A scratch copy of what install.sh reads from its source dir, so a test can add
# and drop files without touching the repo.
_make_src() {
  local src="$1"
  mkdir -p "$src"
  cp "$TALOS_ROOT/install.sh" "$src/install.sh"
  cp -R "$TALOS_ROOT/scripts" "$TALOS_ROOT/agents" "$TALOS_ROOT/templates" "$TALOS_ROOT/skills" "$src/"
}

# install.sh --global from <src> into <home>/.talos, Claude adapter in the sandbox.
_install() {
  local src="$1" home="$2"
  env -u TALOS_HOME HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" \
    bash "$src/install.sh" --global --no-agent-skills --no-statusline 2>&1
}

# ── AC1-AC3: an upgrade that drops files removes them; user files survive ────
SRC="$SANDBOX/src"
H="$SANDBOX/home"
_make_src "$SRC"
mkdir -p "$H"
printf '#!/usr/bin/env bash\necho old\n' > "$SRC/scripts/pipeline-oldthing.sh"
printf 'OLD = 1\n' > "$SRC/scripts/pipeline-oldthing.py"
printf 'old template\n' > "$SRC/templates/prompts/oldprompt.md"
printf 'old ref\n' > "$SRC/skills/pipeline/refs/old-ref.md"
_install "$SRC" "$H" >/dev/null
T="$H/.talos"
assert_file_exists "$T/scripts/pipeline-oldthing.sh" "fixture: the first install ships pipeline-oldthing.sh"
assert_file_exists "$T/skills/pipeline/refs/old-ref.md" "fixture: the first install ships old-ref.md"

# The user's own files in the managed directories.
printf 'mine\n' > "$T/scripts/my-helper.sh"
printf 'mine\n' > "$T/templates/prompts/my-prompt.md"
printf 'mine\n' > "$T/skills/pipeline/refs/my-ref.md"

rm -f "$SRC/scripts/pipeline-oldthing.sh" "$SRC/scripts/pipeline-oldthing.py" \
  "$SRC/templates/prompts/oldprompt.md" "$SRC/skills/pipeline/refs/old-ref.md"
out="$(_install "$SRC" "$H")"
rc=$?
assert_eq "0" "$rc" "AC1 the upgrade install exits 0"
assert_file_absent "$T/scripts/pipeline-oldthing.sh" "AC1 a scripts/*.sh the source dropped is removed from ~/.talos/scripts"
assert_file_absent "$T/scripts/pipeline-oldthing.py" "AC1 a scripts/*.py the source dropped is removed from ~/.talos/scripts"
assert_contains "$out" "removed (no longer shipped): scripts/pipeline-oldthing.sh" "AC1 the removal is reported"
assert_file_absent "$T/templates/prompts/oldprompt.md" "AC2 a templates/<dir>/ file the source dropped is removed"
assert_file_absent "$T/skills/pipeline/refs/old-ref.md" "AC2 a skills/<cmd>/refs/*.md the source dropped is removed"
assert_file_exists "$T/scripts/my-helper.sh" "AC3 a user-added file in ~/.talos/scripts survives the upgrade"
assert_file_exists "$T/templates/prompts/my-prompt.md" "AC3 a user-added file in ~/.talos/templates/<dir> survives the upgrade"
assert_file_exists "$T/skills/pipeline/refs/my-ref.md" "AC3 a user-added file in ~/.talos/skills/<cmd>/refs survives the upgrade"
assert_file_exists "$T/scripts/pipeline-vcs.sh" "AC1 a script the source still ships stays installed"

# ── AC4: the manifest lists exactly the installed files of the three trees ───
H4="$SANDBOX/home4"
mkdir -p "$H4"
_install "$TALOS_ROOT" "$H4" >/dev/null
M4="$H4/.talos/.install-manifest"
assert_file_exists "$M4" "AC4 --global writes <talos home>/.install-manifest"
want="$(cd "$H4/.talos" && { find scripts templates -type f; find skills -path 'skills/*/refs/*' -type f; } | LC_ALL=C sort)"
got="$(LC_ALL=C sort "$M4" 2>/dev/null)"
assert_eq "$want" "$got" "AC4 the manifest lists every installed scripts/templates/skills-refs file and nothing else"
assert_not_contains "$got" "agents/" "AC4 the manifest lists no agents file"
H4B="$SANDBOX/home4b"
mkdir -p "$H4B"
env HOME="$H4B" CLAUDE_CONFIG_DIR="$H4B/.claude" TALOS_HOME="$SANDBOX/t4b" \
  bash "$TALOS_ROOT/install.sh" --global --no-agent-skills --no-statusline >/dev/null 2>&1
assert_file_exists "$SANDBOX/t4b/.install-manifest" "AC4 TALOS_HOME=<dir> puts the manifest in <dir>"

# ── AC5: no previous manifest removes nothing ────────────────────────────────
SRC5="$SANDBOX/src5"
H5="$SANDBOX/home5"
_make_src "$SRC5"
mkdir -p "$H5"
printf '#!/usr/bin/env bash\necho old\n' > "$SRC5/scripts/pipeline-oldthing.sh"
_install "$SRC5" "$H5" >/dev/null
rm -f "$H5/.talos/.install-manifest" "$SRC5/scripts/pipeline-oldthing.sh"
_install "$SRC5" "$H5" >/dev/null
assert_file_exists "$H5/.talos/scripts/pipeline-oldthing.sh" "AC5 with no previous manifest an extra file in ~/.talos/scripts is left in place"
assert_file_exists "$H5/.talos/.install-manifest" "AC5 the run with no previous manifest writes one"

# ── AC6: unsafe or out-of-scope manifest entries are ignored ─────────────────
H6="$SANDBOX/home6"
mkdir -p "$H6"
_install "$TALOS_ROOT" "$H6" >/dev/null
T6="$H6/.talos"
printf 'victim\n' > "$SANDBOX/victim-abs"
printf 'victim\n' > "$T6/victim-dotdot"
printf 'victim\n' > "$T6/agents/my-agent.md"
printf 'victim\n' > "$T6/skills/pipeline/my-notes.md"
printf 'victim\n' > "$T6/scripts/real-target"
ln -s "$T6/scripts/real-target" "$T6/scripts/a-link.sh"
# Control: a valid stale entry in the same manifest is removed, so the ignored
# entries below survive because they are unsafe, not because nothing was pruned.
printf 'stale\n' > "$T6/scripts/pipeline-gone.sh"
{
  printf '%s\n' "scripts/pipeline-gone.sh"
  printf '%s\n' "$SANDBOX/victim-abs"
  printf '%s\n' "scripts/../victim-dotdot"
  printf '%s\n' "agents/my-agent.md"
  printf '%s\n' "skills/pipeline/my-notes.md"
  printf '%s\n' "scripts/a-link.sh"
} >> "$T6/.install-manifest"
_install "$TALOS_ROOT" "$H6" >/dev/null
assert_file_absent "$T6/scripts/pipeline-gone.sh" "AC6 control: a valid stale entry in the same manifest is removed"
assert_file_exists "$SANDBOX/victim-abs" "AC6 an absolute manifest entry is ignored"
assert_file_exists "$T6/victim-dotdot" "AC6 a manifest entry with .. is ignored"
assert_file_exists "$T6/agents/my-agent.md" "AC6 a manifest entry outside scripts/templates/skills refs (agents/) is ignored"
assert_file_exists "$T6/skills/pipeline/my-notes.md" "AC6 a skills entry outside refs/ is ignored"
[ -L "$T6/scripts/a-link.sh" ] && pass "AC6 a manifest entry that is a symlink is not removed" \
  || fail "AC6 a manifest entry that is a symlink is not removed"

finish
