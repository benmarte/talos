#!/usr/bin/env bash
# test-changelog-assemble.sh -- unit tests for scripts/pipeline-changelog.sh
# assemble (#290).
#
# Contract:
#   exit 0  assembled and pushed (fragments folded into [Unreleased] newest
#           first, fragment files deleted in the same commit), or nothing to
#           assemble (no fragments / no <issue>.md fragments).
#   exit 1  setup/config/git error (no base, no CHANGELOG.md heading, push
#           failure). Nothing pushed. Fragments remain -- the next assemble
#           retries.
#
# Uses a local bare-repo fixture as the `origin` remote (no network) --
# same fixture shape as test-mergebase.sh.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
CL="$TALOS_ROOT/scripts/pipeline-changelog.sh"

git config user.email "test@talos.invalid"
git config user.name "talos-test"

UPSTREAM_PARENT="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-cl-origin.XXXXXX")" || exit 1
UPSTREAM="$UPSTREAM_PARENT/upstream.git"
git init -q --bare "$UPSTREAM"
trap '_is_trap_owner && rm -rf "$SANDBOX" "$UPSTREAM_PARENT"' EXIT

git remote set-url origin "$UPSTREAM"

cat > CHANGELOG.md <<'EOF'
# Changelog

## [Unreleased]

## [0.16.0] - 2026-09-15

### Added

- existing entry
EOF
git add CHANGELOG.md
git commit -q -m "seed changelog"
git branch -M main
git push -q origin main

cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main"}
EOF

# ── (a) no fragments -> exit 0, nothing to assemble ──────────────────────────
out="$(bash "$CL" assemble 2>&1)"; rc=$?
assert_eq "0" "$rc" "assemble: exits 0 when docs/CHANGELOG.d is absent"
assert_contains "$out" "nothing to assemble" "assemble: reports nothing to do"
main_sha_before="$(git rev-parse origin/main)"

# ── (b) fragments assemble newest-first, consumed fragments deleted ─────────
git fetch -q origin main
git checkout -q -b frag origin/main
mkdir -p docs/CHANGELOG.d
# Deliberately create 290 before 289 to prove ordering is numeric, not creation order.
cat > docs/CHANGELOG.d/290.md <<'EOF'
- **Fragments for 290.** Fragment body for issue 290.
EOF
cat > docs/CHANGELOG.d/289.md <<'EOF'
- **Fragments for 289.** Fragment body for issue 289.
EOF
# A non-fragment file that must be left alone.
cat > docs/CHANGELOG.d/notes.txt <<'EOF'
not a fragment
EOF
git add docs/CHANGELOG.d
git commit -qm "pr: add fragments"
git push -q origin frag
git push -q origin frag:main --force  # put the fragments on main (docs would commit on base in reality)
git checkout -q main
git branch -D frag >/dev/null 2>&1 || true
git pull -q origin main 2>/dev/null || git reset -q --hard origin/main

out="$(bash "$CL" assemble 2>&1)"; rc=$?
assert_eq "0" "$rc" "assemble: exits 0 with fragments present"
assert_contains "$out" "assembled" "assemble: reports assembly"
assert_contains "$out" "2 fragment" "assemble: assembled both fragments"

git fetch -q origin main
merged="$(git show origin/main:CHANGELOG.md)"
assert_contains "$merged" "Fragment body for issue 290" "assemble: 290 fragment folded in"
assert_contains "$merged" "Fragment body for issue 289" "assemble: 289 fragment folded in"
assert_contains "$merged" "## [Unreleased]" "assemble: [Unreleased] heading intact"
assert_contains "$merged" "existing entry" "assemble: existing entries intact"
# Newest (highest number) first: the 290 bullet must appear before 289.
line290="$(printf '%s\n' "$merged" | grep -n 'issue 290' | head -1 | cut -d: -f1)"
line289="$(printf '%s\n' "$merged" | grep -n 'issue 289' | head -1 | cut -d: -f1)"
assert_eq "1" "$([ "$line290" -lt "$line289" ] && echo 1 || echo 0)" "assemble: fragments appear newest (highest issue number) first"
# Fragments must sit under [Unreleased], above the released section.
unrel="$(printf '%s\n' "$merged" | grep -n '## \[Unreleased\]' | head -1 | cut -d: -f1)"
assert_eq "1" "$([ "$line290" -gt "$unrel" ] && echo 1 || echo 0)" "assemble: fragments inserted under the [Unreleased] heading"
# Consumed fragment files deleted in the same commit; non-fragment files in
# the directory survive untouched.
leftover="$(git ls-tree -r --name-only origin/main docs/CHANGELOG.d 2>/dev/null || true)"
assert_eq "docs/CHANGELOG.d/notes.txt" "$leftover" "assemble: consumed fragments deleted; non-fragment files survive"
# The non-fragment notes.txt is not a tracked fragment target; if it existed
# under the dir it was removed by `git add -A docs/CHANGELOG.d` removals only
# for consumed names -- verify it's not in CHANGELOG.
assert_not_contains "$merged" "not a fragment" "assemble: never folds non-fragment content"
# Commit message names the assembly.
commit_msg="$(git log -1 --format=%s origin/main)"
assert_contains "$commit_msg" "assemble CHANGELOG from fragments" "assemble: commit message names the assembly"

# ── (c) second assemble with no fragments left -> exit 0 no-op ──────────────
out="$(bash "$CL" assemble 2>&1)"; rc=$?
assert_eq "0" "$rc" "assemble: idempotent after consuming all fragments"

