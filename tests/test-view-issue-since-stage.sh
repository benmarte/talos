#!/usr/bin/env bash
# `view-issue <n> --since-stage` (#548, epic #558): the PM and validator read the
# issue body plus only the comments newer than the last stage, not the whole
# thread. The boundary is the latest stage comment (a `**PM spec:**` comment or a
# `**Agent:**` verdict, a needs-owner question included); the output keeps that
# comment (what the last stage found or asked) and what follows, and a bare
# `<!-- talos:` marker comment is dropped. An owner clarification posted after the
# last stage must be seen; the human comments before it are summarised as a
# count, and `read-comments` still reads the whole thread.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# comments_json <body>...: a read-comments-shaped array, one comment per argument,
# in order. Built from a quoted heredoc (bash 3.2 mis-expands a `{...}` literal
# inside a nested `$(python3 -c "...")`).
comments_json() {
  python3 -I - "$@" <<'PYEOF'
import json, sys
bodies = sys.argv[1:]
print(json.dumps([{'id': i, 'user': {'login': 'owner'},
                   'created_at': '2026-01-%02dT00:00:00Z' % (i + 1),
                   'body': b} for i, b in enumerate(bodies)]))
PYEOF
}
count_of() { python3 -I -c "import json,sys; print(len(json.load(sys.stdin)['comments']))"; }
earlier_of() { python3 -I -c "import json,sys; print(json.load(sys.stdin)['earlier_comments'])"; }

EARLY='early question from a bystander before any stage ran'
VERDICT='**Agent:** validator (talos)

**Verdict:** NEEDS_MORE_INFO - which platform?'
ASK='**Agent:** orchestrator (talos)

**Needs owner** - which platform?

<!-- talos:needs-owner -->'
ATTEMPT='Talos attempt record
<!-- talos:attempt stage=validator count=1 total=3 -->'
REPLY='OWNER CLARIFICATION: the target is the Windows build, ignore Linux'
LATER='one more detail: only the CLI, not the GUI'
SPEC='**PM spec:** goal x'

export STUB_ISSUE_TITLE="since-stage"
export STUB_ISSUE_BODY="The issue body text."

# ── a re-run after a NEEDS_MORE_INFO: the owner's reply is seen, the old chatter is a count
export STUB_GH_COMMENTS_RAW="$(comments_json "$EARLY" "$VERDICT" "$ASK" "$ATTEMPT" "$REPLY" "$LATER")"
out="$(bash "$VCS" view-issue 548 --since-stage)"; rc=$?
assert_exit_code "0" "$rc" "view-issue --since-stage exits 0"
assert_contains "$out" "The issue body text." "--since-stage keeps the issue body"
assert_contains "$out" "since-stage" "--since-stage keeps the title"
assert_contains "$out" "OWNER CLARIFICATION" "--since-stage shows the owner clarification posted after the last stage"
assert_contains "$out" "only the CLI" "--since-stage shows every comment after the last stage"
assert_not_contains "$out" "early question from a bystander" "--since-stage drops a comment from before the last stage"
assert_not_contains "$out" "NEEDS_MORE_INFO" "--since-stage drops an older stage verdict"
assert_contains "$out" "talos:needs-owner" "--since-stage keeps the latest stage comment itself (the question the reply answers)"
assert_not_contains "$out" "talos:attempt" "--since-stage drops marker comments"
assert_eq "3" "$(printf '%s' "$out" | count_of)" "--since-stage: the latest stage comment plus the two comments after it"
keys="$(printf '%s' "$out" | python3 -I -c "import json,sys; print(sorted(json.load(sys.stdin).keys()))")"
assert_eq "['body', 'comments', 'earlier_comments', 'labels', 'title']" "$keys" \
  "--since-stage: the view-issue shape plus earlier_comments"
assert_eq "1" "$(printf '%s' "$out" | earlier_of)" \
  "--since-stage: earlier_comments counts the human comments before the boundary (read-comments reads them)"

# ── the boundary is the LATEST stage comment (a PM spec after a validator verdict)
export STUB_GH_COMMENTS_RAW="$(comments_json "$EARLY" "$VERDICT" "$REPLY" "$SPEC" "$LATER")"
out="$(bash "$VCS" view-issue 548 --since-stage)"
assert_eq "2" "$(printf '%s' "$out" | count_of)" "the latest stage comment is the boundary (PM spec included): it and the one after"
assert_contains "$out" "PM spec" "the PM spec comment itself is kept"
assert_contains "$out" "only the CLI" "a comment after the PM spec is kept"
assert_not_contains "$out" "OWNER CLARIFICATION" "a comment before the PM spec is dropped"
assert_eq "2" "$(printf '%s' "$out" | earlier_of)" "earlier_comments counts the two human comments before the PM spec"

# ── nothing newer than the last stage: just that stage comment
export STUB_GH_COMMENTS_RAW="$(comments_json "$EARLY" "$VERDICT")"
out="$(bash "$VCS" view-issue 548 --since-stage)"
assert_eq "1" "$(printf '%s' "$out" | count_of)" "no comment after the last stage: only the stage comment itself"
assert_contains "$out" "NEEDS_MORE_INFO" "no comment after the last stage: it is the latest verdict"

