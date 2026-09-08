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

# ── Test I: a pipeline-<name>.sh with no matching test-<name>*.sh falls back
# to the full suite (not an empty, silently-passing selection) ───────────────
# Reproduces the exact gap QA found: mapping scripts/pipeline-config.sh via
# the convention rule produces zero matches (no tests/test-config*.sh exists
# in this fixture), and pipeline-config.sh isn't otherwise special-cased to
# add anything either. That must fail open to the full suite, never print
# "SELECTED: (none)" / "RESULT: all 0 test file(s) passed".
# Named mutation: this is QA's own "map pipeline-config.sh to nothing"
# mutation -- drop the fallback check in _map_changed_path's
# scripts/pipeline-*.sh branch and rc_i stays 0 but out_i loses both the
# fail-safe note and the "full suite" selection, running 0 files instead.
FDI="$SANDBOX/i"
build_min_fixture "$FDI"
mkdir -p "$FDI/scripts"
for f in test-x.sh test-y.sh; do write_stub "$FDI" "$f" "exit 0"; done
printf '#!/usr/bin/env bash\necho stub\n' > "$FDI/scripts/pipeline-config.sh"

out_i="$(bash "$FDI/tests/run-tests.sh" --no-cache --for scripts/pipeline-config.sh --quiet 2>&1)"; rc_i=$?
assert_exit_code 0 "$rc_i" "I: exits 0"
assert_contains "$out_i" "no tests map to 'scripts/pipeline-config.sh'; running the full suite" "I: prints the fail-safe note"
assert_contains "$out_i" "SELECTED: full suite" "I: falls back to the full suite, not an empty selection"
assert_contains "$out_i" "PASS  tests/test-x.sh" "I: falls back to running test-x.sh"
assert_contains "$out_i" "PASS  tests/test-y.sh" "I: falls back to running test-y.sh"
assert_contains "$out_i" "RESULT: all 2 test file(s) passed" "I: RESULT line covers the whole fixture suite"
assert_not_contains "$out_i" "SELECTED: (none)" "I: never reports an empty selection"
assert_not_contains "$out_i" "RESULT: all 0 test file(s) passed" "I: never silently passes with 0 files"

# ── Test J: a selection that maps to a name with no file on disk (all mapped
# files deleted/renamed) exits non-zero instead of reporting a pass ──────────
# "tests/test-*.sh" maps a path to its own basename unconditionally (it never
# checks the file exists) -- pointing --for at a tests/test-*.sh path that
# isn't a real file reproduces "final selection resolves to nothing" without
# touching run-tests.sh's own source.
# Named mutation: drop the post-ALL_FILES empty-selection guard -- rc_j
# would stay 0 and out_j would print "RESULT: all 0 test file(s) passed"
# instead of failing.
out_j="$(bash "$FDA/tests/run-tests.sh" --no-cache --for tests/test-does-not-exist.sh --quiet 2>&1)"; rc_j=$?
assert_exit_code 1 "$rc_j" "J: a selection with no file on disk exits non-zero"
assert_contains "$out_j" "selected 0 test file(s) to run" "J: prints a clear message naming the empty selection"
assert_not_contains "$out_j" "RESULT: all 0 test file(s) passed" "J: never reports a 0-file pass"

# ── Test K: scripts/pipeline-<name>.sh unions the convention match with
# every test file that references the script's basename (#220 review fix) ──
# Three fixture tests cover pipeline-foo.sh: one matches by the
# tests/test-foo*.sh naming convention, and two others -- with names that do
# NOT match the convention -- reference "pipeline-foo.sh" as a fixed string
# in their contents. A fourth, unrelated test neither matches the
# convention nor references the script and must be excluded.
# Named mutation: this is the exact gap the reviewer found -- reverting the
# union back to convention-only would drop the SELECTED set to just
# test-foo.sh (1 file instead of 3), and reverting to "any test matching a
# broad substring" instead of a fixed-string basename match would risk
# pulling in test-gamma-unrelated.sh too. Asserting the SELECTED line's
# exact contents (not just "contains") catches both directions.
FDL="$SANDBOX/l"
build_min_fixture "$FDL"
mkdir -p "$FDL/scripts"
printf '#!/usr/bin/env bash\necho stub\n' > "$FDL/scripts/pipeline-foo.sh"
write_stub "$FDL" "test-foo.sh" "exit 0"
write_stub "$FDL" "test-alpha-refs-foo.sh" $'# exercises scripts/pipeline-foo.sh\nexit 0'
write_stub "$FDL" "test-beta-refs-foo.sh" $'# also calls scripts/pipeline-foo.sh\nexit 0'
write_stub "$FDL" "test-gamma-unrelated.sh" "exit 0"

out_l="$(bash "$FDL/tests/run-tests.sh" --no-cache --for scripts/pipeline-foo.sh --quiet 2>&1)"; rc_l=$?
assert_exit_code 0 "$rc_l" "K: exits 0"
selected_line_l="$(printf '%s\n' "$out_l" | grep '^SELECTED:')"
assert_eq "SELECTED: test-foo.sh test-alpha-refs-foo.sh test-beta-refs-foo.sh" "$selected_line_l" "K: selects the convention match plus both referencing tests, exact set"
assert_contains "$out_l" "PASS  tests/test-foo.sh" "K: runs the convention-matched test-foo.sh"
assert_contains "$out_l" "PASS  tests/test-alpha-refs-foo.sh" "K: runs the non-convention test that references pipeline-foo.sh"
assert_contains "$out_l" "PASS  tests/test-beta-refs-foo.sh" "K: runs the second non-convention test that references pipeline-foo.sh"
assert_not_contains "$out_l" "test-gamma-unrelated.sh" "K: does not select the unrelated, non-referencing test"
assert_contains "$out_l" "RESULT: all 3 test file(s) passed" "K: RESULT line covers exactly the 3 selected files"

# ── Test L: "RESULT: all 0 test file(s) passed" must never appear in any
# --for/--changed output captured above ───────────────────────────────────────
ALL_TARGETED_OUTPUT="$out_a
$out_b
$out_c
$out_d
$out_e
$out_f
$out_g
$out_h
$out_i
$out_j
$out_l"
assert_not_contains "$ALL_TARGETED_OUTPUT" "RESULT: all 0 test file(s) passed" "L: no --for/--changed run ever silently passes with 0 files"

finish
