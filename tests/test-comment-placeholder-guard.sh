#!/usr/bin/env bash
# test-comment-placeholder-guard.sh -- comment-issue / comment-pr refuse a body
# that still carries an unsubstituted templates/comments placeholder (#306).
#
# #298's validator verdict was posted with a literal `${HEADER}` first line:
# the rendering recipe used safe_substitute(), which leaves unset variables in
# place, and nothing between the render and the post noticed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── A leftover ${HEADER} is refused and nothing is posted ────────────────────
: > "$GH_LOG"
err="$(STUB_ISSUE_STATE=OPEN bash "$VCS" comment-issue 7 '${HEADER}

**Verdict:** CONFIRMED -- repro attached' 2>&1 >/dev/null)"; rc=$?
assert_eq "1" "$rc" "comment-issue: leftover \${HEADER} exits 1"
assert_contains "$err" "HEADER" "comment-issue: stderr names the leftover placeholder"
assert_not_contains "$(cat "$GH_LOG")" "issue comment" "comment-issue: nothing posted"

: > "$GH_LOG"
err="$(STUB_PR_STATE=OPEN bash "$VCS" comment-pr 9 '**Agent:** qa (talos)

**QA:** $VERDICT -- ${SUMMARY}' 2>&1 >/dev/null)"; rc=$?
assert_eq "1" "$rc" "comment-pr: leftover \$VERDICT / \${SUMMARY} exits 1"
assert_contains "$err" "SUMMARY VERDICT" "comment-pr: stderr names every leftover placeholder"
assert_not_contains "$(cat "$GH_LOG")" "pr comment" "comment-pr: nothing posted"

# The list is derived from the templates, so a project template's own
# variable counts too (comments.templates_dir).
mkdir -p templates/comments
printf '${HEADER}\n\nDeployed to ${ENVIRONMENT}\n' > templates/comments/deployed.md
: > "$GH_LOG"
STUB_ISSUE_STATE=OPEN bash "$VCS" comment-issue 7 'Deployed to ${ENVIRONMENT}' >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "comment-issue: a project template variable is guarded too"
assert_not_contains "$(cat "$GH_LOG")" "issue comment" "comment-issue: project-variable body not posted"
rm -rf templates

# ── A fully rendered body posts ──────────────────────────────────────────────
: > "$GH_LOG"
STUB_ISSUE_STATE=OPEN bash "$VCS" comment-issue 7 '**Agent:** validator (talos)

**Verdict:** CONFIRMED -- repro attached' >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "comment-issue: fully rendered body exits 0"
assert_contains "$(cat "$GH_LOG")" "issue comment 7 --body **Agent:** validator (talos)" \
  "comment-issue: fully rendered body is posted"

# ── Unrelated $ text, and placeholders quoted inside code, still post ────────
body='**Agent:** qa (talos)

**QA:** PASS -- costs $5, ${lowercase} is fine

```bash
echo "${foo}" "$PATH" "${HEADER}"
```

The old bug posted a literal `${HEADER}`.'
: > "$GH_LOG"
STUB_PR_STATE=OPEN bash "$VCS" comment-pr 9 "$body" >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "comment-pr: \${foo} / \$PATH in a code fence exits 0"
assert_contains "$(cat "$GH_LOG")" 'echo "${foo}" "$PATH"' \
  "comment-pr: code-fenced body is posted verbatim"

# ── An unclosed fence exempts nothing ────────────────────────────────────────
: > "$GH_LOG"
err="$(STUB_PR_STATE=OPEN bash "$VCS" comment-pr 9 '**Agent:** qa (talos)

```bash
echo hi

**QA:** PASS -- ${SUMMARY}' 2>&1 >/dev/null)"; rc=$?
assert_eq "1" "$rc" "comment-pr: placeholder after an unclosed fence exits 1"
assert_contains "$err" "SUMMARY" "comment-pr: unclosed fence does not hide the leftover"
assert_not_contains "$(cat "$GH_LOG")" "pr comment" "comment-pr: unclosed-fence body not posted"

# ── A long unmatched backtick run is processed in linear time (ReDoS) ────────
# (`+).+?\1 backtracked catastrophically: 16k backticks took ~35 s.
ticks="$(printf '%*s' 20000 '' | tr ' ' '`')"
body="**Agent:** qa (talos)

see ${ticks}x and \${HEADER}
${ticks}"
: > "$GH_LOG"
start="$(python3 -c 'import time; print(time.time())')"
STUB_PR_STATE=OPEN bash "$VCS" comment-pr 9 "$body" >/dev/null 2>&1; rc=$?
elapsed="$(python3 -c 'import sys, time; print("%.2f" % (time.time() - float(sys.argv[1])))' "$start")"
assert_eq "1" "$rc" "comment-pr: 20k-backtick body is still checked (leftover \${HEADER} refused)"
assert_eq "fast" "$(python3 -c 'import sys; print("fast" if float(sys.argv[1]) < 5 else "slow")' "$elapsed")" \
  "comment-pr: 20k-backtick body processed in under 5 s (took ${elapsed}s)"

