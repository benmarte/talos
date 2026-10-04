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
assert_contains "$OUT" "copied the plugin into its plugin cache" "fresh: output says Claude Code copies the plugin into its cache"
assert_not_contains "$OUT" "loads from $TALOS_ROOT in place" "fresh: output no longer claims the plugin loads from the checkout in place"
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

# --keep-marketplace leaves a registration that points elsewhere untouched, but
# the plugin install still runs against it.
newcase other-dir-keep
seed_marketplace dir "$SANDBOX/moved-checkout"
inst --keep-marketplace
assert_eq "0" "$RC" "other directory with --keep-marketplace: exits 0"
assert_eq "0" "$(calls '\[add\]')" "other directory with --keep-marketplace: no repoint"
assert_eq "dir	$SANDBOX/moved-checkout" "$(cat "$CLAUDE_STUB_STATE/marketplace")" "other directory with --keep-marketplace: source unchanged"
assert_contains "$OUT" "points at $SANDBOX/moved-checkout, not this checkout ($TALOS_ROOT); left as is (--keep-marketplace)" "other directory with --keep-marketplace: output names both paths"
assert_eq "1" "$(calls '\[install\] \[talos@talos\]')" "other directory with --keep-marketplace: install still runs"

# A control character in a printed path is stripped: a marketplace path with an
# ESC (JSON \u001b) must not reach the terminal.
newcase esc-path
export CLAUDE_STUB_LIST_RAW='[{"name":"talos","source":"directory","path":"/moved\u001b[31m-checkout"}]'
inst --keep-marketplace
assert_eq "0" "$RC" "ESC in a marketplace path: exits 0"
assert_contains "$OUT" "points at /moved?[31m-checkout, not this checkout" "ESC in a marketplace path: printed with the ESC replaced by ?"
assert_eq "0" "$(printf '%s' "$OUT" | LC_ALL=C grep -c "$(printf '\033')" || true)" "ESC in a marketplace path: no ESC byte in the installer output"

# ESC and a C1 control (U+009B, bytes c2 9b, a one-character CSI) in a path the
# installer prints -- CLAUDE_CONFIG_DIR on a global install, the target repo on
# a per-repo install -- never reach the output. The directories really carry
# the control characters, so the installer and the sandbox both handle them.
newcase ctl-path
ESC_C1="$(printf '\033[31m-\302\233x')"
mkdir -p "$CASE/claude-$ESC_C1" "$CASE/repo-$ESC_C1"
OUT="$(env CLAUDE_CONFIG_DIR="$CASE/claude-$ESC_C1" TALOS_HOME="$CASE/talos" TALOS_AGENTS_HOME="$CASE/agents" \
  "$BASH_BIN" "$INSTALL" --global --no-agent-skills --harness claude 2>&1)"; RC=$?
assert_eq "0" "$RC" "control characters in CLAUDE_CONFIG_DIR: exits 0"
assert_contains "$OUT" "Claude Code adapter ($CASE/claude-?[31m-?x):" "control characters in CLAUDE_CONFIG_DIR: path printed with them replaced by ?"
assert_eq "0" "$(printf '%s' "$OUT" | LC_ALL=C grep -c -e "$(printf '\033')" -e "$(printf '\302\233')" || true)" "control characters in CLAUDE_CONFIG_DIR: no ESC or C1 byte in the output"
OUT="$(env CLAUDE_CONFIG_DIR="$CASE/claude" TALOS_HOME="$CASE/talos" TALOS_AGENTS_HOME="$CASE/agents" \
  "$BASH_BIN" "$INSTALL" "$CASE/repo-$ESC_C1" --no-agent-skills --harness claude 2>&1)"; RC=$?
assert_contains "$OUT" "Configuring Talos for repo: $CASE/repo-?[31m-?x" "control characters in the target repo: path printed with them replaced by ?"
assert_eq "0" "$(printf '%s' "$OUT" | LC_ALL=C grep -c -e "$(printf '\033')" -e "$(printf '\302\233')" || true)" "control characters in the target repo: no ESC or C1 byte in the output"

# has_ctl <text> -- 1 when <text> holds an ESC or a UTF-8 C1 control (bytes
# c2 80..c2 9f), else 0. Byte-wise (LC_ALL=C), whatever the ambient locale.
C1_RE="$(printf '\302')[$(printf '\200')-$(printf '\237')]"
has_ctl() {
  if LC_ALL=C grep -q -E -e "$C1_RE" -e "$(printf '\033')" <<<"$1"; then echo 1; else echo 0; fi
}

