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

# ── SINGLE PR, NO SIBLINGS → exit 0 ──────────────────────────────────────────
# The current PR is the only PR open for issue 42 — no open siblings.
# This covers 10 of 10 current open issues; a regression here blocks everything.
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: only pr","headRefName":"fix/issue-42-guard","body":"Closes #42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "single PR no siblings: exits 0 (gate passes)"

# ── RULE 6 FINAL PR IS NOT BLOCKED: siblings merged, Closes #N → exit 0 ─────
# This is the critical Rule 6 scenario: prior Part of #N siblings are MERGED,
# not open. The open PR list is empty except for the current PR.
# A false positive here breaks every legitimate multi-PR completion.
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=99 \
  STUB_PR_LIST='[{"number":99,"state":"OPEN","title":"fix: final part","headRefName":"fix/issue-42-final","body":"Closes #42"}]' \
  bash "$VCS" check-closing-keyword 99 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "Rule 6 final PR: siblings merged, Closes #N exits 0"

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

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE-73: GH-N and full-issue-URL closing forms
# Each test is paired (positive + negative) and mutation-verified.
# ═══════════════════════════════════════════════════════════════════════════════

# ── GH-N form: positive — closes GH-57 matches issue 57 ──────────────────────
out="$(STUB_PR_BODY="closes GH-57" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-57","body":"closes GH-57"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "GH-N: closes GH-57 DOES match issue 57 with open sibling (must exit 1)"

# ── GH-N form: negative — closes GH-571 must NOT match issue 57 ──────────────
# Without (?!\d) guard, GH-57 inside GH-571 would fire — this is the collision.
out="$(STUB_PR_BODY="closes GH-571" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-571","body":"closes GH-571"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "GH-N right-guard: closes GH-571 does NOT match issue 57 (must exit 0)"

# ── GH-N form: case-insensitive — gh-57 matches issue 57 ─────────────────────
out="$(STUB_PR_BODY="closes gh-57" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-57","body":"closes gh-57"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "GH-N case: closes gh-57 (lowercase) DOES match issue 57 (must exit 1)"

# ── GH-N form: left-guard — XGH-57 must NOT match issue 57 ──────────────────
# Without (?<![0-9]) left guard, a prefix digit could accidentally anchor.
# We use a non-digit prefix letter X here; the spec checks digit prefix specifically,
# but the guard is (?<![0-9]) so a letter prefix like X is irrelevant and won't be
# blocked. The meaningful guard test is that a digit prefix (e.g. "1GH-57") does
# not collide — tested via the presence of the left guard in the source (inspection).
# For blackbox testing, we confirm the standard "XGH-57" form does not match:
out="$(STUB_PR_BODY="closes XGH-57" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-57","body":"closes XGH-57"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "GH-N left-guard: closes XGH-57 does NOT match issue 57 (must exit 0)"

# ── URL form: positive — full github issue URL matches issue 57 (own repo) ────
# Use stub repo acme/widget — the URL must reference the current repo to match.
out="$(STUB_PR_BODY="Closes https://github.com/acme/widget/issues/57" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-57","body":"Closes https://github.com/acme/widget/issues/57"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "URL form: Closes https://github.com/acme/widget/issues/57 DOES match issue 57 (must exit 1)"

# ── URL form: negative — URL for issue 571 does NOT match issue 57 ────────────
out="$(STUB_PR_BODY="Closes https://github.com/acme/widget/issues/571" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-571","body":"Closes https://github.com/acme/widget/issues/571"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "URL right-guard: Closes .../issues/571 does NOT match issue 57 (must exit 0)"

# ── URL form: fragment — #issuecomment-999 is not a digit, so (?!\d) passes ──
out="$(STUB_PR_BODY="Closes https://github.com/acme/widget/issues/57#issuecomment-999" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-57","body":"Closes https://github.com/acme/widget/issues/57#issuecomment-999"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "URL fragment: Closes .../issues/57#issuecomment-999 DOES match issue 57 (must exit 1)"

# ── URL form: trailing slash ──────────────────────────────────────────────────
out="$(STUB_PR_BODY="Closes https://github.com/acme/widget/issues/57/" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-57","body":"Closes https://github.com/acme/widget/issues/57/"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "URL trailing-slash: Closes .../issues/57/ DOES match issue 57 (must exit 1)"

# ── URL form: query string ────────────────────────────────────────────────────
out="$(STUB_PR_BODY="Closes https://github.com/acme/widget/issues/57?tab=timeline" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-57","body":"Closes https://github.com/acme/widget/issues/57?tab=timeline"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "URL query-string: Closes .../issues/57?tab=timeline DOES match issue 57 (must exit 1)"

