#!/usr/bin/env bash
# test-run-tests-for.sh -- tests for run-tests.sh's targeted test discovery
# (--for / --changed, #197): convention-based path->test-file mapping, the
# fail-safe full-suite fallback, --changed's git-diff derivation, and
# composition with existing flags.
#
# Fixture design: cases A-D reuse the shared SANDBOX git repo the same way
# test-run-tests-parallel.sh does (a COPY of the real run-tests.sh under a
# throwaway subdirectory, tracked into $SANDBOX's git repo so the result
# cache's dependency hash can see it) -- --for takes literal path arguments,
# so no git history is needed for those.
#
# --changed cases (E+) instead build a DEDICATED git repo per fixture
# (build_changed_fixture), because `git diff --name-only` reports paths
# relative to the repo root: nesting inside the shared SANDBOX repo would
# report "e/scripts/pipeline-foo.sh" instead of "scripts/pipeline-foo.sh",
# which would never match the mapping rules (that mismatch only exists in
# this test's fixture shape -- a real checkout's TALOS_ROOT already IS the
# git root, so production paths are never prefixed).
#
# Recursion guard: every invocation below runs a COPY of run-tests.sh rooted
# at a throwaway fixture directory, never the suite's own tests/run-tests.sh
# against the suite's own tests/ -- so it cannot recursively re-run itself.
#
# MEASUREMENT DISCIPLINE: out=$(cmd 2>&1); rc=$? throughout -- never pipe.
set -u
. "$(dirname "$0")/helpers.sh"

REAL_RUN_TESTS="$TALOS_ROOT/tests/run-tests.sh"

# build_min_fixture FD -- bare fixture: tests/run-tests.sh (copy) + empty stubs/.
# Shares $SANDBOX's git repo (via track_fixture), same as
# test-run-tests-parallel.sh -- used by the --for cases, which take literal
# path arguments and never call git themselves.
build_min_fixture() {
  local FD="$1"
  mkdir -p "$FD/tests/stubs"
  cp "$REAL_RUN_TESTS" "$FD/tests/run-tests.sh"
  track_fixture "$FD"
}

# build_changed_fixture FD -- fixture with its OWN git repo (not $SANDBOX's),
# so `git diff --name-only` reports paths relative to $FD itself -- see the
# file header for why this matters. HOME already carries a seeded
# ~/.gitconfig (make_sandbox), so a plain `git init` here can commit without
# extra identity config.
build_changed_fixture() {
  local FD="$1"
  mkdir -p "$FD/tests/stubs"
  cp "$REAL_RUN_TESTS" "$FD/tests/run-tests.sh"
  git init -q "$FD"
}

write_stub() {  # FD NAME BODY
  local FD="$1" NAME="$2" BODY="$3"
  printf '#!/usr/bin/env bash\n%s\n' "$BODY" > "$FD/tests/$NAME"
}

track_fixture() {  # stage FD's current contents into $SANDBOX's shared repo
  git -C "$SANDBOX" add -A "$1" >/dev/null 2>&1 || true
}

# commit_fixture FD MSG -- stage and commit everything under FD, in FD's OWN
# repo (build_changed_fixture). Scoped with a pathspec so only FD's files
# land in the commit.
commit_fixture() {
  local FD="$1" msg="$2"
  git -C "$FD" add -A -- . >/dev/null
  git -C "$FD" commit -q -m "$msg" >/dev/null
}

make_sandbox

# ── Test A: scripts/pipeline-<name>.sh selects tests/test-<name>*.sh, nothing else ──
# Named mutation: select every test file regardless of the --for path -- B's
# test-other.sh would then run too, and this test would see 2 SELECTED files.
FDA="$SANDBOX/a"
build_min_fixture "$FDA"
mkdir -p "$FDA/scripts"
write_stub "$FDA" "test-worktree.sh" "exit 0"
write_stub "$FDA" "test-other.sh" "exit 0"
printf '#!/usr/bin/env bash\necho stub\n' > "$FDA/scripts/pipeline-worktree.sh"

