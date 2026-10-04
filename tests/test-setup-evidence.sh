#!/usr/bin/env bash
# test-setup-evidence.sh -- the /pipeline-setup evidence capture step (#411,
# part of epic #352). Grep-based like test-setup-status-file.sh, plus sandbox
# runs: the fenced detection, `.gitignore` and `gh` capability commands are
# extracted from the skill and executed, so the test runs the text the wizard
# actually shows.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

SETUP="${SETUP_FILE:-$TALOS_ROOT/skills/pipeline-setup/SKILL.md}"
CHANGELOG="$TALOS_ROOT/CHANGELOG.md"
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }
SN="$(flat "$SETUP")"

# One step of the skill, by heading prefix, flattened. Ends at the next `---` rule.
step() {
  awk -v a="$1" 'index($0, a) == 1 {on=1} on && /^---$/ {exit} on' "$SETUP" | tr '\n' ' ' | tr -s ' '
}

# The fenced bash block that contains a phrase, verbatim (one block, or empty).
fence() {
  awk -v p="$1" '/^```bash$/{buf=""; inb=1; next} /^```$/{ if (inb && index(buf, p)) printf "%s", buf; inb=0; buf=""; next} inb{buf = buf $0 "\n"}' "$SETUP"
}

# ── Placement: Step 4c sits after 4b and before Step 5 ───────────────────────
b_line="$(grep -n '^## Step 4b' "$SETUP" | head -1 | cut -d: -f1)"
c_line="$(grep -n '^## Step 4c' "$SETUP" | head -1 | cut -d: -f1)"
five_line="$(grep -n '^## Step 5 ' "$SETUP" | head -1 | cut -d: -f1)"
assert_eq "1" "$([ -n "$c_line" ] && [ -n "$b_line" ] && [ "$c_line" -gt "$b_line" ] && [ "$c_line" -lt "$five_line" ] && echo 1 || echo 0)" "the evidence question sits after Step 4b and before Step 5 (Step 4c)"
Q="$(step '## Step 4c')"
assert_contains "$Q" "evidence capture" "Step 4c is the evidence capture question"

# ── Provider skip: one line for gitlab, azure and file, nothing written ──────
assert_contains "$Q" 'When `vcs.provider` is `gitlab`, `azure` or `file`, skip this question with one line' "Step 4c is skipped with one line for gitlab, azure and file"
assert_contains "$Q" "writes no evidence: block" "the provider skip writes no evidence: block"

# ── Costs named in the question; no evidence-branch wording (owner decision) ─
assert_contains "$Q" "public on public repos" "the question says attachments are public on public repos"
assert_contains "$Q" "on-screen secrets" "the question warns about on-screen secrets"
assert_contains "$Q" "10 MB" "the question names the GitHub attachment size limits (10 MB images)"
assert_contains "$Q" "100 MB videos on paid plans" "the question names the 100 MB paid-plan video limit"
assert_contains "$Q" "not verified" "the question says .webm acceptance by gh --attach is not verified"
assert_contains "$Q" ".webm" "the question names .webm"
assert_contains "$Q" "images and videos only" "the question says images and videos only"
assert_not_contains "$SN" "branches-ignore" "no branches-ignore CI advice (gh --attach only)"
assert_not_contains "$SN" "evidence.branch" "no evidence-branch wording (gh --attach only)"
assert_not_contains "$SN" "files over 100 MB" "the obsolete push limit is gone"

# ── Capability check: gh must list --attach, else say so and offer only off ──
assert_contains "$Q" "gh 2.99.0 or newer" "the newer-gh message names gh 2.99.0"
assert_contains "$Q" 'offer only "off"' "without --attach only off is offered"
assert_contains "$Q" "the machine running the pipeline needs the same" "the check covers the machine running setup, and the pipeline's needs the same"

