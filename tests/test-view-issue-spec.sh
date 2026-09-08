#!/usr/bin/env bash
# Unit tests for `view-issue --spec` and `diff-pr --stat` (issue #201, compact
# stage handoff). RED on unpatched pipeline-vcs.sh: `--spec` returns the full
# comment set (or errors) and `--stat` is not recognized.
#
# Fixture thread (used across both providers): a PM spec comment, a validator
# verdict comment (starts "**Agent:** validator (talos)"), an approval marker
# comment (`<!-- talos:approval ... -->`), an attempt marker comment
# (`<!-- talos:attempt ... -->`), and a plain human reply with no special
# prefix. `--spec` must keep only the PM spec comment.
#
# Design decision documented here (not just in code comments): a plain human
# comment is EXCLUDED from `--spec` output, even though it is not a marker or
# a verdict. The PM spec comment is the contract each stage implements
# against; a bystander comment is not part of that contract, and folding it
# in would reopen the same "agents re-ingest the whole thread" problem this
# issue exists to close. Anyone who needs the human comment reads the full
# thread via `view-issue` (no `--spec`) or `read-comments`.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

PM_SPEC_BODY='**PM spec:**
- **Goal** compact stage handoff
- **Acceptance criteria**
  - [ ] view-issue --spec filters markers and verdicts'
VALIDATOR_BODY='**Agent:** validator (talos)

**Verdict:** CONFIRMED — reproducible, in scope'
APPROVAL_MARKER_BODY='QA PASS — all criteria verified
<!-- talos:approval sha=abc123def456abc123def456abc123def456abc role=qa -->'
ATTEMPT_MARKER_BODY='Talos attempt record — stage=developer count=1 total=3
<!-- talos:attempt stage=developer count=1 total=3 -->'
HUMAN_BODY='Thanks for looking into this, any update on timing?'

# Built via a quoted heredoc (reading bodies from env), not `python3 -c
# "...{...}..."`: bash 3.2 (macOS's default /bin/bash) mis-expands a `{...}`
# dict/list literal embedded in a nested, multi-line `$(python3 -c "...")`
# argument (brace-expanding it into multiple words even though it is fully
# double-quoted) -- a quoted heredoc body is never subject to brace
# expansion, sidestepping the bug.
FIXTURE_COMMENTS_JSON="$(
  PM_SPEC_BODY="$PM_SPEC_BODY" VALIDATOR_BODY="$VALIDATOR_BODY" \
  APPROVAL_MARKER_BODY="$APPROVAL_MARKER_BODY" ATTEMPT_MARKER_BODY="$ATTEMPT_MARKER_BODY" \
  HUMAN_BODY="$HUMAN_BODY" python3 <<'PYEOF'
import json, os
bodies = [
    os.environ['PM_SPEC_BODY'],
    os.environ['VALIDATOR_BODY'],       # **Agent:** verdict
    os.environ['APPROVAL_MARKER_BODY'],
    os.environ['ATTEMPT_MARKER_BODY'],
    os.environ['HUMAN_BODY'],
]
print(json.dumps([{'id': i, 'user': {'login': 'x'},
                    'created_at': '2026-01-0%dT00:00:00Z' % (i + 1),
                    'body': b} for i, b in enumerate(bodies)]))
PYEOF
)"

# ── github provider ───────────────────────────────────────────────────────────

export STUB_ISSUE_TITLE="compact stage handoff"
export STUB_ISSUE_BODY="## The problem
Threads grow with every stage."
export STUB_GH_COMMENTS_RAW="$FIXTURE_COMMENTS_JSON"

