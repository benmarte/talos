#!/usr/bin/env bash
# README.md and docs/user-guide.md describe the harness-neutral install (#369,
# part of #353). Structural checks only: stale phrases are gone, every
# `## Setup:` section holds an install command and a start line, the feature
# matrix has no "manual config" cell, and the per-harness facts the epic's
# sub-tasks merged are written down. The tests only read files (the negative
# controls feed planted text to the same helpers through pipes).
#
# Every phrase check runs on whitespace-flattened text: a claim wrapped over
# two lines (`GEMINI.md takes` / `precedence`) would otherwise pass a
# line-by-line grep while still being in the docs.
set -u
. "$(dirname "$0")/helpers.sh"
. "$TALOS_ROOT/scripts/pipeline-contract.sh"

README="$TALOS_ROOT/README.md"
GUIDE="$TALOS_ROOT/docs/user-guide.md"

flat() { tr '\n' ' ' | tr -s ' '; }

# The text of the `## Setup: <name>` section, read from stdin: from its heading
# to the next `## `.
setup_section() {  # $1=name after "## Setup: "
  awk -v h="## Setup: $1" '
    index($0, h) == 1 { s = 1; next }
    s && /^## / { exit }
    s { print }
  '
}

# Predicates shared by the real checks and the negative controls at the bottom:
# a control that planted text no longer trips one of these goes red.
contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }  # $1=text $2=literal

check_has() {  # $1=text $2=literal $3=label
  if contains "$1" "$2"; then pass "$3"; else fail "$3" "missing: $2"; fi
}

# True when the stale phrase is in the (already flattened) text, as written or
# with backticks removed, so a claim written as `GEMINI.md` takes precedence is
# found too. (tr, not ${var//x/}: bash 3.2 is quadratic on a file-sized string.)
stale_in() {  # $1=flattened text $2=literal phrase
  contains "$1" "$2" && return 0
  contains "$(printf '%s' "$1" | tr -d '`')" "$2"
}

# True when the (unflattened) text has a table row for the harness: the name
# is the whole first cell, or starts it ("generic or any unknown name"). A plain
# substring check is vacuous for short names: "pipeline" contains "pi".
has_row() {  # $1=text $2=harness name
  printf '%s\n' "$1" | grep -Eq "^\| $2( |\|)"
}

# True when the flattened text names the `/pipeline` command itself: not
# `/pipeline-setup`, and not the `.../skills/pipeline/SKILL.md` path.
has_pipeline_command() {  # $1=flattened text
  printf '%s' "$1" | grep -Eq '(^|[^a-z.])/pipeline([^-a-z/]|$)'
}

# The first table after `## Harness feature matrix` (the one
# test-runner-conformance.sh reads): consecutive `|` lines, stopping at the
# first line that is not part of the table.
matrix_table() {  # $1=file
  awk '
    /^## Harness feature matrix/ { s = 1; next }
    s && /^\|/ { t = 1; print; next }
    t { exit }
  ' "$1"
}

# Text of the "### Install and start, per harness" subsection.
per_harness_section() {  # $1=file
  awk '
    /^### Install and start, per harness/ { s = 1; next }
    s && /^###? / { exit }
    s { print }
  ' "$1"
}

readme_flat="$(flat < "$README")"
guide_flat="$(flat < "$GUIDE")"

# ── Stale claims are gone (both files) ──────────────────────────────────────
check_absent() {  # $1=label $2=literal phrase
  for pair in "README.md|$readme_flat" "docs/user-guide.md|$guide_flat"; do
    if stale_in "${pair#*|}" "$2"; then
      fail "${pair%%|*} has no '$1'" "unexpected: $2"
    else
      pass "${pair%%|*} has no '$1'"
    fi
  done
}
check_absent 'follow .claude/skills/pipeline/SKILL.md' 'follow .claude/skills/pipeline/SKILL.md'
check_absent 'manual config' 'manual config'
check_absent 'v1.20.3' 'v1.20.3'
check_absent 'contextFileName' 'contextFileName'
check_absent '~/.pi/settings.json' '~/.pi/settings.json'
check_absent 'GEMINI.md takes precedence' 'GEMINI.md takes precedence'
check_absent "<<'PROMPT'" "<<'PROMPT'"
check_absent '(default claude) for --harness' 'names the harness (default claude)'
check_absent 'No install.sh --harness pi needed' 'No `install.sh --harness pi`'
check_absent '"installs nothing" for vendored installs' 'install.sh` copies files and installs nothing'

