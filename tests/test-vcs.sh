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

out="$(bash "$VCS" create-pr branch t body 2>&1)"; rc=$?
assert_eq "0" "$rc" "file: create-pr is a safe no-op"

out="$(bash "$VCS" check-pr-files 1 2>&1)"; rc=$?
assert_eq "0" "$rc" "file: check-pr-files is a safe no-op"

finish
