#!/usr/bin/env bash
# test-diff-pr-stat-gitlab-azure-766.sh -- `diff-pr --stat` on gitlab and azure
# (#766, slice 7 of #753). Both print what github prints (_diff_stat_format):
# one " <path> | +<a> -<d>" line per file, then " N files changed, A
# insertions(+), D deletions(-)". gitlab counts the +/- hunk lines of the MR
# diffs API (the stub's STUB_GITLAB_MR_DIFFS); azure converts `git diff
# --numstat origin/<tgt>...origin/<src>` against a local bare origin. Without
# --stat both keep printing the full diff. Tests are named by criterion id.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

git config user.email "test@talos.invalid"
git config user.name "talos-test"

UPSTREAM_PARENT="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-stat766-origin.XXXXXX")" || exit 1
UPSTREAM="$UPSTREAM_PARENT/upstream.git"
git init -q --bare "$UPSTREAM"
trap '_is_trap_owner && rm -rf "$SANDBOX" "$UPSTREAM_PARENT"' EXIT
git remote set-url origin "$UPSTREAM"

# ── Azure fixture: a source branch that modifies, renames, deletes and adds a
# binary file, with main moving on afterwards (the three-dot diff ignores that).
printf 'l1\nl2\nl3\n' > a.txt
seq 1 10 > old.txt
printf 'g1\ng2\n' > gone.txt
git add a.txt old.txt gone.txt
git commit -q -m "seed"
git branch -M main
git push -q origin main

git checkout -q -b feature/stat
printf 'l1\nl2x\nl3\nl4\n' > a.txt
git mv old.txt new.txt
seq 1 10 | sed 's/^5$/five/' > new.txt
git rm -q gone.txt
printf 'bin\0ary\0' > bin.dat
git add a.txt new.txt bin.dat
git commit -qm "feature:modify, rename, delete, add binary"
git push -q origin feature/stat

git checkout -q main
printf 'main only\n' > main-only.txt
git add main-only.txt
git commit -qm "main: moves on"
git push -q origin main

# ── gitlab: the MR diffs API payload for the same change ─────────────────────
GL_DIFFS="$(python3 -I -c '
import json
print(json.dumps([
  {"old_path": "a.txt", "new_path": "a.txt",
   "diff": "@@ -1,3 +1,4 @@\n l1\n-l2\n+l2x\n l3\n+l4\n"},
  {"old_path": "bin.dat", "new_path": "bin.dat", "new_file": True, "diff": ""},
  {"old_path": "gone.txt", "new_path": "gone.txt", "deleted_file": True,
   "diff": "@@ -1,2 +0,0 @@\n-g1\n--- g2\n"},
  {"old_path": "old.txt", "new_path": "new.txt", "renamed_file": True,
   "diff": "@@ -5 +5 @@\n-5\n+five\n"},
]))
')"

WANT="$(printf ' a.txt | +2 -1\n bin.dat | +0 -0\n gone.txt | +0 -2\n new.txt | +1 -1\n 4 files changed, 3 insertions(+), 4 deletions(-)')"

use_provider() {
  case "$1" in
    gitlab) cat > talos.pipeline.json <<'TALOS_stat766gitlab'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"}, "base_branch": "main"}
TALOS_stat766gitlab
    ;;
    azure) cat > talos.pipeline.json <<'TALOS_stat766azure'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}, "base_branch": "main"}
TALOS_stat766azure
    ;;
  esac
}

# ── AC4: gitlab --stat ───────────────────────────────────────────────────────
use_provider gitlab
: > "$GH_LOG"
out="$(STUB_GITLAB_MR_DIFFS="$GL_DIFFS" bash "$VCS" diff-pr 9 --stat 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC4 gitlab diff-pr --stat exits 0"
assert_eq "$WANT" "$out" "AC4 gitlab diff-pr --stat prints the github-shaped summary (rename under its new path, deletion as all deletions)"
assert_contains "$(cat "$GH_LOG")" "merge_requests/9/diffs" "AC4 gitlab diff-pr --stat reads the MR diffs API"
out="$(STUB_GITLAB_API_FAIL=1 bash "$VCS" diff-pr 9 --stat 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC4 gitlab diff-pr --stat exits 1 when the diffs fetch fails"
assert_eq "" "$out" "AC4 gitlab diff-pr --stat prints nothing when the diffs fetch fails"

# ── AC5: azure --stat ────────────────────────────────────────────────────────
use_provider azure
out="$(STUB_AZURE_PR_SOURCE=feature/stat bash "$VCS" diff-pr 9 --stat 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC5 azure diff-pr --stat exits 0"
assert_eq "$WANT" "$out" "AC5 azure diff-pr --stat prints the same summary from git diff --numstat (rename under its new path, binary as +0 -0)"
out="$(STUB_AZURE_PR_SOURCE="" bash "$VCS" diff-pr 9 --stat 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC5 azure diff-pr --stat exits 1 when the source branch cannot be resolved"
assert_eq "" "$out" "AC5 azure diff-pr --stat prints nothing when the source branch cannot be resolved"

# ── AC6: without --stat both still print the full diff ───────────────────────
out="$(STUB_AZURE_PR_SOURCE=feature/stat bash "$VCS" diff-pr 9 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC6 azure diff-pr without --stat exits 0"
assert_contains "$out" "diff --git a/a.txt b/a.txt" "AC6 azure diff-pr without --stat prints the full diff"
assert_not_contains "$out" "files changed" "AC6 azure diff-pr without --stat prints no summary"

use_provider gitlab
: > "$GH_LOG"
out="$(STUB_GITLAB_MR_DIFFS="$GL_DIFFS" bash "$VCS" diff-pr 9 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC6 gitlab diff-pr without --stat exits 0"
assert_contains "$(cat "$GH_LOG")" "mr diff 9" "AC6 gitlab diff-pr without --stat still runs glab mr diff"
assert_not_contains "$out" "files changed" "AC6 gitlab diff-pr without --stat prints no summary"

rm -f talos.pipeline.json

finish
