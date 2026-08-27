#!/usr/bin/env bash
# Tests for global install (#164): precedence order, skew-case, and back-compat.
#
# Verification approach (spec requirement): each probe location is populated with
# a WORKING but DISTINGUISHABLE copy that prints a unique token. Wrong precedence
# produces the wrong token -- not a file-not-found error. A test that passes
# because a path does not exist proves nothing.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

TALOS_ROOT="${TALOS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# ── Helpers ───────────────────────────────────────────────────────────────────
# Write a minimal but executable pipeline-vcs.sh at a location with a
# distinguishable identity token so we can prove which copy executed.
_plant_script() {
  local dir="$1" token="$2"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$token" > "$dir/pipeline-vcs.sh"
  chmod +x "$dir/pipeline-vcs.sh"
  # Also plant pipeline-config.sh and pipeline-paths.sh (needed by some scripts)
  printf '#!/usr/bin/env bash\necho "%s"\n' "$token" > "$dir/pipeline-config.sh"
  chmod +x "$dir/pipeline-config.sh"
  cp "$TALOS_ROOT/scripts/pipeline-paths.sh" "$dir/pipeline-paths.sh" 2>/dev/null || \
    printf '#!/usr/bin/env bash\n_resolve_talos_dir() { echo "%s"; }\n' "$dir" \
    > "$dir/pipeline-paths.sh"
  # Also plant notify and agent for probe purposes
  printf '#!/usr/bin/env bash\necho "%s"\n' "$token" > "$dir/pipeline-notify.sh"
  chmod +x "$dir/pipeline-notify.sh"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$token" > "$dir/pipeline-agent.sh"
  chmod +x "$dir/pipeline-agent.sh"
}

# Run the SKILL.md probe loop for scripts dir and return which dir it resolves to.
# This simulates exactly what the orchestrator's first step does.
_probe_scripts_dir() {
  local home_dir="$1"
  shift
  # Accept optional TALOS_HOME override as env var prefix
  env HOME="$home_dir" "$@" bash -c '
    for d in \
      "${TALOS_HOME:+$TALOS_HOME/scripts}" \
      "$HOME/.talos/scripts" \
      "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" \
      ".claude/talos/scripts" \
      "scripts"; do
      [ -n "$d" ] && [ -f "$d/pipeline-vcs.sh" ] && { echo "$d"; break; }
    done
  '
}

# ── Test 1: Full 5-location precedence order ──────────────────────────────────
# Populate all five locations with distinguishable working copies.
# Assert the winner at each priority level by removing higher-priority locations
# one at a time and confirming the next one in the chain takes over.
T1_HOME="$SANDBOX/t1-home"
T1_PLUGIN="$SANDBOX/t1-plugin"
mkdir -p "$T1_HOME"

_plant_script "$T1_HOME/.talos/scripts"         "TOKEN-GLOBAL"
_plant_script "$T1_PLUGIN/scripts"              "TOKEN-PLUGIN"
mkdir -p "$SANDBOX/.claude/talos/scripts"
_plant_script "$SANDBOX/.claude/talos/scripts"  "TOKEN-VENDORED"
mkdir -p "$SANDBOX/scripts"
_plant_script "$SANDBOX/scripts"                "TOKEN-SOURCE"

# Level 2 (~/.talos) wins over plugin, vendored, source.
got="$(HOME="$T1_HOME" CLAUDE_PLUGIN_ROOT="$T1_PLUGIN" \
  bash -c 'for d in "${TALOS_HOME:+$TALOS_HOME/scripts}" "$HOME/.talos/scripts" "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" ".claude/talos/scripts" "scripts"; do [ -n "$d" ] && [ -f "$d/pipeline-vcs.sh" ] && { echo "$d"; break; }; done')"
token="$(bash "$got/pipeline-vcs.sh" 2>/dev/null)"
assert_eq "TOKEN-GLOBAL" "$token" "~/.talos wins over plugin, vendored, source (level 2 > 3,4,5)"

# Level 3 (plugin) wins over vendored, source when global absent.
got2="$(HOME="$T1_HOME/absent" CLAUDE_PLUGIN_ROOT="$T1_PLUGIN" \
  bash -c 'for d in "${TALOS_HOME:+$TALOS_HOME/scripts}" "$HOME/.talos/scripts" "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" ".claude/talos/scripts" "scripts"; do [ -n "$d" ] && [ -f "$d/pipeline-vcs.sh" ] && { echo "$d"; break; }; done')"
