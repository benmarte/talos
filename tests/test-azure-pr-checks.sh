#!/usr/bin/env bash
# test-azure-pr-checks.sh -- the azure adapter's pr-checks-required (#318).
# Before this fix it was a stub that always exited 1, so Step 4 saw CI as
# failing on every pass (and called rerun-ci), and QA under qa_mode: ci never
# saw green. It now reads the PR's policy evaluations (`az repos pr policy
# list`) and maps each merge.required_checks name to one by display name.
# Uses the tests/stubs/az stub; no credentials needed.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}},
 "merge": {"required_checks": ["CI build", "Minimum number of reviewers"]}}
EOF

# One policy evaluation record: $1 = settings.displayName ("" = none),
# $2 = type.displayName, $3 = status.
_rec() {
  local settings='{}'
  [ -n "$1" ] && settings="{\"displayName\":\"$1\"}"
  printf '{"configuration":{"type":{"id":"0609b952-1397-4640-95ec-e00a01b2c241","displayName":"%s"},"settings":%s},"status":"%s","evaluationId":"00000001-0000-0000-0000-000000000000"}' \
    "$2" "$settings" "$3"
}
_reviewers() { printf '{"configuration":{"type":{"displayName":"Minimum number of reviewers"}},"status":"%s"}' "$1"; }

# ── approved ──────────────────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(STUB_AZURE_PR_POLICIES="[$(_rec "ci BUILD" Build approved),$(_reviewers approved),$(_rec "lint" Build rejected)]" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "approved: exits 0 when every required evaluation is approved, ignoring a non-required rejection"
assert_contains "$out" "pr-checks-required: all required checks passed: CI build, Minimum number of reviewers" \
  "approved: prints github's summary line"
assert_contains "$(cat "$GH_LOG")" "[repos] [pr] [policy] [list] [--id] [9]" \
  "approved: reads the PR's policy evaluations"

out="$(STUB_AZURE_PR_POLICIES="[$(_rec "" "CI Build" approved),$(_reviewers notApplicable)]" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "approved: falls back to type.displayName when settings.displayName is absent; notApplicable passes"

# ── rejected / broken ─────────────────────────────────────────────────────────
out="$(STUB_AZURE_PR_POLICIES="[$(_rec "CI build" Build rejected),$(_reviewers running)]" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "rejected: exits 1 when a required evaluation is rejected, even while another runs"
assert_contains "$out" "pr-checks-required: failed: CI build" "rejected: names the failed check"

STUB_AZURE_PR_POLICIES="[$(_rec "CI build" Build approved),$(_reviewers broken)]" \
  bash "$VCS" pr-checks-required 9 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "broken: exits 1 when a required evaluation is broken"

# ── running / queued ──────────────────────────────────────────────────────────
out="$(STUB_AZURE_PR_POLICIES="[$(_rec "CI build" Build running),$(_reviewers queued)]" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "2" "$rc" "running: exits 2 while a required evaluation is running or queued"
assert_contains "$out" "pr-checks-required: pending or missing: CI build, Minimum number of reviewers" \
  "running: names the pending checks"

# ── a required name that matches nothing ──────────────────────────────────────
out="$(STUB_AZURE_PR_POLICIES="[$(_rec "CI build" Build approved)]" \
  bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "2" "$rc" "missing: exits 2 when a required name matches no evaluation"
assert_contains "$out" "pending or missing: Minimum number of reviewers" "missing: names the absent check"

# ── fetch and parse failures fail closed ──────────────────────────────────────
out="$(STUB_AZURE_PR_POLICIES_FAIL=1 bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "fetch failure: exits 1, never 0"
assert_contains "$out" "could not list the policies of PR #9" "fetch failure: says why"

out="$(STUB_AZURE_PR_POLICIES='{"message":"TF401180"}' bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "parse failure: a non-list response exits 1"
assert_contains "$out" "could not parse the policies of PR #9" "parse failure: says why"

# ── invalid PR id ─────────────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(bash "$VCS" pr-checks-required '9/../x' 2>&1)"; rc=$?
assert_eq "1" "$rc" "invalid id: a non-numeric PR id exits 1"
assert_not_contains "$(cat "$GH_LOG")" "policy" "invalid id: never reaches az"

# ── empty merge.required_checks: same as github ───────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}
EOF
: > "$GH_LOG"
out="$(STUB_AZURE_PR_POLICIES="[$(_rec "CI build" Build approved)]" bash "$VCS" pr-checks-required 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "empty required_checks: exits 1, never a vacuous pass"
assert_contains "$out" "merge.required_checks is empty" "empty required_checks: prints github's message"
assert_not_contains "$(cat "$GH_LOG")" "policy" "empty required_checks: needs no policy fetch"

finish