out="$(bash "$VCS" view-issue 201 --spec)"; rc=$?
assert_exit_code "0" "$rc" "github: view-issue --spec exits 0"
assert_contains "$out" "compact stage handoff" "github: view-issue --spec keeps the title"
assert_contains "$out" "Threads grow with every stage" "github: view-issue --spec keeps the body"
assert_contains "$out" "PM spec" "github: view-issue --spec keeps the latest PM spec comment"
assert_not_contains "$out" "validator (talos)" "github: view-issue --spec excludes the **Agent:** verdict comment"
assert_not_contains "$out" "talos:approval" "github: view-issue --spec excludes the approval marker comment"
assert_not_contains "$out" "talos:attempt" "github: view-issue --spec excludes the attempt marker comment"
assert_not_contains "$out" "any update on timing" \
  "github: view-issue --spec excludes a plain human comment (design decision: the spec is the contract, not the thread)"

count="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['comments']))")"
assert_eq "1" "$count" "github: view-issue --spec keeps exactly one comment"

# Same top-level keys as the non-`--spec` shape.
keys="$(printf '%s' "$out" | python3 -c "import json,sys; print(sorted(json.load(sys.stdin).keys()))")"
assert_eq "['body', 'comments', 'labels', 'title']" "$keys" \
  "github: view-issue --spec keeps the same top-level keys as plain view-issue"

# No PM spec comment at all (issue body IS the spec, PM skipped) -> empty comments, no error.
export STUB_GH_COMMENTS_RAW="[{\"id\":1,\"user\":{\"login\":\"x\"},\"created_at\":\"2026-01-01T00:00:00Z\",\"body\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$VALIDATOR_BODY")}]"
out="$(bash "$VCS" view-issue 201 --spec)"; rc=$?
assert_exit_code "0" "$rc" "github: view-issue --spec exits 0 with no PM spec comment present"
count="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['comments']))")"
assert_eq "0" "$count" "github: view-issue --spec returns zero comments when no PM spec comment exists"

# Two PM spec comments (a re-run) -> keep only the LATEST one.
# Assign the python3 output to a plain variable first, then `export` it as a
# separate step: `export VAR="$(python3 -c "<multi-line, brace literal>")"`
# in one statement hits the same bash-3.2 mis-expansion this file works
# around elsewhere -- unlike a plain (non-`export`) multi-line assignment,
# which is unaffected.
_two_pm_comments_json="$(python3 -c "
import json
print(json.dumps([
    {'id': 1, 'user': {'login': 'x'}, 'created_at': '2026-01-01T00:00:00Z', 'body': '**PM spec:** first attempt'},
    {'id': 2, 'user': {'login': 'x'}, 'created_at': '2026-01-02T00:00:00Z', 'body': '**PM spec:** second, corrected attempt'},
]))
")"
export STUB_GH_COMMENTS_RAW="$_two_pm_comments_json"
out="$(bash "$VCS" view-issue 201 --spec)"
assert_contains "$out" "second, corrected attempt" "github: view-issue --spec keeps the LATEST PM spec comment"
assert_not_contains "$out" "first attempt" "github: view-issue --spec drops an earlier, superseded PM spec comment"

unset STUB_GH_COMMENTS_RAW STUB_ISSUE_BODY STUB_ISSUE_TITLE

# dry-run: exits 0, prints a marker, makes no gh call.
: > "$GH_LOG"
out="$(bash "$VCS" --dry-run view-issue 201 --spec 2>&1)"; rc=$?
assert_exit_code "0" "$rc" "github: view-issue --spec --dry-run exits 0"
assert_contains "$out" "[dry-run]" "github: view-issue --spec --dry-run prints marker"
log="$(cat "$GH_LOG" 2>/dev/null || true)"
assert_not_contains "$log" "issue view" "github: view-issue --spec --dry-run does not fetch the issue"
assert_not_contains "$log" "api --paginate" "github: view-issue --spec --dry-run does not fetch comments"

