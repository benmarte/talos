#!/usr/bin/env bash
# tests/test-claude-plugin-registration.sh -- install.sh --global registers
# Talos as a local Claude Code plugin so /talos:<command> exists (#335).
#
# Every case runs the installer with CLAUDE_CONFIG_DIR, TALOS_HOME and
# TALOS_AGENTS_HOME inside the sandbox and with the plugin stub first on PATH
# (tests/stubs/plugin-claude/claude, put there by make_sandbox): the real
# `claude`, the real Claude config and the network are never touched. The stub
# logs every call with the CLAUDE_CONFIG_DIR it saw, and the first case asserts
# that is the sandbox directory.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

INSTALL="$TALOS_ROOT/install.sh"
BASH_BIN="$(command -v bash)"
STUB_DIR="$STUBS_DIR/plugin-claude"

# newcase <name> -- a fresh Claude config dir, talos home and stub state.
newcase() {
  CASE="$SANDBOX/case-$1"
  case "$CASE" in "$SANDBOX"/case-*) ;; *) echo "refusing: $CASE" >&2; exit 1 ;; esac
  rm -rf "${CASE:?}"
  mkdir -p "$CASE/claude"
  export CLAUDE_STUB_STATE="$CASE/stub-state"
  export CLAUDE_PLUGIN_LOG="$CASE/plugin.log"
  : > "$CLAUDE_PLUGIN_LOG"
  unset CLAUDE_STUB_NO_PLUGIN CLAUDE_STUB_LIST_RAW CLAUDE_STUB_ADD_FAIL CLAUDE_STUB_INSTALL_FAIL
}

# seed_marketplace <kind> <value> -- what `marketplace list` reports for talos.
seed_marketplace() {
  mkdir -p "$CLAUDE_STUB_STATE"
  printf '%s\t%s\n' "$1" "$2" > "$CLAUDE_STUB_STATE/marketplace"
}

# inst [args...] -- the installer, PATH as make_sandbox left it. $OUT, $RC.
inst() {
  OUT="$(env CLAUDE_CONFIG_DIR="$CASE/claude" TALOS_HOME="$CASE/talos" TALOS_AGENTS_HOME="$CASE/agents" \
    "$BASH_BIN" "$INSTALL" --global --no-agent-skills --harness claude "$@" 2>&1)"; RC=$?
}

# calls <word...> -- how many logged stub calls contain every argument group.
calls() { grep -c -- "$1" "$CLAUDE_PLUGIN_LOG" || true; }

# ── 1. fresh config: marketplace add, then install, both inside the sandbox ──
newcase fresh
inst
assert_eq "0" "$RC" "fresh: --global exits 0"
assert_eq "1" "$(calls '\[plugin\] \[marketplace\] \[list\] \[--json\]')" "fresh: reads the marketplace list once"
assert_eq "1" "$(calls "\[plugin\] \[marketplace\] \[add\] \[$TALOS_ROOT\] \[--json\]")" "fresh: adds this checkout as a directory marketplace"
assert_eq "1" "$(calls '\[plugin\] \[install\] \[talos@talos\] \[--json\]')" "fresh: installs talos@talos"
assert_eq "dir	$TALOS_ROOT" "$(cat "$CLAUDE_STUB_STATE/marketplace")" "fresh: the stub config now holds the checkout as the talos marketplace"
assert_contains "$OUT" "registered: talos@talos" "fresh: output says the plugin is registered"
assert_contains "$OUT" "loads from $TALOS_ROOT in place" "fresh: output says the plugin loads from the checkout in place"
assert_contains "$OUT" "agent-skills dependency" "fresh: output names the agent-skills side effect"
assert_contains "$OUT" "/talos:pipeline, /talos:setup, /talos:resume" "fresh: the closing note names the three commands"
# Isolation: every call saw the sandbox config dir, never a real one.
bad="$(grep -vF "CLAUDE_CONFIG_DIR=$CASE/claude" "$CLAUDE_PLUGIN_LOG" || true)"
assert_eq "" "$bad" "fresh: every claude call ran with CLAUDE_CONFIG_DIR inside the sandbox"

# A second run is idempotent: the marketplace is already this checkout.
: > "$CLAUDE_PLUGIN_LOG"
inst
assert_eq "0" "$RC" "same directory: re-run exits 0"
assert_eq "0" "$(calls '\[add\]')" "same directory: no marketplace add"
assert_eq "1" "$(calls '\[install\] \[talos@talos\]')" "same directory: install is still run (idempotent)"