# ── Detection and proposals, same signals as agents/developer.md ─────────────
assert_contains "$Q" "npx playwright test --grep @evidence" "the Playwright proposal command"
assert_contains "$Q" "dir: test-results" "the Playwright proposal dir"
assert_contains "$Q" "screenshot: 'on', video: 'on'" "the Playwright note about screenshot/video on"
assert_contains "$Q" "@evidence" "the Playwright note about tagging tests @evidence"
assert_contains "$Q" "dir: cypress/evidence" "the Cypress proposal dir"
assert_contains "$Q" "screenshotsFolder" "the Cypress note names screenshotsFolder"
assert_contains "$Q" "videosFolder" "the Cypress note names videosFolder"
assert_contains "$Q" "npx cypress run" "the Cypress command is an editable suggestion"
assert_contains "$Q" "agent capture" "neither framework: agent capture is offered"
assert_contains "$Q" "setup never runs it" "a typed command goes to config text only"
assert_contains "$Q" "Both" "both frameworks present: ask which"

# detection fixtures: the fenced command, run at a repo root
DET="$SANDBOX/detect.sh"
fence "playwright.config" > "$DET"
assert_eq "1" "$([ -s "$DET" ] && echo 1 || echo 0)" "the skill has a fenced detection block"
detect_in() {  # $1 = fixture dir
  ( cd "$1" && bash "$DET" 2>&1 )
}
mkrepo() {  # $1 = path; a sandbox repo, no remote
  mkdir -p "$1" && ( cd "$1" && git init -q -b main && git config user.email t@example.com && git config user.name t )
}
mkrepo "$SANDBOX/pw";   : > "$SANDBOX/pw/playwright.config.ts"
mkrepo "$SANDBOX/cy";   : > "$SANDBOX/cy/cypress.config.js"
mkrepo "$SANDBOX/both"; : > "$SANDBOX/both/playwright.config.js"; : > "$SANDBOX/both/cypress.config.ts"
mkrepo "$SANDBOX/none"
mkrepo "$SANDBOX/e2edir"; mkdir -p "$SANDBOX/e2edir/tests/e2e"
mkrepo "$SANDBOX/e2escript"; printf '{"scripts":{"test:e2e":"x"}}\n' > "$SANDBOX/e2escript/package.json"
assert_contains "$(detect_in "$SANDBOX/pw")"   "playwright=yes cypress=no" "playwright.config.ts fixture yields the Playwright signal"
assert_contains "$(detect_in "$SANDBOX/cy")"   "playwright=no cypress=yes" "cypress.config.js fixture yields the Cypress signal"
assert_contains "$(detect_in "$SANDBOX/both")" "playwright=yes cypress=yes" "both config files yield both signals"
assert_contains "$(detect_in "$SANDBOX/none")" "playwright=no cypress=no" "no harness yields neither signal (agent capture / off)"
assert_contains "$(detect_in "$SANDBOX/e2edir")"    "playwright=no cypress=no e2e=yes" "a tests/e2e dir alone is neither framework"
assert_contains "$(detect_in "$SANDBOX/e2escript")" "playwright=no cypress=no e2e=yes" "a test:e2e script alone is neither framework"
assert_contains "$(detect_in "$SANDBOX/none")" "e2e=no" "no e2e signal when none is present"

