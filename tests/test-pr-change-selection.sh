#!/usr/bin/env bash
# test-pr-change-selection.sh -- PRs run only the tests their changes select (#972).
#   AC1/AC2  a Markdown path selects the test files whose contents name it
#   AC3      hooks/ and install.sh are fail-safe (full suite) paths
#   AC4      a shard whose slice of the selection is empty passes
#   AC5      tests.yml: PR shards run --changed HEAD^1, push events the full suite
#   AC6      the other --for mapping rules are unchanged
# MEASUREMENT DISCIPLINE: out=$(cmd); rc=$? -- never pipe.
set -u
. "$(dirname "$0")/helpers.sh"

REAL_RUN_TESTS="$TALOS_ROOT/tests/run-tests.sh"
WORKFLOW="$TALOS_ROOT/.github/workflows/tests.yml"
make_sandbox

# list_for ARGS... -- stdout in $out, stderr in $err, status in $rc.
list_for() {
  out="$(bash "$REAL_RUN_TESTS" "$@" --list 2>"$SANDBOX/err")"; rc=$?
  err="$(cat "$SANDBOX/err")"
}
# naming FILE -- the tests/test-*.sh basenames whose contents contain FILE.
naming() {
  (cd "$TALOS_ROOT/tests" && grep -lF -- "$1" test-*.sh | LC_ALL=C sort)
}
count_lines() { printf '%s\n' "$1" | grep -c .; }
all_count="$(ls "$TALOS_ROOT"/tests/test-*.sh | wc -l | tr -d ' ')"

# ── AC1: a Markdown path selects exactly the tests that name it ──────────────
list_for --for docs/reference.md
assert_exit_code 0 "$rc" "AC1 --for docs/reference.md exits 0"
assert_eq "$(naming docs/reference.md)" "$out" "AC1 --for docs/reference.md selects exactly the test files naming it"
n="$(count_lines "$out")"
if [ "$n" -gt 0 ] && [ "$n" -lt "$all_count" ]; then
  assert_eq "ok" "ok" "AC1 the selection is a proper subset of the suite"
else
  assert_eq "a proper subset" "$n of $all_count" "AC1 the selection is a proper subset of the suite"
fi
assert_not_contains "$err" "full suite" "AC1 no full-suite fallback for a Markdown path"
list_for --for CHANGELOG.md
assert_eq "$(naming CHANGELOG.md)" "$out" "AC1 --for CHANGELOG.md selects exactly the test files naming it"

# ── AC2: a Markdown path no test names selects nothing ───────────────────────
nobody="docs/no-test-names-""this-page.md"
list_for --for "$nobody"
assert_eq "" "$out" "AC2 an unnamed Markdown path lists no test file"
assert_not_contains "$err" "full suite" "AC2 an unnamed Markdown path causes no full-suite fallback"
bash "$REAL_RUN_TESTS" --for "$nobody" --strict --list >/dev/null 2>&1; rc=$?
assert_exit_code 3 "$rc" "AC2 --strict with only an unnamed Markdown path exits 3"
list_for --for "$nobody" --for tests/timings.txt --strict
assert_eq "test-shard-weights.sh" "$out" "AC2 an unnamed Markdown path adds nothing beside a mapped path"

# ── AC3: hooks/ and install.sh are fail-safe paths ───────────────────────────
for p in hooks/hooks.json install.sh; do
  list_for --for "$p"
  assert_eq "$all_count" "$(count_lines "$out")" "AC3 --for $p runs the full suite"
  assert_contains "$err" "no test mapping for '$p'; running the full suite" "AC3 --for $p prints the one-line note"
done

# ── AC4: an empty slice of the selection passes ──────────────────────────────
FD="$SANDBOX/fx"
mkdir -p "$FD/tests" "$FD/docs"
cp "$REAL_RUN_TESTS" "$FD/tests/run-tests.sh"
printf '#!/usr/bin/env bash\n# reads docs/named.md\nexit 0\n' > "$FD/tests/test-named.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FD/tests/test-other.sh"
printf '1 test-named.sh\n1 test-other.sh\n' > "$FD/tests/timings.txt"
printf 'x\n' > "$FD/docs/named.md"
git init -q "$FD"
git -C "$FD" config user.name t
git -C "$FD" config user.email t@example.invalid
git -C "$FD" add -A -- . >/dev/null
git -C "$FD" commit -q -m base >/dev/null
BASE="$(git -C "$FD" rev-parse HEAD)"
printf 'y\n' > "$FD/docs/named.md"
git -C "$FD" add -A -- . >/dev/null
git -C "$FD" commit -q -m change >/dev/null