# ── 2. marketplace named talos pointing at another directory: repoint ────────
newcase other-dir
seed_marketplace dir "$SANDBOX/moved-checkout"
inst
assert_eq "0" "$RC" "other directory: exits 0"
assert_eq "1" "$(calls "\[add\] \[$TALOS_ROOT\]")" "other directory: re-adds the marketplace at this checkout"
assert_eq "dir	$TALOS_ROOT" "$(cat "$CLAUDE_STUB_STATE/marketplace")" "other directory: now points at this checkout"
assert_contains "$OUT" "repointed from $SANDBOX/moved-checkout to $TALOS_ROOT" "other directory: output says it repointed"

newcase other-dir-no-overwrite
seed_marketplace dir "$SANDBOX/moved-checkout"
inst --no-overwrite
assert_eq "0" "$(calls '\[add\]')" "other directory with --no-overwrite: no repoint"
assert_eq "dir	$SANDBOX/moved-checkout" "$(cat "$CLAUDE_STUB_STATE/marketplace")" "other directory with --no-overwrite: source unchanged"
assert_contains "$OUT" "left as is (--no-overwrite)" "other directory with --no-overwrite: output says so"

# ── 3. a github source is never replaced ─────────────────────────────────────
newcase github
seed_marketplace github "benmarte/talos"
inst
assert_eq "0" "$RC" "github source: exits 0"
assert_eq "0" "$(calls '\[add\]')" "github source: the marketplace is not re-added"
assert_eq "github	benmarte/talos" "$(cat "$CLAUDE_STUB_STATE/marketplace")" "github source: left exactly as it was"
assert_contains "$OUT" "non-directory source (github); left as is" "github source: output says it was left alone"

# ── 4. failures never abort the install and never delete anything ────────────
newcase install-fails
export CLAUDE_STUB_INSTALL_FAIL=1
mkdir -p "$CASE/claude/skills/talos-resume"
printf -- '---\nname: resume\ndescription: x\n---\nrun bash scripts/pipeline-config.sh\n' > "$CASE/claude/skills/talos-resume/SKILL.md"
inst
assert_eq "0" "$RC" "install fails: --global still exits 0"
assert_contains "$OUT" "'claude plugin install talos@talos' failed" "install fails: output reports the failure"
assert_contains "$OUT" "Done. Global Talos install" "install fails: the install ran to the end"
assert_contains "$OUT" "/talos:* commands are missing" "install fails: the closing note says the commands are missing"
assert_file_exists "$CASE/claude/skills/talos-resume/SKILL.md" "install fails: the old talos-resume copy is not deleted"
assert_file_exists "$CASE/talos/skills/pipeline/SKILL.md" "install fails: the ~/.talos playbooks are installed"

newcase add-fails
export CLAUDE_STUB_ADD_FAIL=1
inst
assert_eq "0" "$RC" "add fails: --global still exits 0"
assert_contains "$OUT" "'claude plugin marketplace add' failed" "add fails: output reports the failure"
assert_eq "0" "$(calls '\[install\]')" "add fails: install is not attempted"

# ── 5. the CLI cannot do it: notice and carry on ─────────────────────────────
newcase no-plugin-subcommand
export CLAUDE_STUB_NO_PLUGIN=1
inst
assert_eq "0" "$RC" "no plugin subcommand: exits 0"
assert_contains "$OUT" "has no 'claude plugin' subcommand" "no plugin subcommand: notice"
assert_contains "$OUT" "/plugin marketplace add $TALOS_ROOT" "no plugin subcommand: the notice gives the manual command"
assert_eq "0" "$(calls '\[marketplace\]')" "no plugin subcommand: no marketplace call"
assert_file_exists "$CASE/claude/skills/pipeline/SKILL.md" "no plugin subcommand: the /pipeline alias is still installed"

newcase unreadable-list
export CLAUDE_STUB_LIST_RAW='this is not json'
inst
assert_eq "0" "$RC" "unreadable list: exits 0"
assert_contains "$OUT" "could not read 'claude plugin marketplace list --json'" "unreadable list: notice"
assert_eq "0" "$(calls '\[add\]')" "unreadable list: never guesses, so no marketplace add"
assert_eq "0" "$(calls '\[install\]')" "unreadable list: no install"

