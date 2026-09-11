#!/usr/bin/env bash
# test-setup-prompt-rules.sh -- pins the setup wizard's board-bootstrap
# prompt (skills/pipeline-setup/SKILL.md Step 8a, #266) in place: it must
# offer bootstrap-board.sh with an explicit y/n, gate on board.enabled, and
# state it never runs silently / never touches a real board without the
# answer -- a future edit that drops any of those must fail here.
#
# Same fenced-block extraction convention as test-prompt-rules.sh (which is
# scoped to skills/pipeline/SKILL.md, the orchestrator skill -- this file
# covers skills/pipeline-setup/SKILL.md, the setup wizard, instead).
set -u
. "$(dirname "$0")/helpers.sh"

SETUP_MD="$TALOS_ROOT/skills/pipeline-setup/SKILL.md"

extract_window() {  # $1=file $2=anchor substring
  local file="$1" anchor="$2" start end
  start="$(grep -n -F "$anchor" "$file" | head -1 | cut -d: -f1)"
  [ -z "$start" ] && return 1
  end="$(awk -v s="$start" 'NR > s && /^---$/ { print NR; exit }' "$file")"
  [ -z "$end" ] && end=$((start + 40))
  sed -n "${start},$((end - 1))p" "$file"
}

board_step="$(extract_window "$SETUP_MD" "## Step 8a")"

# Flatten line wraps to spaces (prose wraps at ~80 cols): a phrase can
# straddle a newline and miss a literal substring match otherwise.
board_step_flat="$(printf '%s' "$board_step" | tr '\n' ' ' | tr -s ' ')"

assert_contains "$board_step_flat" "(y/n)" \
  "setup wizard: Step 8a offers the board bootstrap with an explicit y/n"
assert_contains "$board_step_flat" "bootstrap-board.sh" \
  "setup wizard: Step 8a references bootstrap-board.sh"
assert_contains "$board_step_flat" "board.enabled" \
  "setup wizard: Step 8a is conditioned on board.enabled"
assert_contains "$board_step_flat" "Never run this silently" \
  "setup wizard: Step 8a states it never runs silently"
assert_contains "$board_step_flat" "without an explicit yes" \
  "setup wizard: Step 8a states it never runs without the user's explicit yes"

# The "if no" branch must never claim the script ran -- it only tells the
# user how to run it themselves later.
assert_contains "$board_step_flat" "If no: skip" \
  "setup wizard: Step 8a's 'no' branch skips (never runs bootstrap-board.sh unasked)"

finish
