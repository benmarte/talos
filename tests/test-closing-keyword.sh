#!/usr/bin/env bash
# Tests for check-closing-keyword verb in pipeline-vcs.sh.
# Covers Rule 6 (multi-PR issues): a closing keyword is only blocked when
# other PRs referencing the same issue are still OPEN.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── Dry-run: verb is recognised ───────────────────────────────────────────────
out="$(bash "$VCS" --dry-run check-closing-keyword 9 42)"
assert_contains "$out" "[dry-run]" "check-closing-keyword dry-run produces output"
assert_contains "$out" "check-closing-keyword" "dry-run names the verb"

# ── No closing keyword → immediate exit 0 ────────────────────────────────────
# PR body has "Part of #42" only — no closing keyword.
out="$(STUB_PR_BODY="Part of #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: first slice","headRefName":"fix/issue-42-part1","body":"Part of #42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "no closing keyword: exits 0 immediately"
assert_not_contains "$out" "blocked" "no closing keyword: no blocked message"

# ── SINGLE PR, NO SIBLINGS → exit 0 ──────────────────────────────────────────
# The current PR is the only PR open for issue 42 — no open siblings.
# This covers 10 of 10 current open issues; a regression here blocks everything.
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: only pr","headRefName":"fix/issue-42-guard","body":"Closes #42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "single PR no siblings: exits 0 (gate passes)"
assert_not_contains "$out" "blocked" "single PR: no blocked message"

# ── RULE 6 FINAL PR IS NOT BLOCKED: siblings merged, Closes #N → exit 0 ─────
# This is the critical Rule 6 scenario: prior Part of #N siblings are MERGED,
# not open. The open PR list is empty except for the current PR.
# A false positive here breaks every legitimate multi-PR completion.
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=99 \
  STUB_PR_LIST='[{"number":99,"state":"OPEN","title":"fix: final part","headRefName":"fix/issue-42-final","body":"Closes #42"}]' \
  bash "$VCS" check-closing-keyword 99 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "Rule 6 final PR: siblings merged, Closes #N exits 0"
assert_not_contains "$out" "blocked" "Rule 6 final PR: not blocked"

# ── OPEN SIBLING BLOCKS: another PR for #42 still open → exit 1 ───────────
# PR #9 says "Closes #42"; PR #7 is another open PR referencing #42.
# The gate must exit 1 and name the sibling.
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: part one","headRefName":"fix/issue-42-part1","body":"Closes #42"},{"number":7,"state":"OPEN","title":"fix: part two","headRefName":"fix/issue-42-part2","body":"Part of #42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "open sibling: exits 1"
assert_contains "$out" "#7" "open sibling: diagnostic names sibling PR #7"

# ── KEYWORD VARIANTS: all closing keywords parse case-insensitively ───────────
for kw in "Closes" "closes" "CLOSES" "Close" "Closed" "Fixes" "fixes" "Fix" "Fixed" "Resolves" "resolves" "Resolve" "Resolved"; do
  body="$kw #42"
  out="$(STUB_PR_BODY="$body" STUB_PR_NUMBER=9 \
    STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"test","headRefName":"fix/issue-42","body":"test"}]' \
    bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
  assert_exit_code 0 "$rc" "keyword variant '$kw': exits 0 when no open siblings"
done

# ── REFERENCE FORMS: #N, repo#N, owner/repo#N all parse ─────────────────────
out="$(STUB_PR_BODY="Closes acme/widget#42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"t","headRefName":"fix/issue-42","body":"t"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "owner/repo#N form: parsed, exits 0 with no open siblings"

out="$(STUB_PR_BODY="Closes widget#42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"t","headRefName":"fix/issue-42","body":"t"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "repo#N form: parsed, exits 0 with no open siblings"

# ── owner/repo#N with open sibling → exit 1 ─────────────────────────────────
out="$(STUB_PR_BODY="Closes acme/widget#42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"first","headRefName":"fix/issue-42-a","body":"Closes acme/widget#42"},{"number":8,"state":"OPEN","title":"second","headRefName":"fix/issue-42-b","body":"Part of #42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "owner/repo#N with open sibling: exits 1"
assert_contains "$out" "#8" "owner/repo#N sibling: names PR #8"

# ── FAIL-OPEN: PR body cannot be fetched → exit 0 + stdout marker ─────────
# Simulate fetch failure by making the PR number resolve to empty JSON.
# We do this by pointing the stub at an empty response via STUB_PR_NUMBER=""
# and relying on the stub returning '{"number":,"body":""}' which won't parse.
# Instead, override via a wrapper script.
cat > "$SANDBOX/bad_gh" <<'GHSCRIPT'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
case "$args" in
  "pr view "*"--json number,body"*)
    # Simulate a failed fetch — print nothing
    exit 1 ;;
  "repo view --json nameWithOwner"*)
    printf 'acme/widget\n' ;;
  "repo view --json defaultBranchRef"*)
    printf 'main\n' ;;
  *)
    ;;