# plain view-issue (no --spec) is unaffected: still returns the full comment set.
# NOTE: plain view-issue fetches comments via `gh issue view --json ...,comments`
# (STUB_ISSUE_COMMENTS_JSON), a different stub path than --spec's paginated
# read-comments fetch (STUB_GH_COMMENTS_RAW) -- both must be set here.
export STUB_ISSUE_COMMENTS_JSON="$FIXTURE_COMMENTS_JSON"
out="$(bash "$VCS" view-issue 201)"
assert_contains "$out" "any update on timing" \
  "github: plain view-issue (no --spec) still returns the plain human comment"
assert_contains "$out" "talos:approval" \
  "github: plain view-issue (no --spec) still returns the approval marker comment"
unset STUB_ISSUE_COMMENTS_JSON

# ── diff-pr --stat (github) ───────────────────────────────────────────────────

STAT_FILES_JSON="$(python3 -c "
import json
print(json.dumps([
    {'filename': 'scripts/pipeline-vcs.sh', 'additions': 156, 'deletions': 0},
    {'filename': 'README.md', 'additions': 2, 'deletions': 1},
]))
")"
out="$(STUB_GH_PR_FILES_RAW="$STAT_FILES_JSON" bash "$VCS" diff-pr 201 --stat)"; rc=$?
assert_exit_code "0" "$rc" "github: diff-pr --stat exits 0"
assert_contains "$out" "scripts/pipeline-vcs.sh | +156 -0" "github: diff-pr --stat shows per-file additions/deletions"
assert_contains "$out" "README.md | +2 -1" "github: diff-pr --stat shows the second file"
assert_contains "$out" "2 files changed, 158 insertions(+), 1 deletions(-)" \
  "github: diff-pr --stat prints a git-diff-stat-style total line"

# Pagination: a >100-file PR spread over 2 pages must be fully summarized (#171 pattern).
_p1="$(python3 -c "
import json
print(json.dumps([{'filename': 'scripts/file' + str(i) + '.sh', 'additions': 1, 'deletions': 0} for i in range(1, 101)]))
")"
_p2="$(python3 -c "
import json
print(json.dumps([{'filename': 'CHANGELOG.md', 'additions': 3, 'deletions': 0}]))
")"
out="$(STUB_GH_PR_FILES_RAW="${_p1}${_p2}" bash "$VCS" diff-pr 201 --stat)"; rc=$?
assert_exit_code "0" "$rc" "github: diff-pr --stat exits 0 across 2 pages"
assert_contains "$out" "101 files changed, 103 insertions(+), 0 deletions(-)" \
  "github: diff-pr --stat totals span every page, not just the first"
assert_contains "$out" "CHANGELOG.md | +3 -0" "github: diff-pr --stat includes a file from the second page"

out="$(STUB_GH_API_FAIL=pr-files bash "$VCS" diff-pr 201 --stat 2>/dev/null)"; rc=$?
assert_exit_code "1" "$rc" "github: diff-pr --stat exits non-zero when a page fails"
assert_eq "" "$out" "github: diff-pr --stat prints no partial output on a failed page"

out="$(bash "$VCS" --dry-run diff-pr 201 --stat)"
assert_contains "$out" "[dry-run]" "github: diff-pr --stat --dry-run prints a marker, not a real call"

# ── github-api provider ───────────────────────────────────────────────────────

cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
export GITHUB_TOKEN="test-token-view-issue-spec"

# view-issue --spec: issue metadata fetch, then a paginated comments fetch
# (single page here -- an empty CURL_LINK_QUEUE means no Link header).
: > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
# Assign the python3 output to a variable before printf'ing it -- bash 3.2
# (macOS's default /bin/bash) mis-expands a `{...}` dict literal produced by
# a nested `$(python3 -c "...")` when that substitution is passed directly
# as a command argument (brace-expanding it into multiple words), even
# though it is fully double-quoted; assigning first avoids the bug.
GA_META_JSON="$(python3 -c "import json; print(json.dumps({'title': 'compact stage handoff', 'body': 'Threads grow with every stage.', 'labels': []}))")"
{
  printf '%s\n' "$GA_META_JSON"
  printf '%s\n' "$FIXTURE_COMMENTS_JSON"
} >> "$CURL_QUEUE"

