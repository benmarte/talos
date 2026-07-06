#!/usr/bin/env bash
# run-tests.sh — run every tests/test-*.sh file and report a summary.
# Usage: bash tests/run-tests.sh [pattern]
#   pattern  optional substring filter, e.g. "notify" runs test-notify*.sh
set -u

TALOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TALOS_ROOT
chmod +x "$TALOS_ROOT"/tests/stubs/* 2>/dev/null

PATTERN="${1:-}"
total_files=0
failed_files=0

for t in "$TALOS_ROOT"/tests/test-*.sh; do
  name="$(basename "$t")"
  [ -n "$PATTERN" ] && case "$name" in *"$PATTERN"*) ;; *) continue ;; esac
  total_files=$((total_files + 1))
  echo "── $name"
  if ! bash "$t"; then
    failed_files=$((failed_files + 1))
  fi
  echo ""
done

if [ "$failed_files" -gt 0 ]; then
  echo "RESULT: $failed_files of $total_files test file(s) FAILED"
  exit 1
fi
echo "RESULT: all $total_files test file(s) passed"
