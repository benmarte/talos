#!/usr/bin/env bash
# tests/test-legacy-aliases.sh -- the deprecated /pipeline and /pipeline-setup
# names (#335). install.sh --global keeps them as thin alias skills until v0.20:
# each prints one rename line and follows the ~/.talos playbook. --no-legacy-aliases
# installs none and removes Talos-owned bare copies; a skill that is not Talos's
# is never overwritten or deleted.
#
# Every case runs the installer with CLAUDE_CONFIG_DIR, TALOS_HOME and
# TALOS_AGENTS_HOME inside the sandbox and the plugin stub first on PATH
# (make_sandbox), so the real `claude` and ~/.claude are never touched.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

INSTALL="$TALOS_ROOT/install.sh"
BASH_BIN="$(command -v bash)"
MARKER='<!-- talos:alias -->'

newcase() {
  CASE="$SANDBOX/case-$1"
  case "$CASE" in "$SANDBOX"/case-*) ;; *) echo "refusing: $CASE" >&2; exit 1 ;; esac
  rm -rf "${CASE:?}"
  mkdir -p "$CASE/claude/skills"
  SK="$CASE/claude/skills"
  export CLAUDE_STUB_STATE="$CASE/stub-state"
  export CLAUDE_PLUGIN_LOG="$CASE/plugin.log"
  : > "$CLAUDE_PLUGIN_LOG"
  unset CLAUDE_STUB_NO_PLUGIN CLAUDE_STUB_LIST_RAW CLAUDE_STUB_ADD_FAIL CLAUDE_STUB_INSTALL_FAIL
}

inst() {
  OUT="$(env CLAUDE_CONFIG_DIR="$CASE/claude" TALOS_HOME="$CASE/talos" TALOS_AGENTS_HOME="$CASE/agents" \
    "$BASH_BIN" "$INSTALL" --global --no-agent-skills --harness claude "$@" 2>&1)"; RC=$?
}

# old_copy <dir name> <frontmatter name> -- a full copy as installers before
# #335 wrote it: no marker, frontmatter name, text naming a Talos script.
old_copy() {
  mkdir -p "$SK/$1"
  printf -- '---\nname: %s\ndescription: old full copy\n---\nRun bash scripts/pipeline-vcs.sh and read talos.pipeline.yml\n' "$2" > "$SK/$1/SKILL.md"
}

# ── 1. default install: two thin aliases, marker, rename line, pointer ───────
newcase default
inst
assert_eq "0" "$RC" "default: exits 0"
for pair in "pipeline:pipeline" "pipeline-setup:setup"; do
  name="${pair%%:*}"; cmd="${pair#*:}"
  f="$SK/$name/SKILL.md"
  assert_file_exists "$f" "default: ~/.claude/skills/$name/SKILL.md is installed"
  [ -f "$f" ] || continue
  assert_eq "1" "$(grep -cxF "$MARKER" "$f")" "default: $name carries the alias marker on its own line"
  assert_eq "name: $name" "$(sed -n '2p' "$f")" "default: $name frontmatter name equals the directory name"
  assert_contains "$(cat "$f")" "renamed to /talos:$cmd; this alias is removed in v0.20" "default: $name prints the deprecation line"
  assert_contains "$(cat "$f")" "~/.talos/skills/$cmd/SKILL.md" "default: $name follows the ~/.talos playbook"
  assert_contains "$(cat "$f")" '$TALOS_HOME/skills/'"$cmd"'/SKILL.md' "default: $name honours TALOS_HOME"
  assert_contains "$(cat "$f")" "same arguments" "default: $name runs the command unchanged"
  n_lines="$(wc -l < "$f" | tr -d ' ')"
  if [ "$n_lines" -le 12 ]; then pass "default: $name is thin ($n_lines lines)"; else fail "default: $name is thin" "$n_lines lines"; fi
  assert_file_exists "$CASE/talos/skills/$cmd/SKILL.md" "default: the playbook the alias names exists: ~/.talos/skills/$cmd/SKILL.md"
done
assert_file_absent "$SK/setup" "default: no bare /setup skill"
assert_file_absent "$SK/resume" "default: no bare /resume skill (clashes with the built-in)"
assert_file_absent "$SK/talos-resume" "default: no bare talos-resume skill"
assert_contains "$OUT" "Old names /pipeline and /pipeline-setup still work as aliases until v0.20" "default: the closing note names the aliases"

# The plugin's own skills/pipeline-setup keeps /talos:pipeline-setup working and
# is exactly the alias text the installer generates for the same name.
cmp -s "$TALOS_ROOT/skills/pipeline-setup/SKILL.md" "$SK/pipeline-setup/SKILL.md" \
  && pass "skills/pipeline-setup/SKILL.md (the /talos:pipeline-setup alias) equals the generated alias" \
  || fail "skills/pipeline-setup/SKILL.md (the /talos:pipeline-setup alias) equals the generated alias"
assert_eq "1" "$(grep -cxF "$MARKER" "$TALOS_ROOT/skills/pipeline-setup/SKILL.md")" "the plugin alias carries the alias marker"