# ── no stage has run yet (first validation): every human comment is new, markers still dropped
export STUB_GH_COMMENTS_RAW="$(comments_json "$EARLY" "$ATTEMPT" "$REPLY")"
out="$(bash "$VCS" view-issue 548 --since-stage)"
assert_eq "2" "$(printf '%s' "$out" | count_of)" "no stage comment yet: all human comments, no marker comments"
assert_contains "$out" "early question from a bystander" "no stage comment yet: the early comment is seen"
assert_eq "0" "$(printf '%s' "$out" | earlier_of)" "no stage comment yet: nothing is earlier"

# ── no comments at all
export STUB_GH_COMMENTS_RAW="[]"
out="$(bash "$VCS" view-issue 548 --since-stage)"; rc=$?
assert_exit_code "0" "$rc" "no comments: exits 0"
assert_eq "0" "$(printf '%s' "$out" | count_of)" "no comments: an empty list"

# ── plain view-issue and --spec are unchanged
export STUB_GH_COMMENTS_RAW="$(comments_json "$EARLY" "$VERDICT" "$REPLY" "$SPEC")"
out="$(bash "$VCS" view-issue 548 --spec)"
assert_contains "$out" "PM spec" "--spec still keeps the PM spec comment"
assert_not_contains "$out" "OWNER CLARIFICATION" "--spec still drops human comments"

# ── dry-run: a marker, no fetch
: > "$GH_LOG"
out="$(bash "$VCS" --dry-run view-issue 548 --since-stage 2>&1)"; rc=$?
assert_exit_code "0" "$rc" "--since-stage --dry-run exits 0"
assert_contains "$out" "[dry-run]" "--since-stage --dry-run prints a marker"
assert_not_contains "$(cat "$GH_LOG" 2>/dev/null || true)" "api --paginate" "--since-stage --dry-run fetches nothing"

# ── a failed comment fetch is fail-closed (no partial thread)
export STUB_GH_COMMENTS_RAW="$(comments_json "$REPLY")"
out="$(STUB_GH_API_FAIL=comments bash "$VCS" view-issue 548 --since-stage 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "--since-stage fails closed when the comment read fails"
assert_eq "" "$out" "--since-stage prints nothing on a failed comment read"
unset STUB_GH_COMMENTS_RAW STUB_ISSUE_BODY STUB_ISSUE_TITLE

# ── the token transport answers the same
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
export GITHUB_TOKEN="test-token-since-stage"
: > "$CURL_QUEUE"; : > "$CURL_LINK_QUEUE"
META="$(python3 -I -c "import json; print(json.dumps({'title': 't', 'body': 'api body', 'labels': []}))")"
{ printf '%s\n' "$META"; comments_json "$EARLY" "$VERDICT" "$REPLY"; } >> "$CURL_QUEUE"
out="$(bash "$VCS" view-issue 548 --since-stage)"; rc=$?
assert_exit_code "0" "$rc" "github-api: --since-stage exits 0"
assert_contains "$out" "OWNER CLARIFICATION" "github-api: the owner clarification after the last stage is seen"
assert_not_contains "$out" "early question from a bystander" "github-api: a comment before the last stage is dropped"
unset GITHUB_TOKEN
rm -f talos.pipeline.json

# ── gitlab / azure / file: the flag falls back to the full view with a stderr note
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}
EOF
err="$(bash "$VCS" view-issue 548 --since-stage 2>&1 >/dev/null)"
assert_contains "$err" "view-issue --since-stage: not implemented for provider 'gitlab'" "gitlab: --since-stage prints a stderr fallback note"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "azure": {"org_url": "https://dev.azure.com/acme", "project": "widget"}}}
EOF
err="$(bash "$VCS" view-issue 548 --since-stage 2>&1 >/dev/null)"
assert_contains "$err" "view-issue --since-stage: not implemented for provider 'azure'" "azure: --since-stage prints a stderr fallback note"
echo '- [ ] A plan item' > plan.md
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "file", "file": {"source": {"path": "plan.md"}}}}
EOF
err="$(bash "$VCS" view-issue 1 --since-stage 2>&1 >/dev/null)"
assert_contains "$err" "view-issue --since-stage: not implemented for provider 'file'" "file: --since-stage prints a stderr fallback note"
rm -f talos.pipeline.json plan.md

# ── the PM and validator profiles use it, and the verb exists
assert_contains "$(cat "$TALOS_ROOT/agents/pm.md")" "view-issue <N> --since-stage" "agents/pm.md reads the issue with --since-stage"
assert_contains "$(cat "$TALOS_ROOT/agents/validator.md")" "view-issue <N> --since-stage" "agents/validator.md reads the issue with --since-stage"
assert_contains "$(cat "$TALOS_ROOT/agents/pm.md")" "read-comments" "agents/pm.md says how to read the earlier thread"
assert_contains "$(cat "$TALOS_ROOT/agents/validator.md")" "read-comments" "agents/validator.md says how to read the earlier thread"

finish
