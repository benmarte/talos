#!/usr/bin/env bash
# README.md and docs/user-guide.md describe spend visibility, the budget guard
# and the status line (#387, sub-task 10 of epic #334). Structural checks only:
# the config rows exist with their defaults, the guide's `### Seeing token
# spend (#334)` section carries the facts the earlier sub-tasks shipped (key
# names, what "unrecorded" means, "off by default", the corrections the
# validator found), and the one stale comment in the YAML example is fixed.
# The tests only read files (the negative controls feed planted text to the
# same helpers through pipes).
#
# Every phrase check runs on whitespace-flattened text, so a claim wrapped over
# two lines cannot hide from a line-by-line grep.
set -u
. "$(dirname "$0")/helpers.sh"

README="$TALOS_ROOT/README.md"
GUIDE="$TALOS_ROOT/docs/user-guide.md"
EXAMPLE="$TALOS_ROOT/talos.pipeline.json.example"
CHANGELOG="$TALOS_ROOT/CHANGELOG.md"

flat() { tr '\n' ' ' | tr -s ' '; }

contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }  # $1=text $2=literal

check_has() {  # $1=flattened text $2=literal $3=label
  if contains "$1" "$2"; then pass "$3"; else fail "$3" "missing: $2"; fi
}

check_lacks() {  # $1=flattened text $2=literal $3=label
  if contains "$1" "$2"; then fail "$3" "present: $2"; else pass "$3"; fi
}

# The text of the guide section that starts at the given `### ` heading, read
# from stdin, up to the next `### ` or `## ` heading (`####` subsections belong to it).
guide_section() {  # $1=heading line prefix
  awk -v h="$1" '
    index($0, h) == 1 { s = 1; next }
    s && /^###? / { exit }
    s { print }
  '
}

