#!/usr/bin/env bash
# test-providers.sh — regression tests for the gitlab, azure, and teams adapters.
# Uses stub CLIs on PATH (glab, az, curl) so no real credentials are needed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
NOTIFY="$TALOS_ROOT/scripts/pipeline-notify.sh"

# ── GitLab adapter ────────────────────────────────────────────────────────────
echo "  [gitlab]"

cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab"}}
EOF

# comment-issue → glab issue note
: > "$GH_LOG"
bash "$VCS" comment-issue 5 "findings body" >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "issue note 5" "gitlab comment-issue invokes glab issue note"
assert_contains "$log" "--message findings body" "gitlab comment-issue passes body with --message"

# label-issue --add → glab issue update --label
: > "$GH_LOG"
bash "$VCS" label-issue 5 --add "pipeline:review" >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "issue update 5" "gitlab label-issue --add invokes glab issue update"
assert_contains "$log" "--label pipeline:review" "gitlab label-issue --add maps to --label"

# label-issue --remove → glab issue update --unlabel
: > "$GH_LOG"
bash "$VCS" label-issue 5 --remove "pipeline:dev" >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "issue update 5" "gitlab label-issue --remove invokes glab issue update"
assert_contains "$log" "--unlabel pipeline:dev" "gitlab label-issue --remove maps to --unlabel"

# close-issue → glab issue note + glab issue close
: > "$GH_LOG"
bash "$VCS" close-issue 5 "resolved" >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "issue note 5" "gitlab close-issue posts a note before closing"
assert_contains "$log" "issue close 5" "gitlab close-issue closes the issue"

# create-pr → glab mr create --head ... --target-branch ...
: > "$GH_LOG"
printf 'test PR body' > "$SANDBOX/body.txt"
bash "$VCS" create-pr "fix/branch" "PR title" "$SANDBOX/body.txt" >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "mr create" "gitlab create-pr invokes glab mr create"
assert_contains "$log" "--head fix/branch" "gitlab create-pr passes source branch"
assert_contains "$log" "--target-branch" "gitlab create-pr passes target-branch flag"

# merge-pr → glab mr merge
: > "$GH_LOG"
bash "$VCS" merge-pr 7 >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "mr merge 7" "gitlab merge-pr invokes glab mr merge"

# approve-pr with body → glab mr approve + glab mr note (note fallback)
: > "$GH_LOG"
bash "$VCS" approve-pr 7 "LGTM" >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "mr approve 7" "gitlab approve-pr invokes glab mr approve"
assert_contains "$log" "mr note 7" "gitlab approve-pr posts body as a separate note"
assert_contains "$log" "--message LGTM" "gitlab approve-pr note includes the body"

# ── Azure DevOps adapter ──────────────────────────────────────────────────────
echo "  [azure]"

cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure"}}
EOF

# comment-issue → az boards work-item comment add
: > "$GH_LOG"
bash "$VCS" comment-issue 5 "azure comment" >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "[boards] [work-item] [comment] [add]" "azure comment-issue invokes work-item comment add"
assert_contains "$log" "[--text] [azure comment]" "azure comment-issue passes body as --text"

# view-issue → az boards work-item show
: > "$GH_LOG"
bash "$VCS" view-issue 5 >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "[boards] [work-item] [show]" "azure view-issue invokes work-item show"
assert_contains "$log" "[--id] [5]" "azure view-issue passes correct id"

# label-issue tag-merge: stub returns "bug; ui"; add "backend"
# → Python merges and calls az boards work-item update with sorted tags
: > "$GH_LOG"
bash "$VCS" label-issue 5 --add "backend" >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "[boards] [work-item] [update]" "azure label-issue calls work-item update"
assert_contains "$log" "backend" "azure label-issue adds new tag"
assert_contains "$log" "bug" "azure label-issue preserves existing tag: bug"
assert_contains "$log" "ui" "azure label-issue preserves existing tag: ui"

