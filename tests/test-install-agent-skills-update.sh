#!/usr/bin/env bash
# tests/test-install-agent-skills-update.sh -- every install and re-install gets
# upstream's latest agent-skills unless --no-agent-skills is passed (#1092).
#
# Global: install.sh --global runs `claude plugin update agent-skills@talos`
# after `claude plugin install talos@talos`, against the plugin stub
# make_sandbox puts first on PATH. Per-repo: the skills it vendored (recorded in
# .claude/skills/.agent-skills-manifest) are refreshed from a local git fixture
# passed as TALOS_AGENT_SKILLS_REPO. The real `claude`, the real Claude config
# and the network are never touched.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

INSTALL="$TALOS_ROOT/install.sh"
BASH_BIN="$(command -v bash)"

# ── global ───────────────────────────────────────────────────────────────────
# newcase <name> -- a fresh Claude config dir, talos home and stub log.
newcase() {
  CASE="$SANDBOX/case-$1"
  mkdir -p "$CASE/claude"
  export CLAUDE_STUB_STATE="$CASE/stub-state"
  export CLAUDE_PLUGIN_LOG="$CASE/plugin.log"
  : > "$CLAUDE_PLUGIN_LOG"
  unset CLAUDE_STUB_INSTALL_FAIL CLAUDE_STUB_UPDATE_RC
}

# inst [args...] -- install.sh --global with the Claude adapter. $OUT, $RC.
inst() {
  OUT="$(env CLAUDE_CONFIG_DIR="$CASE/claude" TALOS_HOME="$CASE/talos" TALOS_AGENTS_HOME="$CASE/agents" \
    "$BASH_BIN" "$INSTALL" --global --harness claude --no-statusline "$@" 2>&1)"; RC=$?
}

# calls <pattern> -- how many logged stub calls match.
calls() { grep -c -- "$1" "$CLAUDE_PLUGIN_LOG" || true; }
# line_of <pattern> -- the log line number of the first matching stub call.
line_of() { grep -n -- "$1" "$CLAUDE_PLUGIN_LOG" | head -1 | cut -d: -f1; }

newcase ok
inst
assert_eq "0" "$RC" "AC1 a global install exits 0"
assert_eq "1" "$(calls '\[plugin\] \[update\] \[agent-skills@talos\] \[--json\]')" "AC1 calls claude plugin update agent-skills@talos once"
_in="$(line_of '\[plugin\] \[install\] \[talos@talos\]')"
_up="$(line_of '\[plugin\] \[update\] \[agent-skills@talos\]')"
assert_eq "1" "$([ -n "$_in" ] && [ -n "$_up" ] && [ "$_in" -lt "$_up" ] && echo 1 || echo 0)" "AC1 the update runs after the talos install"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'agent-skills: updated to the latest (agent-skills@talos)')" "AC1 prints agent-skills: updated to the latest"

newcase update-fails
export CLAUDE_STUB_UPDATE_RC=1
inst
assert_eq "0" "$RC" "AC2 a failed update: the install still exits 0"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep 'notice:' | grep -c 'claude plugin update agent-skills@talos')" "AC2 a failed update: one notice line names the manual command"
assert_contains "$(printf '%s\n' "$OUT" | grep 'notice:' | grep 'update agent-skills@talos')" "could not reach github.com" "AC2 a failed update: the notice carries the last output line"
assert_not_contains "$OUT" "agent-skills: updated to the latest" "AC2 a failed update: no success line"
assert_contains "$OUT" "Done. Global Talos install" "AC2 a failed update: the install runs to Done."

newcase opt-out
inst --no-agent-skills
assert_eq "1" "$(calls '\[plugin\] \[install\] \[talos@talos\]')" "AC3 --no-agent-skills: talos is still installed"
assert_eq "0" "$(calls '\[plugin\] \[update\]')" "AC3 --no-agent-skills: no plugin update call"