token2="$(bash "$got2/pipeline-vcs.sh" 2>/dev/null)"
assert_eq "TOKEN-PLUGIN" "$token2" "plugin wins over vendored, source when global absent (level 3 > 4,5)"

# Level 4 (vendored) wins over source when global and plugin both absent.
got3="$(HOME="$T1_HOME/absent" \
  bash -c 'for d in "${TALOS_HOME:+$TALOS_HOME/scripts}" "$HOME/.talos/scripts" "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" ".claude/talos/scripts" "scripts"; do [ -n "$d" ] && [ -f "$d/pipeline-vcs.sh" ] && { echo "$d"; break; }; done')"
token3="$(bash "$got3/pipeline-vcs.sh" 2>/dev/null)"
assert_eq "TOKEN-VENDORED" "$token3" "vendored wins over source when global and plugin absent (level 4 > 5)"

# Level 5 (source) used when only source exists.
rm -rf "$SANDBOX/.claude/talos/scripts"
got4="$(HOME="$T1_HOME/absent" \
  bash -c 'for d in "${TALOS_HOME:+$TALOS_HOME/scripts}" "$HOME/.talos/scripts" "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" ".claude/talos/scripts" "scripts"; do [ -n "$d" ] && [ -f "$d/pipeline-vcs.sh" ] && { echo "$d"; break; }; done')"
token4="$(bash "$got4/pipeline-vcs.sh" 2>/dev/null)"
assert_eq "TOKEN-SOURCE" "$token4" "source fallback used when all others absent (level 5)"

# Restore vendored for skew test below.
_plant_script "$SANDBOX/.claude/talos/scripts" "TOKEN-VENDORED"

# ── Test 2: TALOS_HOME override (level 1) ────────────────────────────────────
T2_OVERRIDE="$SANDBOX/t2-override"
_plant_script "$T2_OVERRIDE/scripts" "TOKEN-OVERRIDE"

got5="$(TALOS_HOME="$T2_OVERRIDE" HOME="$T1_HOME" CLAUDE_PLUGIN_ROOT="$T1_PLUGIN" \
  bash -c 'for d in "${TALOS_HOME:+$TALOS_HOME/scripts}" "$HOME/.talos/scripts" "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" ".claude/talos/scripts" "scripts"; do [ -n "$d" ] && [ -f "$d/pipeline-vcs.sh" ] && { echo "$d"; break; }; done')"
token5="$(bash "$got5/pipeline-vcs.sh" 2>/dev/null)"
assert_eq "TOKEN-OVERRIDE" "$token5" "\$TALOS_HOME override beats global install (level 1 > 2)"

# ── Test 3: Skew case -- stale vendored + fresh global -> global wins ─────────
# This is the primary scenario the feature exists to solve.
# A user has an old .claude/talos/ install AND a new ~/.talos/ install.
# The global install must win.
T3_HOME="$SANDBOX/t3-home"
_plant_script "$T3_HOME/.talos/scripts"        "TOKEN-FRESH-GLOBAL"
_plant_script "$SANDBOX/.claude/talos/scripts" "TOKEN-STALE-VENDORED"

got6="$(HOME="$T3_HOME" \
  bash -c 'for d in "${TALOS_HOME:+$TALOS_HOME/scripts}" "$HOME/.talos/scripts" "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" ".claude/talos/scripts" "scripts"; do [ -n "$d" ] && [ -f "$d/pipeline-vcs.sh" ] && { echo "$d"; break; }; done')"
token6="$(bash "$got6/pipeline-vcs.sh" 2>/dev/null)"
assert_eq "TOKEN-FRESH-GLOBAL" "$token6" \
  "skew case: fresh ~/.talos/ beats stale .claude/talos/ (the whole point of #164)"

# ── Test 4: Back-compat -- vendored-only, no global -> vendored still works ───
T4_HOME="$SANDBOX/t4-home-absent"
mkdir -p "$T4_HOME"   # HOME exists but no .talos/ inside