# Idempotent: a second run leaves the same bytes.
cp "$SK/pipeline/SKILL.md" "$CASE/pipeline.first"
inst
cmp -s "$CASE/pipeline.first" "$SK/pipeline/SKILL.md" && pass "default: a re-run rewrites the same alias bytes" || fail "default: a re-run rewrites the same alias bytes"

# ── 2. --no-legacy-aliases installs no bare names ────────────────────────────
newcase no-aliases
inst --no-legacy-aliases
assert_eq "0" "$RC" "--no-legacy-aliases: exits 0"
assert_file_absent "$SK/pipeline" "--no-legacy-aliases: no ~/.claude/skills/pipeline"
assert_file_absent "$SK/pipeline-setup" "--no-legacy-aliases: no ~/.claude/skills/pipeline-setup"
assert_file_absent "$SK/talos-resume" "--no-legacy-aliases: no talos-resume"
assert_file_exists "$CASE/claude/agents/developer.md" "--no-legacy-aliases: the role profiles are still installed"
assert_file_exists "$CASE/talos/skills/pipeline/SKILL.md" "--no-legacy-aliases: the ~/.talos playbooks are still installed"
assert_eq "1" "$(grep -c '\[install\] \[talos@talos\]' "$CLAUDE_PLUGIN_LOG" || true)" "--no-legacy-aliases: the plugin is still registered"
assert_not_contains "$OUT" "Old names /pipeline" "--no-legacy-aliases: the closing note does not promise aliases"

# ── 3. stale Talos copies: removed once the plugin is registered ─────────────
newcase stale-removed
inst
inst --no-legacy-aliases
assert_file_absent "$SK/pipeline" "--no-legacy-aliases: an earlier alias (marker) is removed"
assert_file_absent "$SK/pipeline-setup" "--no-legacy-aliases: the earlier pipeline-setup alias is removed"
assert_contains "$OUT" "removed: $SK/pipeline/SKILL.md" "--no-legacy-aliases: output names what it removed"

newcase stale-full-copies
old_copy pipeline pipeline
old_copy pipeline-setup pipeline-setup
old_copy talos-resume resume
printf 'keep me\n' > "$SK/pipeline/notes.txt"
inst --no-legacy-aliases
assert_file_absent "$SK/pipeline/SKILL.md" "--no-legacy-aliases: a pre-alias full copy of pipeline is removed"
assert_file_exists "$SK/pipeline/notes.txt" "--no-legacy-aliases: other files in that directory are kept"
assert_file_absent "$SK/pipeline-setup" "--no-legacy-aliases: a pre-alias full copy of pipeline-setup is removed"
assert_file_absent "$SK/talos-resume" "--no-legacy-aliases: the old talos-resume copy is removed"

newcase stale-resume-default
old_copy talos-resume resume
old_copy pipeline pipeline
inst
assert_file_absent "$SK/talos-resume" "default: the old talos-resume copy is removed (/talos:resume replaces it)"
assert_eq "1" "$(grep -cxF "$MARKER" "$SK/pipeline/SKILL.md")" "default: a pre-alias full copy of pipeline is replaced by the alias"
assert_not_contains "$(cat "$SK/pipeline/SKILL.md")" "old full copy" "default: the old text is gone"

newcase stale-no-overwrite
old_copy pipeline pipeline
inst --no-overwrite
assert_contains "$(cat "$SK/pipeline/SKILL.md")" "old full copy" "--no-overwrite: an old full copy is left as it is"
assert_contains "$OUT" "skip (exists): $SK/pipeline/SKILL.md" "--no-overwrite: output says it skipped"

# ── 4. nothing is deleted while the plugin is not registered ─────────────────
newcase unregistered
export CLAUDE_STUB_INSTALL_FAIL=1
old_copy talos-resume resume
old_copy pipeline pipeline
inst --no-legacy-aliases
assert_file_exists "$SK/talos-resume/SKILL.md" "unregistered: the old talos-resume copy is kept"
assert_file_exists "$SK/pipeline/SKILL.md" "unregistered, --no-legacy-aliases: a Talos copy of pipeline is kept"
assert_contains "$OUT" "kept (the talos plugin is not registered" "unregistered: output says why it was kept"