# The sanitisers themselves. Deleting a control can join its neighbours into a
# new one (c2 c2 9b 9b -> c2 9b, c2 1b 9b -> c2 9b), so no output may hold an
# ESC or a c2 80..c2 9f pair, whatever the input; other UTF-8 passes through.
eval "$(awk '/^_P_C2=/{p=1} p{print} p&&/^}/{exit}' "$INSTALL")"
eval "$(awk '/^_P_C2=/{p=1} p{print} p&&/^}/{exit}' "$TALOS_ROOT/scripts/pipeline-instructions.sh")"
for _in in "$(printf '\302\302\233\233')" "$(printf '\302\033\233')" "$(printf '\302\302\302\200\200\200')" \
           "$(printf '\033\302\033\233\233')" "$(printf '\302\t\233\177')" "$(printf 'a\033[31mb\302\233c')"; do
  assert_eq "0" "$(has_ctl "$(printable "$_in")")" "printable: no ESC or C1 control survives input $(printf '%s' "$_in" | od -An -tx1 | tr -d '\n')"
  assert_eq "0" "$(has_ctl "$(_printable "$_in")")" "_printable: no ESC or C1 control survives input $(printf '%s' "$_in" | od -An -tx1 | tr -d '\n')"
done
_ok="$(printf 'caf\303\251 \303\204 \342\202\254 \342\202\233 \302\240x')"
assert_eq "$_ok" "$(printable "$_ok")" "printable: e-acute, A-umlaut, euro, e2 82 9b and c2 a0 pass through"
assert_eq "$_ok" "$(_printable "$_ok")" "_printable: e-acute, A-umlaut, euro, e2 82 9b and c2 a0 pass through"

# A repo path holding ESC and c2 9b, with an existing CLAUDE.md and GEMINI.md
# (so the Claude and Gemini notices print the repo-derived paths), and a hostile
# TALOS_HOME (the missing-skill warning): none of it reaches the output raw,
# from pipeline-instructions.sh itself or through install.sh.
newcase hostile-repo
HOSTILE="$(printf 'r\033[31m-\302\233x')"
# The scripts print `pwd` paths, which collapse a doubled slash in $TMPDIR.
CASE_P="$(cd "$CASE" && pwd)"
HREPO="$CASE_P/$HOSTILE"
mkdir -p "$HREPO"
git -C "$HREPO" init -q -b main
printf '# claude rules\n' > "$HREPO/CLAUDE.md"
printf '# gemini rules\n' > "$HREPO/GEMINI.md"
OUT="$(env TALOS_HOME="$CASE/talos-$HOSTILE" "$BASH_BIN" "$TALOS_ROOT/scripts/pipeline-instructions.sh" write "$HREPO" 2>&1)"; RC=$?
assert_eq "0" "$RC" "hostile repo path: pipeline-instructions write exits 0"
assert_contains "$OUT" "Claude Code: found $CASE_P/r?[31m-?x/CLAUDE.md." "hostile repo path: the Claude notice prints the path with controls replaced"
assert_contains "$OUT" "add the line @AGENTS.md to $CASE_P/r?[31m-?x/GEMINI.md" "hostile repo path: the Gemini notice prints the path with controls replaced"
assert_contains "$OUT" "warning: $CASE/talos-r?[31m-?x/skills/pipeline/SKILL.md is missing" "hostile TALOS_HOME: the missing-skill warning prints the path with controls replaced"
assert_eq "0" "$(has_ctl "$OUT")" "hostile repo path: no ESC or C1 byte anywhere in pipeline-instructions write output"
OUT="$(env TALOS_HOME="$CASE/talos" "$BASH_BIN" "$TALOS_ROOT/scripts/pipeline-instructions.sh" write "$HREPO" --import-agents-md 2>&1)"; RC=$?
assert_eq "0" "$RC" "hostile repo path: write --import-agents-md exits 0"
assert_contains "$OUT" "import: added @AGENTS.md to $CASE_P/r?[31m-?x/CLAUDE.md" "hostile repo path: the import line prints the path with controls replaced"
assert_eq "0" "$(has_ctl "$OUT")" "hostile repo path: no ESC or C1 byte anywhere in write --import-agents-md output"
OUT="$(env TALOS_HOME="$CASE/talos" "$BASH_BIN" "$TALOS_ROOT/scripts/pipeline-instructions.sh" write "$HREPO" "--bad$HOSTILE" 2>&1)"; RC=$?
assert_eq "2" "$RC" "hostile option: pipeline-instructions write exits 2"
assert_eq "0" "$(has_ctl "$OUT")" "hostile option: no ESC or C1 byte in the error"
OUT="$(env TALOS_HOME="$CASE/talos" "$BASH_BIN" "$TALOS_ROOT/scripts/pipeline-instructions.sh" write "$CASE/missing-$HOSTILE" 2>&1)"; RC=$?
assert_eq "2" "$RC" "hostile missing repo: pipeline-instructions write exits 2"
assert_eq "0" "$(has_ctl "$OUT")" "hostile missing repo: no ESC or C1 byte in the error"
# Back to the plain fixture (the --import-agents-md run above edited both files).
rm -f "${HREPO:?}/AGENTS.md"
printf '# claude rules\n' > "$HREPO/CLAUDE.md"
printf '# gemini rules\n' > "$HREPO/GEMINI.md"
OUT="$(env CLAUDE_CONFIG_DIR="$CASE/claude" TALOS_HOME="$CASE/talos" TALOS_AGENTS_HOME="$CASE/agents" \
  "$BASH_BIN" "$INSTALL" "$HREPO" --no-agent-skills --harness claude,gemini 2>&1)"; RC=$?