# True when a markdown table row in the stdin text starts with the key as its
# whole first cell and carries the default in the second cell.
has_config_row() {  # $1=key $2=default cell text (without backticks)
  awk -F'|' -v k="\`$1\`" -v d="$2" '
    { c1 = $2; c2 = $3; gsub(/^ +| +$/, "", c1); gsub(/^ +| +$/, "", c2); gsub(/`/, "", c2) }
    c1 == k && index(c2, d) == 1 { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

readme_text="$(cat "$README")"
guide_text="$(cat "$GUIDE")"
section="$(printf '%s\n' "$guide_text" | guide_section '### Seeing token spend (#334)' | flat)"

# --- README -----------------------------------------------------------------
if printf '%s\n' "$guide_text" | has_config_row 'limits.tokens_per_issue' 'unset'; then
  pass "user guide config table: limits.tokens_per_issue (unset = guard off)"
else fail "user guide config table: limits.tokens_per_issue (unset = guard off)"; fi
if printf '%s\n' "$guide_text" | has_config_row 'limits.warn_at' '0.8'; then
  pass "user guide config table: limits.warn_at (0.8)"
else fail "user guide config table: limits.warn_at (0.8)"; fi
if printf '%s\n' "$guide_text" | has_config_row 'spend.comment' 'true'; then
  pass "user guide config table: spend.comment (true)"
else fail "user guide config table: spend.comment (true)"; fi

readme_flat="$(printf '%s\n' "$readme_text" | flat)"
for needle in 'upsert-pr-comment' 'pipeline-budget.sh' 'talos-status.sh' \
  'cost --issue N [--pr M] --line' '--markdown' '--summary' \
  'user-guide.md#seeing-token-spend-334)'; do
  check_has "$readme_flat" "$needle" "README mentions $needle"
done

# --- User guide: the new section ---------------------------------------------
if [ -n "$section" ]; then pass "guide has the ### Seeing token spend (#334) section"
else fail "guide has the ### Seeing token spend (#334) section"; fi

for needle in 'limits.tokens_per_issue' 'limits.warn_at' 'spend.comment' \
  'stage_start' 'upsert-pr-comment' 'pipeline-budget.sh' 'talos-status.sh' \
  '--line' '--markdown' '--summary' '--pr' 'statusLine' 'transcript_path'; do
  check_has "$section" "$needle" "guide section names $needle"
done

check_has "$section" 'off by default' "guide section: the budget guard is off by default"
check_has "$section" 'fix rounds only' "guide section: the guard runs before fix rounds only"
check_has "$section" 'user-level file under' "guide section: limits.* and spend.* may be set in the user-level file"
check_has "$section" 'each block grants one more limit' "guide section: each block grants one more limit"
check_has "$section" 'requested model' "guide section: model attribution is the requested model"
check_has "$section" 'never as 0' "guide section: unrecorded is shown, never as 0"
check_has "$section" '`tokens` field is `null` or not a finite non-negative number' "guide section: what unrecorded means"
check_has "$section" 'exits 0 on every input' "guide section: talos-status.sh exits 0 on every input"
check_has "$section" 'currently fails closed' "guide section: Enterprise Managed User logins fail closed"
check_has "$section" 'GITHUB_TOKEN' "guide section: the Actions GITHUB_TOKEN caveat"
check_has "$section" 'never replaces a' "guide section: install never replaces a statusLine that is not Talos's"
check_lacks "$section" 'statusline.yml`** is' "guide section: the statusline.yml file is gone"
check_has "$section" 'TALOS_STATUS_TIMEOUT_S' "guide section: TALOS_STATUS_TIMEOUT_S"
check_has "$section" 'TALOS_STATUS_DEBUG' "guide section: TALOS_STATUS_DEBUG"
check_lacks "$section" '--configure`, `--uninstall` are available' "guide section does not offer --configure as available"

# #456: the spend comment is public on a public repo, the run summary has its
# stage models column, and the status-line example is real output that fits the
# format.
check_has "$section" 'On a public repo the comment is public' "guide section: the spend comment says outright it is public on a public repo"
check_has "$section" '`stage models` column' "guide section: the run summary has a stage models column"
if grep -q '"stage models"' "$TALOS_ROOT/scripts/pipeline-events.sh"; then pass "pipeline-events.sh prints the stage models column the guide names"
else fail "pipeline-events.sh prints the stage models column the guide names"; fi
check_has "$section" 'talos #7 qa ●●●◐○○ 3.41M' "guide section: the status-line example is the one-line format"
check_lacks "$section" 'rev ✓' "guide section: the old segment example is gone"

guide_flat="$(printf '%s\n' "$guide_text" | flat)"
check_has "$guide_flat" '(the status line refuses it)' "guide events.path text: the status line refuses an absolute path"
check_has "$guide_flat" '| `TALOS_STATUS_DEBUG` |' "guide env table has TALOS_STATUS_DEBUG"
check_has "$guide_flat" '| `TALOS_STATUS_TIMEOUT_S` |' "guide env table has TALOS_STATUS_TIMEOUT_S"
check_has "$guide_flat" '[Seeing token spend](#seeing-token-spend-334)' "guide cost paragraph links to the new section"

# --- talos.pipeline.json.example _note: the spend comment goes on the PR -----
example_flat="$(flat < "$EXAMPLE")"
check_has "$example_flat" 'on the PR' "example: the spend comment is described as on the PR"
check_lacks "$example_flat" 'on the issue' "example: the spend comment is not described as on the issue"

# --- CHANGELOG ----------------------------------------------------------------
if awk '/^## \[Unreleased\]/{u=1;next} u && /^## /{exit} u && /#387/ {f=1} END{exit f?0:1}' "$CHANGELOG"; then
  pass "CHANGELOG [Unreleased] has a bullet for #387"
else fail "CHANGELOG [Unreleased] has a bullet for #387"; fi

# --- Negative controls --------------------------------------------------------
planted="$(printf '%s\n' '### Seeing token spend (#334)' 'The guard is on.' '### Next' 'off by default' | guide_section '### Seeing token spend (#334)' | flat)"
if contains "$planted" 'off by default'; then
  fail "negative control: guide_section stops at the next heading"
else pass "negative control: guide_section stops at the next heading"; fi
if contains "$planted" 'The guard is on.'; then
  pass "negative control: guide_section keeps the section body"
else fail "negative control: guide_section keeps the section body"; fi

planted_table='| `limits.warn_at` | `0.9` | text |
| `limits.warn_at_extra` | `0.8` | text |'
if printf '%s\n' "$planted_table" | has_config_row 'limits.warn_at' '0.8'; then
  fail "negative control: has_config_row checks the default and the whole key cell"
else pass "negative control: has_config_row checks the default and the whole key cell"; fi
if printf '%s\n' "$planted_table" | has_config_row 'limits.warn_at' '0.9'; then
  pass "negative control: has_config_row finds a real row"
else fail "negative control: has_config_row finds a real row"; fi

finish
