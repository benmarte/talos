#!/usr/bin/env bash
# Tests for the ~/.agents/skills pointer skills that install.sh --global writes
# for the codex, pi, cursor and opencode harnesses (#366, part of #353).
#
# Every installer run happens under a HOME inside make_sandbox's directory, with
# TALOS_HOME, CLAUDE_CONFIG_DIR and TALOS_AGENTS_HOME unset (or pointed inside
# it) in the SAME command as the installer. The real ~/.agents, ~/.claude and
# ~/.talos are never read or written; every rm below is guarded by newhome.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

INSTALL="$TALOS_ROOT/install.sh"
BASH_BIN="$(command -v bash)"
. "$TALOS_ROOT/scripts/pipeline-contract.sh"
MARKER='<!-- talos:pointer -->'

# Every destructive line below runs under a HOME created here.
newhome() {
  HOME="$SANDBOX/home-$1"
  export HOME
  case "$HOME" in "$SANDBOX"/*) ;; *) echo "refusing: HOME=$HOME is not inside the sandbox" >&2; exit 1 ;; esac
  rm -rf "$HOME"
  mkdir -p "$HOME"
}

# inst <args...> -- run `install.sh --global --no-agent-skills <args>` under the
# sandbox HOME. Output in $OUT, status in $RC.
inst() {
  case "$HOME" in "$SANDBOX"/*) ;; *) echo "refusing: HOME=$HOME is not inside the sandbox" >&2; exit 1 ;; esac
  OUT="$(env -u TALOS_HOME -u CLAUDE_CONFIG_DIR -u TALOS_AGENTS_HOME "$BASH_BIN" "$INSTALL" --global --no-agent-skills "$@" 2>&1)"; RC=$?
}

# src_desc <command> -- the description line of the source skill, read at run
# time (another change rewrites the setup one).
src_desc() {
  awk 'NR>1 && /^---$/{exit} /^description:/{print; exit}' "$TALOS_ROOT/skills/$1/SKILL.md"
}

# frontmatter_value <file> <key> -- first "key: value" line inside the frontmatter.
fm_line() {
  awk -v k="$2" 'NR>1 && /^---$/{exit} index($0, k ":")==1 {print; exit}' "$1"
}

fileset() { (cd "$1" && find . -type f | sort); }

POINTER_HARNESSES="codex pi cursor opencode"

# ── criteria 1-4: content of every pointer, for each pointer harness ─────────
for h in $POINTER_HARNESSES; do
  newhome "ptr-$h"
  inst --harness "$h"
  assert_eq "0" "$RC" "--harness $h exits 0"
  for cmd in "${TALOS_COMMANDS[@]}"; do
    f="$HOME/.agents/skills/talos-$cmd/SKILL.md"
    lbl="--harness $h: talos-$cmd"
    assert_file_exists "$f" "$lbl pointer is written"
    [ -f "$f" ] || continue
    assert_eq "name: talos-$cmd" "$(fm_line "$f" name)" "$lbl frontmatter name equals the directory name"
    assert_eq "$(src_desc "$cmd")" "$(fm_line "$f" description)" "$lbl description is the source skill's description line"
    assert_eq "1" "$(grep -cxF "$MARKER" "$f")" "$lbl carries the marker on its own line"
    body="$(cat "$f")"
    assert_contains "$body" "~/.talos/skills/$cmd/SKILL.md" "$lbl names the ~/.talos playbook"
    assert_contains "$body" "\$TALOS_HOME/skills/$cmd/SKILL.md" "$lbl names the \$TALOS_HOME playbook"
    assert_contains "$body" "follow it exactly" "$lbl tells the agent to follow the playbook exactly"
    assert_contains "$body" "Read" "$lbl tells the agent to read the file"
    assert_not_contains "$body" ".claude" "$lbl names no path under ~/.claude"
    lines="$(wc -l < "$f" | tr -d ' ')"
    if [ "$lines" -le 15 ]; then pass "$lbl is at most 15 lines ($lines)"; else fail "$lbl is at most 15 lines" "got $lines"; fi
    # no copy of the playbook: the first body line of the source is absent
    first="$(awk 'c==2 && NF{print; exit} /^---$/{c++}' "$TALOS_ROOT/skills/$cmd/SKILL.md")"
    if [ -n "$first" ] && grep -qxF -- "$first" "$f"; then fail "$lbl holds no copy of the playbook" "found: $first"
    else pass "$lbl holds no copy of the playbook"; fi
    # the file it names exists after the same run, with ~ expanded to the sandbox HOME
    named="$(grep -o '~/\.talos/skills/[a-z-]*/SKILL\.md' "$f" | head -1)"
    assert_file_exists "$HOME/${named#\~/}" "$lbl: the file it names exists after the same run"
  done
  assert_file_absent "$HOME/.claude" "--harness $h creates no ~/.claude"
done

# ── criterion 5: nothing else creates ~/.agents ─────────────────────────────
for list in claude antigravity generic gemini "claude,gemini,antigravity,generic" mytool; do
  newhome "none-$list"
  inst --harness "$list"
  assert_eq "0" "$RC" "--harness $list exits 0"
  assert_file_absent "$HOME/.agents" "--harness $list creates no ~/.agents"
done
newhome none-bare
inst
assert_eq "0" "$RC" "no --harness exits 0"
assert_file_absent "$HOME/.agents" "no --harness creates no ~/.agents"
# ~/.agents existing is no signal: nothing is written into it without a pointer harness.
newhome none-existing
mkdir -p "$HOME/.agents/skills/graphify"
printf 'keep\n' > "$HOME/.agents/skills/graphify/SKILL.md"
inst --harness claude
assert_eq "1" "$(find "$HOME/.agents" -type f | wc -l | tr -d ' ')" "an existing ~/.agents gains no file without a pointer harness"
# per-repo mode writes nothing under ~/.agents
newhome none-repo
mkdir -p "$SANDBOX/repo-r"; git -C "$SANDBOX/repo-r" init -q -b main
OUT="$(env -u TALOS_HOME -u CLAUDE_CONFIG_DIR -u TALOS_AGENTS_HOME "$BASH_BIN" "$INSTALL" "$SANDBOX/repo-r" --no-agent-skills --harness pi 2>&1)"; RC=$?
assert_eq "0" "$RC" "per-repo --harness pi exits 0"
assert_file_absent "$HOME/.agents" "per-repo --harness pi creates no ~/.agents"

# ── criterion 6: collisions ─────────────────────────────────────────────────
newhome collide
mkdir -p "$HOME/.agents/skills/talos-setup" "$HOME/.agents/skills/graphify"
printf 'foreign skill\n' > "$HOME/.agents/skills/talos-setup/SKILL.md"
mkdir -p "$HOME/.agents/skills/talos-pipeline"
printf 'also foreign, mentions %s inline\n' "$MARKER" > "$HOME/.agents/skills/talos-pipeline/SKILL.md"
printf 'graphify\n' > "$HOME/.agents/skills/graphify/SKILL.md"
cp "$HOME/.agents/skills/talos-setup/SKILL.md" "$SANDBOX/foreign-setup.orig"
cp "$HOME/.agents/skills/talos-pipeline/SKILL.md" "$SANDBOX/foreign-pipeline.orig"
inst --harness codex
assert_eq "0" "$RC" "collision run exits 0"
cmp -s "$SANDBOX/foreign-setup.orig" "$HOME/.agents/skills/talos-setup/SKILL.md" \
  && pass "a foreign talos-setup/SKILL.md is left byte-identical" || fail "a foreign talos-setup/SKILL.md is left byte-identical"
cmp -s "$SANDBOX/foreign-pipeline.orig" "$HOME/.agents/skills/talos-pipeline/SKILL.md" \
  && pass "a foreign file that only quotes the marker inline is left byte-identical" || fail "a foreign file that only quotes the marker inline is left byte-identical"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'talos-setup/SKILL.md' )" "one line names the foreign talos-setup file"
