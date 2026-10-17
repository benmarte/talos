#!/usr/bin/env bash
# test-conflict-files-gitlab-azure-766.sh -- `conflict-files` on gitlab and
# azure (#766, slice 7 of #753). Same contract as github (tests/test-conflict-
# files.sh): paths one per line, exit 0 clean or conflicting, 2 when the PR
# head cannot be determined, 1 for bad arguments. gitlab fetches the head from
# refs/merge-requests/<iid>/head; azure resolves the source branch with the az
# stub's `repos pr show --query sourceRefName` and fetches refs/heads/<it>.
# A local bare repo is origin (no network); the merge is a real git merge.
# Tests are named by the spec's criterion id.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

git config user.email "test@talos.invalid"
git config user.name "talos-test"

UPSTREAM_PARENT="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-cf766-origin.XXXXXX")" || exit 1
UPSTREAM="$UPSTREAM_PARENT/upstream.git"
git init -q --bare "$UPSTREAM"
trap '_is_trap_owner && rm -rf "$SANDBOX" "$UPSTREAM_PARENT"' EXIT
git remote set-url origin "$UPSTREAM"

printf 'base\n' > shared.txt
git add shared.txt
git commit -q -m "seed"
git branch -M main
git push -q origin main

# A conflicting head and a clean head, both branched from the seed commit.
git checkout -q -b head-conflict
printf 'head side\n' > shared.txt
git commit -aqm "head: edit shared.txt"
git push -q origin head-conflict
git push -q origin head-conflict:refs/merge-requests/42/head

git checkout -q main
git checkout -q -b head-clean
printf 'clean\n' > other.txt
git add other.txt
git commit -qm "head: add other.txt"
git push -q origin head-clean
git push -q origin head-clean:refs/merge-requests/43/head

git checkout -q main
printf 'main side\n' > shared.txt
git commit -aqm "base: edit shared.txt"
git push -q origin main
git branch -D head-conflict head-clean >/dev/null 2>&1 || true

use_provider() {
  case "$1" in
    gitlab) cat > talos.pipeline.json <<'TALOS_cf766gitlab'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"}, "base_branch": "main"}
TALOS_cf766gitlab
    ;;
    azure) cat > talos.pipeline.json <<'TALOS_cf766azure'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}, "base_branch": "main"}
TALOS_cf766azure
    ;;
  esac
}

# ── AC1: gitlab ──────────────────────────────────────────────────────────────
use_provider gitlab
out="$(bash "$VCS" conflict-files 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC1 gitlab conflict-files exits 0 for a conflicting MR"
assert_eq "shared.txt" "$out" "AC1 gitlab conflict-files prints the conflicting path"
out="$(bash "$VCS" conflict-files 43 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC1 gitlab conflict-files exits 0 for a clean MR"
assert_eq "" "$out" "AC1 gitlab conflict-files prints nothing for a clean MR"
out="$(bash "$VCS" --dry-run conflict-files 42 2>&1)"
assert_contains "$out" "refs/merge-requests/42/head" "AC1 gitlab dry-run names the merge-request ref"

# ── AC2: azure ───────────────────────────────────────────────────────────────
use_provider azure
out="$(STUB_AZURE_PR_SOURCE=head-conflict bash "$VCS" conflict-files 42 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC2 azure conflict-files exits 0 for a conflicting PR"
assert_eq "shared.txt" "$out" "AC2 azure conflict-files prints the conflicting path"
out="$(STUB_AZURE_PR_SOURCE=head-clean bash "$VCS" conflict-files 43 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC2 azure conflict-files exits 0 for a clean PR"
assert_eq "" "$out" "AC2 azure conflict-files prints nothing for a clean PR"
out="$(STUB_AZURE_PR_SOURCE=head-conflict bash "$VCS" --dry-run conflict-files 42 2>&1)"
assert_contains "$out" "refs/heads/head-conflict" "AC2 azure dry-run names the source branch ref"

# ── AC3: exit codes and the unchanged `file` provider ────────────────────────
use_provider gitlab
out="$(bash "$VCS" conflict-files 99 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "AC3 gitlab exits 2 when the MR head cannot be fetched"
assert_eq "" "$out" "AC3 gitlab prints no paths when the MR head cannot be fetched"
bash "$VCS" conflict-files >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC3 gitlab exits 1 for a missing number"
bash "$VCS" conflict-files abc >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC3 gitlab exits 1 for a non-integer number"

use_provider azure
STUB_AZURE_PR_SOURCE="" bash "$VCS" conflict-files 42 >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "AC3 azure exits 2 when the source branch cannot be resolved"
STUB_AZURE_PR_SOURCE=no-such-branch bash "$VCS" conflict-files 42 >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "AC3 azure exits 2 when the source branch cannot be fetched"
bash "$VCS" conflict-files >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC3 azure exits 1 for a missing number"
bash "$VCS" conflict-files 4x >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC3 azure exits 1 for a non-integer number"

cat > talos.pipeline.json <<'TALOS_cf766file'
{"vcs": {"provider": "file"}, "base_branch": "main"}
TALOS_cf766file
out="$(bash "$VCS" conflict-files 42 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC3 file still exits 1"
assert_contains "$out" "not implemented" "AC3 file still says not implemented"

rm -f talos.pipeline.json

finish