assert_eq "0" "$RC" "hostile repo path: install.sh on the repo exits 0"
assert_contains "$OUT" "Claude Code: found $CASE_P/r?[31m-?x/CLAUDE.md." "hostile repo path: install.sh prints the Claude notice path with controls replaced"
assert_contains "$OUT" "add the line @AGENTS.md to $CASE_P/r?[31m-?x/GEMINI.md" "hostile repo path: install.sh prints the Gemini notice path with controls replaced"
assert_eq "0" "$(has_ctl "$OUT")" "hostile repo path: no ESC or C1 byte anywhere in install.sh output"
OUT="$(env CLAUDE_CONFIG_DIR="$CASE/claude" TALOS_HOME="$CASE/talos" TALOS_AGENTS_HOME="$CASE/agents-$HOSTILE" \
  "$BASH_BIN" "$INSTALL" --global --no-agent-skills --harness codex,claude 2>&1)"; RC=$?
assert_eq "0" "$RC" "hostile TALOS_AGENTS_HOME: global install exits 0"
assert_eq "0" "$(has_ctl "$OUT")" "hostile TALOS_AGENTS_HOME: no ESC or C1 byte anywhere in the output"
for _h in "$(printf 'a\033b')" "$(printf 'a\302\233b')" "$(printf ',\033')" ; do
  OUT="$(env CLAUDE_CONFIG_DIR="$CASE/claude" TALOS_HOME="$CASE/talos" TALOS_AGENTS_HOME="$CASE/agents" \
    "$BASH_BIN" "$INSTALL" --global --no-agent-skills "--harness=$_h" 2>&1)"; RC=$?
  assert_eq "1" "$RC" "hostile --harness value: install.sh exits 1"
  assert_eq "0" "$(has_ctl "$OUT")" "hostile --harness value: no ESC or C1 byte in the error"
done
OUT="$(env CLAUDE_CONFIG_DIR="$CASE/claude" TALOS_HOME="$CASE/talos" TALOS_AGENTS_HOME="$CASE/agents" \
  "$BASH_BIN" "$INSTALL" --global --no-agent-skills --harness "$(printf -- '-\033x')" 2>&1)"; RC=$?
assert_eq "1" "$RC" "hostile --harness next-argument: install.sh exits 1"
assert_eq "0" "$(has_ctl "$OUT")" "hostile --harness next-argument: no ESC or C1 byte in the error"

newcase keep-fresh
inst --keep-marketplace
assert_eq "1" "$(calls "\[add\] \[$TALOS_ROOT\]")" "--keep-marketplace on a fresh config: still registers the checkout"

# The agent-skills note says it happens even with --no-agent-skills (inst passes it).
assert_contains "$OUT" "even with --no-agent-skills" "agent-skills note: says it applies even with --no-agent-skills"

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