# ── 6. no claude on PATH ─────────────────────────────────────────────────────
BIN="$SANDBOX/bin"
mkdir -p "$BIN"
STRIP_OK=true
for tool in bash dirname basename mkdir cp chmod mktemp rm rmdir cat grep sed awk env git python3 \
            sort tr cut head tail wc date uname ls ln mv touch readlink find xargs \
            sleep expr diff cmp; do
  t="$(command -v "$tool" 2>/dev/null || true)"
  case "$t" in
    /*) ln -sf "$t" "$BIN/$tool" ;;
    *) case "$tool" in
         bash|dirname|basename|mkdir|cp|chmod|mktemp|rm|rmdir|cat|grep|env|awk|sed|python3) STRIP_OK=false ;;
       esac ;;
  esac
done
if [ "$STRIP_OK" = true ] && [ -z "$(PATH="$BIN" command -v claude 2>/dev/null || true)" ]; then
  newcase no-claude
  OUT="$(env CLAUDE_CONFIG_DIR="$CASE/claude" TALOS_HOME="$CASE/talos" TALOS_AGENTS_HOME="$CASE/agents" PATH="$BIN" \
    "$BASH_BIN" "$INSTALL" --global --no-agent-skills --harness claude 2>&1)"; RC=$?
  assert_eq "0" "$RC" "no claude on PATH: exits 0"
  assert_contains "$OUT" "claude is not on PATH, so the talos plugin was not registered" "no claude on PATH: notice"
  assert_contains "$OUT" "/plugin marketplace add $TALOS_ROOT, then /plugin install talos@talos" "no claude on PATH: the notice gives both manual commands"
  assert_file_exists "$CASE/claude/agents/developer.md" "no claude on PATH: the role profiles are still installed"
  assert_file_exists "$CASE/claude/skills/pipeline/SKILL.md" "no claude on PATH: the /pipeline alias is still installed"
else
  echo "  -- skipped: cannot build a PATH without claude (no-claude case)"
fi

# ── 7. the adapter is skipped: claude is never called ────────────────────────
newcase adapter-skipped
OUT="$(env CLAUDE_CONFIG_DIR="$CASE/claude" TALOS_HOME="$CASE/talos" TALOS_AGENTS_HOME="$CASE/agents" \
  "$BASH_BIN" "$INSTALL" --global --no-agent-skills --harness codex 2>&1)"; RC=$?
assert_eq "0" "$RC" "--harness codex: exits 0"
assert_eq "" "$(cat "$CLAUDE_PLUGIN_LOG")" "--harness codex: no claude call at all"
assert_file_absent "$CASE/claude/skills" "--harness codex: nothing is written under the Claude config dir"

# ── 8. a checkout without the marketplace manifest is not registered ─────────
newcase no-manifest
NOMAN="$SANDBOX/no-manifest-src"
mkdir -p "$NOMAN"
cp "$INSTALL" "$NOMAN/install.sh"
cp -R "$TALOS_ROOT/scripts" "$TALOS_ROOT/agents" "$TALOS_ROOT/templates" "$TALOS_ROOT/skills" "$NOMAN/"
OUT="$(env CLAUDE_CONFIG_DIR="$CASE/claude" TALOS_HOME="$CASE/talos" TALOS_AGENTS_HOME="$CASE/agents" \
  "$BASH_BIN" "$NOMAN/install.sh" --global --no-agent-skills --harness claude 2>&1)"; RC=$?
assert_eq "0" "$RC" "no marketplace.json: exits 0"
assert_contains "$OUT" "marketplace.json not found" "no marketplace.json: notice"
assert_eq "0" "$(calls '\[add\]')" "no marketplace.json: no marketplace add"

# ── 9. the plugin's own manifest is the marketplace, and the stub is the stub ─
assert_file_exists "$TALOS_ROOT/.claude-plugin/marketplace.json" "the repo ships .claude-plugin/marketplace.json (the local marketplace)"
assert_eq "plugin-claude" "$(basename "$STUB_DIR")" "the plugin stub directory is the one make_sandbox puts on PATH"
assert_eq "$STUB_DIR/claude" "$(command -v claude)" "make_sandbox puts the plugin stub first on PATH"

finish