esac
exit 0
GHSCRIPT
chmod +x "$SANDBOX/bad_gh"

# Use the custom gh (PATH already has stubs first; temporarily override with a
# wrapper that shadows gh for just this test).
# We can't easily override individual stubs so we copy bad_gh as gh in a subdir.
mkdir -p "$SANDBOX/badstubs"
cp "$SANDBOX/bad_gh" "$SANDBOX/badstubs/gh"
chmod +x "$SANDBOX/badstubs/gh"

out="$(PATH="$SANDBOX/badstubs:$PATH" GH_LOG="$SANDBOX/gh.log" \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
# The full output is both stdout and stderr (merged above).  Split for clarity.
stdout_out="$(PATH="$SANDBOX/badstubs:$PATH" GH_LOG="$SANDBOX/gh.log" \
  bash "$VCS" check-closing-keyword 9 42 2>/dev/null)"
assert_exit_code 0 "$rc" "fail-open: PR fetch failure exits 0"
assert_contains "$stdout_out" "talos:closing-keyword-unverified" "fail-open: marker emitted on stdout"
assert_contains "$stdout_out" "pr-fetch-failed" "fail-open: reason=pr-fetch-failed in marker"

# ── FAIL-OPEN: sibling list cannot be fetched → exit 0 + stdout marker ───────
# PR body fetch succeeds (has Closes #42) but pr list returns empty.
cat > "$SANDBOX/nolist_gh" <<'GHSCRIPT'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
case "$args" in
  "pr view "*"--json number,body"*)
    printf '{"number":9,"body":"Closes #42"}\n' ;;
  "pr list --state open"*)
    # Simulate failure — return nothing
    exit 1 ;;
  "repo view --json nameWithOwner"*)
    printf 'acme/widget\n' ;;
  "repo view --json defaultBranchRef"*)
    printf 'main\n' ;;
  *)
    ;;
esac
exit 0
GHSCRIPT
chmod +x "$SANDBOX/nolist_gh"
mkdir -p "$SANDBOX/noliststubs"
cp "$SANDBOX/nolist_gh" "$SANDBOX/noliststubs/gh"
chmod +x "$SANDBOX/noliststubs/gh"

stdout_out="$(PATH="$SANDBOX/noliststubs:$PATH" GH_LOG="$SANDBOX/gh.log" \
  bash "$VCS" check-closing-keyword 9 42 2>/dev/null)"; rc=$?
assert_exit_code 0 "$rc" "fail-open sibling fetch: exits 0"
assert_contains "$stdout_out" "talos:closing-keyword-unverified" "fail-open sibling fetch: marker on stdout"
assert_contains "$stdout_out" "sibling-fetch-failed" "fail-open sibling fetch: reason=sibling-fetch-failed"

# ── view-pr now includes body in --json fields ────────────────────────────────
out="$(bash "$VCS" --dry-run view-pr 9)"
assert_contains "$out" "body" "view-pr dry-run: body included in --json fields"

