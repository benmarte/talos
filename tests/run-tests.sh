#!/usr/bin/env bash
# run-tests.sh -- run every tests/test-*.sh file and report a summary.
# Usage: bash tests/run-tests.sh [--base-ref <ref>] [pattern]
#   --base-ref  override the auto-detected base ref for count comparison
#               (default: auto-detects origin/HEAD, falls back to origin/main)
#   pattern     optional substring filter, e.g. "notify" runs test-notify*.sh
set -u

TALOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TALOS_ROOT
chmod +x "$TALOS_ROOT"/tests/stubs/* 2>/dev/null

# ── Argument parsing ──────────────────────────────────────────────────────────
BASE_REF_OVERRIDE=""
PATTERN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-ref)
      BASE_REF_OVERRIDE="$2"
      shift 2
      ;;
    *)
      PATTERN="$1"
      shift
      ;;
  esac
done

# ── Resolve base ref (default-on) ────────────────────────────────────────────
if [ -n "$BASE_REF_OVERRIDE" ]; then
  RESOLVED_BASE="$BASE_REF_OVERRIDE"
else
  _raw_base="$(git -C "$TALOS_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')"
  if [ -n "$_raw_base" ]; then
    RESOLVED_BASE="origin/$_raw_base"
  else
    RESOLVED_BASE="origin/main"
  fi
fi

# ── Part B: base-currency warning (warn only, never hard-fail) ────────────────
_behind_count="$(git -C "$TALOS_ROOT" rev-list --count "HEAD..${RESOLVED_BASE}" 2>/dev/null || true)"
if [ -n "$_behind_count" ] && [ "$_behind_count" -gt 0 ] 2>/dev/null; then
  echo "WARN: branch is $_behind_count commit(s) behind $RESOLVED_BASE; main may have advanced:" >&2
  git -C "$TALOS_ROOT" log --oneline "HEAD..${RESOLVED_BASE}" 2>/dev/null | sed 's/^/  /' >&2
fi

# ── Part A: build expected file list from base ref ───────────────────────────
# Fail-open: if ref is unresolvable (no remote, detached checkout, fork),
# skip the count check so local development is not broken.
SKIP_COUNT_CHECK=0
EXPECTED_FILES=""
if _raw="$(git -C "$TALOS_ROOT" ls-tree --name-only "$RESOLVED_BASE" tests/ 2>/dev/null)"; then
  EXPECTED_FILES="$(printf '%s\n' "$_raw" | grep 'test-.*\.sh$' || true)"
else
  echo "WARNING: could not resolve $RESOLVED_BASE for expected count; skipping count check" >&2
  SKIP_COUNT_CHECK=1
fi

total_files=0
failed_files=0

for t in "$TALOS_ROOT"/tests/test-*.sh; do
  name="$(basename "$t")"
  [ -n "$PATTERN" ] && case "$name" in *"$PATTERN"*) ;; *) continue ;; esac
  total_files=$((total_files + 1))
  echo "-- $name"
  if ! bash "$t"; then
    failed_files=$((failed_files + 1))
  fi
  echo ""
done

# ── Part A: test-file count check ────────────────────────────────────────────
# Only applies when no pattern filter is active (pattern runs a subset by design).
if [ "$SKIP_COUNT_CHECK" -eq 0 ] && [ -z "$PATTERN" ] && [ -n "$EXPECTED_FILES" ]; then
  MISSING_FILES=""
  EXPECTED_COUNT=0
  while IFS= read -r _entry; do
    [ -z "$_entry" ] && continue
    _fname="$(basename "$_entry")"
    EXPECTED_COUNT=$((EXPECTED_COUNT + 1))
    if [ ! -f "$TALOS_ROOT/tests/$_fname" ]; then
      MISSING_FILES="${MISSING_FILES}  $_fname
"
    fi
  done <<EOF
$EXPECTED_FILES
EOF

  if [ -n "$MISSING_FILES" ]; then
    echo "RESULT: test count SHORT -- ran $total_files of $EXPECTED_COUNT file(s); missing:" >&2
    printf '%s' "$MISSING_FILES" >&2
    exit 1
  fi
fi

if [ "$failed_files" -gt 0 ]; then
  echo "RESULT: $failed_files of $total_files test file(s) FAILED"
  exit 1
fi
echo "RESULT: all $total_files test file(s) passed"