# ── Colon form: Closes: #57 must NOT match — colon form is excluded ───────────
out="$(STUB_PR_BODY="Closes: #57" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-57","body":"Closes: #57"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "colon form: Closes: #57 does NOT trigger the gate (must exit 0)"

# ── Regression: existing #N and owner/repo#N forms still work ─────────────────
out="$(STUB_PR_BODY="Closes #57" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-57","body":"Closes #57"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "regression: Closes #57 still DOES match issue 57 (must exit 1)"

out="$(STUB_PR_BODY="Closes #571" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-571","body":"Closes #571"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "regression: Closes #571 still does NOT match issue 57 (must exit 0)"

out="$(STUB_PR_BODY="Fixes acme/widget#57" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-57","body":"Fixes acme/widget#57"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "regression: Fixes acme/widget#57 still DOES match issue 57 (must exit 1)"

out="$(STUB_PR_BODY="Fixes acme/widget#571" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-571","body":"Fixes acme/widget#571"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-57-b","body":"Part of #57"}]' \
  bash "$VCS" check-closing-keyword 9 57 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "regression: Fixes acme/widget#571 still does NOT match issue 57 (must exit 0)"

# ═══════════════════════════════════════════════════════════════════════════════
# ISSUE-88: Repo-scoped closing-keyword matching
# All tests use issue 76, STUB_REPO=acme/widget (the default stub repo).
# MATCH rows include an open sibling so a wrong match causes exit 1 (discriminating).
# NO MATCH rows include a sibling so a wrong match would also exit 1 (not vacuous).
# ═══════════════════════════════════════════════════════════════════════════════

# ── A1. Bare #N — implicit current repo; must still match (regression guard) ──
out="$(STUB_PR_BODY="Fixes #76" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-76-a","body":"Fixes #76"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-76-b","body":"Part of #76"}]' \
  bash "$VCS" check-closing-keyword 9 76 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "#N bare: Fixes #76 matches own issue with open sibling (must exit 1)"

# ── A2. Own-repo URL — must match ─────────────────────────────────────────────
out="$(STUB_PR_BODY="Fixes https://github.com/acme/widget/issues/76" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-76-a","body":"Fixes https://github.com/acme/widget/issues/76"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-76-b","body":"Part of #76"}]' \
  bash "$VCS" check-closing-keyword 9 76 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "URL own-repo: Fixes https://github.com/acme/widget/issues/76 matches (must exit 1)"

# ── A3. Foreign-repo URL — must NOT match (the core bug being fixed) ──────────
# Open sibling exists so a wrong MATCH would exit 1, making this non-vacuous.
out="$(STUB_PR_BODY="Fixes https://github.com/other-owner/other-repo/issues/76" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-76-a","body":"Fixes https://github.com/other-owner/other-repo/issues/76"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-76-b","body":"Part of #76"}]' \
  bash "$VCS" check-closing-keyword 9 76 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "URL foreign-repo: Fixes https://github.com/other-owner/other-repo/issues/76 does NOT match (must exit 0)"

# ── A4. Own-repo shorthand (owner/repo#N) — must match ────────────────────────
out="$(STUB_PR_BODY="Fixes acme/widget#76" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-76-a","body":"Fixes acme/widget#76"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-76-b","body":"Part of #76"}]' \
  bash "$VCS" check-closing-keyword 9 76 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "owner/repo#N own-repo: Fixes acme/widget#76 matches (must exit 1)"

# ── A5. Foreign shorthand (owner/repo#N) — must NOT match ─────────────────────
# Open sibling exists so a wrong MATCH would exit 1, making this non-vacuous.
out="$(STUB_PR_BODY="Fixes other-owner/other-repo#76" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-76-a","body":"Fixes other-owner/other-repo#76"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-76-b","body":"Part of #76"}]' \
  bash "$VCS" check-closing-keyword 9 76 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "owner/repo#N foreign: Fixes other-owner/other-repo#76 does NOT match (must exit 0)"

# ── A6. Right-guard: #760 does NOT match issue 76 ─────────────────────────────
# Sibling present so a wrong MATCH would cause exit 1.
out="$(STUB_PR_BODY="Fixes #760" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-760","body":"Fixes #760"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-76-b","body":"Part of #76"}]' \
  bash "$VCS" check-closing-keyword 9 76 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "right-guard issue-88: Fixes #760 does NOT match issue 76 (must exit 0)"

# ── A7. Left-boundary: #7 does NOT match issue 76 ─────────────────────────────
out="$(STUB_PR_BODY="Fixes #7" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-7","body":"Fixes #7"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-76-b","body":"Part of #76"}]' \
  bash "$VCS" check-closing-keyword 9 76 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "left-boundary issue-88: Fixes #7 does NOT match issue 76 (must exit 0)"