assert_contains "$(printf '%s\n' "$OUT" | grep 'talos-setup/SKILL.md')" "warning" "the line about the foreign file is a warning"
assert_eq "graphify" "$(cat "$HOME/.agents/skills/graphify/SKILL.md")" "an unrelated skill in ~/.agents/skills is untouched"
# a pointer (marker present) is overwritten; --no-overwrite skips it
newhome overwrite
inst --harness codex
f="$HOME/.agents/skills/talos-setup/SKILL.md"
cp "$f" "$SANDBOX/pointer.orig"
printf '%s\nstale\n' "$MARKER" > "$f"
inst --harness codex --no-overwrite
assert_eq "stale" "$(sed -n 2p "$f")" "--no-overwrite leaves an existing pointer alone"
assert_contains "$OUT" "skip (exists)" "--no-overwrite says it skipped the pointer"
inst --harness codex
cmp -s "$SANDBOX/pointer.orig" "$f" && pass "a re-run overwrites a pointer that carries the marker" || fail "a re-run overwrites a pointer that carries the marker"
# --no-overwrite never claims a foreign file either
printf 'foreign\n' > "$f"
inst --harness codex --no-overwrite
assert_eq "foreign" "$(cat "$f")" "--no-overwrite leaves a foreign file byte-identical"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'talos-setup/SKILL.md')" "--no-overwrite names the foreign file once"

