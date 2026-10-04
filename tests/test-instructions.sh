#!/usr/bin/env bash
# Tests for scripts/pipeline-instructions.sh (#364): the harness-neutral
# AGENTS.md block, its repair, and the CLAUDE.md / GEMINI.md import notices.
# Every call runs in the make_sandbox HOME with TALOS_HOME unset, so the real
# ~/.talos and ~/.claude are never read or written.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
# Fixture paths must match what the script prints: it prints `pwd` paths, which
# collapse the `//` a TMPDIR ending in `/` leaves in $SANDBOX.
SBX="$(cd "$SANDBOX" && pwd)"

INSTR="$TALOS_ROOT/scripts/pipeline-instructions.sh"
. "$TALOS_ROOT/scripts/pipeline-contract.sh"

# new_repo <name> -- a fresh git repo of its own under the sandbox.
new_repo() {
  mkdir -p "$SBX/$1"
  git -C "$SBX/$1" init -q -b main
  printf '%s' "$SBX/$1"
}
sum() { cksum < "$1"; }

# ── print ─────────────────────────────────────────────────────────────────────
block="$(bash "$INSTR" print)"; rc=$?
assert_eq "0" "$rc" "print exits 0"
assert_eq "<!-- talos:begin -->" "$(printf '%s\n' "$block" | head -n 1)" "print starts with the begin marker"
assert_eq "<!-- talos:end -->" "$(printf '%s\n' "$block" | tail -n 1)" "print ends with the end marker"
nlines="$(printf '%s\n' "$block" | wc -l | tr -d ' ')"
if [ "$nlines" -le 20 ]; then pass "block is at most 20 lines ($nlines)"; else fail "block is at most 20 lines" "got $nlines"; fi
for cmd in "${TALOS_COMMANDS[@]}"; do
  assert_contains "$block" "~/.talos/skills/$cmd/SKILL.md" "block names the $cmd playbook"
done
assert_contains "$block" '$TALOS_HOME' "block mentions \$TALOS_HOME"
assert_contains "$block" "agents.subagents" "block names agents.subagents"
assert_contains "$block" "agents.runner" "block names agents.runner"
assert_contains "$block" "talos.pipeline" "block names talos.pipeline.*"
assert_contains "$block" "pipeline-vcs.sh" "block routes VCS operations through pipeline-vcs.sh"
assert_contains "$block" "ignore this section" "block tells a stage agent to ignore the section"
assert_contains "$block" "managed by Talos" "block says the text inside the markers is managed by Talos"
assert_not_contains "$block" ".claude/skills/pipeline/SKILL.md" "block has no .claude/skills path"
assert_not_contains "$block" "no native subagents" "block does not claim no native subagents"
assert_not_contains "$block" "<<" "block has no heredoc"
assert_not_contains "$block" "1.20" "block has no Antigravity version claim"
assert_not_contains "$block" "$HOME" "block has no machine HOME path"

# ── write: create, append, replace, idempotence ──────────────────────────────
R="$(new_repo create)"
out="$(bash "$INSTR" write "$R" 2>&1)"; rc=$?
assert_eq "0" "$rc" "write exits 0"
assert_file_exists "$R/AGENTS.md" "write creates AGENTS.md when absent"
assert_eq "$block" "$(cat "$R/AGENTS.md")" "created AGENTS.md is exactly the block"
assert_contains "$out" "commit AGENTS.md" "write tells the user to commit AGENTS.md"
assert_contains "$out" "install.sh --global" "write warns when the global playbook is missing"
before="$(sum "$R/AGENTS.md")"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_eq "$before" "$(sum "$R/AGENTS.md")" "second write leaves the file byte-identical"
assert_contains "$out" "up to date" "second write prints 'up to date'"
assert_not_contains "$out" "illegal" "second write (block at line 1) prints no head/tail error"
err="$(bash "$INSTR" write "$R" 2>&1 >/dev/null)"
assert_eq "" "$err" "second write prints nothing on stderr"
assert_not_contains "$out" "commit AGENTS.md" "an unchanged file prints no commit line"