# ── 5. a skill that is not Talos's is never touched ──────────────────────────
newcase foreign
mkdir -p "$SK/pipeline" "$SK/pipeline-setup"
printf -- '---\nname: pipeline\ndescription: my own CI pipeline helper\n---\nBuilds the thing.\n' > "$SK/pipeline/SKILL.md"
printf -- 'not even frontmatter, quotes %s inline\n' "$MARKER" > "$SK/pipeline-setup/SKILL.md"
cp "$SK/pipeline/SKILL.md" "$CASE/foreign-pipeline.orig"
cp "$SK/pipeline-setup/SKILL.md" "$CASE/foreign-setup.orig"
inst
assert_eq "0" "$RC" "foreign: exits 0"
cmp -s "$CASE/foreign-pipeline.orig" "$SK/pipeline/SKILL.md" && pass "foreign: ~/.claude/skills/pipeline is byte-identical" || fail "foreign: ~/.claude/skills/pipeline is byte-identical"
cmp -s "$CASE/foreign-setup.orig" "$SK/pipeline-setup/SKILL.md" && pass "foreign: a file that only quotes the marker inline is byte-identical" || fail "foreign: a file that only quotes the marker inline is byte-identical"
assert_contains "$OUT" "warning: $SK/pipeline/SKILL.md exists and is not a Talos alias; left untouched" "foreign: the installer warns about pipeline"
assert_contains "$OUT" "warning: $SK/pipeline-setup/SKILL.md exists and is not a Talos alias; left untouched" "foreign: the installer warns about pipeline-setup"
assert_file_exists "$CASE/talos/skills/pipeline/SKILL.md" "foreign: the rest of the install still ran"
inst --force
cmp -s "$CASE/foreign-pipeline.orig" "$SK/pipeline/SKILL.md" && pass "foreign: --force does not overwrite it either" || fail "foreign: --force does not overwrite it either"
inst --no-legacy-aliases
cmp -s "$CASE/foreign-pipeline.orig" "$SK/pipeline/SKILL.md" && pass "foreign: --no-legacy-aliases does not delete it" || fail "foreign: --no-legacy-aliases does not delete it"
assert_file_exists "$SK/pipeline-setup/SKILL.md" "foreign: --no-legacy-aliases keeps the other foreign file too"

# A symlink on the path is skipped, nothing is written through it.
newcase symlink
mkdir -p "$CASE/elsewhere"
ln -s "$CASE/elsewhere" "$SK/pipeline"
inst
assert_eq "0" "$RC" "symlink: exits 0"
assert_eq "0" "$(find "$CASE/elsewhere" -mindepth 1 | wc -l | tr -d ' ')" "symlink: nothing is written through the link"
assert_contains "$OUT" "$SK/pipeline is a symlink; left untouched" "symlink: the notice names the link"
assert_file_exists "$SK/pipeline-setup/SKILL.md" "symlink: the other alias is still written"

# ── 6. a skipped adapter touches nothing under ~/.claude ─────────────────────
newcase skipped-adapter
old_copy pipeline pipeline
cp "$SK/pipeline/SKILL.md" "$CASE/pipeline.before"
OUT="$(env CLAUDE_CONFIG_DIR="$CASE/claude" TALOS_HOME="$CASE/talos" TALOS_AGENTS_HOME="$CASE/agents" \
  "$BASH_BIN" "$INSTALL" --global --no-agent-skills --harness codex --no-legacy-aliases 2>&1)"; RC=$?
assert_eq "0" "$RC" "skipped adapter: exits 0"
cmp -s "$CASE/pipeline.before" "$SK/pipeline/SKILL.md" && pass "skipped adapter: an existing ~/.claude skill is not deleted or refreshed" || fail "skipped adapter: an existing ~/.claude skill is not deleted or refreshed"

# ── 7. a repo whose CLAUDE.md says /pipeline still has a command to run ──────
# The alias is the bare /pipeline; the playbook it reads is the one /talos:pipeline runs.
newcase claude-md
printf 'Run /pipeline to start.\n' > "$CASE/CLAUDE.md"
inst
assert_file_exists "$SK/pipeline/SKILL.md" "a CLAUDE.md saying /pipeline: the /pipeline alias exists"
assert_contains "$(cat "$SK/pipeline/SKILL.md")" "read the playbook with your file-read tool and follow it exactly" "a CLAUDE.md saying /pipeline: the alias hands off to the playbook"

# ── 8. the setup wizard offers to rewrite old names (Step 7d) ────────────────
SETUP_MD="$TALOS_ROOT/skills/setup/SKILL.md"
grep_cmd="$(grep -F "grep -nE '(^|[^A-Za-z0-9_./:-])/" "$SETUP_MD" | head -1)"
if [ -n "$grep_cmd" ]; then pass "setup Step 7d: the old-name grep is in the wizard"; else fail "setup Step 7d: the old-name grep is in the wizard"; fi
mkdir -p "$CASE/repo"
printf '%s\n' \
  'a: run /pipeline now' \
  'b: run /pipeline-setup first' \
  'c: the old /talos:pipeline-setup' \
  'd: the new /talos:pipeline and /talos:setup' \
  'e: /pipeline.' \
  'f: .claude/skills/pipeline/SKILL.md' \
  'g: /pipeline-foo' \
  'h: see /pipelines' > "$CASE/repo/CLAUDE.md"
hits="$(cd "$CASE/repo" && eval "$grep_cmd" | cut -d: -f2 | tr '\n' ' ')"
assert_eq "1 2 3 5 " "$hits" "setup Step 7d: the grep flags /pipeline, /pipeline-setup, /talos:pipeline-setup and nothing else"
assert_contains "$(cat "$SETUP_MD")" "Update these old command names? (yes/no)" "setup Step 7d: asks before rewriting"
assert_contains "$(cat "$SETUP_MD")" "never the text between the Talos block's two markers" "setup Step 7d: leaves the Talos block alone"

finish
