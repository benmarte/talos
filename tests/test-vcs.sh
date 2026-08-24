#!/usr/bin/env bash
# Regression tests for pipeline-vcs.sh — github verb → gh command mapping
# (via --dry-run and the gh stub) and the file-mode adapter's real logic.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── GitHub adapter: dry-run command construction ─────────────────────────────
out="$(bash "$VCS" --dry-run label-issue 5 --add pipeline:confirmed --remove pipeline:ready)"
assert_contains "$out" "gh issue edit 5" "label-issue targets the issue"
assert_contains "$out" "--add-label 'pipeline:confirmed'" "label-issue --add mapped"
assert_contains "$out" "--remove-label 'pipeline:ready'" "label-issue --remove mapped"

out="$(bash "$VCS" --dry-run merge-pr 9)"
assert_contains "$out" "gh pr merge 9 --squash --delete-branch" "merge-pr defaults to squash"

cat > talos.pipeline.json <<'EOF'
{"merge": {"method": "rebase"}}
EOF
out="$(bash "$VCS" --dry-run merge-pr 9)"
assert_contains "$out" "--rebase" "merge.method config changes merge flag"
rm talos.pipeline.json

out="$(bash "$VCS" --dry-run comment-pr 9 "review done")"
assert_contains "$out" "gh issue comment 9" "comment-pr uses issue comment API"

out="$(bash "$VCS" --dry-run close-issue 5 "resolved")"
assert_contains "$out" "gh issue close 5" "close-issue closes after commenting"

# Real-run against the stub: verify gh receives the calls
bash "$VCS" comment-issue 5 "findings body" >/dev/null 2>&1
assert_contains "$(cat "$GH_LOG")" "issue comment 5 --body findings body" \
  "comment-issue invokes gh with the body"

# ── Comment body: --body-file support, and no silent flag-as-body ─────────────
# Regression: passing `--body-file <path>` used to make "$2" the body verbatim,
# so the posted comment was the literal string "--body-file" and exit was 0.

printf 'verdict from a file' > body.md

out="$(bash "$VCS" --dry-run comment-issue 7 --body-file body.md)"
assert_contains "$out" "--body verdict from a file" \
  "comment-issue --body-file reads the file into the body"
assert_not_contains "$out" "body.md" \
  "comment-issue --body-file does not pass the path through as the body"

out="$(bash "$VCS" --dry-run comment-pr 8 --body-file body.md)"
assert_contains "$out" "--body verdict from a file" \
  "comment-pr --body-file reads the file into the body"

out="$(bash "$VCS" --dry-run comment-issue 7 --body "inline via flag")"
assert_contains "$out" "--body inline via flag" \
  "comment-issue --body accepts an explicit flag form too"

# A bare flag must never reach gh as the body.
out="$(bash "$VCS" --dry-run comment-issue 7 --body-file 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "comment-issue refuses a flag-shaped body"
assert_contains "$out" "looks like a flag" "the refusal explains itself"
assert_not_contains "$out" "gh issue comment" "no gh call is constructed"

out="$(bash "$VCS" --dry-run comment-pr 8 --body-file 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "comment-pr refuses a flag-shaped body"

# An unreadable path fails loudly rather than posting the path.
out="$(bash "$VCS" --dry-run comment-issue 7 --body-file no-such-file.md 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "comment-issue --body-file exits 1 on an unreadable path"
assert_contains "$out" "cannot read" "the unreadable path is named"

# A body that legitimately starts with a dash is still a body, not a flag.
out="$(bash "$VCS" --dry-run comment-issue 7 "- bullet one")"
assert_contains "$out" "--body - bullet one" "a leading single dash is not treated as a flag"

# Verbs that are not comment verbs keep their own flag handling.
out="$(bash "$VCS" --dry-run label-issue 7 --add pipeline:ready)"
assert_contains "$out" "--add-label 'pipeline:ready'" "label-issue flags are untouched"

rm -f body.md

# Unknown verb fails loudly
if bash "$VCS" no-such-verb 1 >/dev/null 2>&1; then
  fail "unknown verb exits non-zero"
else
  pass "unknown verb exits non-zero"
fi

# ── find-pr: locate PRs belonging to an issue ─────────────────────────────────
out="$(bash "$VCS" find-pr 42)"
assert_contains "$out" '"number": 9' "find-pr matches branch fix/issue-42"
out="$(bash "$VCS" find-pr 7)"
assert_eq "" "$out" "find-pr returns nothing for unrelated issue"

# ── check-pr-files: forbidden-files gate ──────────────────────────────────────
out="$(bash "$VCS" check-pr-files 9)"; rc=$?
assert_eq "0" "$rc" "clean PR passes forbidden-files check"
assert_contains "$out" "no forbidden files" "clean PR reported clean"

out="$(STUB_PR_FILES=$'src/app.js\ndeploy/prod.pem\n.env.production' bash "$VCS" check-pr-files 9)"; rc=$?
assert_eq "1" "$rc" "PR touching secrets exits 1 (default patterns)"
assert_contains "$out" "deploy/prod.pem" "violating path listed (*.pem)"
assert_contains "$out" ".env.production" "violating path listed (.env.*)"
assert_not_contains "$out" "src/app.js" "clean path not listed"

cat > talos.pipeline.json <<'EOF'
{"merge": {"forbidden_files": ["*.tfstate"]}}
EOF
out="$(STUB_PR_FILES=$'infra/prod.tfstate\n.env' bash "$VCS" check-pr-files 9)"; rc=$?
assert_eq "1" "$rc" "custom forbidden_files config enforced"
assert_contains "$out" "infra/prod.tfstate" "custom pattern matched"
assert_not_contains "$out" ".env" "custom config replaces defaults"
rm talos.pipeline.json