# label-issue remove: stub returns "bug; ui"; remove "ui" → only "bug" remains
: > "$GH_LOG"
bash "$VCS" label-issue 5 --remove "ui" >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "[boards] [work-item] [update]" "azure label-issue remove calls work-item update"
assert_contains "$log" "[--tags] [bug]" "azure label-issue remove drops removed tag"

# label-issue with org_url: org_arg must be split into two argv elements (not one)
# so az receives '--org' and 'https://dev.azure.com/testorg' as separate arguments.
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "azure": {"org_url": "https://dev.azure.com/testorg"}}}
EOF
: > "$GH_LOG"
rc=0
bash "$VCS" label-issue 5 --add "backend" >/dev/null 2>&1 || rc=$?
log="$(cat "$GH_LOG")"
assert_eq "0" "$rc" "azure label-issue with org_url exits 0"
# Extract only the subprocess 'update' line — the shell 'show' call also word-splits correctly,
# so we must assert against the update line specifically to guard the Python argv fix.
update_line="$(printf '%s' "$log" | grep '\[work-item\] \[update\]')"
assert_contains "$update_line" "[--org] [https://dev.azure.com/testorg]" "azure label-issue splits org_arg into separate argv elements in subprocess"
assert_not_contains "$update_line" "[--org https://dev.azure.com/testorg]" "azure label-issue does not pass org_arg as one concatenated element"
# Restore config without org_url for remaining tests
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure"}}
EOF

# merge-pr → az repos pr update --status completed
: > "$GH_LOG"
bash "$VCS" merge-pr 7 >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "[repos] [pr] [update]" "azure merge-pr invokes repos pr update"
assert_contains "$log" "[--status] [completed]" "azure merge-pr sets status to completed"

# missing-extension error path: AZ_STUB_NO_EXT=1 → exit 1 with clear message
err="$(AZ_STUB_NO_EXT=1 bash "$VCS" comment-issue 5 "hi" 2>&1)"; rc=$?
assert_eq "1" "$rc" "azure adapter exits 1 when azure-devops extension is missing"
assert_contains "$err" "azure-devops extension missing" "azure adapter reports missing extension clearly"

# ── Teams notifications ───────────────────────────────────────────────────────
echo "  [teams]"

# Debug mode: TEAMS_WEBHOOK_URL set + PIPELINE_NOTIFY_DEBUG=1 → prints text, no curl
: > "$CURL_LOG"
out="$(TEAMS_WEBHOOK_URL="https://outlook.office.com/webhook/test" \
  PIPELINE_NOTIFY_DEBUG=1 \
  PIPELINE_ISSUE_TITLE="My Issue" \
  bash "$NOTIFY" info "#5" "teams debug message" 5 2>&1)"
assert_contains "$out" "[pipeline-notify DEBUG] TEAMS" "teams debug mode prints DEBUG line"
assert_contains "$out" "teams debug message" "teams debug mode output includes message text"
assert_not_contains "$(cat "$CURL_LOG")" "outlook.office.com" "teams debug mode does not call curl"

# Real post: TEAMS_WEBHOOK_URL set, no debug → curl log contains webhook URL + AdaptiveCard
: > "$CURL_LOG"
TEAMS_WEBHOOK_URL="https://outlook.office.com/webhook/test" \
  PIPELINE_ISSUE_TITLE="My Issue" \
  bash "$NOTIFY" info "#5" "teams real message" 5 >/dev/null 2>&1
log="$(cat "$CURL_LOG")"
assert_contains "$log" "outlook.office.com/webhook/test" "teams real post hits the webhook URL"
assert_contains "$log" "AdaptiveCard" "teams payload contains AdaptiveCard type"
assert_contains "$log" "teams real message" "teams payload contains the message text"

# No webhook: TEAMS_WEBHOOK_URL unset → no curl call at all
: > "$CURL_LOG"
PIPELINE_ISSUE_TITLE="My Issue" \
  bash "$NOTIFY" info "#5" "no teams" 5 >/dev/null 2>&1
assert_not_contains "$(cat "$CURL_LOG")" "outlook.office.com" "no TEAMS_WEBHOOK_URL means no curl call"

finish