# Unmatched runs of every length 1..350 (the worst case for a naive "find the
# closing run" search) plus one long run, 65,000 characters in all.
python3 -c '
body = "**Agent:** qa (talos)\n\n${HEADER} " + "x".join("`" * k for k in range(1, 351)) + "\n"
print(body + "`" * (65000 - len(body)), end="")' > "$SANDBOX/adversarial.md"
: > "$GH_LOG"
start="$(python3 -c 'import time; print(time.time())')"
err="$(STUB_PR_STATE=OPEN bash "$VCS" comment-pr 9 --body-file "$SANDBOX/adversarial.md" 2>&1 >/dev/null)"; rc=$?
elapsed="$(python3 -c 'import sys, time; print("%.2f" % (time.time() - float(sys.argv[1])))' "$start")"
assert_eq "1" "$rc" "comment-pr: 65k adversarial backtick body is still checked"
assert_contains "$err" "placeholder(s): HEADER" "comment-pr: 65k adversarial body names the leftover"
assert_eq "fast" "$(python3 -c 'import sys; print("fast" if float(sys.argv[1]) < 5 else "slow")' "$elapsed")" \
  "comment-pr: 65k adversarial backtick body guard-scanned in under 5 s (took ${elapsed}s)"

# ── A body over GitHub's 65536-character limit is refused before scanning ────
python3 -c 'print("`" * 2000000, end="")' > "$SANDBOX/huge.md"
: > "$GH_LOG"
start="$(python3 -c 'import time; print(time.time())')"
err="$(STUB_PR_STATE=OPEN bash "$VCS" comment-pr 9 --body-file "$SANDBOX/huge.md" 2>&1 >/dev/null)"; rc=$?
elapsed="$(python3 -c 'import sys, time; print("%.2f" % (time.time() - float(sys.argv[1])))' "$start")"
assert_eq "1" "$rc" "comment-pr: 2,000,000-backtick body exits 1"
assert_contains "$err" "65536" "comment-pr: stderr names the 65536-character limit"
assert_not_contains "$(cat "$GH_LOG")" "pr comment" "comment-pr: oversized body not posted"
assert_eq "fast" "$(python3 -c 'import sys; print("fast" if float(sys.argv[1]) < 5 else "slow")' "$elapsed")" \
  "comment-pr: 2,000,000-backtick body refused in under 5 s (took ${elapsed}s)"

# Just over the cap in characters (not bytes) is refused too.
python3 -c 'print("x" * 65537, end="")' > "$SANDBOX/over.md"
: > "$GH_LOG"
err="$(STUB_ISSUE_STATE=OPEN bash "$VCS" comment-issue 7 --body-file "$SANDBOX/over.md" 2>&1 >/dev/null)"; rc=$?
assert_eq "1" "$rc" "comment-issue: 65537-character body exits 1"
assert_contains "$err" "65536" "comment-issue: stderr names the limit for a just-over body"
assert_not_contains "$(cat "$GH_LOG")" "issue comment" "comment-issue: just-over body not posted"

# ── An invalid-UTF-8 body is still guard-scanned, not an error ───────────────
printf '**Agent:** qa (talos)\n\ncaf\351 ${HEADER}\n' > "$SANDBOX/latin1-body.md"
: > "$GH_LOG"
err="$(STUB_PR_STATE=OPEN bash "$VCS" comment-pr 9 --body-file "$SANDBOX/latin1-body.md" 2>&1 >/dev/null)"; rc=$?
assert_eq "1" "$rc" "comment-pr: invalid-UTF-8 body with a leftover exits 1"
assert_contains "$err" "placeholder(s): HEADER" "comment-pr: invalid-UTF-8 body is scanned, not a guard error"

# ── A non-UTF-8 template is skipped with a note, not a blocked comment ───────
mkdir -p templates/comments
printf 'caf\351 ${HEADER}\n' > templates/comments/latin1.md
: > "$GH_LOG"
err="$(STUB_ISSUE_STATE=OPEN bash "$VCS" comment-issue 7 '**Agent:** validator (talos)

**Verdict:** CONFIRMED' 2>&1 >/dev/null)"; rc=$?
assert_eq "0" "$rc" "comment-issue: a non-UTF-8 template does not block the comment"
assert_contains "$err" "latin1.md" "comment-issue: stderr names the skipped template"
assert_contains "$(cat "$GH_LOG")" "issue comment 7" "comment-issue: body posted despite the bad template"
rm -rf templates

# ── No template directory resolves: the built-in names still guard ───────────
# A scripts/ copy with no sibling templates/ and no project templates_dir;
# every variable of the shipped templates must still be refused.
mkdir -p "$SANDBOX/bare"
cp -R "$TALOS_ROOT/scripts" "$SANDBOX/bare/scripts"
for name in $(cat "$TALOS_ROOT"/templates/comments/*.md \
              | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' | tr -d '${' | sort -u); do
  : > "$GH_LOG"
  STUB_ISSUE_STATE=OPEN bash "$SANDBOX/bare/scripts/pipeline-vcs.sh" comment-issue 7 "left \${$name}" \
    >/dev/null 2>&1; rc=$?
  assert_eq "1" "$rc" "comment-issue: no template dir -- built-in \${$name} still refused"
  assert_not_contains "$(cat "$GH_LOG")" "issue comment" "comment-issue: no template dir -- \${$name} body not posted"
done
# Control: the bare copy itself works, so the refusals above are the guard's.
STUB_ISSUE_STATE=OPEN bash "$SANDBOX/bare/scripts/pipeline-vcs.sh" comment-issue 7 "all filled" \
  >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "comment-issue: no template dir -- a fully rendered body still posts"

finish