newcase install-fails
export CLAUDE_STUB_INSTALL_FAIL=1
inst
assert_eq "1" "$(calls '\[plugin\] \[install\] \[talos@talos\]')" "AC3 failed talos install: the install was attempted"
assert_eq "0" "$(calls '\[plugin\] \[update\]')" "AC3 failed talos install: no plugin update call"
unset CLAUDE_STUB_INSTALL_FAIL

# ── per-repo ─────────────────────────────────────────────────────────────────
# make_upstream <dir> -- a local git agent-skills fixture with two skills.
make_upstream() {
  local d="$1" s
  for s in test-driven-development code-review-and-quality; do
    mkdir -p "$d/skills/$s"
    printf -- '---\nname: %s\n---\nfixture v1\n' "$s" > "$d/skills/$s/SKILL.md"
  done
  printf 'MIT fixture licence\n' > "$d/LICENSE"
  git -C "$d" init -q
  commit_upstream "$d"
}
commit_upstream() {
  git -C "$1" add -A
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm change
}
# repo_inst <upstream> <target> -- a per-repo install. $OUT, $RC.
repo_inst() {
  OUT="$(TALOS_AGENT_SKILLS_REPO="$1" "$BASH_BIN" "$INSTALL" "$2" --no-agents-md --harness claude 2>&1)"; RC=$?
}
same_file() { if cmp -s "$1" "$2"; then pass "$3"; else fail "$3" "differs: $1 vs $2"; fi; }

TDD=test-driven-development
CRQ=code-review-and-quality
BOTH="$CRQ
$TDD"

UP="$SANDBOX/upstream"
make_upstream "$UP"
T="$SANDBOX/repo-fresh"
mkdir -p "$T"
S="$T/.claude/skills"
repo_inst "$UP" "$T"
assert_eq "0" "$RC" "AC8 a first per-repo install exits 0"
same_file "$UP/skills/$TDD/SKILL.md" "$S/$TDD/SKILL.md" "AC8 a first install vendors $TDD"
same_file "$UP/skills/$CRQ/SKILL.md" "$S/$CRQ/SKILL.md" "AC8 a first install vendors $CRQ"
same_file "$UP/LICENSE" "$S/AGENT-SKILLS-LICENSE" "AC8 a first install ships the licence"
assert_contains "$OUT" "installed: 2 new, updated: 0 skill(s) into $S/" "AC8 the summary line counts new and updated"
assert_eq "$BOTH" "$(cat "$S/.agent-skills-manifest" 2>/dev/null)" "AC8 a first install writes the sorted manifest"

printf -- '---\nname: %s\n---\nfixture v2\n' "$TDD" > "$UP/skills/$TDD/SKILL.md"
commit_upstream "$UP"
repo_inst "$UP" "$T"
assert_eq "0" "$RC" "AC4 a re-install exits 0"
same_file "$UP/skills/$TDD/SKILL.md" "$S/$TDD/SKILL.md" "AC4 a re-install overwrites the vendored skill without --force"
assert_not_contains "$OUT" "skip (exists)" "AC4 a re-install skips no vendored skill"
assert_contains "$OUT" "installed: 0 new, updated: 2 skill(s) into $S/" "AC4 the summary counts both as updated"
assert_eq "$BOTH" "$(cat "$S/.agent-skills-manifest" 2>/dev/null)" "AC4 the manifest is written"
assert_eq ".agent-skills-manifest
AGENT-SKILLS-LICENSE
$BOTH" "$(ls -A "$S" | LC_ALL=C sort)" "AC4 the re-install leaves no temp file"
assert_eq "SKILL.md" "$(ls -A "$S/$TDD")" "AC4 the re-install leaves no temp file beside the skill"