# ── gh capability check: a stub gh on PATH, with and without --attach ────────
CAP="$SANDBOX/cap.sh"
fence "pr comment --help" > "$CAP"
assert_eq "1" "$([ -s "$CAP" ] && echo 1 || echo 0)" "the skill has a fenced gh capability check"
assert_eq "1" "$(grep -c . "$CAP")" "the capability check is one command"
mkdir -p "$SANDBOX/gh-new" "$SANDBOX/gh-old" "$SANDBOX/gh-none"
printf '#!/bin/sh\necho "Usage: gh pr comment [flags]"\necho "      --attach strings   Attach a file"\n' > "$SANDBOX/gh-new/gh"
printf '#!/bin/sh\necho "Usage: gh pr comment [flags]"\necho "  -b, --body string   The comment body text"\n' > "$SANDBOX/gh-old/gh"
chmod +x "$SANDBOX/gh-new/gh" "$SANDBOX/gh-old/gh"
BASH_BIN="$(command -v bash)"
PATH_NEW="$SANDBOX/gh-new:/usr/bin:/bin"
PATH_OLD="$SANDBOX/gh-old:/usr/bin:/bin"
# no gh anywhere on PATH (a CI runner has one in /usr/bin): only grep is linked in
ln -s "$(command -v grep)" "$SANDBOX/gh-none/grep"
PATH_NONE="$SANDBOX/gh-none"
PATH="$PATH_NEW" "$BASH_BIN" "$CAP" >/dev/null 2>&1; assert_eq "0" "$?" "gh whose help lists --attach passes the check"
PATH="$PATH_OLD" "$BASH_BIN" "$CAP" >/dev/null 2>&1; assert_eq "1" "$?" "gh whose help lacks --attach fails the check"
PATH="$PATH_NONE" "$BASH_BIN" "$CAP" >/dev/null 2>&1; assert_eq "1" "$?" "a missing gh fails the check"

# ── .gitignore edit: only after an explicit yes, only when the probe fails ───
assert_contains "$Q" "explicit yes" "the .gitignore edit waits for an explicit yes"
assert_contains "$Q" 'git check-ignore -q' "the .gitignore edit is gated on git check-ignore -q"
assert_contains "$Q" '.probe' "the probe is a path inside the directory (a missing directory reads as unignored)"
assert_contains "$Q" "appends one line" "one line is appended"
GI="$SANDBOX/gi.sh"
fence "check-ignore" > "$GI"
assert_eq "1" "$([ -s "$GI" ] && echo 1 || echo 0)" "the skill has a fenced .gitignore block"
assert_contains "$(cat "$GI")" "<dir>" "the .gitignore block takes the directory as <dir>"

# Run the fenced block with <dir> replaced by $2, at repo $1.
run_gi() {
  local repo="$1" value="$2" mode="${3:-write}" txt
  txt="$(cat "$GI")"
  txt="${txt//<rand>/k3v9xq7mzp2w}"
  txt="${txt//<mode>/$mode}"
  printf '%s\n' "${txt//<dir>/$value}" > "$SANDBOX/gi-run.sh"
  ( cd "$repo" && bash "$SANDBOX/gi-run.sh" 2>&1 )
}

mkrepo "$SANDBOX/gi1"
out="$(run_gi "$SANDBOX/gi1" "test-results")"
assert_eq "test-results/" "$(cat "$SANDBOX/gi1/.gitignore")" "a clean repo gets exactly one line: test-results/"
assert_contains "$out" "added" "the block reports what it added"
out="$(run_gi "$SANDBOX/gi1" "test-results")"
assert_eq "1" "$(grep -c . "$SANDBOX/gi1/.gitignore")" "a second run is a no-op (still one line)"
assert_contains "$out" "already ignored" "the second run says it is already ignored"

mkrepo "$SANDBOX/gi2"; printf '/test-results/\n' > "$SANDBOX/gi2/.gitignore"
run_gi "$SANDBOX/gi2" "test-results" >/dev/null
assert_eq "/test-results/" "$(cat "$SANDBOX/gi2/.gitignore")" "a directory already ignored (non-existent, via /dir/) is left alone"

mkrepo "$SANDBOX/gi3"; printf 'node_modules' > "$SANDBOX/gi3/.gitignore"
run_gi "$SANDBOX/gi3" "cypress/evidence" >/dev/null
assert_eq "node_modules
cypress/evidence/" "$(cat "$SANDBOX/gi3/.gitignore")" "a .gitignore with no final newline keeps its line and gains one"

mkrepo "$SANDBOX/gi4"
out="$(run_gi "$SANDBOX/gi4" "./cypress//evidence/")"
assert_eq "cypress/evidence/" "$(cat "$SANDBOX/gi4/.gitignore" 2>/dev/null)" "the line is normalised: ./ stripped, // collapsed, one trailing /"

