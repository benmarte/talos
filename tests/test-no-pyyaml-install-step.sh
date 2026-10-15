#!/usr/bin/env bash
# The CI workflow and the shipped CI template install no PyYAML (#701).
# Talos config is JSON only, every remaining `yaml` import is optional, and the
# install step failed on the macos-26-arm64 runner image.
set -u
. "$(dirname "$0")/helpers.sh"

check_no_pyyaml_step() {  # $1=file $2=label prefix $3=the run step that must remain
  local f="$1" p="$2" content
  content=$(cat "$f")
  assert_not_contains "$content" "Install PyYAML" "$p has no 'Install PyYAML' step"
  assert_not_contains "$(printf '%s' "$content" | tr '[:upper:]' '[:lower:]')" "pyyaml" "$p has no pyyaml string"
  assert_not_contains "$content" "--break-system-packages" "$p has no --break-system-packages"
  assert_not_contains "$content" "setup-python" "$p has no setup-python step"
  assert_contains "$content" "$3" "$p still has its '$3' step"
}

check_no_pyyaml_step "$TALOS_ROOT/.github/workflows/tests.yml" \
  "AC1 .github/workflows/tests.yml" "Run test shard"
check_no_pyyaml_step "$TALOS_ROOT/templates/ci/github-tests.yml" \
  "AC2 templates/ci/github-tests.yml" "Run test suite"

# AC3 (same, green on base): both files still parse as the documented structure.
for t in test-ci-tests-workflow.sh test-draft-check.sh; do
  if bash "$TALOS_ROOT/tests/$t" >/dev/null 2>&1; then
    pass "AC3 tests/$t still passes"
  else
    fail "AC3 tests/$t still passes"
  fi
done

finish
