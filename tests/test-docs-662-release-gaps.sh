#!/usr/bin/env bash
# test-docs-662-release-gaps.sh -- docs/reference.md names the release gaps of #662.
set -u
. "$(dirname "$0")/helpers.sh"

REF="$TALOS_ROOT/docs/reference.md"
has() { grep -qF -- "$1" "$REF"; }
row() { grep -F -- "$1" "$REF" | head -n 1; }

if has 'pipeline-criteria.sh placement'; then pass "AC1 reference documents pipeline-criteria.sh placement"
else fail "AC1 reference documents pipeline-criteria.sh placement"; fi
if has 'placement: GAP'; then pass "AC1 reference says what placement prints"
else fail "AC1 reference says what placement prints"; fi

if has '`tests-line-open`' && has '`tests-line-missing`'; then pass "AC2 reference names tests-line-open and tests-line-missing"
else fail "AC2 reference names tests-line-open and tests-line-missing"; fi

r="$(row '| `spec-unusable issue=')"
case "$r" in
  *vacuous*head=missing*) pass "AC3 spec-unusable row names the vacuous and head=missing FAIL" ;;
  *) fail "AC3 spec-unusable row names the vacuous and head=missing FAIL" ;;
esac

if has 'tests/test-bash3-lint.sh' && has 'scripts/bash3-lint.sh' && has '# bash3-ok: <reason>'; then
  pass "AC4 Developing Talos names the bash 3.2 lint and its opt-out"
else fail "AC4 Developing Talos names the bash 3.2 lint and its opt-out"; fi

r="$(row '| `action=wait reason=ci`')"
case "$r" in
  *green*) pass "AC5 stop-reasons table has action=wait reason=ci and says to run again when green" ;;
  *) fail "AC5 stop-reasons table has action=wait reason=ci and says to run again when green" ;;
esac

finish
