#!/usr/bin/env bash
# test-run-tests-timings-select.sh -- run-tests.sh --changed/--for also select
# test-shard-weights.sh (its W1 is the tests/timings.txt check) when a
# tests/test-*.sh is ADDED (absent at the base ref) or tests/timings.txt
# changes, so a missing timings line fails in the developer's own run (#860).
#
# Each case builds its own fixture git repo (copy of the real run-tests.sh,
# stub tests) and names its assertions by the spec's AC<n> id.
# MEASUREMENT DISCIPLINE: out=$(cmd 2>&1); rc=$? -- never pipe.
set -u
. "$(dirname "$0")/helpers.sh"

REAL_RUN_TESTS="$TALOS_ROOT/tests/run-tests.sh"

# build_fixture FD -- own git repo with a base commit holding a stub
# test-shard-weights.sh, an existing test-old.sh and tests/timings.txt.
# Sets BASE to the base commit.
build_fixture() {
  local FD="$1"
  mkdir -p "$FD/tests/stubs"
  cp "$REAL_RUN_TESTS" "$FD/tests/run-tests.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FD/tests/test-shard-weights.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FD/tests/test-old.sh"
  printf '1 test-old.sh\n1 test-shard-weights.sh\n' > "$FD/tests/timings.txt"
  git init -q "$FD"
  git -C "$FD" config user.name t
  git -C "$FD" config user.email t@example.invalid
  git -C "$FD" add -A -- . >/dev/null
  git -C "$FD" commit -q -m base >/dev/null
  BASE="$(git -C "$FD" rev-parse HEAD)"
}

commit_all() {  # FD MSG
  git -C "$1" add -A -- . >/dev/null
  git -C "$1" commit -q -m "$2" >/dev/null
}

make_sandbox

# -- AC1: a branch that adds tests/test-new-x.sh selects test-shard-weights.sh --
# Named mutation: drop the new-file rule -- only test-new-x.sh is listed.
FD1="$SANDBOX/ac1"
build_fixture "$FD1"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FD1/tests/test-new-x.sh"
commit_all "$FD1" "add test"
out1="$(bash "$FD1/tests/run-tests.sh" --no-cache --changed "$BASE" --strict --list 2>/dev/null)"; rc1=$?
assert_exit_code 0 "$rc1" "AC1 exits 0"
assert_contains "$out1" "test-new-x.sh" "AC1 selects the added test itself"
assert_contains "$out1" "test-shard-weights.sh" "AC1 selects test-shard-weights.sh for an added test"

# -- AC2: only tests/timings.txt changed -> selected, not skipped as unmapped --
# Named mutation: leave timings.txt in the unmapped arm -- --strict skips it,
# nothing is selected and the run exits 3.
FD2="$SANDBOX/ac2"
build_fixture "$FD2"
printf '2 test-old.sh\n1 test-shard-weights.sh\n' > "$FD2/tests/timings.txt"
commit_all "$FD2" "timings"
out2="$(bash "$FD2/tests/run-tests.sh" --no-cache --changed "$BASE" --strict --list 2>/dev/null)"; rc2=$?
assert_exit_code 0 "$rc2" "AC2 exits 0, not 3 (not skipped as unmapped)"
assert_contains "$out2" "test-shard-weights.sh" "AC2 selects test-shard-weights.sh for a timings.txt change"

# -- AC3: editing an existing test selects that file only ----------------------
# Named mutation: select test-shard-weights.sh for every tests/test-*.sh path
# -- it would show up here although test-old.sh already exists at the base.
FD3="$SANDBOX/ac3"
build_fixture "$FD3"
printf '# edited\n' >> "$FD3/tests/test-old.sh"
commit_all "$FD3" "edit test"
out3="$(bash "$FD3/tests/run-tests.sh" --no-cache --changed "$BASE" --strict --list 2>/dev/null)"; rc3=$?
assert_exit_code 0 "$rc3" "AC3 exits 0"
assert_contains "$out3" "test-old.sh" "AC3 selects the edited test"
assert_not_contains "$out3" "test-shard-weights.sh" "AC3 does not add test-shard-weights.sh for an edit"

finish