out_a="$(bash "$FDA/tests/run-tests.sh" --no-cache --for scripts/pipeline-worktree.sh --quiet 2>&1)"; rc_a=$?
assert_exit_code 0 "$rc_a" "A: exits 0"
assert_contains "$out_a" "SELECTED: test-worktree.sh" "A: selects test-worktree.sh"
assert_contains "$out_a" "PASS  tests/test-worktree.sh" "A: runs test-worktree.sh"
assert_not_contains "$out_a" "test-other.sh" "A: does not select or run test-other.sh"
assert_contains "$out_a" "RESULT: all 1 test file(s) passed" "A: RESULT line covers exactly 1 file"

# ── Test B: tests/stubs/* selects the full suite ──────────────────────────────
# Named mutation: treat tests/stubs/* like any other unmapped path (still
# full suite, but WITHOUT the dedicated case -- if a future edit narrowed
# the fail-safe list this would catch it) -- covered together with the
# unmapped-path case (D) since both assert the same "runs everything" shape.
FDB="$SANDBOX/b"
build_min_fixture "$FDB"
for f in test-x.sh test-y.sh; do write_stub "$FDB" "$f" "exit 0"; done

out_b="$(bash "$FDB/tests/run-tests.sh" --no-cache --for tests/stubs/gh --quiet 2>&1)"; rc_b=$?
assert_exit_code 0 "$rc_b" "B: exits 0"
assert_contains "$out_b" "SELECTED: full suite" "B: announces the full-suite fallback"
assert_contains "$out_b" "PASS  tests/test-x.sh" "B: runs test-x.sh (full suite)"
assert_contains "$out_b" "PASS  tests/test-y.sh" "B: runs test-y.sh (full suite)"
assert_contains "$out_b" "RESULT: all 2 test file(s) passed" "B: RESULT line covers the whole fixture suite"

# ── Test C: agents/*.md selects test-skill-names.sh + any test referencing it ─
# Named mutation: only add the fixed test-skill-names.sh entry and skip the
# grep -l sweep -- test-references-agents.sh would then never be selected.
FDC="$SANDBOX/c"
build_min_fixture "$FDC"
write_stub "$FDC" "test-skill-names.sh" "exit 0"
write_stub "$FDC" "test-references-agents.sh" $'# reads agents/developer.md\nexit 0'
write_stub "$FDC" "test-unrelated.sh" "exit 0"

out_c="$(bash "$FDC/tests/run-tests.sh" --no-cache --for agents/developer.md --quiet 2>&1)"; rc_c=$?
assert_exit_code 0 "$rc_c" "C: exits 0"
assert_contains "$out_c" "PASS  tests/test-skill-names.sh" "C: runs the fixed test-skill-names.sh entry"
assert_contains "$out_c" "PASS  tests/test-references-agents.sh" "C: runs the test that references agents/ (grep -l sweep)"
assert_not_contains "$out_c" "test-unrelated.sh" "C: does not select the unrelated test"

# ── Test D: an unmapped path falls back to the full suite (fail-safe) ────────
# Named mutation: exit non-zero (or select nothing) on an unmapped path
# instead of failing open to the full suite -- rc_d would be non-zero, or
# the RESULT line would show 0 files instead of every fixture file.
FDD="$SANDBOX/d"
build_min_fixture "$FDD"
for f in test-p.sh test-q.sh; do write_stub "$FDD" "$f" "exit 0"; done

out_d="$(bash "$FDD/tests/run-tests.sh" --no-cache --for some/unmapped/path.txt --quiet 2>&1)"; rc_d=$?
assert_exit_code 0 "$rc_d" "D: exits 0"
assert_contains "$out_d" "no test mapping" "D: prints a one-line fail-safe note"
assert_contains "$out_d" "PASS  tests/test-p.sh" "D: falls back to running test-p.sh"
assert_contains "$out_d" "PASS  tests/test-q.sh" "D: falls back to running test-q.sh"
assert_contains "$out_d" "RESULT: all 2 test file(s) passed" "D: RESULT line covers the whole fixture suite"

