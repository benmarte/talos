#!/usr/bin/env bash
# Unit tests for `has-spec` and `slug-for` (issue #199, skip-PM-when-spec-
# present). RED on main: neither verb exists there, so every assertion below
# fails against unpatched pipeline-vcs.sh and passes once both verbs are
# implemented.
#
# Covers: `## Acceptance criteria` heading, `**Acceptance criteria**` bold
# heading, a heading with no checkboxes (must fail), the `spec:ready` label
# path, both providers (github, github-api), dry-run, and slug-for's
# punctuation-collapsing + 40-char truncation.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── github provider ───────────────────────────────────────────────────────────

# (a) '## Acceptance criteria' heading with an unticked box -> exit 0
export STUB_ISSUE_BODY='Some problem statement.

## Acceptance criteria

- [ ] Do the thing'
bash "$VCS" has-spec 199 >/dev/null 2>&1
assert_exit_code "0" "$?" "github: has-spec exits 0 for a '## Acceptance criteria' heading with a checkbox"

# (b) bold '**Acceptance criteria**' heading with a ticked box -> exit 0
export STUB_ISSUE_BODY='Some problem statement.

**Acceptance criteria**
- [x] Already done'
bash "$VCS" has-spec 199 >/dev/null 2>&1
assert_exit_code "0" "$?" "github: has-spec exits 0 for a bold '**Acceptance criteria**' heading with a checkbox"

# (c) heading present but no checkbox items under it -> exit 1
export STUB_ISSUE_BODY='Some problem statement.

## Acceptance criteria

Nothing checkable here, just prose.

## Files likely to change
- foo.js'
bash "$VCS" has-spec 199 >/dev/null 2>&1
assert_exit_code "1" "$?" "github: has-spec exits 1 when the heading has no checklist items"

# (d) no heading at all -> exit 1
export STUB_ISSUE_BODY='Just a plain issue body with no structure.'
bash "$VCS" has-spec 199 >/dev/null 2>&1
assert_exit_code "1" "$?" "github: has-spec exits 1 when there is no acceptance-criteria heading"

# (e) checkbox items belong to a LATER, unrelated heading -> exit 1
export STUB_ISSUE_BODY='## Acceptance criteria

No boxes right here.

## Somewhere else
- [ ] this box is under a different heading'
bash "$VCS" has-spec 199 >/dev/null 2>&1
assert_exit_code "1" "$?" "github: has-spec does not credit checkboxes under a later, unrelated heading"

unset STUB_ISSUE_BODY

# (f) spec:ready label present, no heading at all -> exit 0
export STUB_ISSUE_LABELS_JSON='[{"name":"spec:ready"}]'
export STUB_ISSUE_BODY='No structure whatsoever.'
bash "$VCS" has-spec 199 >/dev/null 2>&1
assert_exit_code "0" "$?" "github: has-spec exits 0 when the issue carries spec:ready, regardless of body"
unset STUB_ISSUE_LABELS_JSON STUB_ISSUE_BODY

# (g) dry-run: exits 0, prints a marker, makes no gh call
: > "$GH_LOG"
out="$(bash "$VCS" --dry-run has-spec 199 2>&1)"; rc=$?
assert_exit_code "0" "$rc" "github: has-spec --dry-run exits 0"
assert_contains "$out" "[dry-run]" "github: has-spec --dry-run prints marker"
log="$(cat "$GH_LOG" 2>/dev/null || true)"
assert_not_contains "$log" "issue view" "github: has-spec --dry-run does not fetch the issue"

# (h) missing issue number -> exit non-zero
bash "$VCS" has-spec >/dev/null 2>&1
assert_exit_code "1" "$?" "github: has-spec with no argument exits non-zero"

# ── github-api provider ───────────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
export GITHUB_TOKEN="test-token-has-spec"

# (i) heading + checkbox -> exit 0 (two queued responses: issue, then comments)
: > "$CURL_QUEUE"
{
  printf '%s\n' '{"number":199,"title":"perf: skip pm","body":"## Acceptance criteria\n\n- [ ] Ship it","labels":[]}'
  printf '%s\n' '[]'
} >> "$CURL_QUEUE"
bash "$VCS" has-spec 199 >/dev/null 2>&1
assert_exit_code "0" "$?" "github-api: has-spec exits 0 for a heading with a checkbox"

# (j) no heading, no label -> exit 1
: > "$CURL_QUEUE"
{
  printf '%s\n' '{"number":199,"title":"perf: skip pm","body":"Just prose.","labels":[]}'
  printf '%s\n' '[]'
} >> "$CURL_QUEUE"
bash "$VCS" has-spec 199 >/dev/null 2>&1
assert_exit_code "1" "$?" "github-api: has-spec exits 1 with no heading and no spec:ready label"

# (k) spec:ready label, no heading -> exit 0
: > "$CURL_QUEUE"
{
  printf '%s\n' '{"number":199,"title":"perf: skip pm","body":"Just prose.","labels":[{"name":"spec:ready"}]}'
  printf '%s\n' '[]'
} >> "$CURL_QUEUE"
bash "$VCS" has-spec 199 >/dev/null 2>&1
assert_exit_code "0" "$?" "github-api: has-spec exits 0 when the issue carries spec:ready"

# (l) dry-run: exits 0, no curl call
: > "$CURL_LOG"
out="$(bash "$VCS" --dry-run has-spec 199 2>&1)"; rc=$?
assert_exit_code "0" "$rc" "github-api: has-spec --dry-run exits 0"
log="$(cat "$CURL_LOG" 2>/dev/null || true)"
assert_eq "" "$log" "github-api: has-spec --dry-run makes no curl call"

unset GITHUB_TOKEN
rm -f talos.pipeline.json

# ── slug-for (provider-agnostic) ──────────────────────────────────────────────

out="$(bash "$VCS" slug-for "Fix: parseToken() dereferencing a null claim!!!")"
assert_eq "fix-parsetoken-dereferencing-a-null-clai" "$out" \
  "slug-for: punctuation collapses to single hyphens, lowercased, truncated to 40 chars"
len="$(printf '%s' "$out" | wc -c | tr -d ' ')"
assert_eq "40" "$len" "slug-for: output never exceeds 40 characters"

out="$(bash "$VCS" slug-for "  --Leading and trailing punctuation--  ")"
assert_eq "leading-and-trailing-punctuation" "$out" \
  "slug-for: leading/trailing non-alphanumeric runs are trimmed, not turned into hyphens"

out="$(bash "$VCS" slug-for "Short Title")"
assert_eq "short-title" "$out" "slug-for: a short title is lowercased and hyphenated with no truncation"

out="$(bash "$VCS" --dry-run slug-for "anything")"
assert_contains "$out" "[dry-run]" "slug-for --dry-run prints marker instead of computing"

finish
