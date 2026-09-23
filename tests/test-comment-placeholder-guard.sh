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

finish