mkrepo "$SANDBOX/gi5"; mkdir -p "$SANDBOX/gi5/sub"
run_gi "$SANDBOX/gi5/sub" "ev" >/dev/null
assert_eq "ev/" "$(cat "$SANDBOX/gi5/.gitignore" 2>/dev/null)" "run from a subdirectory, the line goes into the repo-root .gitignore"
assert_file_absent "$SANDBOX/gi5/sub/.gitignore" "no .gitignore is written in the subdirectory"

mkrepo "$SANDBOX/gi6"; mkdir -p "$SANDBOX/gi6/out"; : > "$SANDBOX/gi6/out/a.png"
( cd "$SANDBOX/gi6" && git add out/a.png )
out="$(run_gi "$SANDBOX/gi6" "out")"
assert_contains "$out" "tracked" "a tracked directory is warned about"

# a symlinked .gitignore (committed by the repo) is never followed
mkrepo "$SANDBOX/gi7"
printf 'KEEP\n' > "$SANDBOX/gi7-target"
ln -s "$SANDBOX/gi7-target" "$SANDBOX/gi7/.gitignore"
out="$(run_gi "$SANDBOX/gi7" "test-results")"
assert_contains "$out" "rejected:" "a symlinked .gitignore is refused"
assert_contains "$out" "by hand" "the refusal tells the operator to add the line by hand"
assert_eq "KEEP" "$(cat "$SANDBOX/gi7-target")" "the symlink target stays byte-identical"
assert_eq "1" "$([ -L "$SANDBOX/gi7/.gitignore" ] && echo 1 || echo 0)" "the symlink is left in place"
# a dangling symlink too
mkrepo "$SANDBOX/gi8"
ln -s "$SANDBOX/gi8-missing" "$SANDBOX/gi8/.gitignore"
out="$(run_gi "$SANDBOX/gi8" "test-results")"
assert_contains "$out" "rejected:" "a dangling symlinked .gitignore is refused"
assert_file_absent "$SANDBOX/gi8-missing" "nothing is created through a dangling symlink"
# a directory named .gitignore is not a regular file
mkrepo "$SANDBOX/gi9"; mkdir "$SANDBOX/gi9/.gitignore"
out="$(run_gi "$SANDBOX/gi9" "test-results")"
assert_contains "$out" "rejected:" "a .gitignore that is not a regular file is refused"
# a regular file still works, and a missing one is created as a regular file
mkrepo "$SANDBOX/gi10"; printf 'dist/\n' > "$SANDBOX/gi10/.gitignore"
run_gi "$SANDBOX/gi10" "test-results" >/dev/null
assert_eq "dist/
test-results/" "$(cat "$SANDBOX/gi10/.gitignore")" "a regular .gitignore still gets the line appended"
assert_eq "1" "$([ -f "$SANDBOX/gi1/.gitignore" ] && [ ! -L "$SANDBOX/gi1/.gitignore" ] && echo 1 || echo 0)" "a missing .gitignore is created as a regular file"

# check mode (the user said no to the .gitignore edit): nothing written, dir= printed
mkrepo "$SANDBOX/gi11"
out="$(run_gi "$SANDBOX/gi11" "./cypress//evidence/" check)"
assert_contains "$out" "dir=cypress/evidence" "check mode prints the normalised dir"
assert_file_absent "$SANDBOX/gi11/.gitignore" "check mode never writes .gitignore"