# ── criterion 7: symlinks ───────────────────────────────────────────────────
newhome link-root
mkdir -p "$SANDBOX/target-root"
ln -s "$SANDBOX/target-root" "$HOME/.agents"
inst --harness codex
assert_eq "0" "$RC" "a symlinked ~/.agents: exit 0"
assert_eq "0" "$(find "$SANDBOX/target-root" -mindepth 1 | wc -l | tr -d ' ')" "a symlinked ~/.agents: nothing written through it"
assert_contains "$OUT" "$HOME/.agents" "a symlinked ~/.agents: the notice names the link"
assert_contains "$OUT" "symlink" "a symlinked ~/.agents: the notice says symlink"

newhome link-dangling
ln -s "$SANDBOX/does-not-exist" "$HOME/.agents"
inst --harness codex
assert_eq "0" "$RC" "a dangling ~/.agents: exit 0"
assert_file_absent "$SANDBOX/does-not-exist" "a dangling ~/.agents: the target is not created"
assert_contains "$OUT" "$HOME/.agents" "a dangling ~/.agents: the notice names the link"

newhome link-skills
mkdir -p "$HOME/.agents" "$SANDBOX/target-skills"
ln -s "$SANDBOX/target-skills" "$HOME/.agents/skills"
inst --harness codex
assert_eq "0" "$RC" "a symlinked ~/.agents/skills: exit 0"
assert_eq "0" "$(find "$SANDBOX/target-skills" -mindepth 1 | wc -l | tr -d ' ')" "a symlinked ~/.agents/skills: nothing written through it"
assert_contains "$OUT" "$HOME/.agents/skills" "a symlinked ~/.agents/skills: the notice names the link"

newhome link-cmd
mkdir -p "$HOME/.agents/skills" "$SANDBOX/target-cmd"
ln -s "$SANDBOX/target-cmd" "$HOME/.agents/skills/talos-setup"
inst --harness codex
assert_eq "0" "$RC" "a symlinked talos-setup dir: exit 0"
assert_eq "0" "$(find "$SANDBOX/target-cmd" -mindepth 1 | wc -l | tr -d ' ')" "a symlinked talos-setup dir: nothing written through it"
assert_contains "$OUT" "$HOME/.agents/skills/talos-setup" "a symlinked talos-setup dir: the notice names the link"
assert_file_exists "$HOME/.agents/skills/talos-pipeline/SKILL.md" "a symlinked talos-setup dir: the other pointers are still written"

newhome link-file
mkdir -p "$HOME/.agents/skills/talos-setup"
printf 'elsewhere\n' > "$SANDBOX/target-file"
ln -s "$SANDBOX/target-file" "$HOME/.agents/skills/talos-setup/SKILL.md"
inst --harness codex
assert_eq "0" "$RC" "a symlinked SKILL.md: exit 0"
assert_eq "elsewhere" "$(cat "$SANDBOX/target-file")" "a symlinked SKILL.md: nothing written through it"
assert_contains "$OUT" "$HOME/.agents/skills/talos-setup/SKILL.md" "a symlinked SKILL.md: the notice names it"

newhome nondir
mkdir -p "$HOME/.agents"
printf 'x\n' > "$HOME/.agents/skills"
inst --harness codex
assert_eq "0" "$RC" "a regular file at ~/.agents/skills: exit 0"
assert_eq "x" "$(cat "$HOME/.agents/skills")" "a regular file at ~/.agents/skills is left alone"