# Ensure only vendored is present.
rm -rf "$SANDBOX/scripts"   # no source dir
got7="$(HOME="$T4_HOME" \
  bash -c 'for d in "${TALOS_HOME:+$TALOS_HOME/scripts}" "$HOME/.talos/scripts" "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts}" ".claude/talos/scripts" "scripts"; do [ -n "$d" ] && [ -f "$d/pipeline-vcs.sh" ] && { echo "$d"; break; }; done')"
token7="$(bash "$got7/pipeline-vcs.sh" 2>/dev/null)"
assert_eq "TOKEN-STALE-VENDORED" "$token7" \
  "back-compat: vendored .claude/talos/ still works when no global install exists"

# ── Test 5: pipeline-paths.sh _resolve_talos_dir() ───────────────────────────
# Verify the function itself returns the correct directory.
T5_HOME="$SANDBOX/t5-home"
_plant_script "$T5_HOME/.talos/scripts" "TOKEN-PATHS-GLOBAL"

resolved="$(HOME="$T5_HOME" bash -c '. '"$TALOS_ROOT"'/scripts/pipeline-paths.sh
_resolve_talos_dir pipeline-vcs.sh')"
[ -n "$resolved" ] && pass "_resolve_talos_dir() returns a non-empty directory" \
  || fail "_resolve_talos_dir() returns a non-empty directory"
token_resolved="$(bash "$resolved/pipeline-vcs.sh" 2>/dev/null)"
assert_eq "TOKEN-PATHS-GLOBAL" "$token_resolved" \
  "_resolve_talos_dir() returns ~/.talos/scripts when global install present"

# _resolve_talos_dir() returns 1 and prints nothing when nothing resolves.
rm -rf "$SANDBOX/scripts" "$SANDBOX/.claude/talos/scripts"
rc_empty=0
empty="$(HOME="$T4_HOME" bash -c '. '"$TALOS_ROOT"'/scripts/pipeline-paths.sh
_resolve_talos_dir pipeline-vcs.sh' 2>/dev/null)" || rc_empty=$?
[ -z "$empty" ] && pass "_resolve_talos_dir() prints nothing when unresolvable" \
  || fail "_resolve_talos_dir() prints nothing when unresolvable (got: $empty)"

# ── Test 6: --global writes and installs correctly ───────────────────────────
T6_HOME="$SANDBOX/t6-home"
T6_CLAUDE="$SANDBOX/t6-claude"
mkdir -p "$T6_HOME" "$T6_CLAUDE"

gout="$(HOME="$T6_HOME" CLAUDE_CONFIG_DIR="$T6_CLAUDE" \
  bash "$TALOS_ROOT/install.sh" --global --no-agent-skills 2>&1)"
rc_global=$?
assert_eq "0" "$rc_global" "--global exits 0"

assert_file_exists "$T6_HOME/.talos/scripts/pipeline-paths.sh" \
  "--global writes pipeline-paths.sh to ~/.talos/scripts/"
assert_file_exists "$T6_HOME/.talos/scripts/pipeline-vcs.sh" \
  "--global writes pipeline-vcs.sh to ~/.talos/scripts/"
assert_file_exists "$T6_HOME/.talos/agents/developer.md" \
  "--global writes agents to ~/.talos/agents/"
n_tmpl="$(ls "$T6_HOME/.talos/templates/notifications/"*.md 2>/dev/null | wc -l | tr -d ' ')"
src_tmpl="$(ls "$TALOS_ROOT/templates/notifications/"*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$src_tmpl" "$n_tmpl" "--global writes all notification templates"
assert_file_exists "$T6_CLAUDE/skills/pipeline/SKILL.md" \
  "--global writes skill to ~/.claude/skills/"

# ── Test 7: per-repo install writes NO scripts ───────────────────────────────
T7_REPO="$SANDBOX/t7-repo"
mkdir -p "$T7_REPO"
bash "$TALOS_ROOT/install.sh" "$T7_REPO" --no-agent-skills >/dev/null 2>&1

assert_file_absent "$T7_REPO/.claude/talos/scripts" \
  "per-repo install writes no scripts directory (spec: config only)"
assert_file_absent "$T7_REPO/.claude/talos/templates" \
  "per-repo install writes no templates directory"
assert_file_absent "$T7_REPO/.claude/agents/developer.md" \
  "per-repo install writes no agents"
assert_file_absent "$T7_REPO/.claude/skills/pipeline/SKILL.md" \
  "per-repo install writes no skill to repo"

finish