# ── Each `## Setup:` section: install command and start line ────────────────
# name | --harness value
SETUP_SECTIONS=(
  "Claude Code|claude"
  "pi|pi"
  "Codex CLI|codex"
  "Gemini CLI|gemini"
  "Google Antigravity|antigravity"
  "local models|generic"
)
START_LINE='Read ~/.talos/skills/pipeline/SKILL.md and follow it'
for entry in "${SETUP_SECTIONS[@]}"; do
  name="${entry%%|*}"; harness="${entry##*|}"
  sec="$(setup_section "$name" < "$GUIDE" | flat)"
  if [ -z "$sec" ]; then fail "guide has a '## Setup: $name' section"; continue; fi
  check_has "$sec" 'install.sh' "Setup: $name holds an install command"
  check_has "$sec" "install.sh --global --harness $harness" \
    "Setup: $name uses install.sh --global --harness $harness"
  if [ "$harness" = "claude" ]; then
    if has_pipeline_command "$sec"; then pass "Setup: $name has a start line (/pipeline)"
    else fail "Setup: $name has a start line (/pipeline)" "no /pipeline command"; fi
  else
    check_has "$sec" "$START_LINE" "Setup: $name has the start line"
  fi
done

# ── README names each playbook, the new script and the contract lists ───────
for id in "${TALOS_COMMANDS[@]}"; do
  assert_contains "$readme_flat" "~/.talos/skills/$id/SKILL.md" \
    "README names ~/.talos/skills/$id/SKILL.md"
done
assert_contains "$readme_flat" 'scripts/pipeline-instructions.sh print' \
  "README Scripts reference lists pipeline-instructions.sh"
assert_contains "$readme_flat" 'TALOS_RUNNERS' "README Contract names TALOS_RUNNERS"
assert_contains "$readme_flat" 'TALOS_COMMANDS' "README Contract names TALOS_COMMANDS"
assert_contains "$readme_flat" 'agents.runner: custom' "README has the any-other-agent paragraph (custom runner)"
assert_contains "$readme_flat" 'Install and start, per harness' "README points at the per-harness table"

# ── The two axes, said explicitly ───────────────────────────────────────────
for pair in "README.md|$readme_flat" "docs/user-guide.md|$guide_flat"; do
  f="${pair%%|*}"; t="${pair#*|}"
  assert_contains "$t" '`--harness` selects installer glue' "$f: --harness selects installer glue"
  assert_contains "$t" '`agents.runner` selects the CLI that runs stages' "$f: agents.runner selects the CLI"
  assert_contains "$t" '`runner_cmd`' "$f: unknown harness uses runner_cmd"
done

# ── The feature matrix ──────────────────────────────────────────────────────
matrix="$(matrix_table "$GUIDE")"
matrix_flat="$(printf '%s' "$matrix" | flat)"
assert_contains "$matrix" '| Feature | Claude Code | pi | Codex CLI | Gemini CLI | Antigravity | Custom/local |' \
  "matrix header cells unchanged"
assert_not_contains "$matrix_flat" 'manual config' "matrix has no manual config cell"
assert_not_contains "$matrix_flat" 'v1.20.3' "matrix has no v1.20.3"
wizard_row="$(printf '%s\n' "$matrix" | grep -F 'Interactive setup wizard' | flat)"
assert_contains "$wizard_row" '/talos:setup' "wizard row names Claude Code's /talos:setup"
assert_contains "$wizard_row" '~/.talos/skills/setup/SKILL.md' "wizard row says how the other harnesses start it"
agents_row="$(printf '%s\n' "$matrix" | grep -F 'Native AGENTS.md orchestration' | flat)"
assert_contains "$agents_row" '@AGENTS.md' "AGENTS.md row: Claude Code needs an @AGENTS.md import or no CLAUDE.md"
assert_contains "$agents_row" 'context.fileName' "AGENTS.md row: Gemini CLI uses context.fileName or an import"

# ── The per-harness subsection of the guide ─────────────────────────────────
per_raw="$(per_harness_section "$GUIDE")"
per="$(printf '%s' "$per_raw" | flat)"
if [ -z "$per" ]; then
  fail "guide has a '### Install and start, per harness' subsection"
else
  pass "guide has a '### Install and start, per harness' subsection"
  for h in 'Claude Code' 'Codex CLI' 'Gemini CLI' 'Antigravity' 'pi' 'Cursor' 'OpenCode' 'generic'; do
    if has_row "$per_raw" "$h"; then pass "per-harness table has a row for $h"
    else fail "per-harness table has a row for $h"; fi
  done
  assert_contains "$per" 'VERIFIED' "per-harness section lists verified facts"
  assert_contains "$per" 'UNVERIFIED' "per-harness section lists unverified facts"
  assert_contains "$per" 'TALOS_AGENTS_HOME' "per-harness section documents TALOS_AGENTS_HOME"
  assert_contains "$per" 'never overwritten' "per-harness section says existing skills are never overwritten"
  assert_contains "$per" 'confined to the workspace' "per-harness section says Gemini's file tools are workspace-confined"
  assert_contains "$per" 'conformance test covers `pi -p` only' "per-harness section: conformance covers pi -p only"
  assert_contains "$per" 'inline mode is not covered' "per-harness section: pi inline mode is not covered"
  # Claude Code reading ~/.agents/skills is unverified: never stated as fact.
  assert_contains "$per" 'whether Claude Code reads `~/.agents/skills`' "per-harness section marks Claude Code reading ~/.agents/skills as unverified"
