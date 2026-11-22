#!/usr/bin/env bash
# Workflow files are linted with actionlint (#1006). PR #989 made
# .github/workflows/tests.yml invalid YAML (an unquoted ": " in a step name) and
# nothing noticed: GitHub refused to start the workflow, so the required check
# never appeared. Talos config is JSON only (#701/#725), so the PyYAML-optional
# checks in test-ci-tests-workflow.sh / test-canary.sh are skipped in CI.
# actionlint needs no PyYAML. This test runs it on every workflow file, so a
# developer with actionlint installed catches the error before pushing; CI runs
# the same lint in the `workflow-lint` job of .github/workflows/tests.yml.
#
#   bash tests/test-workflow-lint.sh            the test
#   bash tests/test-workflow-lint.sh --probe    only the actionlint-on-PATH probe
#
# Without actionlint on PATH: one `skip:` line, except under CI, where it fails
# (a skipped lint in CI is the gap this closes). The static checks on
# tests.yml (AC4) and the no-PyYAML check (AC5) need no actionlint and always run.

# The shellcheck codes actionlint ignores, as one regex (actionlint -ignore).
# SC2016 (info: "expressions don't expand in single quotes") is used on purpose
# by timings.yml. Keep this in step with the `-ignore` in tests.yml's
# workflow-lint job (AC4 checks it).
LINT_IGNORE='SC2016'

# resolve_actionlint -- 0: actionlint is on PATH. 1: it is not and CI is unset
# (prints the one `skip:` line). 2: it is not and CI is set (prints why, stderr).
# Builtins only, so --probe can run with an empty PATH.
resolve_actionlint() {
  command -v actionlint >/dev/null 2>&1 && return 0
  if [ -n "${CI:-}" ]; then
    printf 'FAIL  actionlint is not on PATH and CI is set: the workflow lint must not be skipped in CI\n' >&2
    return 2
  fi
  printf 'skip: actionlint is not on PATH (install it to lint .github/workflows and templates/ci before pushing)\n'
  return 1
}

if [ "${1:-}" = "--probe" ]; then
  resolve_actionlint
  exit $?
fi

set -u
. "$(dirname "$0")/helpers.sh"

WORKFLOW="$TALOS_ROOT/.github/workflows/tests.yml"
LINT_FILES=()
for f in "$TALOS_ROOT"/.github/workflows/*.yml "$TALOS_ROOT"/templates/ci/*.yml; do
  [ -f "$f" ] && LINT_FILES+=("$f")
done

# job_block <file> <job> -- the lines of one top-level job under `jobs:`.
job_block() {
  awk -v job="$2" '
    /^jobs:/ { injobs = 1; next }
    injobs && /^[^ #]/ { injobs = 0 }
    injobs && /^  [A-Za-z0-9_-]+:/ { cur = $1; sub(/:$/, "", cur); on = (cur == job) }
    injobs && on { print }
  ' "$1"
}

# ── AC3: no actionlint on PATH -> fail under CI, one `skip:` line otherwise. ──
EMPTY_PATH_DIR="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-wflint.XXXXXX")" || exit 1
trap 'rm -rf "${EMPTY_PATH_DIR:?}"' EXIT
no_ci_out="$(env -u CI PATH="$EMPTY_PATH_DIR" "$BASH" "$TALOS_ROOT/tests/test-workflow-lint.sh" --probe 2>&1)"; no_ci_rc=$?
ci_out="$(env CI=true PATH="$EMPTY_PATH_DIR" "$BASH" "$TALOS_ROOT/tests/test-workflow-lint.sh" --probe 2>&1)"; ci_rc=$?
assert_eq "1" "$no_ci_rc" "AC3 without actionlint and without CI the probe reports a skip"
assert_eq "1" "$(printf '%s\n' "$no_ci_out" | grep -c '^skip:')" "AC3 without CI it prints exactly one skip: line"
assert_eq "1" "$(printf '%s\n' "$no_ci_out" | wc -l | tr -d ' ')" "AC3 without CI the skip: line is the only output"
assert_eq "2" "$ci_rc" "AC3 with CI=true and no actionlint the probe fails instead of skipping"
assert_not_contains "$ci_out" "skip:" "AC3 with CI=true it does not print a skip: line"

# ── AC1 / AC2: the lint itself (needs actionlint). ──
resolve_actionlint; probe_rc=$?
case "$probe_rc" in
  0)
    FIX="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-wflint-fix.XXXXXX")" || exit 1
    trap 'rm -rf "${EMPTY_PATH_DIR:?}" "${FIX:?}"' EXIT
    # An unquoted ": " in a step name is what broke tests.yml in #989. Line 7.
    cat > "$FIX/bad.yml" <<'TALOS_WFLINT_FIXTURE_Q7'
name: bad
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: Check no test file went missing: against the base
        run: echo hi
TALOS_WFLINT_FIXTURE_Q7
    # Run from the fixture dir: actionlint prints a path relative to the cwd.
    bad_out="$(cd "$FIX" && actionlint -ignore "$LINT_IGNORE" bad.yml 2>&1)"; bad_rc=$?
    assert_eq "1" "$bad_rc" "AC1 actionlint fails on a step name with an unquoted ': '"
    case "$bad_out" in
      bad.yml:7:*) pass "AC1 the failure names the fixture file and line 7" ;;
      *) fail "AC1 the failure names the fixture file and line 7" "$(printf '%s' "$bad_out" | head -c 300)" ;;
    esac

    lint_out="$(actionlint -ignore "$LINT_IGNORE" "${LINT_FILES[@]}" 2>&1)"; lint_rc=$?
    assert_eq_ctx "0" "$lint_rc" "AC2 every file under .github/workflows/ and templates/ci/ lints clean" "$lint_out"
    ;;
  2)
    fail "AC1 actionlint is on PATH under CI (the lint cannot be skipped there)"
    fail "AC2 actionlint is on PATH under CI (the lint cannot be skipped there)"
    ;;
esac

# ── AC4: tests.yml has a `workflow-lint` job with a pinned, checksummed actionlint,
#        and the required `test` job needs it. ──
lint_job="$(job_block "$WORKFLOW" workflow-lint)"
test_job="$(job_block "$WORKFLOW" test)"
assert_contains "$lint_job" "workflow-lint:" "AC4 tests.yml has a workflow-lint job"
version_line="$(printf '%s\n' "$lint_job" | grep -E 'ACTIONLINT_VERSION:' | head -1)"
version="$(printf '%s' "$version_line" | sed -E 's/.*ACTIONLINT_VERSION:[[:space:]]*["'"'"']?([^"'"'"'[:space:]]*).*/\1/')"
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) pass "AC4 the workflow-lint job pins an actionlint version ($version)" ;;
  *) fail "AC4 the workflow-lint job pins an actionlint version" "ACTIONLINT_VERSION line: ${version_line:-<none>}" ;;