# ── forbidden_files_allow: allow-list checked before deny patterns ─────────────
# .env.example matches the default .env.* deny pattern, but should be exempt.
cat > talos.pipeline.json <<'EOF'
{"merge": {"forbidden_files_allow": [".env.example"]}}
EOF
out="$(STUB_PR_FILES=$'.env.example\n.env.production' bash "$VCS" check-pr-files 9)"; rc=$?
assert_eq "1" "$rc" "allow-list: still blocks the non-allowed .env.production"
assert_not_contains "$out" ".env.example" "allow-list: .env.example is not reported as forbidden"
assert_contains "$out" ".env.production" "allow-list: .env.production is still blocked"

# A file in BOTH allow and deny is permitted (allow wins because it is checked first).
cat > talos.pipeline.json <<'EOF'
{"merge": {"forbidden_files_allow": [".env.example"], "forbidden_files": [".env.*", ".env.example"]}}
EOF
out="$(STUB_PR_FILES=$'.env.example' bash "$VCS" check-pr-files 9)"; rc=$?
assert_eq "0" "$rc" "allow-list before deny: allowed file is not blocked even when it appears in deny list"
assert_contains "$out" "no forbidden files" "allow-list before deny: clean result reported"
rm talos.pipeline.json

# ── list-prs passes --base and includes baseRefName ──────────────────────────
# With BASE_BRANCH set via config, --dry-run must show --base and baseRefName.
cat > talos.pipeline.json <<'EOF'
{"base_branch": "main"}
EOF
out="$(bash "$VCS" --dry-run list-prs)"
assert_contains "$out" "--base" "list-prs passes --base flag when base_branch is configured"
assert_contains "$out" "baseRefName" "list-prs includes baseRefName in the --json field list"
rm talos.pipeline.json

# ── rerun-ci: re-runs only failed runs for the head SHA ───────────────────────
: > "$GH_LOG"
bash "$VCS" rerun-ci 9 >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "run rerun 111 --failed" "failed run re-run"
assert_not_contains "$log" "run rerun 112" "successful run left alone"

# ── Dry-run variants of the new verbs never hit gh ────────────────────────────
: > "$GH_LOG"
out="$(bash "$VCS" --dry-run find-pr 42; bash "$VCS" --dry-run check-pr-files 9; bash "$VCS" --dry-run rerun-ci 9)"
assert_contains "$out" "[dry-run]" "new verbs support --dry-run"
assert_not_contains "$(grep -v "repo view" "$GH_LOG")" "pr " "dry-run makes no pr/run gh calls"

# ── GitHub adapter: create-issue ─────────────────────────────────────────────
out="$(bash "$VCS" --dry-run create-issue "Fix the crash" /dev/null --label pipeline:ready)"
assert_contains "$out" "gh issue create" "create-issue dry-run contains 'gh issue create'"
assert_contains "$out" "--label" "create-issue dry-run includes --label arg"

: > "$GH_LOG"
printf '' > "$SANDBOX/body.md"
bash "$VCS" create-issue "Fix the crash" "$SANDBOX/body.md" --label pipeline:ready >/dev/null 2>&1
assert_contains "$(cat "$GH_LOG")" "issue create" "create-issue invokes gh with issue create"
assert_contains "$(cat "$GH_LOG")" "--label pipeline:ready" "create-issue passes label to gh"

# ── GitLab adapter: new verbs fail open with a warning ───────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab"}}
EOF
out="$(bash "$VCS" check-pr-files 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "gitlab: check-pr-files fails open (exit 0)"
assert_contains "$out" "not implemented for gitlab" "gitlab: fail-open warns the orchestrator"
rm talos.pipeline.json

# ── File-mode adapter: real markdown checklist manipulation ──────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "file", "file": {"source": {"path": "plan.md"}}}}
EOF
cat > plan.md <<'EOF'
# Plan

- [ ] Add login page
- [ ] Fix logout bug
- [x] Old finished item <!-- id: 1 -->
EOF

out="$(bash "$VCS" list-issues)"
assert_contains "$out" '"title": "Add login page"' "file: list-issues returns open items"
assert_not_contains "$out" "Old finished item" "file: checked items excluded"
assert_contains "$(cat plan.md)" "Add login page <!-- id: 2 -->" "file: ids auto-assigned"

out="$(bash "$VCS" view-issue 2)"
assert_contains "$out" "status: open" "file: view-issue shows status"

bash "$VCS" comment-issue 2 "validator: CONFIRMED" >/dev/null
assert_contains "$(cat plan.md)" "validator: CONFIRMED" "file: comment lands in detail block"

bash "$VCS" close-issue 2 "merged branch fix/login" >/dev/null
assert_contains "$(cat plan.md)" "- [x] Add login page" "file: close-issue checks the box"
assert_contains "$(cat plan.md)" "resolved: merged branch fix/login" "file: resolution note appended"

new_id="$(bash "$VCS" create-issue "Add dark mode" "$SANDBOX/body.md")"
assert_contains "$(cat plan.md)" "- [ ] Add dark mode <!-- id:" "file: create-issue appends checklist item"
# ID should be a number
assert_contains "$new_id" "" "file: create-issue prints the assigned id"
if ! printf '%s' "$new_id" | grep -qE '^[0-9]+$'; then
  fail "file: create-issue id is numeric"
else
  pass "file: create-issue id is numeric"
fi

out="$(bash "$VCS" create-pr branch t body 2>&1)"; rc=$?
assert_eq "0" "$rc" "file: create-pr is a safe no-op"

out="$(bash "$VCS" check-pr-files 1 2>&1)"; rc=$?
assert_eq "0" "$rc" "file: check-pr-files is a safe no-op"

finish
