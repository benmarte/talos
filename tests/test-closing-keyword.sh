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

finish