esac
assert_not_contains "$(printf '%s' "$lint_job" | tr '[:upper:]' '[:lower:]' | sed 's/ubuntu-latest//g')" "latest" "AC4 the workflow-lint job never names 'latest'"
case "$lint_job" in
  *sha256sum*-c*|*shasum*-c*) pass "AC4 the workflow-lint job checks the download's checksum" ;;
  *) fail "AC4 the workflow-lint job checks the download's checksum" "no sha256sum -c / shasum -c in the job" ;;
esac
assert_contains "$lint_job" "-ignore" "AC4 the workflow-lint job uses actionlint's own -ignore for shellcheck info codes"
assert_contains "$lint_job" "-ignore '$LINT_IGNORE'" "AC4 the -ignore regex matches the one this test uses ($LINT_IGNORE)"
assert_contains "$lint_job" ".github/workflows/*.yml" "AC4 the workflow-lint job lints .github/workflows/*.yml"
assert_contains "$lint_job" "templates/ci/*.yml" "AC4 the workflow-lint job lints templates/ci/*.yml"
needs_line="$(printf '%s\n' "$test_job" | grep -E '^    needs:' | head -1)"
assert_contains "$needs_line" "workflow-lint" "AC4 the test job needs workflow-lint"
assert_contains "$test_job" "name: test (ubuntu-latest)" "AC4 the required check name test (ubuntu-latest) is unchanged"

# ── AC5 (same): no workflow step installs PyYAML (#701/#725). ──
lc_all="$(cat "${LINT_FILES[@]}" | tr '[:upper:]' '[:lower:]')"
assert_not_contains "$lc_all" "pyyaml" "AC5 no workflow or CI template mentions PyYAML"
assert_not_contains "$lc_all" "pip install" "AC5 no workflow or CI template runs pip install"
assert_not_contains "$lc_all" "pip3 install" "AC5 no workflow or CI template runs pip3 install"
if bash "$TALOS_ROOT/tests/test-no-pyyaml-install-step.sh" >/dev/null 2>&1; then
  pass "AC5 tests/test-no-pyyaml-install-step.sh passes"
else
  fail "AC5 tests/test-no-pyyaml-install-step.sh passes"
fi

finish
