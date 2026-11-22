#!/usr/bin/env bash
# test-ci-count-merge-base.sh -- the CI `count` job compares a PR's merge commit
# against its own base parent, not against the current base branch (#996).
#
# On pull_request GitHub checks out refs/pull/<n>/merge, built from the base as
# it was when the PR event fired. Comparing that against the *current*
# origin/<base> reports a test file another PR merged since as missing. HEAD^1 of
# the merge commit is the base it was built from. Push events keep origin/<base>.
#   AC1 tests.yml count job: PR runs --count-only --base-ref HEAD^1, checkout depth >= 2
#   AC2 tests.yml count job: push events still compare against origin/<base>
#   AC3 run-tests.sh --count-only --base-ref HEAD^1 on a merge commit
#   AC4 a PR that deletes a base test file still fails, unless retired-tests.txt names it
set -u
. "$(dirname "$0")/helpers.sh"

WORKFLOW="$TALOS_ROOT/.github/workflows/tests.yml"
REAL_RUN_TESTS="$TALOS_ROOT/tests/run-tests.sh"

# ── AC1 / AC2: the workflow's count job ──────────────────────────────────────
# The job block: from "  count:" to the next two-space job key.
count_job="$(awk '/^  count:/ {on = 1; print; next} on && /^  [A-Za-z_-]+:/ {exit} on {print}' "$WORKFLOW")"
assert_contains "$count_job" "--count-only" "AC1 tests.yml: the count job runs run-tests.sh --count-only"

# One line per step that runs --count-only: "<if: line>|<run: line>".
steps="$(printf '%s\n' "$count_job" | awk '
  function flush() { if (n && run != "") print ifl "|" run; ifl = ""; run = "" }
  /^      - / { flush(); n = 1 }
  /^ +(- )?if:/ { ifl = $0 }
  /--count-only/ { run = run $0 }
  END { flush() }')"

pr_step="$(printf '%s\n' "$steps" | grep -F -- '--base-ref HEAD^1' || true)"
assert_contains "$pr_step" "pull_request" "AC1 tests.yml: the HEAD^1 count step is scoped to pull_request"
assert_not_contains "$pr_step" "!= 'pull_request'" "AC1 tests.yml: the HEAD^1 count step is not the push step"

depth="$(printf '%s\n' "$count_job" | sed -n 's/^ *fetch-depth: *\([0-9][0-9]*\).*/\1/p' | head -1)"
if [ -n "$depth" ] && [ "$depth" -ge 2 ] 2>/dev/null; then
  pass "AC1 tests.yml: the count job checkout fetches depth $depth (>= 2), so HEAD^1 exists"
else
  fail "AC1 tests.yml: the count job checkout fetches depth >= 2" "fetch-depth: '${depth:-unset}'"
fi

push_step="$(printf '%s\n' "$steps" | grep -F -- 'origin/${BASE}' || true)"
assert_contains "$push_step" "--count-only" "AC2 tests.yml: a count step still compares against origin/<base>"
assert_contains "$push_step" "!= 'pull_request'" "AC2 tests.yml: the origin/<base> count step runs on push events (not pull_request)"
assert_not_contains "$push_step" "HEAD^1" "AC2 tests.yml: the push count step does not use HEAD^1"

# ── AC3 / AC4: run-tests.sh --count-only --base-ref HEAD^1 on a merge commit ─
# Fixture: base commit B holds test-a.sh and test-b.sh. A PR branch forks from B.
# The merge commit's first parent is the base side, its second the PR side.
make_sandbox
mk_repo() {  # $1=dir -- a repo whose HEAD is B on branch main
  local d="$1"
  mkdir -p "$d/tests"
  cp "$REAL_RUN_TESTS" "$d/tests/run-tests.sh"
  for f in test-a.sh test-b.sh; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/tests/$f"; done
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@talos.invalid
  git -C "$d" config user.name talos-test
  git -C "$d" add -A
  git -C "$d" commit -q -m base
}
add_test() {  # $1=dir $2=basename $3=commit message
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/tests/$2"
  git -C "$1" add -A
  git -C "$1" commit -q -m "$3"
}
merge_pr() {  # $1=dir -- merge branch pr into main with a merge commit
  git -C "$1" checkout -q main
  git -C "$1" merge -q --no-ff -m "merge pr" pr
}

# PR drops test-b.sh: the merge commit lacks a file its first parent has.
M1="$SANDBOX/drop"
mk_repo "$M1"
git -C "$M1" checkout -q -b pr
git -C "$M1" rm -q tests/test-b.sh
git -C "$M1" commit -q -m "pr drops b"
merge_pr "$M1"

out="$(bash "$M1/tests/run-tests.sh" --count-only --base-ref 'HEAD^1' 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "AC3 merge commit missing a file its first parent has: count-only fails"
assert_contains "$out" "test-b.sh" "AC3 the missing file is named"
assert_exit_code 1 "$rc" "AC4 a PR that deletes a base test file still fails count"

printf 'test-b.sh\n' > "$M1/tests/retired-tests.txt"
out="$(bash "$M1/tests/run-tests.sh" --count-only --base-ref 'HEAD^1' 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "AC4 tests/retired-tests.txt naming the file excuses it"
rm -f "$M1/tests/retired-tests.txt"

# PR keeps both files and adds one: both parents have what the base has.
M2="$SANDBOX/keep"
mk_repo "$M2"
git -C "$M2" checkout -q -b pr
add_test "$M2" test-pr.sh "pr adds pr"
merge_pr "$M2"
out="$(bash "$M2/tests/run-tests.sh" --count-only --base-ref 'HEAD^1' 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "AC3 both parents have the file: count-only passes"

# The race: main gains test-c.sh while the PR is open, the merge commit is built
# (both parents have it), then main moves on with test-d.sh. The current base
# ref reports test-d.sh missing; the merge commit's own base parent does not.
M3="$SANDBOX/race"
mk_repo "$M3"
git -C "$M3" checkout -q -b pr
add_test "$M3" test-pr.sh "pr adds pr"
git -C "$M3" checkout -q main
add_test "$M3" test-c.sh "main gains c"
merge_pr "$M3"
git -C "$M3" branch -q mergecommit
git -C "$M3" checkout -q -b newmain 'HEAD^1'
add_test "$M3" test-d.sh "main gains d"
git -C "$M3" checkout -q --detach mergecommit

out="$(bash "$M3/tests/run-tests.sh" --count-only --base-ref newmain 2>&1)"; rc=$?
assert_exit_code 1 "$rc" "AC3 control: the current base ref reports a file main gained since the merge commit as missing"
assert_contains "$out" "test-d.sh" "AC3 control: the race names the file main gained"
out="$(bash "$M3/tests/run-tests.sh" --count-only --base-ref 'HEAD^1' 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "AC3 HEAD^1 ignores a file main gained after the merge commit was built"

finish