fi
# (The sentence "whether Claude Code reads ..." is the unverified list item, not a claim.)
guide_claims="$(printf '%s' "$guide_flat" | sed 's/whether Claude Code reads//g')"
assert_not_contains "$guide_claims" 'Claude Code reads ~/.agents/skills' "guide never claims Claude Code reads ~/.agents/skills"
assert_not_contains "$guide_claims" 'Claude Code reads `~/.agents/skills`' "guide never claims Claude Code reads ~/.agents/skills (code span)"

# ── Antigravity and pi text ─────────────────────────────────────────────────
ag="$(setup_section 'Google Antigravity' < "$GUIDE" | flat)"
assert_contains "$ag" 'both read' "Antigravity: AGENTS.md and GEMINI.md are both read"
assert_contains "$ag" 'cumulative' "Antigravity: cumulative"
ag_readme="$(awk '/^\*\*Google Antigravity:\*\*/ {s=1} s && /^\*\*Local models:\*\*/ {exit} s' "$README" | flat)"
assert_contains "$ag_readme" 'cumulative' "README Antigravity paragraph says cumulative"
pi_sec="$(setup_section 'pi' < "$GUIDE" | flat)"
assert_contains "$pi_sec" '~/.agents/skills' "Setup: pi relies on the pointer skills in ~/.agents/skills"

# ── Detection rule, override, writes ────────────────────────────────────────
for pair in "README.md|$readme_flat" "docs/user-guide.md|$guide_flat"; do
  f="${pair%%|*}"; t="${pair#*|}"
  assert_contains "$t" 'CLAUDE_CONFIG_DIR' "$f documents the Claude detection rule"
  assert_contains "$t" '--harness claude' "$f documents the --harness claude override"
  assert_contains "$t" '--no-agents-md' "$f documents --no-agents-md"
  assert_contains "$t" '--import-agents-md' "$f documents --import-agents-md"
  assert_contains "$t" 'assert-sync' "$f says AGENTS.md must be committed (assert-sync)"
done
assert_contains "$guide_flat" 'never writes the block into `CLAUDE.md`' "guide: the block is never written into CLAUDE.md"
assert_contains "$guide_flat" '--resolve-profile' "guide documents --resolve-profile"
assert_contains "$guide_flat" '.agents/talos/agents/<role>.md' "guide documents the neutral role override path"
assert_contains "$guide_flat" '~/.talos/skills/resume/SKILL.md' "guide points other agents at ~/.talos/skills/resume/SKILL.md"
assert_contains "$guide_flat" 'skills/resume/SKILL.md' "guide keeps the skills/resume/SKILL.md substring (test-setup-status-file.sh)"
assert_contains "$readme_flat" '~/.talos/skills/resume/SKILL.md' "README points other agents at ~/.talos/skills/resume/SKILL.md"
assert_contains "$readme_flat" 'TALOS_<rand>' "README adapter example points at the TALOS_<rand> heredoc form"

# ── Negative controls: the helpers above go red on planted text ─────────────
# Each runs the same function the real checks use. Break the function and the
# control fails with it.
planted="$(printf 'Run it: follow .claude/skills/pipeline/SKILL.md\nThe `GEMINI.md` takes\nprecedence in Antigravity\n' | flat)"
if stale_in "$planted" 'follow .claude/skills/pipeline/SKILL.md'; then
  pass "negative control: stale_in finds a planted stale start line"
else fail "negative control: stale_in finds a planted stale start line"; fi
if stale_in "$planted" 'GEMINI.md takes precedence'; then
  pass "negative control: stale_in finds a wrapped, backticked precedence claim"
else fail "negative control: stale_in finds a wrapped, backticked precedence claim"; fi
if stale_in "$planted" 'v1.20.3'; then
  fail "negative control: stale_in stays quiet on text without the phrase"
else pass "negative control: stale_in stays quiet on text without the phrase"; fi

planted_sec="$(printf '## Setup: x\nno install here\n## Setup: y\ninstall.sh\n' | setup_section x | flat)"
if contains "$planted_sec" 'install.sh'; then
  fail "negative control: setup_section stops at the next section" "leaked: $planted_sec"
else pass "negative control: setup_section stops at the next section"; fi

planted_table="$(printf '| Harness | x |\n|---|---|\n| Claude Code | a |\n| pipeline note | b |\n')"
if has_row "$planted_table" 'pi'; then
  fail "negative control: has_row does not match pi inside pipeline"
else pass "negative control: has_row does not match pi inside pipeline"; fi
if has_row "$planted_table" 'Claude Code'; then
  pass "negative control: has_row finds a real row"
else fail "negative control: has_row finds a real row"; fi

if has_pipeline_command 'run ~/.talos/skills/pipeline/SKILL.md or /pipeline-setup'; then
  fail "negative control: has_pipeline_command ignores the playbook path and /pipeline-setup"
else pass "negative control: has_pipeline_command ignores the playbook path and /pipeline-setup"; fi
if has_pipeline_command 'then run `/pipeline`.'; then
  pass "negative control: has_pipeline_command finds /pipeline"
else fail "negative control: has_pipeline_command finds /pipeline"; fi

finish
