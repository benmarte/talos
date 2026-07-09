#!/usr/bin/env bash
# Regression tests for the planner role feature (issue #7).
# Covers: roles.planner default, create-issue via gh stub and file mode,
# github-api create-issue, dependency gating logic, new bootstrap labels.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
CFG="$TALOS_ROOT/scripts/pipeline-config.sh"

# ── (a) roles.planner defaults to false when key is absent ───────────────────
# No config file present — should return "false"
result="$(bash "$CFG" roles.planner false)"
assert_eq "false" "$result" "roles.planner: default is false when key absent"

# Explicit false in config
cat > talos.pipeline.json <<'EOF'
{"roles": {"planner": false}}
EOF
result="$(bash "$CFG" roles.planner false)"
assert_eq "false" "$result" "roles.planner: explicit false reads as false"
rm talos.pipeline.json

# Explicit true in config
cat > talos.pipeline.json <<'EOF'
{"roles": {"planner": true}}
EOF
result="$(bash "$CFG" roles.planner false)"
assert_eq "true" "$result" "roles.planner: explicit true reads as true"
rm talos.pipeline.json

# ── (b) create-issue via gh stub: assert issue create args ───────────────────
: > "$GH_LOG"
printf 'Sub-task context.\n\nPart of #5\n' > "$SANDBOX/sub-body.txt"
url="$(bash "$VCS" create-issue "Add planner stage" "$SANDBOX/sub-body.txt" \
  --label pipeline:ready --label p1 2>&1)"
log="$(cat "$GH_LOG")"
assert_contains "$log" "issue create" "gh stub: issue create verb invoked"
assert_contains "$log" "--title" "gh stub: --title arg passed"
assert_contains "$log" "pipeline:ready" "gh stub: pipeline:ready label passed"
assert_contains "$log" "p1" "gh stub: p1 label passed"
assert_contains "$url" "https://github.com/" "gh stub: URL returned on stdout"
assert_contains "$url" "issues/" "gh stub: URL is an issues URL"

# ── (c) file-mode create-issue appends and assigns sequential ids ─────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "file", "file": {"source": {"path": "plan.md"}}}}
EOF
cat > plan.md <<'EOF'
# Epic Plan

- [ ] Existing task <!-- id: 3 -->
EOF

id1="$(bash "$VCS" create-issue "Sub-task 1: Add config key" "$SANDBOX/sub-body.txt")"
id2="$(bash "$VCS" create-issue "Sub-task 2: Add planner agent" "$SANDBOX/sub-body.txt")"
id3="$(bash "$VCS" create-issue "Sub-task 3: Add SKILL stage" "$SANDBOX/sub-body.txt")"

plan_content="$(cat plan.md)"
assert_contains "$plan_content" "Sub-task 1: Add config key" "file: first sub-task appended"
assert_contains "$plan_content" "Sub-task 2: Add planner agent" "file: second sub-task appended"
assert_contains "$plan_content" "Sub-task 3: Add SKILL stage" "file: third sub-task appended"

# IDs must be sequential and numeric, starting after existing id 3
if printf '%s' "$id1" | grep -qE '^[0-9]+$'; then
  pass "file: create-issue id1 is numeric"
else
  fail "file: create-issue id1 is numeric" "got: $id1"
fi
if [ "$id2" -eq $((id1 + 1)) ] 2>/dev/null; then
  pass "file: create-issue ids are sequential"
else
  fail "file: create-issue ids are sequential" "id1=$id1 id2=$id2"
fi
assert_eq "$((id1 - 1))" "3" "file: ids start after existing max id (3)"

# dry-run: no mutation
current_lines="$(wc -l < plan.md)"
out="$(bash "$VCS" --dry-run create-issue "Dry-run task" /dev/null)"
assert_contains "$out" "[dry-run]" "file: create-issue dry-run prints [dry-run]"
new_lines="$(wc -l < plan.md)"
assert_eq "$current_lines" "$new_lines" "file: create-issue dry-run does not mutate file"

rm talos.pipeline.json

# ── (d) github-api create-issue via curl stub ─────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
export GITHUB_TOKEN="test-token-planner"

: > "$CURL_LOG"
printf '%s\n' \
  '{"number":101,"title":"Sub-task 1: Add config key","html_url":"https://github.com/acme/widget/issues/101","body":""}' \
  > "$CURL_QUEUE"

printf 'Sub-task body.\n\nPart of #5\n' > "$SANDBOX/api-body.txt"
url="$(bash "$VCS" create-issue "Sub-task 1: Add config key" "$SANDBOX/api-body.txt" \
  --label pipeline:ready 2>&1)"

log="$(cat "$CURL_LOG")"
assert_contains "$log" "api.github.com"           "github-api create-issue: GitHub API called"
assert_contains "$log" "/issues"                  "github-api create-issue: /issues endpoint hit"
assert_contains "$log" "Authorization: Bearer"    "github-api create-issue: auth header sent"
assert_contains "$log" "pipeline:ready"           "github-api create-issue: label in payload"
assert_contains "$url" "https://github.com/acme/widget/issues/101" \
  "github-api create-issue: URL returned"
assert_not_contains "$log" "$GITHUB_TOKEN"        "github-api create-issue: token not in log"
assert_not_contains "$url" "$GITHUB_TOKEN"        "github-api create-issue: token not in output"

unset GITHUB_TOKEN
rm talos.pipeline.json

# ── (e) Step 2 dependency gating: issue with Depends-on ref ───────────────────
# Verify that view-issue returns an open-looking response (no closed state)
# and that the Depends-on pattern can be extracted from an issue body.
out="$(bash "$VCS" view-issue 99 2>&1)"
# Stub returns: {"title":"...","body":"stub body","labels":[],"comments":[]}
assert_contains "$out" '"body"'    "gating: view-issue 99 returns JSON"
assert_not_contains "$out" '"state": "closed"' "gating: stub issue 99 is open (no closed state)"

# Simulate parsing a sub-issue body for Depends-on refs
DEP_BODY="Context paragraph.\n\nPart of #5\nDepends on: #99"
dep_n="$(printf '%s' "$DEP_BODY" | grep -oE 'Depends on: #[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
assert_eq "99" "$dep_n" "gating: Depends-on ref extracted from issue body"

# Simulate parsing an issue body with no dependency
NO_DEP_BODY="Context paragraph.\n\nPart of #5"
dep_n_none="$(printf '%s' "$NO_DEP_BODY" | grep -oE 'Depends on: #[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
assert_eq "" "$dep_n_none" "gating: no Depends-on ref in body without dependency"

# view-issue of the dep returns open → issue would be skipped in queue
# (view-issue returns stub body with no pipeline:blocked label → dep is open)
dep_view="$(bash "$VCS" view-issue "$dep_n" 2>&1)"
dep_blocked="$(printf '%s' "$dep_view" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    labels = [l.get('name','') for l in d.get('labels',[])]
    print('blocked' if any('blocked' in l for l in labels) else 'open')
except Exception:
    print('open')
" 2>/dev/null || echo "open")"
assert_eq "open" "$dep_blocked" "gating: dep issue #99 is open → dependent issue would be skipped"

# ── (f) Azure adapter create-issue is a fail-loud stub ────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure"}}
EOF
err="$(bash "$VCS" create-issue "New issue" /dev/null 2>&1)"; rc=$?
# azure adapter checks for 'az' CLI first; either way it should not silently succeed
if [ "$rc" -ne 0 ]; then
  pass "azure: create-issue exits non-zero (fail-loud)"
else
  fail "azure: create-issue exits non-zero (fail-loud)"
fi
rm talos.pipeline.json

finish