out="$(bash "$VCS" view-issue 201 --spec)"; rc=$?
assert_exit_code "0" "$rc" "github-api: view-issue --spec exits 0"
assert_contains "$out" "PM spec" "github-api: view-issue --spec keeps the latest PM spec comment"
assert_not_contains "$out" "validator (talos)" "github-api: view-issue --spec excludes the **Agent:** verdict comment"
assert_not_contains "$out" "talos:approval" "github-api: view-issue --spec excludes the approval marker comment"
assert_not_contains "$out" "talos:attempt" "github-api: view-issue --spec excludes the attempt marker comment"
assert_not_contains "$out" "any update on timing" \
  "github-api: view-issue --spec excludes a plain human comment"

count="$(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['comments']))")"
assert_eq "1" "$count" "github-api: view-issue --spec keeps exactly one comment"

keys="$(printf '%s' "$out" | python3 -c "import json,sys; print(sorted(json.load(sys.stdin).keys()))")"
assert_eq "['body', 'comments', 'labels', 'title']" "$keys" \
  "github-api: view-issue --spec keeps the same top-level keys as plain view-issue"

# dry-run: exits 0, no curl call.
: > "$CURL_LOG"
out="$(bash "$VCS" --dry-run view-issue 201 --spec 2>&1)"; rc=$?
assert_exit_code "0" "$rc" "github-api: view-issue --spec --dry-run exits 0"
log="$(cat "$CURL_LOG" 2>/dev/null || true)"
assert_eq "" "$log" "github-api: view-issue --spec --dry-run makes no curl call"

# ── diff-pr --stat (github-api) ───────────────────────────────────────────────

: > "$CURL_LOG"; : > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
printf '%s\n' "$STAT_FILES_JSON" > "$CURL_QUEUE"
out="$(bash "$VCS" diff-pr 201 --stat)"; rc=$?
assert_exit_code "0" "$rc" "github-api: diff-pr --stat exits 0"
assert_contains "$out" "scripts/pipeline-vcs.sh | +156 -0" "github-api: diff-pr --stat shows per-file additions/deletions"
assert_contains "$out" "2 files changed, 158 insertions(+), 1 deletions(-)" \
  "github-api: diff-pr --stat prints a git-diff-stat-style total line"

out="$(bash "$VCS" --dry-run diff-pr 201 --stat)"
assert_contains "$out" "[dry-run]" "github-api: diff-pr --stat --dry-run prints a marker, not a real call"

unset GITHUB_TOKEN
rm -f talos.pipeline.json

# ── gitlab / azure / file: --spec falls back to the plain full view ─────────
# with a stderr note, rather than silently ignoring the flag or erroring.

cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}
EOF
: > "$GH_LOG"
err="$(bash "$VCS" view-issue 201 --spec 2>&1 >/dev/null)"
assert_contains "$err" "not implemented for provider 'gitlab'" \
  "gitlab: view-issue --spec prints a stderr fallback note"
rm -f talos.pipeline.json

cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "azure": {"org_url": "https://dev.azure.com/acme", "project": "widget"}}}
EOF
err="$(bash "$VCS" view-issue 201 --spec 2>&1 >/dev/null)"
assert_contains "$err" "not implemented for provider 'azure'" \
  "azure: view-issue --spec prints a stderr fallback note"
rm -f talos.pipeline.json

echo '- [ ] A plan item' > plan.md
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "file", "file": {"source": {"path": "plan.md"}}}}
EOF
err="$(bash "$VCS" view-issue 1 --spec 2>&1 >/dev/null)"
assert_contains "$err" "not implemented for provider 'file'" \
  "file: view-issue --spec prints a stderr fallback note"
rm -f talos.pipeline.json plan.md

finish