# ── (d) empty fragment file -> nothing to assemble, nothing pushed ──────────
git fetch -q origin main
git checkout -q -b frag2 origin/main
mkdir -p docs/CHANGELOG.d
: > docs/CHANGELOG.d/291.md
git add docs/CHANGELOG.d
git commit -qm "pr: add empty fragment"
git push -q origin frag2
git push -q origin frag2:main --force
git checkout -q main
git branch -D frag2 >/dev/null 2>&1 || true
git reset -q --hard origin/main

main_sha_before="$(git rev-parse origin/main)"
out="$(bash "$CL" assemble 2>&1)"; rc=$?
assert_eq "0" "$rc" "assemble: an all-empty fragment set is a no-op success"
git fetch -q origin main
assert_eq "$main_sha_before" "$(git rev-parse origin/main)" "assemble: nothing pushed for empty fragments"

# ── (e) worktree cleaned up on every exit path ──────────────────────────────
wt_before="$(git worktree list | wc -l | tr -d ' ')"
bash "$CL" assemble >/dev/null 2>&1
assert_eq "$wt_before" "$(git worktree list | wc -l | tr -d ' ')" "assemble: leaves no worktree behind"

# ── (f) missing base -> exit 1 ───────────────────────────────────────────────
python3 -c "
import json
cfg = json.load(open('talos.pipeline.json'))
cfg['base_branch'] = 'nonexistent-branch'
json.dump(cfg, open('talos.pipeline.json', 'w'))
"
out="$(bash "$CL" assemble 2>&1)"; rc=$?
assert_eq "1" "$rc" "assemble: exits 1 when the base branch cannot be resolved"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main"}
EOF

# ── (g) option-injection base_branch is refused before any git call (#457) ──
# A value starting with `-` would be read by `git fetch` as an option; the
# marker file proves no command ran. JSON config (not YAML, see #490).
MARKER="$SANDBOX/PWNED"
for bad in "--upload-pack=touch $MARKER;" "-x" "a..b" "main.lock" "a b"; do
  BAD="$bad" python3 -I -c "
import json, os
json.dump({'vcs': {'provider': 'github', 'repo': 'acme/widget'}, 'base_branch': os.environ['BAD']}, open('talos.pipeline.json', 'w'))
"
  out="$(bash "$CL" assemble 2>&1)"; rc=$?
  assert_eq "1" "$rc" "assemble: rejects base_branch '$bad' (rc)"
  assert_contains "$out" "not an accepted branch name" "assemble: names the refused base_branch '$bad'"
  assert_file_absent "$MARKER" "assemble: base_branch '$bad' ran no command"
done

# ── (h) a symlinked fragment is never read through; the rest still assemble ─
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main"}
EOF
printf 'SECRET-VIA-FRAGMENT-LINK\n' > "$SANDBOX/outside-secret.txt"
git fetch -q origin main
git checkout -q -b frag3 origin/main
mkdir -p docs/CHANGELOG.d
printf -- '- **Real fragment 300.** Body for issue 300.\n' > docs/CHANGELOG.d/300.md
ln -s "$SANDBOX/outside-secret.txt" docs/CHANGELOG.d/301.md
git add docs/CHANGELOG.d
git commit -qm "pr: real fragment plus a symlinked one"
git push -q origin frag3:main --force
git checkout -q main
git branch -D frag3 >/dev/null 2>&1 || true
git reset -q --hard origin/main

out="$(bash "$CL" assemble 2>&1)"; rc=$?
assert_eq "0" "$rc" "assemble: a symlinked fragment does not fail the run"
assert_contains "$out" "301.md is not a regular file" "assemble: names the skipped symlinked fragment"
git fetch -q origin main
merged="$(git show origin/main:CHANGELOG.md)"
assert_contains "$merged" "Real fragment 300" "assemble: the regular fragment beside a symlink is folded in"
assert_not_contains "$merged" "SECRET-VIA-FRAGMENT-LINK" "assemble: a symlinked fragment is never read through"
assert_eq "120000" "$(git ls-tree origin/main docs/CHANGELOG.d/301.md | cut -c1-6)" "assemble: the symlinked fragment is left in place"

# ── (i) a symlinked CHANGELOG.md on the base is refused ─────────────────────
git checkout -q -b frag4 origin/main
printf -- '- **Fragment 302.** Body for issue 302.\n' > docs/CHANGELOG.d/302.md
git rm -q --cached CHANGELOG.md
mv CHANGELOG.md "$SANDBOX/real-changelog.md"
ln -s "$SANDBOX/real-changelog.md" CHANGELOG.md
git add CHANGELOG.md docs/CHANGELOG.d/302.md
git commit -qm "pr: CHANGELOG.md as a symlink"
git push -q origin frag4:main --force
git checkout -q main
git branch -D frag4 >/dev/null 2>&1 || true
git reset -q --hard origin/main
main_sha_before="$(git rev-parse origin/main)"
out="$(bash "$CL" assemble 2>&1)"; rc=$?
assert_eq "1" "$rc" "assemble: a symlinked CHANGELOG.md exits 1"
assert_contains "$out" "CHANGELOG.md on origin/main is not a regular file" "assemble: names the refused CHANGELOG.md"
git fetch -q origin main
assert_eq "$main_sha_before" "$(git rev-parse origin/main)" "assemble: nothing pushed for a symlinked CHANGELOG.md"
assert_not_contains "$(cat "$SANDBOX/real-changelog.md")" "Fragment 302" "assemble: the symlink target was not written through"

rm -f talos.pipeline.json
finish