# ── B. Case-insensitive own-repo match ────────────────────────────────────────
# URL with different case for owner/repo — must match (case-insensitive).
out="$(STUB_PR_BODY="Fixes https://github.com/Acme/Widget/issues/76" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-76-a","body":"Fixes https://github.com/Acme/Widget/issues/76"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-76-b","body":"Part of #76"}]' \
  bash "$VCS" check-closing-keyword 9 76 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "URL case-insensitive: Fixes .../Acme/Widget/issues/76 matches (must exit 1)"

# Shorthand with different case — must match (case-insensitive).
out="$(STUB_PR_BODY="Fixes ACME/WIDGET#76" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-76-a","body":"Fixes ACME/WIDGET#76"},{"number":8,"state":"OPEN","title":"sibling","headRefName":"fix/issue-76-b","body":"Part of #76"}]' \
  bash "$VCS" check-closing-keyword 9 76 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "shorthand case-insensitive: Fixes ACME/WIDGET#76 matches (must exit 1)"

# ── C. EXIT-ZERO PROOF: Fixes #76 with no open siblings exits 0 ───────────────
# This is the most common real-world case. A crash or false-positive here would
# block everything. Prove the gate does not crash and exits cleanly when healthy.
out="$(STUB_PR_BODY="Fixes #76" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix","headRefName":"fix/issue-76-a","body":"Fixes #76"}]' \
  bash "$VCS" check-closing-keyword 9 76 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "exit-zero proof: Fixes #76 with no open siblings exits 0 (gate passes)"

# ── D. Repo-resolution-failure: REPO empty → fail-open with fixed-literal marker
# Override both cfg and gh to return nothing so $REPO stays empty.
cat > "$SANDBOX/norepo_gh" <<'GHSCRIPT'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "repo view --json nameWithOwner"*)
    # Return nothing — simulate unresolvable repo
    exit 1 ;;
  "repo view --json defaultBranchRef"*)
    printf 'main\n' ;;
  "repo view --json url"*)
    exit 1 ;;
  "repo view --json owner"*)
    exit 1 ;;
  *)
    ;;
esac
exit 0
GHSCRIPT
chmod +x "$SANDBOX/norepo_gh"
mkdir -p "$SANDBOX/norepostubs"
cp "$SANDBOX/norepo_gh" "$SANDBOX/norepostubs/gh"
chmod +x "$SANDBOX/norepostubs/gh"

# Also need a cfg stub that returns empty for vcs.repo.
# pipeline-vcs.sh reads cfg vcs.repo first; if empty it falls back to gh/git.
# With our norepo_gh, gh repo view also fails. git remote get-url would still
# work unless we override it. Provide a fake git in the stubs dir that returns
# nothing for remote get-url, to ensure REPO stays empty.
cat > "$SANDBOX/norepostubs/git" <<'GITSCRIPT'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "remote get-url origin")
    exit 1 ;;
  *)
    command git "$@" ;;
esac
GITSCRIPT
chmod +x "$SANDBOX/norepostubs/git"

stdout_out="$(PATH="$SANDBOX/norepostubs:$PATH" \
  bash "$VCS" check-closing-keyword 9 76 2>/dev/null)"; rc=$?
assert_exit_code 0 "$rc" "repo-unresolved: exits 0 (fail open)"
assert_contains "$stdout_out" "talos:closing-keyword-unverified" "repo-unresolved: marker emitted on stdout"
assert_contains "$stdout_out" "reason=repo-unresolved" "repo-unresolved: fixed-literal reason in marker"

# =============================================================================
# ISSUE-91: Repo-scoped sibling-scan body_match
# All tests use issue 42, STUB_REPO=acme/widget (the default stub repo).
# The current PR (#9) carries "Closes #42".
# =============================================================================

# -- S1. Foreign repo in sibling body -- must NOT be counted (the bug) --------
# Sibling PR #8 body: "Fixes other-owner/other-repo#42" — foreign-repo reference.
# With the current unscoped regex this counts as a sibling and exits 1.
# After the fix it must NOT match, so exit 0.
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: curr","headRefName":"fix/issue-42-a","body":"Closes #42"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/other-b","body":"Fixes other-owner/other-repo#42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "issue-91 S1: foreign other-owner/other-repo#42 in sibling body is NOT counted (must exit 0)"

# -- S2. Bare #N in sibling body without keyword -- MUST be counted -----------
# Sibling PR #8 body: "Part of #42" — bare #N with no closing keyword.
# This is the guard's core purpose; must NOT be narrowed away by the scoping fix.
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: curr","headRefName":"fix/issue-42-a","body":"Closes #42"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/other-b","body":"Part of #42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "issue-91 S2: bare #42 in sibling body (no keyword) IS counted (must exit 1)"
assert_contains "$out" "#8" "issue-91 S2: sibling PR #8 named in diagnostic"