# vendored before this change: skills and licence, no manifest
L="$SANDBOX/repo-legacy"
LS="$L/.claude/skills"
mkdir -p "$LS/$TDD" "$LS/$CRQ" "$LS/my-own"
printf 'old vendored copy\n' > "$LS/$TDD/SKILL.md"
printf 'old vendored copy\n' > "$LS/$CRQ/SKILL.md"
printf 'my own skill\n' > "$LS/my-own/SKILL.md"
printf 'MIT fixture licence\n' > "$LS/AGENT-SKILLS-LICENSE"
repo_inst "$UP" "$L"
assert_eq "0" "$RC" "AC5 a legacy re-install exits 0"
same_file "$UP/skills/$TDD/SKILL.md" "$LS/$TDD/SKILL.md" "AC5 a legacy vendored $TDD is updated"
same_file "$UP/skills/$CRQ/SKILL.md" "$LS/$CRQ/SKILL.md" "AC5 a legacy vendored $CRQ is updated"
assert_eq "$BOTH" "$(cat "$LS/.agent-skills-manifest" 2>/dev/null)" "AC5 its manifest is written, upstream names only"
assert_eq "my own skill" "$(cat "$LS/my-own/SKILL.md")" "AC5 a skill upstream does not ship is left alone"

# the user's own skill, no licence beside it
O="$SANDBOX/repo-own"
OS="$O/.claude/skills"
mkdir -p "$OS/$TDD"
printf 'my own tdd, no trailing newline' > "$OS/$TDD/SKILL.md"
cp "$OS/$TDD/SKILL.md" "$SANDBOX/own.orig"
repo_inst "$UP" "$O"
assert_eq "0" "$RC" "AC6 an install beside a user's own skill exits 0"
assert_contains "$OUT" "skip (exists): $OS/$TDD/SKILL.md" "AC6 the user's own skill is skipped"
same_file "$SANDBOX/own.orig" "$OS/$TDD/SKILL.md" "AC6 the user's own skill is unchanged byte for byte"
assert_eq "$CRQ" "$(cat "$OS/.agent-skills-manifest" 2>/dev/null)" "AC6 the user's own skill is not recorded as vendored"
# The first run left a licence behind: the manifest must still protect the skill.
repo_inst "$UP" "$O"
assert_contains "$OUT" "skip (exists): $OS/$TDD/SKILL.md" "AC6 a second install still skips it"
same_file "$SANDBOX/own.orig" "$OS/$TDD/SKILL.md" "AC6 a second install leaves it unchanged byte for byte"
# Nothing vendored at all still writes a manifest, so the licence cannot claim it later.
A="$SANDBOX/repo-all-own"
mkdir -p "$A/.claude/skills/$TDD" "$A/.claude/skills/$CRQ"
cp "$SANDBOX/own.orig" "$A/.claude/skills/$TDD/SKILL.md"
cp "$SANDBOX/own.orig" "$A/.claude/skills/$CRQ/SKILL.md"
repo_inst "$UP" "$A"
repo_inst "$UP" "$A"
same_file "$SANDBOX/own.orig" "$A/.claude/skills/$TDD/SKILL.md" "AC6 with every skill the user's own, a second install overwrites none"
# A manifest name that is a symlinked directory is not written through.
mkdir -p "$SANDBOX/outside"
cp "$SANDBOX/own.orig" "$SANDBOX/outside/SKILL.md"
rm -rf "${S:?}/$CRQ"
ln -s "$SANDBOX/outside" "$S/$CRQ"
repo_inst "$UP" "$T"
same_file "$SANDBOX/own.orig" "$SANDBOX/outside/SKILL.md" "AC6 a symlinked skill directory is not written through"
assert_contains "$OUT" "skip (symlink): $S/$CRQ/SKILL.md" "AC6 the symlinked skill is named"
rm -f "${S:?}/$CRQ"
repo_inst "$UP" "$T"

# upstream drops a skill
git -C "$UP" rm -qr "skills/$CRQ"
commit_upstream "$UP"
cp "$S/$CRQ/SKILL.md" "$SANDBOX/dropped.orig"
repo_inst "$UP" "$T"
assert_eq "0" "$RC" "AC7 a dropped skill: the install exits 0"
same_file "$SANDBOX/dropped.orig" "$S/$CRQ/SKILL.md" "AC7 the dropped skill stays on disk, unchanged"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c "agent-skills: no longer upstream: $CRQ\$")" "AC7 the dropped skill is named in one line"
repo_inst "$UP" "$T"
assert_contains "$OUT" "agent-skills: no longer upstream: $CRQ" "AC7 it is still named on the next re-install"

finish