# docs/named.md selects test-named.sh only: of 4 shards one runs it, 3 are empty.
empty=0
ran=0
for i in 1 2 3 4; do
  out="$(bash "$FD/tests/run-tests.sh" --no-cache --quiet --changed "$BASE" --shard "$i/4" 2>&1)"; rc=$?
  case "$out" in
    *"no tests in this shard"*)
      empty=$((empty + 1))
      assert_exit_code 0 "$rc" "AC4 shard $i/4 with an empty slice exits 0"
      assert_eq "1" "$(printf '%s\n' "$out" | grep -c 'no tests in this shard')" "AC4 shard $i/4 prints no tests in this shard once"
      ;;
    *"PASS  tests/test-named.sh"*)
      ran=$((ran + 1))
      assert_exit_code 0 "$rc" "AC4 the shard holding the selected test exits 0"
      assert_not_contains "$out" "test-other.sh" "AC4 an unselected test never runs"
      ;;
    *) assert_eq "a pass or an empty slice" "rc=$rc: $out" "AC4 shard $i/4 reports its slice" ;;
  esac
done
assert_eq "3" "$empty" "AC4 three of four shards have an empty slice"
assert_eq "1" "$ran" "AC4 exactly one shard runs the selected test"

# A change no test names: the whole selection is empty and every shard passes.
printf 'z\n' > "$FD/docs/unnamed.md"
git -C "$FD" add -A -- . >/dev/null
git -C "$FD" commit -q -m unnamed >/dev/null
out="$(bash "$FD/tests/run-tests.sh" --no-cache --quiet --changed HEAD~1 --shard 2/4 2>&1)"; rc=$?
assert_exit_code 0 "$rc" "AC4 a PR whose changes select nothing passes its shard"
assert_contains "$out" "no tests in this shard" "AC4 an empty selection reports no tests in this shard"

# ── AC5: tests.yml ───────────────────────────────────────────────────────────
wf="$(grep -v '^[[:space:]]*#' "$WORKFLOW")"
pr_run="$(printf '%s\n' "$wf" | grep 'run-tests.sh.*--changed')"
assert_contains "$pr_run" "--changed HEAD^1" "AC5 tests.yml: the PR shard step runs --changed HEAD^1"
assert_contains "$pr_run" "--shard" "AC5 tests.yml: the PR shard step passes --shard"
assert_contains "$pr_run" "--timings" "AC5 tests.yml: the PR shard step passes --timings"
assert_contains "$wf" "fetch-depth: 2" "AC5 tests.yml: the shard checkout fetches depth 2 so HEAD^1 resolves"
push_run="$(printf '%s\n' "$wf" | grep 'run-tests.sh' | grep -v -e '--changed' -e '--count-only')"
assert_contains "$push_run" "--shard" "AC5 tests.yml: a full-suite shard step remains for push events"
assert_contains "$wf" "if: github.event_name == 'pull_request'" "AC5 tests.yml: the --changed step is gated on pull_request"
assert_contains "$wf" "if: github.event_name != 'pull_request'" "AC5 tests.yml: the full-suite step is gated on the other events"

# ── AC6: every other --for rule is unchanged ─────────────────────────────────
expected6="$( (cd "$TALOS_ROOT/tests" && { ls test-next*.sh 2>/dev/null; grep -lF -- 'pipeline-next.py' test-*.sh; }) | LC_ALL=C sort -u)"
out="$(bash "$REAL_RUN_TESTS" --for scripts/pipeline-next.py --strict --list 2>/dev/null)"; rc=$?
assert_exit_code 0 "$rc" "AC6 --for scripts/pipeline-next.py --strict --list exits 0"
assert_eq "$expected6" "$out" "AC6 --for scripts/pipeline-next.py --strict --list selects the convention and referencing files"
list_for --for tests/helpers.sh
assert_eq "$all_count" "$(count_lines "$out")" "AC6 tests/helpers.sh still runs the full suite"
list_for --for agents/developer.md
assert_contains "$out" "test-agent-skill-refs.sh" "AC6 agents/*.md still selects test-agent-skill-refs.sh"

finish