# ── Test E: --changed picks up an UNCOMMITTED change against a given base ref ─
# Named mutation: only look at `<base>...HEAD` and ignore the working tree --
# this test's change (staged but never committed) would then never be seen,
# and test-worktree.sh would not run.
FDE="$SANDBOX/e"
build_changed_fixture "$FDE"
mkdir -p "$FDE/scripts"
write_stub "$FDE" "test-worktree.sh" "exit 0"
write_stub "$FDE" "test-other.sh" "exit 0"
printf '#!/usr/bin/env bash\necho v1\n' > "$FDE/scripts/pipeline-worktree.sh"
commit_fixture "$FDE" "base"
BASE_E="$(git -C "$FDE" rev-parse HEAD)"
printf '#!/usr/bin/env bash\necho v2\n' >> "$FDE/scripts/pipeline-worktree.sh"   # uncommitted
git -C "$FDE" add -A >/dev/null   # staged, not committed

out_e="$(bash "$FDE/tests/run-tests.sh" --no-cache --changed "$BASE_E" --quiet 2>&1)"; rc_e=$?
assert_exit_code 0 "$rc_e" "E: exits 0"
assert_contains "$out_e" "SELECTED: test-worktree.sh" "E: --changed maps the uncommitted change via the same rules as --for"
assert_not_contains "$out_e" "test-other.sh" "E: does not select the untouched test-other.sh"

# ── Test F: --changed picks up a COMMITTED change since the given base ref ───
# Named mutation: diff only the working tree (HEAD) and ignore
# `<base>...HEAD` -- a change committed after BASE_F, with a clean working
# tree, would then be invisible and nothing would be selected.
FDF="$SANDBOX/f"
build_changed_fixture "$FDF"
mkdir -p "$FDF/scripts"
write_stub "$FDF" "test-worktree.sh" "exit 0"
write_stub "$FDF" "test-other.sh" "exit 0"
printf '#!/usr/bin/env bash\necho v1\n' > "$FDF/scripts/pipeline-worktree.sh"
commit_fixture "$FDF" "base"
BASE_F="$(git -C "$FDF" rev-parse HEAD)"
printf '#!/usr/bin/env bash\necho v2\n' >> "$FDF/scripts/pipeline-worktree.sh"
commit_fixture "$FDF" "change"   # committed, working tree is clean

out_f="$(bash "$FDF/tests/run-tests.sh" --no-cache --changed "$BASE_F" --quiet 2>&1)"; rc_f=$?
assert_exit_code 0 "$rc_f" "F: exits 0"
assert_contains "$out_f" "SELECTED: test-worktree.sh" "F: --changed maps a committed change via <base>...HEAD"
assert_not_contains "$out_f" "test-other.sh" "F: does not select the untouched test-other.sh"

# ── Test G: --changed with an unresolvable base ref fails open to the full suite ─
# Named mutation: hard-fail (non-zero exit, no tests run) on an unresolvable
# ref instead of falling back -- rc_g would be non-zero and no PASS lines
# would appear.
FDG="$SANDBOX/g"
build_changed_fixture "$FDG"
for f in test-r.sh test-s.sh; do write_stub "$FDG" "$f" "exit 0"; done
commit_fixture "$FDG" "base"

out_g="$(bash "$FDG/tests/run-tests.sh" --no-cache --changed no-such-ref-xyz --quiet 2>&1)"; rc_g=$?
assert_exit_code 0 "$rc_g" "G: exits 0"
assert_contains "$out_g" "base ref 'no-such-ref-xyz' not found" "G: prints a fail-open note naming the ref"
assert_contains "$out_g" "PASS  tests/test-r.sh" "G: falls back to running test-r.sh"
assert_contains "$out_g" "PASS  tests/test-s.sh" "G: falls back to running test-s.sh"

# ── Test H: --for composes with --quiet (already exercised above) and -j ─────
# Named mutation: ignore -j / drop the JOBS override once --for is active --
# covered by re-running A's fixture with an explicit -j and confirming the
# same selection and result.
out_h="$(bash "$FDA/tests/run-tests.sh" --no-cache --for scripts/pipeline-worktree.sh -j 2 --quiet 2>&1)"; rc_h=$?
assert_exit_code 0 "$rc_h" "H: --for composes with -j -- exits 0"
assert_contains "$out_h" "SELECTED: test-worktree.sh" "H: --for composes with -j -- same selection"
assert_contains "$out_h" "RESULT: all 1 test file(s) passed" "H: --for composes with -j -- same RESULT"

finish
