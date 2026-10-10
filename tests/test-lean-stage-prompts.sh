#!/usr/bin/env bash
# test-lean-stage-prompts.sh -- the short rules that cut stage turns (#583).
#
# The profiles' wording is not pinned (#556); only the rule lines `talos.sh prompt`
# renders into the stage prompt are, because the prompt is the first thing a
# stage reads. Test names start with the criterion id.
#   AC1 qa: qa-run proved it, do not re-run by hand; hand-check `prose hand-checked`
#   AC2 validator: `Effort cap:` scales effort to the issue type
#   AC3 reviewer, security: `Context cap:` bounds the reads beyond the diff
#   AC4 post-approval's self-verified stamp is stated once per prompt
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

RS="$SANDBOX/restamp.txt"
printf 'approved_sha=aaaa\nhead_sha=bbbb\n' > "$RS"

QA="$(talos_prompt_text qa --issue 5 --pr 7)"
assert_contains "$QA" '`red@<sha8> green@head`' "AC1 qa prompt: the rule names the qa-run line it applies to"
assert_contains "$QA" 'do not re-run or hand-exercise it' "AC1 qa prompt: a red@/green@head criterion is neither re-run nor hand-exercised"
assert_contains "$QA" 'Exercise real behaviour for every other criterion' "AC1 qa prompt: every other criterion still gets a real-behaviour check"
assert_contains "$QA" '`green@head (red: missing)`' "AC1 qa prompt: a criterion with no red proof is still checked"
assert_contains "$QA" '`prose hand-checked`' "AC1 qa prompt: prose hand-checked lines are still checked"
assert_contains "$QA" 'did not run' "AC1 qa prompt: a criterion qa-run did not run is still checked"

VAL="$(talos_prompt_text validator --issue 5)"
effort="$(printf '%s\n' "$VAL" | grep '^Effort cap:')"
assert_contains "$effort" 'scale effort to the issue type' "AC2 validator prompt: an Effort cap: line scales effort"
assert_contains "$effort" 'feature or enhancement' "AC2 validator prompt: a feature request is named"
assert_contains "$effort" 'duplicate check' "AC2 validator prompt: a feature needs a duplicate check"
assert_contains "$effort" 'no repro hunt' "AC2 validator prompt: no repro hunt for a feature"
assert_contains "$effort" 'bug reports' "AC2 validator prompt: reproduce only for bug reports"
assert_contains "$effort" 'cited' "AC2 validator prompt: stop once the evidence is cited"

for role in reviewer security; do
  ctx="$(talos_prompt_text "$role" --issue 5 --pr 7 | grep '^Context cap:')"
  assert_contains "$ctx" 'read the whole diff once' "AC3 $role prompt: a Context cap: line reads the whole diff once"
  assert_contains "$ctx" 'page through a long one' "AC3 $role prompt: a long diff is paged through, not skipped"
  assert_contains "$ctx" 'No repo tour' "AC3 $role prompt: no repo tour"
done
assert_contains "$(talos_prompt_text reviewer --issue 5 --pr 7 | grep '^Context cap:')" 'suspected finding' "AC3 reviewer prompt: a file outside the diff only for a suspected finding"
assert_contains "$(talos_prompt_text security --issue 5 --pr 7 | grep '^Context cap:')" 'sink or caller' "AC3 security prompt: trace a changed line's input to its sink or caller"

needle='post-approval verifies its own stamp'
for role in qa reviewer security docs adversarial; do
  text="$(talos_prompt_text "$role" --issue 5 --pr 7)"
  assert_eq "1" "$(printf '%s\n' "$text" | grep -o "$needle" | wc -l | tr -d ' ')" "AC4 $role first-shape prompt: the self-verified stamp is stated once"
  assert_contains "$text" "$needle: do not re-read your comment or re-check labels" "AC4 $role first-shape prompt: the sentence ends with the do-not-re-read rule"
done
for role in qa reviewer security adversarial; do
  text="$(talos_prompt_text "$role" --issue 5 --pr 7 --shape restamp --restamp-file "$RS")"
  assert_eq "1" "$(printf '%s\n' "$text" | grep -o "$needle" | wc -l | tr -d ' ')" "AC4 $role re-stamp prompt: the self-verified stamp is stated once"
  assert_contains "$text" "$needle: do not re-read your comment or re-check labels" "AC4 $role re-stamp prompt: the sentence ends with the do-not-re-read rule"
done

finish