# the config value is the same normalised dir the .gitignore line uses (round trip)
mkrepo "$SANDBOX/rt"
out="$(run_gi "$SANDBOX/rt" "./cypress//evidence/")"
norm="$(printf '%s\n' "$out" | sed -n 's/^dir=//p')"
printf 'evidence:\n  enabled: true\n  dir: %s\n' "$norm" > "$SANDBOX/rt-config.yml"
got="$(cd "$SANDBOX/rt" && PIPELINE_CONFIG="$SANDBOX/rt-config.yml" bash "$TALOS_ROOT/scripts/pipeline-config.sh" evidence.dir unset 2>&1)"
assert_eq "cypress/evidence" "$got" "the written evidence.dir round-trips through pipeline-config.sh"
assert_eq "$got/" "$(cat "$SANDBOX/rt/.gitignore")" "and it matches the .gitignore line (plus the trailing /)"

# bad directories: rejected, nothing written
for bad in ".." "../x" "a/../b" "a b" "a;b" ".git" "a/.git/b" ".GIT" "/abs" "-x" "." "./" 'a$b'; do
  rm -rf "${SANDBOX:?}/bad"
  mkrepo "$SANDBOX/bad"
  out="$(run_gi "$SANDBOX/bad" "$bad")"
  assert_contains "$out" "rejected:" "the block says it rejected [$bad]"
  assert_file_absent "$SANDBOX/bad/.gitignore" "rejected, nothing written: [$bad]"
done
mkrepo "$SANDBOX/bad2"; : > "$SANDBOX/bad2/ev"
out="$(run_gi "$SANDBOX/bad2" "a;touch PWNED")"
assert_file_absent "$SANDBOX/bad2/PWNED" "a shell-metacharacter directory never reaches a command"

# ── Step 0 re-run path: asks once when evidence.enabled is unset ─────────────
Z="$(step '## Step 0')"
assert_contains "$Z" "--has evidence.enabled" "Step 0 asks whether evidence.enabled is set with --has (no sentinel default)"
assert_contains "$Z" "Step 4c" "Step 0's re-run path offers the evidence question"
assert_contains "$Z" 'ONLY the `evidence:` block' "the re-run path adds only the evidence: block"
assert_contains "$Z" "Idempotency rules" "the evidence re-run bullet defers to the Idempotency rules"
Z_ev_line="$(grep -n -e "--has evidence.enabled" "$SETUP" | head -1 | cut -d: -f1)"
Z_7c_line="$(grep -n 'run Step 7c with the harness' "$SETUP" | head -1 | cut -d: -f1)"
assert_eq "1" "$([ -n "$Z_ev_line" ] && [ -n "$Z_7c_line" ] && [ "$Z_ev_line" -lt "$Z_7c_line" ] && echo 1 || echo 0)" "the evidence bullet comes before the Step 7c / Step 8 jump"
assert_contains "$Z" "Step 8" "Step 0 still jumps to Step 8"

# ── Step 7: the evidence: block, decline writes an ACTIVE enabled: false ─────
T="$(step '## Step 7 ')"
assert_contains "$T" "# ── Evidence (Step 4c)" "Step 7 template has an Evidence block"
assert_contains "$T" "evidence:" "Step 7 template has an evidence: block"
assert_contains "$T" "- Evidence (Step 4c):" "Step 7 has an Evidence bullet"
assert_contains "$T" "enabled: false" "a declined question writes enabled: false"
assert_contains "$T" "a commented block reads as unset" "the skill says why a commented block is not used"
assert_contains "$T" '"evidence": { "enabled": false }' "a declined JSON config gets an active evidence key"
assert_contains "$T" 'the normalised `dir=` value Step 4c printed, never the typed text' "Step 7 writes the same normalised dir the .gitignore line uses"
assert_contains "$T" "Ask me later" "an ask-me-later choice is handled"
assert_contains "$T" "store" "the store key is mentioned"
assert_contains "$T" "attach" "store is attach only"

# ── Idempotency, summary, changelog ──────────────────────────────────────────
assert_contains "$(step '## Idempotency rules')" "evidence:" "Idempotency: the evidence re-run is covered"
assert_contains "$(step '## Step 11')" "Evidence:" "the summary has an Evidence line"
assert_contains "$(flat "$CHANGELOG")" "(#411" "CHANGELOG has an entry for #411"

finish
