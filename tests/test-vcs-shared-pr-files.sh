#!/usr/bin/env bash
# test-vcs-shared-pr-files.sh — direct unit tests for the forbidden-files
# helper shared by _github and _github_api (#177 slice 3):
#   _vcs_shared_check_pr_files.
#
# These drive the shared function directly (not through either adapter's CLI
# verb) so a regression in the pattern/allow-list logic itself is caught here
# even if both adapters happened to still agree by coincidence. Every test can
# fail: disabling/breaking the shared helper causes RED. A separate CLI-level
# fixture at the bottom exercises the fetch-failure -> fail-closed contract,
# which lives at the call site (gh path), not inside the shared function.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── Load ONLY the shared-helper function definitions ──────────────────────────
# Never `source`/`.` the whole script: it has top-level arg-parsing/dispatch
# that ends in `exit`, which would terminate this test process. Extract the
# byte range from `_vcs_shared_read_attempt() {` up to (not including) the
# `_github() {` adapter that follows it -- pure function definitions, safe to
# eval into this shell. (Same anchors as test-vcs-shared-markers.sh and
# test-vcs-shared-approval-sha.sh; picks up every shared helper defined so
# far, including _vcs_shared_check_pr_files.)
_shared_src="$(awk '/^_github\(\) \{/{exit} /^_vcs_shared_read_attempt\(\) \{/{flag=1} flag{print}' "$VCS")"
if [ -z "$_shared_src" ]; then
  fail "setup: extracted shared-helper source is non-empty" "extraction produced nothing -- check the awk anchors against pipeline-vcs.sh"
fi
eval "$_shared_src"
if ! declare -F _vcs_shared_check_pr_files >/dev/null; then
  fail "setup: _vcs_shared_check_pr_files loaded" "function not defined after eval"
fi

# run_check <files-newline-list> [configured] [replace] [allow] — call the
# shared function directly with the given changed-file list on stdin and the
# three merge.forbidden_files* config values as env (mirrors what each
# adapter passes in after its own `cfg` lookup).
run_check() {
  local files="$1" configured="${2:-}" replace="${3:-}" allow="${4:-}"
  printf '%s\n' "$files" \
    | CONFIGURED="$configured" REPLACE="$replace" ALLOW="$allow" _vcs_shared_check_pr_files
}

# ═══════════════════════════════════════════════════════════════════════════
# clean list — no changed file matches an active (default) pattern
# ═══════════════════════════════════════════════════════════════════════════
out="$(run_check $'src/app.js\nREADME.md\ntests/app.test.js' 2>&1)"; rc=$?
assert_eq "0" "$rc" "clean list: exits 0"
assert_contains "$out" "no forbidden files" "clean list: reports no forbidden files"
assert_contains "$out" "talos:forbidden-files-active patterns=" "clean list: transparency marker present"

# ═══════════════════════════════════════════════════════════════════════════
# .env at repo root — matched by the built-in literal '.env' default
# ═══════════════════════════════════════════════════════════════════════════
out="$(run_check $'src/app.js\n.env' 2>&1)"; rc=$?
assert_eq "1" "$rc" ".env at root: exits 1"
assert_contains "$out" "FORBIDDEN FILES in PR" ".env at root: banner printed"
assert_contains "$out" ".env" ".env at root: path listed"
assert_not_contains "$out" "src/app.js" ".env at root: clean file not listed"

# ═══════════════════════════════════════════════════════════════════════════
# sub/.env — the same literal default matches on basename, not just root
# ═══════════════════════════════════════════════════════════════════════════
out="$(run_check $'src/app.js\nsub/.env' 2>&1)"; rc=$?
assert_eq "1" "$rc" "sub/.env: exits 1"
assert_contains "$out" "sub/.env" "sub/.env: nested path listed"

# ═══════════════════════════════════════════════════════════════════════════
# *.pem — a built-in wildcard default
# ═══════════════════════════════════════════════════════════════════════════
out="$(run_check $'src/app.js\ndeploy/server.pem' 2>&1)"; rc=$?
assert_eq "1" "$rc" "*.pem: exits 1"
assert_contains "$out" "deploy/server.pem" "*.pem: matched path listed"