mkdir -p "$HOME/.talos/skills/pipeline" && : > "$HOME/.talos/skills/pipeline/SKILL.md"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_not_contains "$out" "install.sh --global" "no warning when the global playbook exists"
out="$(TALOS_HOME="$SBX/elsewhere" bash "$INSTR" write "$R" 2>&1)"
assert_contains "$out" "install.sh --global" "the warning follows \$TALOS_HOME"
case "$HOME" in "$SANDBOX"/*) ;; *) echo "refusing: HOME=$HOME is not the sandbox" >&2; exit 1 ;; esac
rm -rf "${HOME:?}/.talos"

R="$(new_repo append)"
printf '# Project notes\n\nkeep me' > "$R/AGENTS.md"
orig_size="$(wc -c < "$R/AGENTS.md" | tr -d ' ')"
cp "$R/AGENTS.md" "$SBX/append.orig"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_eq "$(cat "$SBX/append.orig")" "$(head -c "$orig_size" "$R/AGENTS.md")" "append keeps the existing bytes as an unchanged prefix"
assert_eq "1" "$(grep -c 'talos:begin' "$R/AGENTS.md")" "append adds exactly one block"
assert_contains "$out" "commit AGENTS.md" "append prints the commit line"
assert_contains "$out" "added the Talos block" "appending to a file without a block says 'added'"
assert_not_contains "$out" "updated" "appending to a file without a block does not say 'updated'"

# The block `install.sh` wrote on main (codex/antigravity), pre-#364.
R="$(new_repo old)"
{
  printf '# Notes above\n'
  cat <<'TALOS_OLDBLOCK_k3v9x2q7wzm1'

<!-- talos:begin -->
## Talos pipeline

follow the playbook in .claude/skills/pipeline/SKILL.md exactly.

This harness has no native subagents.
<!-- talos:end -->
TALOS_OLDBLOCK_k3v9x2q7wzm1
  printf '\n# Notes below\n'
} > "$R/AGENTS.md"
cp "$R/AGENTS.md" "$SBX/old.orig"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_contains "$out" "updated the Talos block" "replacing a stale block says 'updated'"
assert_not_contains "$out" "added the Talos block" "replacing a stale block does not say 'added'"
agents="$(cat "$R/AGENTS.md")"
assert_eq "1" "$(grep -c 'talos:begin' "$R/AGENTS.md")" "repair leaves exactly one block"
assert_contains "$agents" "~/.talos/skills/pipeline/SKILL.md" "repaired block names the ~/.talos playbook"
assert_not_contains "$agents" ".claude/skills/pipeline/SKILL.md" "repaired file drops the old path"
assert_not_contains "$agents" "no native subagents" "repaired file drops the old claim"
# Bytes outside the old begin..end are unchanged: strip both blocks and compare.
strip() { awk '/^<!-- talos:begin -->$/{skip=1} !skip{print} /^<!-- talos:end -->$/{skip=0}' "$1"; }
assert_eq "$(strip "$SBX/old.orig")" "$(strip "$R/AGENTS.md")" "repair changes only the text from begin to end"
before="$(sum "$R/AGENTS.md")"
bash "$INSTR" write "$R" >/dev/null 2>&1
assert_eq "$before" "$(sum "$R/AGENTS.md")" "write after a repair is a no-op"

# ── malformed fences ─────────────────────────────────────────────────────────
for case_name in begin-only end-first two-begins two-ends; do
  R="$(new_repo "bad-$case_name")"
  case "$case_name" in
    begin-only)  printf 'a\n<!-- talos:begin -->\nb\n' ;;
    end-first)   printf 'a\n<!-- talos:end -->\nb\n<!-- talos:begin -->\n' ;;
    two-begins)  printf '<!-- talos:begin -->\nx\n<!-- talos:begin -->\ny\n<!-- talos:end -->\n' ;;
    two-ends)    printf '<!-- talos:begin -->\nx\n<!-- talos:end -->\n<!-- talos:end -->\n' ;;
  esac > "$R/AGENTS.md"
  before="$(sum "$R/AGENTS.md")"
  err="$(bash "$INSTR" write "$R" 2>&1 >/dev/null)"; rc=$?
  assert_eq "0" "$rc" "malformed ($case_name) exits 0"
  assert_eq "$before" "$(sum "$R/AGENTS.md")" "malformed ($case_name) leaves the file byte-identical"
  assert_eq "1" "$(printf '%s\n' "$err" | grep -c 'AGENTS.md')" "malformed ($case_name) prints one stderr line naming the file"
done

# ── symlinks and bad arguments ───────────────────────────────────────────────
R="$(new_repo link-in)"
printf 'target text\n' > "$R/real.md"
ln -s real.md "$R/AGENTS.md"
before_t="$(sum "$R/real.md")"
out="$(bash "$INSTR" write "$R" 2>&1)"; rc=$?
assert_eq "0" "$rc" "symlinked AGENTS.md (inside the repo) exits 0"
assert_eq "$before_t" "$(sum "$R/real.md")" "symlink target inside the repo is untouched"
assert_eq "real.md" "$(readlink "$R/AGENTS.md")" "symlink itself is untouched"
assert_contains "$out" "symlink" "symlinked AGENTS.md prints a notice"

R="$(new_repo link-out)"
printf 'outside text\n' > "$SBX/outside.md"
ln -s "$SBX/outside.md" "$R/AGENTS.md"
before_t="$(sum "$SBX/outside.md")"
out="$(bash "$INSTR" write "$R" 2>&1)"; rc=$?
assert_eq "0" "$rc" "symlinked AGENTS.md (outside the repo) exits 0"
assert_eq "$before_t" "$(sum "$SBX/outside.md")" "symlink target outside the repo is untouched"
assert_contains "$out" "symlink" "outside symlink prints a notice"
ln -sf "$SBX/missing-target.md" "$R/AGENTS.md"
bash "$INSTR" write "$R" >/dev/null 2>&1
assert_file_absent "$SBX/missing-target.md" "a dangling AGENTS.md symlink is not written through"

bash "$INSTR" write "$SBX/no-such-dir" >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "missing <repo-dir> exits 2"
assert_file_absent "$SBX/no-such-dir" "missing <repo-dir> is not created"
bash "$INSTR" write >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "write without <repo-dir> exits 2"
bash "$INSTR" bogus >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "unknown subcommand exits 2"

# ── Claude notice ─────────────────────────────────────────────────────────────
R="$(new_repo claude-plain)"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_not_contains "$out" "2.1.277" "no Claude notice without a CLAUDE.md"

R="$(new_repo claude-root)"
printf '# rules\n' > "$R/CLAUDE.md"
before="$(sum "$R/CLAUDE.md")"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_contains "$out" "$R/CLAUDE.md" "Claude notice names the file found"
assert_contains "$out" "2.1.277" "Claude notice names the version"
assert_contains "$out" "registered pipeline skill needs nothing" "Claude notice says the registered skill needs nothing"
assert_contains "$out" "@AGENTS.md" "Claude notice prints the import line"
assert_contains "$out" "--import-agents-md" "Claude notice offers --import-agents-md for <repo>/CLAUDE.md"
assert_eq "$before" "$(sum "$R/CLAUDE.md")" "CLAUDE.md is byte-identical without --import-agents-md"

R="$(new_repo claude-nested)"
mkdir -p "$R/.claude"; printf '# rules\n' > "$R/.claude/CLAUDE.md"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_contains "$out" "$R/.claude/CLAUDE.md" "notice names .claude/CLAUDE.md"
assert_not_contains "$out" "--import-agents-md" "no --import-agents-md hint for .claude/CLAUDE.md (the flag does not touch it)"
assert_contains "$out" "@../AGENTS.md" "the .claude/CLAUDE.md import is relative to that file"

R="$(new_repo claude-local)"
printf '# mine\n' > "$R/CLAUDE.local.md"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_contains "$out" "$R/CLAUDE.local.md" "notice names CLAUDE.local.md"
assert_not_contains "$out" "--import-agents-md" "no --import-agents-md hint for CLAUDE.local.md (the flag does not touch it)"

# A line that already resolves to <repo>/AGENTS.md suppresses the notice.
R="$(new_repo claude-imported)"
printf '# rules\n@AGENTS.md\n' > "$R/CLAUDE.md"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_not_contains "$out" "2.1.277" "an @AGENTS.md line in CLAUDE.md suppresses the notice"
R="$(new_repo claude-imported-nested)"
mkdir -p "$R/.claude"; printf '@../AGENTS.md\n' > "$R/.claude/CLAUDE.md"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_not_contains "$out" "2.1.277" "@../AGENTS.md in .claude/CLAUDE.md counts as the import"
R="$(new_repo claude-wrong-import)"
mkdir -p "$R/.claude"; printf '@AGENTS.md\n' > "$R/.claude/CLAUDE.md"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_contains "$out" "@../AGENTS.md" "@AGENTS.md in .claude/CLAUDE.md does not resolve to the repo file"

# Import paths are never glob-expanded: `@A*` run from a cwd holding AGENTS.md
# must not resolve to AGENTS.md and hide the notice.
R="$(new_repo claude-glob)"
printf '# rules\n@A*\n' > "$R/CLAUDE.md"
out="$(cd "$R" && bash "$INSTR" write "$R" 2>&1)"
assert_contains "$out" "2.1.277" "an @A* import line is not glob-expanded into AGENTS.md"

# A CLAUDE.md that is not a regular file is never opened: a FIFO would hang the
# read. Needs timeout(1); skipped (with a note) where it is absent.
R="$(new_repo claude-fifo)"
if command -v timeout >/dev/null 2>&1 && mkfifo "$R/CLAUDE.md" 2>/dev/null; then
  out="$(timeout 10 bash "$INSTR" write "$R" 2>&1)"; rc=$?
  assert_eq "0" "$rc" "a FIFO named CLAUDE.md does not hang or fail write"
  assert_contains "$out" "$R/CLAUDE.md" "a FIFO CLAUDE.md is still reported by the notice"
else
  echo "  skip  FIFO CLAUDE.md check: timeout(1) or mkfifo not available"
fi

# An ancestor up to the git top-level counts; the line is the path from that file.
mkdir -p "$SBX/mono/pkg/app"; git -C "$SBX/mono" init -q -b main
printf '# root rules\n' > "$SBX/mono/CLAUDE.md"
out="$(bash "$INSTR" write "$SBX/mono/pkg/app" 2>&1)"
assert_contains "$out" "$SBX/mono/CLAUDE.md" "notice names a CLAUDE.md in an ancestor within the repo"
assert_contains "$out" "@pkg/app/AGENTS.md" "ancestor notice gives the path from that file to AGENTS.md"
assert_not_contains "$out" "--import-agents-md" "no --import-agents-md hint for an ancestor CLAUDE.md"

# No walk above the git top-level.
mkdir -p "$SBX/outer"; printf '# outer\n' > "$SBX/outer/CLAUDE.md"
R="$(new_repo outer/inner)"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_not_contains "$out" "2.1.277" "a CLAUDE.md above the git top-level is not considered"

# Outside a git work tree only <repo-dir> itself is checked.
NOGIT="$(mktemp -d "${TMPDIR:-/tmp}/talos-nogit.XXXXXX")" || exit 1
mkdir -p "$NOGIT/sub"; printf '# up\n' > "$NOGIT/CLAUDE.md"
out="$(bash "$INSTR" write "$NOGIT/sub" 2>&1)"
assert_not_contains "$out" "2.1.277" "outside a git work tree, ancestors are not walked"
printf '# here\n' > "$NOGIT/sub/CLAUDE.md"
out="$(bash "$INSTR" write "$NOGIT/sub" 2>&1)"
assert_contains "$out" "2.1.277" "outside a git work tree, <repo-dir> itself is checked"
rm -rf "$NOGIT"

# ── Gemini notice ─────────────────────────────────────────────────────────────
R="$(new_repo gemini-none)"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_not_contains "$out" "Gemini" "no Gemini notice without GEMINI.md or --harness gemini"

R="$(new_repo gemini-file)"
printf '# gemini rules\n' > "$R/GEMINI.md"
before="$(sum "$R/GEMINI.md")"
out="$(bash "$INSTR" write "$R" 2>&1)"
assert_contains "$out" "Gemini CLI reads GEMINI.md by default" "GEMINI.md without the import prints the Gemini notice"
assert_contains "$out" 'context.fileName' "Gemini notice names context.fileName"
assert_contains "$out" '["AGENTS.md","GEMINI.md"]' "Gemini notice gives the settings value"
assert_contains "$out" "@AGENTS.md" "Gemini notice gives the import option"
assert_eq "$before" "$(sum "$R/GEMINI.md")" "GEMINI.md is byte-identical without --import-agents-md"

R="$(new_repo gemini-harness)"
out="$(bash "$INSTR" write "$R" --harness gemini 2>&1)"; rc=$?
assert_eq "0" "$rc" "write accepts --harness gemini (unvalidated)"
assert_contains "$out" "Gemini CLI reads GEMINI.md by default" "--harness gemini prints the Gemini notice"
out="$(bash "$INSTR" write "$R" --harness claude,gemini 2>&1)"
assert_contains "$out" "Gemini CLI reads GEMINI.md by default" "--harness list containing gemini prints the notice"
out="$(bash "$INSTR" write "$R" --harness claude 2>&1)"
assert_not_contains "$out" "Gemini" "--harness claude prints no Gemini notice"
bash "$INSTR" write "$R" --harness wholly-unknown >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "write does not validate the --harness value"

# ── --import-agents-md ───────────────────────────────────────────────────────
R="$(new_repo import)"
printf '# claude rules' > "$R/CLAUDE.md"          # no trailing newline
printf '# gemini rules\n' > "$R/GEMINI.md"
cp "$R/CLAUDE.md" "$SBX/c.orig"; cp "$R/GEMINI.md" "$SBX/g.orig"
csize="$(wc -c < "$R/CLAUDE.md" | tr -d ' ')"; gsize="$(wc -c < "$R/GEMINI.md" | tr -d ' ')"
out="$(bash "$INSTR" write "$R" --import-agents-md 2>&1)"; rc=$?
assert_eq "0" "$rc" "--import-agents-md exits 0"
assert_eq "$(cat "$SBX/c.orig")" "$(head -c "$csize" "$R/CLAUDE.md")" "CLAUDE.md keeps its bytes as a prefix"
assert_eq "$(cat "$SBX/g.orig")" "$(head -c "$gsize" "$R/GEMINI.md")" "GEMINI.md keeps its bytes as a prefix"
for f in CLAUDE.md GEMINI.md; do
  tail_text="$(tail -n 3 "$R/$f")"
  assert_eq "<!-- talos:import:begin -->
@AGENTS.md
<!-- talos:import:end -->" "$tail_text" "$f gets exactly the three import lines"
  assert_eq "0" "$(grep -c 'talos:begin' "$R/$f")" "the Talos block is never written into $f"
done
assert_not_contains "$out" "2.1.277" "after the import there is no Claude notice"
assert_not_contains "$out" "Gemini CLI reads" "after the import there is no Gemini notice"
before_c="$(sum "$R/CLAUDE.md")"; before_g="$(sum "$R/GEMINI.md")"
bash "$INSTR" write "$R" --import-agents-md >/dev/null 2>&1
assert_eq "$before_c" "$(sum "$R/CLAUDE.md")" "a second --import-agents-md leaves CLAUDE.md alone"
assert_eq "$before_g" "$(sum "$R/GEMINI.md")" "a second --import-agents-md leaves GEMINI.md alone"

R="$(new_repo import-absent)"
bash "$INSTR" write "$R" --import-agents-md >/dev/null 2>&1
assert_file_absent "$R/CLAUDE.md" "--import-agents-md never creates CLAUDE.md"
assert_file_absent "$R/GEMINI.md" "--import-agents-md never creates GEMINI.md"

R="$(new_repo import-link)"
printf 'real claude\n' > "$R/real-claude.md"; ln -s real-claude.md "$R/CLAUDE.md"
before_t="$(sum "$R/real-claude.md")"
out="$(bash "$INSTR" write "$R" --import-agents-md 2>&1)"
assert_eq "$before_t" "$(sum "$R/real-claude.md")" "a symlinked CLAUDE.md is not written through"
assert_contains "$out" "symlink" "a symlinked CLAUDE.md is skipped with a notice"

R="$(new_repo import-dotclaude)"
mkdir -p "$R/.claude"; printf '# rules\n' > "$R/.claude/CLAUDE.md"
before="$(sum "$R/.claude/CLAUDE.md")"
bash "$INSTR" write "$R" --import-agents-md >/dev/null 2>&1
assert_eq "$before" "$(sum "$R/.claude/CLAUDE.md")" "--import-agents-md never edits .claude/CLAUDE.md"

# ── writes go through a same-directory temp file and a rename (#457) ─────────
mode_of() { ls -l "$1" | cut -c1-10; }
leftovers() { find "$1" -maxdepth 1 -name '.talos-instr.*' | wc -l | tr -d ' '; }

R="$(new_repo atomic-mode)"
printf '# notes\n' > "$R/AGENTS.md"; printf '# claude rules\n' > "$R/CLAUDE.md"
chmod 640 "$R/AGENTS.md" "$R/CLAUDE.md"
want_mode="$(mode_of "$R/AGENTS.md")"
bash "$INSTR" write "$R" --import-agents-md >/dev/null 2>&1
assert_contains "$(cat "$R/AGENTS.md")" "talos:begin" "an appended AGENTS.md carries the block"
assert_contains "$(cat "$R/CLAUDE.md")" "@AGENTS.md" "an imported CLAUDE.md carries the import"
assert_eq "$want_mode" "$(mode_of "$R/AGENTS.md")" "an updated AGENTS.md keeps its mode"
assert_eq "$want_mode" "$(mode_of "$R/CLAUDE.md")" "an imported CLAUDE.md keeps its mode"
assert_eq "0" "$(leftovers "$R")" "no temp file is left next to the instruction files"

# A write that cannot create its temp file fails closed: the original is
# byte-identical, the reason is on stderr, and nothing claims success.
R="$(new_repo atomic-fail)"
printf '# notes\n' > "$R/AGENTS.md"; printf '# claude rules\n' > "$R/CLAUDE.md"
before_a="$(sum "$R/AGENTS.md")"; before_c="$(sum "$R/CLAUDE.md")"
chmod 555 "$R"
out="$(bash "$INSTR" write "$R" --import-agents-md 2>&1)"; rc=$?
chmod 755 "$R"
assert_eq "0" "$rc" "a failed instruction-file write is best-effort (exit 0)"
assert_eq "$before_a" "$(sum "$R/AGENTS.md")" "a failed AGENTS.md write leaves the original intact"
assert_eq "$before_c" "$(sum "$R/CLAUDE.md")" "a failed CLAUDE.md import leaves the original intact"
assert_contains "$out" "left unchanged" "a failed write says it left the file unchanged"
assert_not_contains "$out" "Next: commit AGENTS.md" "a failed AGENTS.md write does not print the commit hint"
assert_not_contains "$out" "import: added" "a failed import does not claim success"
assert_eq "0" "$(leftovers "$R")" "a failed write leaves no temp file"

finish