# ── file provider: check-closing-keyword is a no-op ─────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "file", "file": {"source": {"path": "plan.md"}}}}
EOF
cat > plan.md <<'EOF'
# Plan
- [ ] Task one
EOF
out="$(bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "file mode: check-closing-keyword is a no-op exit 0"
assert_contains "$out" "not applicable in file mode" "file mode: informative message"
rm talos.pipeline.json plan.md

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE-NUMBER COLLISION TESTS (fix for #57 — anchored matching)
# Each test is constructed so it will RED if the guard is removed.
# ═══════════════════════════════════════════════════════════════════════════════

# ── Closing-keyword regex: #571 must NOT match issue 57 ───────────────────────
# QA-failed case: a PR body saying "Closes #571" must exit 0 when no open PR for
# issue 57 exists except the current PR (so no siblings).
# An OPEN sibling PR #8 is included so that if (?!\d) is absent and "Closes #571"
# wrongly fires has_closing, the gate will find the sibling and exit 1 — making
# this assertion discriminating rather than vacuous.
out="$(STUB_PR_BODY="Closes #571" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: unrelated","headRefName":"fix/issue-571-foo","body":"Closes #571"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/issue-57-other","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "collision: Closes #571 does NOT match issue 57 (must exit 0)"
assert_not_contains "$out" "blocked" "collision: Closes #571 no blocked message for issue 57"

# ── Closing-keyword regex: #57 still DOES match issue 57 ─────────────────────
out="$(STUB_PR_BODY="Closes #57" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: part","headRefName":"fix/issue-57-slug","body":"Closes #57"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/issue-57-other","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "collision: Closes #57 DOES match issue 57 with open sibling (must exit 1)"

# ── Closing-keyword: #7 does not match issue 5 ───────────────────────────────
out="$(STUB_PR_BODY="Closes #7" STUB_PR_NUMBER=3 \
  STUB_PR_LIST='[{"number":3,"state":"OPEN","title":"t","headRefName":"fix/issue-7-foo","body":"Closes #7"}]' \
  bash "$VCS" check-closing-keyword 3 5 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "collision: Closes #7 does NOT match issue 5 (must exit 0)"

# ── Closing-keyword: #5 matches issue 5, #57 does not match issue 5 ──────────
out="$(STUB_PR_BODY="Closes #57" STUB_PR_NUMBER=3 \
  STUB_PR_LIST='[{"number":3,"state":"OPEN","title":"t","headRefName":"fix/issue-57-bar","body":"Closes #57"}]' \
  bash "$VCS" check-closing-keyword 3 5 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "collision: Closes #57 does NOT match issue 5 (must exit 0)"

# ── Sibling check: fix/issue-571-x is NOT a sibling of issue 57 ──────────────
# PR 9 says "Closes #57"; PR 8 is on branch fix/issue-571-foo — NOT a sibling.
out="$(STUB_PR_BODY="Closes #57" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: final","headRefName":"fix/issue-57-final","body":"Closes #57"},{"number":8,"state":"OPEN","title":"fix: other","headRefName":"fix/issue-571-foo","body":"Other work"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "sibling-collision: fix/issue-571-foo is NOT a sibling of issue 57 (must exit 0)"
assert_not_contains "$out" "blocked" "sibling-collision: no blocked message for issue-571 branch"

# ── Sibling check: fix/issue-57-x IS a sibling of issue 57 ──────────────────
out="$(STUB_PR_BODY="Closes #57" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: final","headRefName":"fix/issue-57-final","body":"Closes #57"},{"number":8,"state":"OPEN","title":"fix: part","headRefName":"fix/issue-57-part1","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "sibling-collision: fix/issue-57-part1 IS a sibling of issue 57 (must exit 1)"
assert_contains "$out" "#8" "sibling-collision: sibling PR #8 named in diagnostic"

# ── find-pr: fix/issue-571-x is NOT returned by find-pr 57 ──────────────────
# Regression guard: find-pr 57 must not return a PR on branch fix/issue-571-x
out="$(STUB_PR_LIST='[{"number":10,"state":"OPEN","title":"fix: 571","headRefName":"fix/issue-571-foo","body":"Some work"}]' \
  bash "$VCS" find-pr 57 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "find-pr: exits 0 when fix/issue-571 branch present for find-pr 57"
assert_not_contains "$out" "571" "find-pr 57: fix/issue-571-foo branch must NOT be returned"
assert_not_contains "$out" "fix/issue-571-foo" "find-pr 57: PR #10 (issue-571) must not appear"

# ── find-pr: fix/issue-57-x IS returned by find-pr 57 ───────────────────────
out="$(STUB_PR_LIST='[{"number":11,"state":"OPEN","title":"fix: 57","headRefName":"fix/issue-57-slug","body":"Closes #57"}]' \
  bash "$VCS" find-pr 57 2>&1)"
assert_contains "$out" "fix/issue-57-slug" "find-pr 57: fix/issue-57-slug IS returned"

# ── find-pr: fix/issue-71-x is NOT returned by find-pr 7 ────────────────────
out="$(STUB_PR_LIST='[{"number":12,"state":"OPEN","title":"fix: 71","headRefName":"fix/issue-71-foo","body":"Work on 71"}]' \
  bash "$VCS" find-pr 7 2>&1)"
# Assert on headRefName, not "number":12 — json.dumps emits "number": 12 (with space)
# so the no-space needle never matches, making it vacuous. headRefName is unambiguous.
assert_not_contains "$out" "fix/issue-71-foo" "find-pr 7: fix/issue-71-foo must NOT be returned"

# ── find-pr: fix/issue-7-x IS returned by find-pr 7 ─────────────────────────
out="$(STUB_PR_LIST='[{"number":13,"state":"OPEN","title":"fix: 7","headRefName":"fix/issue-7-slug","body":"Closes #7"}]' \
  bash "$VCS" find-pr 7 2>&1)"
assert_contains "$out" "fix/issue-7-slug" "find-pr 7: fix/issue-7-slug IS returned"

# ── find-pr body matching: #71 in body NOT returned by find-pr 7 ─────────────
out="$(STUB_PR_LIST='[{"number":14,"state":"OPEN","title":"fix: seventy-one","headRefName":"feature/xyz","body":"Closes #71"}]' \
  bash "$VCS" find-pr 7 2>&1)"
# Assert on title text, not "number":14 — json.dumps emits "number": 14 (with space)
# so the no-space needle never matches, making it vacuous. Title is unambiguous here.
assert_not_contains "$out" "seventy-one" "find-pr 7: PR with body #71 must NOT be returned"

# ── find-pr body matching: #7 in body IS returned by find-pr 7 ───────────────
out="$(STUB_PR_LIST='[{"number":15,"state":"OPEN","title":"fix: seven","headRefName":"feature/abc","body":"Closes #7"}]' \
  bash "$VCS" find-pr 7 2>&1)"
assert_contains "$out" "fix: seven" "find-pr 7: PR with body #7 IS returned"

finish