# ── criterion 8: codex + claude ─────────────────────────────────────────────
newhome both
inst --harness codex,claude
assert_eq "0" "$RC" "--harness codex,claude exits 0"
newhome only-codex
inst --harness codex
newhome only-claude
inst --harness claude
for cmd in "${TALOS_COMMANDS[@]}"; do
  cmp -s "$SANDBOX/home-both/.agents/skills/talos-$cmd/SKILL.md" "$SANDBOX/home-only-codex/.agents/skills/talos-$cmd/SKILL.md" \
    && pass "codex,claude writes the same talos-$cmd pointer as codex alone" || fail "codex,claude writes the same talos-$cmd pointer as codex alone"
done
assert_eq "$(fileset "$SANDBOX/home-only-claude/.claude")" "$(fileset "$SANDBOX/home-both/.claude")" \
  "codex,claude writes the same ~/.claude file set as claude alone"
assert_file_absent "$SANDBOX/home-only-claude/.agents" "claude alone writes no ~/.agents"
newhome both
inst --harness codex,claude
assert_contains "$OUT" "Restart any open" "codex,claude: the Claude restart note still prints"

# ── criterion 9: final notes ────────────────────────────────────────────────
newhome notes
inst --harness opencode
assert_contains "$OUT" "$HOME/.agents/skills" "the final notes name the pointer directory when it was written"
assert_not_contains "$OUT" "Restart any open" "no Claude restart note when only a pointer harness is selected"
assert_contains "$OUT" "Claude Code adapter skipped (not selected" "the adapter line is unchanged"
newhome notes-none
inst --harness generic
assert_not_contains "$OUT" "$HOME/.agents/skills/" "the final notes do not name a pointer directory when none was written"

# ── installer-only override TALOS_AGENTS_HOME ───────────────────────────────
newhome override
OUT="$(env -u TALOS_HOME -u CLAUDE_CONFIG_DIR TALOS_AGENTS_HOME="$SANDBOX/agents-elsewhere" "$BASH_BIN" "$INSTALL" --global --no-agent-skills --harness pi 2>&1)"; RC=$?
assert_eq "0" "$RC" "TALOS_AGENTS_HOME: exit 0"
assert_file_exists "$SANDBOX/agents-elsewhere/skills/talos-pipeline/SKILL.md" "TALOS_AGENTS_HOME redirects the pointers"
assert_file_absent "$HOME/.agents" "TALOS_AGENTS_HOME: nothing under \$HOME/.agents"
OUT="$(env -u TALOS_HOME -u CLAUDE_CONFIG_DIR TALOS_AGENTS_HOME="$SANDBOX/agents-unused" "$BASH_BIN" "$INSTALL" --global --no-agent-skills --harness claude 2>&1)"
assert_file_absent "$SANDBOX/agents-unused" "TALOS_AGENTS_HOME with no pointer harness writes nothing"
# make_sandbox unsets it so an ambient value cannot redirect other suites
probe="$SANDBOX/probe-sandbox.sh"
printf '%s\n' '. "$1/tests/helpers.sh"' 'make_sandbox || exit 1' 'printf "%s\n" "${TALOS_AGENTS_HOME-unset}"' > "$probe"
assert_eq "unset" "$(env TALOS_AGENTS_HOME=/nonexistent/agents "$BASH_BIN" "$probe" "$TALOS_ROOT")" "make_sandbox unsets TALOS_AGENTS_HOME"

# ── hygiene: no python3 without -I, no CLAUDE_DIR in the new function ───────
fn="$(awk '/^install_agents_pointers\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$INSTALL")"
if [ -n "$fn" ]; then pass "install.sh defines install_agents_pointers"; else fail "install.sh defines install_agents_pointers"; fi
if printf '%s\n' "$fn" | grep 'python3' | grep -qv 'python3 -I'; then fail "any python3 call in install_agents_pointers uses -I"
else pass "any python3 call in install_agents_pointers uses -I"; fi
assert_not_contains "$fn" "CLAUDE_DIR" "install_agents_pointers does not touch the Claude directory"
header="$(sed -n '1,/^set -euo/p' "$INSTALL")"
assert_contains "$header" "install_agents_pointers" "header names the pointer function"
assert_contains "$header" "TALOS_AGENTS_HOME" "header documents the installer-only override"

finish