# -- S3. Own-repo qualified form in sibling body -- MUST be counted -----------
# Sibling PR #8 body: "See acme/widget#42" — own-repo qualified reference.
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: curr","headRefName":"fix/issue-42-a","body":"Closes #42"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/other-b","body":"See acme/widget#42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "issue-91 S3: own-repo acme/widget#42 in sibling body IS counted (must exit 1)"
assert_contains "$out" "#8" "issue-91 S3: sibling PR #8 named in diagnostic"

# -- S4. Branch-name matcher unchanged ----------------------------------------
# A sibling with a fix/issue-42-slug branch is still detected by branch match
# regardless of the body content — branch matching is local and unchanged.
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: curr","headRefName":"fix/issue-42-a","body":"Closes #42"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/issue-42-b","body":"no reference here"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "issue-91 S4: branch fix/issue-42-b still fires (branch matcher unchanged, must exit 1)"
assert_contains "$out" "#8" "issue-91 S4: sibling PR #8 named via branch match"

# -- S5. Genuine sibling block still exits 1 ----------------------------------
# Confirm the guard is not silently disabled by the scoping fix.
# Sibling body "Related to #42" is a bare reference — must still block.
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: curr","headRefName":"fix/issue-42-a","body":"Closes #42"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/other-b","body":"Related to #42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "issue-91 S5: genuine sibling with bare #42 still exits 1 (guard not disabled)"

# -- S6. Exit-zero proof: closing keyword + no open siblings ------------------
# A PR with a proper closing keyword and no open siblings must exit 0.
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: curr","headRefName":"fix/issue-42-a","body":"Closes #42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "issue-91 S6: closing keyword with no open siblings exits 0"

# ── issue-113: GH-N and URL forms in sibling body ────────────────────────────
# Mutation that makes these tests fail: remove gh_pat and url_pat from body_pat
# — a sibling using GH-42 or the full URL silently bypasses the guard.

# -- 113-G1. GH-42 in sibling body IS counted (exits 1) ----------------------
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: curr","headRefName":"fix/issue-42-a","body":"Closes #42"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/other-b","body":"Part of GH-42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "issue-113 G1: GH-42 in sibling body IS counted (must exit 1)"
assert_contains "$out" "#8" "issue-113 G1: sibling PR #8 named in diagnostic"

# -- 113-G2. GH-N case variant (gh-42) IS counted ----------------------------
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: curr","headRefName":"fix/issue-42-a","body":"Closes #42"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/other-b","body":"Related to gh-42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "issue-113 G2: gh-42 (lowercase) in sibling body IS counted (case-insensitive)"

# -- 113-G3. GH-420 does NOT match issue 42 (right boundary guard) ------------
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: curr","headRefName":"fix/issue-42-a","body":"Closes #42"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/other-b","body":"See GH-420 for context"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "issue-113 G3: GH-420 does NOT match issue 42 (right-digit guard)"

# -- 113-G4. GH-4 does NOT match issue 42 (?!\d suffix guard) ----------------
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: curr","headRefName":"fix/issue-42-a","body":"Closes #42"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/other-b","body":"Related to GH-4"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "issue-113 G4: GH-4 does NOT match issue 42 (different issue number)"

# -- 113-U1. Own-repo issue URL in sibling body IS counted (exits 1) ----------
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: curr","headRefName":"fix/issue-42-a","body":"Closes #42"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/other-b","body":"Part of https://github.com/acme/widget/issues/42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "issue-113 U1: own-repo URL in sibling body IS counted (must exit 1)"
assert_contains "$out" "#8" "issue-113 U1: sibling PR #8 named in diagnostic"

# -- 113-U2. Foreign-repo URL is NOT counted (exits 0) -----------------------
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: curr","headRefName":"fix/issue-42-a","body":"Closes #42"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/other-b","body":"See https://github.com/other-owner/other-repo/issues/42"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "issue-113 U2: foreign-repo URL in sibling body is NOT counted (must exit 0)"

# -- 113-U3. Own-repo URL with wrong issue number does NOT match (exits 0) ----
out="$(STUB_PR_BODY="Closes #42" STUB_PR_NUMBER=9 \
  STUB_PR_LIST='[{"number":9,"state":"OPEN","title":"fix: curr","headRefName":"fix/issue-42-a","body":"Closes #42"},{"number":8,"state":"OPEN","title":"fix: sibling","headRefName":"fix/other-b","body":"Part of https://github.com/acme/widget/issues/420"}]' \
  bash "$VCS" check-closing-keyword 9 42 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "issue-113 U3: own-repo URL /issues/420 does NOT match issue 42 (right-digit guard)"

finish