# ═══════════════════════════════════════════════════════════════════════════
# config that ADDS a pattern — merge.forbidden_files unions with defaults
# (#61: never replaces them unless forbidden_files_replace: true)
# ═══════════════════════════════════════════════════════════════════════════
out="$(run_check $'src/app.js\ninfra/prod.tfstate\n.env' "*.tfstate" "" "" 2>&1)"; rc=$?
assert_eq "1" "$rc" "config adds pattern: exits 1"
assert_contains "$out" "infra/prod.tfstate" "config adds pattern: custom pattern enforced"
assert_contains "$out" ".env" "config adds pattern: built-in default still active (union, not replace)"
assert_not_contains "$out" "src/app.js" "config adds pattern: clean file not listed"

# ═══════════════════════════════════════════════════════════════════════════
# config that removes defaults — merge.forbidden_files_replace: true
# (current semantics: REPLACE fully suppresses the built-in defaults in favor
# of the configured pattern list alone; there is no selective-removal knob,
# only whole-list replace. This test preserves exactly that behaviour.)
# ═══════════════════════════════════════════════════════════════════════════
out="$(run_check $'infra/prod.tfstate\n.env' "*.tfstate" "true" "" 2>&1)"; rc=$?
assert_eq "1" "$rc" "config removes defaults: still exits 1 on the custom pattern"
assert_contains "$out" "infra/prod.tfstate" "config removes defaults: custom pattern enforced"
assert_not_contains "$out" ".env" "config removes defaults: built-in default suppressed"

err_only="$(run_check $'infra/prod.tfstate' "*.tfstate" "true" "" 2>&1 1>/dev/null)"
assert_contains "$err_only" "SUPPRESSED" "config removes defaults: stderr warning emitted"
out_marker="$(run_check $'infra/prod.tfstate' "*.tfstate" "true" "" 2>/dev/null)"
assert_contains "$out_marker" "talos:forbidden-files-defaults-replaced" "config removes defaults: stdout marker emitted"

# ═══════════════════════════════════════════════════════════════════════════
# empty file list — 0 changed files is a pass, not a fetch failure
# ═══════════════════════════════════════════════════════════════════════════
out="$(run_check "" 2>&1)"; rc=$?
assert_eq "0" "$rc" "empty file list: exits 0"
assert_contains "$out" "no forbidden files" "empty file list: reports no forbidden files"
assert_contains "$out" "talos:forbidden-files-active patterns=" "empty file list: transparency marker still present"

# ═══════════════════════════════════════════════════════════════════════════
# bad allow-list entry — fail-closed regardless of the file list
# ═══════════════════════════════════════════════════════════════════════════
out="$(run_check $'src/app.js' "" "" "*" 2>&1)"; rc=$?
assert_eq "1" "$rc" "bad allow entry '*': exits 1 (fail-closed on config, not just on a match)"
assert_contains "$out" "ERROR: merge.forbidden_files_allow entry" "bad allow entry '*': error message printed"

# ═══════════════════════════════════════════════════════════════════════════
# fetch failure -> fail closed (CLI level, gh adapter)
# The shared function only ever sees an already-fetched file list; the
# fetch-failure contract lives in the case arm that calls it. Before #177
# slice 3, the gh path used `gh pr view ... 2>/dev/null` with no `|| exit 1`
# guard: a failed fetch produced empty stdin, which the old inline python
# read as "0 changed files" and reported PASS -- a fail-OPEN bug. The
# refactor reuses pr-files' `gh api --paginate ... || exit 1` fetch, which
# is fail-closed: a failed fetch never reaches the shared function at all.
# ═══════════════════════════════════════════════════════════════════════════
out="$(STUB_GH_API_FAIL=pr-files bash "$VCS" check-pr-files 9 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "fetch failure: check-pr-files exits non-zero"
assert_eq "" "$out" "fetch failure: check-pr-files prints no partial/misleading stdout"
assert_not_contains "$out" "no forbidden files" "fetch failure: does NOT silently report a pass (fail-open regression guard)"

finish
