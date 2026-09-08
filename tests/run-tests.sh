#!/usr/bin/env bash
# run-tests.sh -- run every tests/test-*.sh file and report a summary.
# Usage: bash tests/run-tests.sh [--base-ref <ref>] [-j N] [--quiet] [--no-cache] [pattern]
#        bash tests/run-tests.sh --for <path> [--for <path> ...] [--quiet] ...
#        bash tests/run-tests.sh --changed [<base-ref>] [--quiet] ...
#   --base-ref  override the auto-detected base ref for count comparison
#               (default: auto-detects origin/HEAD, falls back to origin/main)
#   -j N        run up to N test files concurrently (also: TALOS_TEST_JOBS)
#               default: CPU count (nproc, then sysctl -n hw.ncpu, then 4)
#   --quiet     print one line per file (pass/fail/cached) plus full output
#               only for failing files (also: TALOS_TEST_QUIET=1)
#   --no-cache  ignore and do not write the per-file result cache
#   --repeat N  run the selected files N times, stopping at the first
#               iteration that fails (its full log is printed; also implies
#               --no-cache, since a cache hit on iteration 2+ would silently
#               skip the re-run this flag exists for). N=1 (the default) is
#               a no-op: output is byte-for-byte identical to omitting the
#               flag. Intended for reproducing nondeterministic ("flaky")
#               failures locally, e.g.:
#                 bash tests/run-tests.sh -j 8 --repeat 20 test-foo.sh
#   pattern     optional substring filter, e.g. "notify" runs test-notify*.sh
#   --for <path>       select tests by convention instead of running the
#                       whole suite; repeatable. Convention (nothing else
#                       runs unless a rule below adds it):
#                         scripts/pipeline-<name>.sh -> tests/test-<name>*.sh
#                         tests/test-*.sh            -> itself
#                         agents/*.md, skills/**, templates/**
#                                                     -> tests/test-skill-names.sh
#                                                        plus any test file
#                                                        whose contents
#                                                        reference the path's
#                                                        directory prefix
#                       Always-run additions:
#                         scripts/pipeline-vcs.sh              -> + test-verb-parity.sh
#                         scripts/pipeline-config.sh,
#                         scripts/pipeline-cfg-cache.sh         -> + tests/test-config*.sh
#                       Fail-safe (full suite, one-line stderr note):
#                         tests/stubs/*, tests/helpers.sh, tests/run-tests.sh,
#                         talos.pipeline.*, .github/**, any path matching no
#                         rule above, or a scripts/pipeline-<name>.sh whose
#                         convention + always-run rules match zero files
#                         (e.g. no tests/test-<name>*.sh exists). An empty
#                         selection is never allowed to silently "pass"; if
#                         the final selected list is still empty after all
#                         rules (e.g. every mapped file was deleted), the
#                         run exits non-zero with a clear message instead.
#                       Prints the selected file list before running.
#   --changed [<ref>]  derive --for's paths from
#                       `git diff --name-only <ref>...HEAD` plus uncommitted
#                       and untracked changes. <ref> defaults to origin/main;
#                       an unresolvable ref falls back to the full suite.
#
# A test file that cannot run concurrently with the others (shared fixtures,
# fixed ports) can opt out of the parallel pool with a full-line marker
# comment anywhere in the file:
#   # SERIAL
# Marked files run sequentially, after the parallel batch finishes.
#
# Result cache: passing files are cached under .talos/test-cache/<key>, keyed
# on the test file's own content plus a whole-set hash of every git-tracked
# file in the repo (`git ls-files`) EXCEPT a small, proven-unread exclusion
# list -- see the comment on compute_deps_hash() for the list and how it was
# proven safe. This includes tests/run-tests.sh itself and every
# tests/test-*.sh (whole-set hashing, not per-file dependency tracking -- any
# tracked change outside the exclusion list invalidates every cached test).
# Untracked files are not hashed and cannot invalidate the cache; a test that
# asserts against an untracked file is outside this cache's safety net. A
# cache hit prints "CACHED tests/<name>.sh", counts as passed, and is not
# re-executed. Failing files are never cached. --no-cache bypasses reads and
# writes; CI always runs with --no-cache. If neither sha256sum nor shasum is
# available, caching is disabled outright (a warning is printed) rather than
# risk a degraded key.
set -u

# Source guard (#121): sourcing this file would run test suites in the caller's
# shell, changing the caller's CWD to a temp sandbox that gets deleted on exit.
# Always invoke as: bash tests/run-tests.sh [pattern]
if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
  printf 'ERROR: do not source run-tests.sh; use: bash tests/run-tests.sh\n' >&2
  return 1
fi

TALOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TALOS_ROOT
chmod +x "$TALOS_ROOT"/tests/stubs/* 2>/dev/null

# ── Argument parsing ──────────────────────────────────────────────────────────
BASE_REF_OVERRIDE=""
PATTERN=""
JOBS_OVERRIDE=""
QUIET=0
NO_CACHE=0
REPEAT=1
FOR_PATHS=()
CHANGED_MODE=0
CHANGED_BASE_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-ref)
      BASE_REF_OVERRIDE="$2"
      shift 2
      ;;
    -j)
      JOBS_OVERRIDE="$2"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --no-cache)
      NO_CACHE=1
      shift
      ;;
    --repeat)
      REPEAT="$2"
      shift 2
      ;;
    --for)
      FOR_PATHS+=("$2")
      shift 2
      ;;
    --changed)
      CHANGED_MODE=1
      shift
      # Optional base-ref: consume the next token only if it isn't another
      # flag (a bare "--changed" with nothing after it keeps the default).
      if [ $# -gt 0 ]; then
        case "$1" in
          --*) ;;
          *) CHANGED_BASE_REF="$1"; shift ;;
        esac
      fi
      ;;
    *)
      PATTERN="$1"
      shift
      ;;
  esac
done
if [ "${TALOS_TEST_QUIET:-0}" = "1" ]; then
  QUIET=1
fi

# --repeat validation: fall back to 1 (a no-op) on anything non-numeric,
# same convention as the JOBS fallback below.
case "$REPEAT" in
  ''|*[!0-9]*) REPEAT=1 ;;
esac
[ "$REPEAT" -lt 1 ] && REPEAT=1
# Repeating with a warm cache would report CACHED (not re-run) from the
# second iteration on, defeating the flag's purpose of catching flakes.
[ "$REPEAT" -gt 1 ] && NO_CACHE=1

# ── Resolve worker count ──────────────────────────────────────────────────────
JOBS=""
if [ -n "$JOBS_OVERRIDE" ]; then
  JOBS="$JOBS_OVERRIDE"
elif [ -n "${TALOS_TEST_JOBS:-}" ]; then
  JOBS="$TALOS_TEST_JOBS"
elif command -v nproc >/dev/null 2>&1; then
  JOBS="$(nproc)"
elif command -v sysctl >/dev/null 2>&1; then
  JOBS="$(sysctl -n hw.ncpu 2>/dev/null)"
fi
case "$JOBS" in
  ''|*[!0-9]*) JOBS=4 ;;
esac
[ "$JOBS" -lt 1 ] && JOBS=1

# ── Result cache ───────────────────────────────────────────────────────────────
CACHE_ENABLED=1
[ "$NO_CACHE" -eq 1 ] && CACHE_ENABLED=0
CACHE_DIR="$TALOS_ROOT/.talos/test-cache"

# _HASH_TOOL -- the hashing command to pipe stdin through, resolved once.
# Left empty (rather than defaulting to a missing binary) if neither tool
# exists, so callers can detect and disable caching instead of erroring out.
_HASH_TOOL=""
if command -v sha256sum >/dev/null 2>&1; then
  _HASH_TOOL="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  _HASH_TOOL="shasum -a 256"
fi
if [ -z "$_HASH_TOOL" ] && [ "$CACHE_ENABLED" -eq 1 ]; then
  echo "WARNING: neither sha256sum nor shasum found; disabling test result cache" >&2
  CACHE_ENABLED=0
fi

# _sha256 -- hash stdin, print the hex digest only.
_sha256() {
  $_HASH_TOOL | awk '{print $1}'
}

# _sha256_file PATH -- hash a file's content (empty hash if it does not exist
# or is not a regular file, e.g. a symlink to a directory).
_sha256_file() {
  if [ -f "$1" ]; then
    _sha256 < "$1"
  else
    printf '' | _sha256
  fi
}

# compute_deps_hash -- whole-set hash of every git-tracked file in the repo
# (`git ls-files -z`, NUL-delimited so filenames with spaces are safe) EXCEPT
# an explicit exclusion list, plus tests/run-tests.sh and every
# tests/test-*.sh (both already git-tracked, so no special-casing is needed).
# Sorted (LC_ALL=C) so the result is order-independent.
#
# Why "every tracked file minus an exclusion list" instead of an allow-list
# of directories: an allow-list silently rots -- #175's own review round
# found the original allow-list (scripts/*.sh, tests/helpers.sh,
# tests/stubs/*, templates/**) missing tests/run-tests.sh itself, and a
# follow-up security finding found it also missing agents/**, skills/**, and
# .claude-plugin/**, which several tests read directly (test-callsite-guard.sh,
# test-marker-contract.sh, test-global-install.sh, test-plugin-install.sh).
# An exclusion list only needs to be provably *safe to leave out*, not
# provably *complete* -- so it is far cheaper to keep correct.
#
# Exclusion list and how it was proven safe: for each candidate below,
# `grep -l '<pattern>' tests/*.sh` was run across every tests/test-*.sh (the
# full read-closure of the suite) and returned zero matches, i.e. no test
# reads or asserts against that path. Re-run that grep before adding
# anything here.
#   tasks/**             -- internal planning notes; zero references
#   docs/superpowers/**  -- spec drafts; zero references
#   .github/**           -- CI workflow config; zero references
#   .gitignore           -- tests that mention ".gitignore" (test-assert-sync*)
#                            write and check their OWN fixture .gitignore in
#                            a sandbox; none reads the repo's real .gitignore
# CHANGELOG.md was considered and REJECTED: tests/test-comment-post-failure.sh
# reads "$TALOS_ROOT/CHANGELOG.md" directly and asserts on its content, so it
# stays hashed like every other tracked file.
compute_deps_hash() {
  [ -z "$_HASH_TOOL" ] && { printf '' | _sha256; return; }
  git -C "$TALOS_ROOT" ls-files -z 2>/dev/null | while IFS= read -r -d '' _dep; do
    case "$_dep" in
      tasks/*|docs/superpowers/*|.github/*|.gitignore) continue ;;
    esac
    printf '%s %s\n' "$_dep" "$(_sha256_file "$TALOS_ROOT/$_dep")"
  done | LC_ALL=C sort | _sha256
}

if [ "$CACHE_ENABLED" -eq 1 ]; then
  DEPS_HASH="$(compute_deps_hash)"
  mkdir -p "$CACHE_DIR" 2>/dev/null
fi

# cache_key_for TESTFILE -- deterministic key combining the test file's own
# content hash with the shared dependency-set hash.
cache_key_for() {
  printf '%s:%s' "$(_sha256_file "$1")" "$DEPS_HASH" | _sha256
}

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

# ── Targeted test discovery (--for / --changed, #197) ────────────────────────
# Maps changed paths to the test files that cover them, by convention, so an
# agent iterating on one script does not have to pay for the whole suite on
# every loop. See the usage comment at the top of this file for the rule
# table. Composes with every other flag (--quiet, -j, --no-cache, --repeat)
# unchanged -- this section only decides which files land in ALL_FILES below.
TARGETED_ACTIVE=0
FULL_SUITE=0
SELECTED_SET=()

if [ "$CHANGED_MODE" -eq 1 ]; then
  _changed_ref="${CHANGED_BASE_REF:-origin/main}"
  if ! git -C "$TALOS_ROOT" rev-parse --verify -q "${_changed_ref}^{commit}" >/dev/null 2>&1; then
    echo "run-tests.sh: --changed: base ref '$_changed_ref' not found; falling back to full suite" >&2
    FULL_SUITE=1
  else
    _changed_raw="$(
      {
        git -C "$TALOS_ROOT" diff --name-only "${_changed_ref}...HEAD" 2>/dev/null
        git -C "$TALOS_ROOT" diff --name-only HEAD 2>/dev/null
        git -C "$TALOS_ROOT" ls-files --others --exclude-standard 2>/dev/null
      } | LC_ALL=C sort -u
    )"
    while IFS= read -r _cp; do
      [ -z "$_cp" ] && continue
      FOR_PATHS+=("$_cp")
    done <<EOF
$_changed_raw
EOF
  fi
fi

if [ "${#FOR_PATHS[@]}" -gt 0 ] || [ "$CHANGED_MODE" -eq 1 ]; then
  TARGETED_ACTIVE=1
fi

# _add_selected NAME -- append a test file basename to SELECTED_SET, deduped.
# ("${arr[@]}" on an empty array errors under `set -u` in bash 3.2/macOS, so
# every array expansion here is guarded by a ${#arr[@]} count check first.)
_add_selected() {
  local f="$1" e
  if [ "${#SELECTED_SET[@]}" -gt 0 ]; then
    for e in "${SELECTED_SET[@]}"; do
      [ "$e" = "$f" ] && return 0
    done
  fi
  SELECTED_SET+=("$f")
}

# _add_glob_matches PATTERN -- append every tests/<PATTERN> match's basename.
_add_glob_matches() {
  local pat="$1" f
  for f in "$TALOS_ROOT"/tests/$pat; do
    [ -f "$f" ] || continue
    _add_selected "$(basename "$f")"
  done
}

# _add_referencing PREFIX -- append every tests/test-*.sh whose contents
# mention PREFIX (e.g. "agents/"), found via grep -l over the whole suite.
_add_referencing() {
  local prefix="$1" f
  for f in "$TALOS_ROOT"/tests/test-*.sh; do
    [ -f "$f" ] || continue
    grep -q -- "$prefix" "$f" 2>/dev/null && _add_selected "$(basename "$f")"
  done
}

# _map_changed_path PATH -- the convention table from the usage comment.
_map_changed_path() {
  local p="$1" base name before
  case "$p" in
    tests/stubs/*|tests/helpers.sh|tests/run-tests.sh|talos.pipeline.*|.github/*)
      FULL_SUITE=1
      ;;
    tests/test-*.sh)
      _add_selected "$(basename "$p")"
      ;;
    scripts/pipeline-*.sh)
      base="$(basename "$p")"
      name="${base#pipeline-}"
      name="${name%.sh}"
      before="${#SELECTED_SET[@]}"
      _add_glob_matches "test-${name}*.sh"
      [ "$base" = "pipeline-vcs.sh" ] && _add_selected "test-verb-parity.sh"
      case "$base" in
        pipeline-config.sh|pipeline-cfg-cache.sh) _add_glob_matches "test-config*.sh" ;;
      esac
      # Convention + always-run rules matched nothing for this path (e.g. no
      # tests/test-<name>*.sh exists and it isn't one of the always-run
      # names above): an empty mapping must never pass through as an empty
      # selection, so fail open to the full suite -- same fail-safe as an
      # unmapped path below.
      if [ "${#SELECTED_SET[@]}" -eq "$before" ]; then
        echo "run-tests.sh: --for: no tests map to '$p'; running the full suite" >&2
        FULL_SUITE=1
      fi
      ;;
    agents/*.md|skills/*|templates/*)
      _add_selected "test-skill-names.sh"
      case "$p" in
        agents/*) _add_referencing "agents/" ;;
        skills/*) _add_referencing "skills/" ;;
        templates/*) _add_referencing "templates/" ;;
      esac
      ;;
    *)
      echo "run-tests.sh: --for: no test mapping for '$p'; falling back to full suite" >&2
      FULL_SUITE=1
      ;;
  esac
}

if [ "$TARGETED_ACTIVE" -eq 1 ] && [ "$FULL_SUITE" -eq 0 ] && [ "${#FOR_PATHS[@]}" -gt 0 ]; then
  for _fp in "${FOR_PATHS[@]}"; do
    [ -z "$_fp" ] && continue
    _map_changed_path "$_fp"
  done
fi

if [ "$TARGETED_ACTIVE" -eq 1 ]; then
  if [ "$FULL_SUITE" -eq 1 ]; then
    echo "SELECTED: full suite" >&2
  elif [ "${#SELECTED_SET[@]}" -eq 0 ]; then
    echo "SELECTED: (none)" >&2
  else
    echo "SELECTED: ${SELECTED_SET[*]}" >&2
  fi
fi

# ── Build the file list, then split into parallel/serial groups ──────────────
# A file opts out of the parallel pool with a full-line "# SERIAL" marker
# comment anywhere in its body; those run sequentially, after the parallel
# batch. Order within each group follows the original glob (alphabetical),
# and reporting order is always parallel-group-then-serial-group -- stable,
# and independent of actual completion order.
ALL_FILES=()
if [ "$TARGETED_ACTIVE" -eq 1 ] && [ "$FULL_SUITE" -eq 0 ]; then
  if [ "${#SELECTED_SET[@]}" -gt 0 ]; then
    for name in "${SELECTED_SET[@]}"; do
      t="$TALOS_ROOT/tests/$name"
      [ -f "$t" ] || continue
      [ -n "$PATTERN" ] && case "$name" in *"$PATTERN"*) ;; *) continue ;; esac
      ALL_FILES+=("$t")
    done
  fi
  # Stable, deterministic order regardless of mapping-rule visitation order.
  if [ "${#ALL_FILES[@]}" -gt 1 ]; then
    IFS=$'\n' ALL_FILES=($(printf '%s\n' "${ALL_FILES[@]}" | LC_ALL=C sort))
    unset IFS
  fi
else
  for t in "$TALOS_ROOT"/tests/test-*.sh; do
    [ -f "$t" ] || continue
    name="$(basename "$t")"
    [ -n "$PATTERN" ] && case "$name" in *"$PATTERN"*) ;; *) continue ;; esac
    ALL_FILES+=("$t")
  done
fi

# A targeted (--for/--changed) run that isn't falling back to the full suite
# must never finish with an empty file list -- e.g. every name the mapping
# selected turned out not to exist under tests/ (deleted, renamed, or a
# mapping bug). "0 of 0 passed" is not a pass; it means the selection is
# broken, so fail loudly instead of reporting a silent green.
if [ "$TARGETED_ACTIVE" -eq 1 ] && [ "$FULL_SUITE" -eq 0 ] && [ "${#ALL_FILES[@]}" -eq 0 ]; then
  echo "run-tests.sh: --for/--changed selected 0 test file(s) to run -- refusing to report a pass; check the mapping in _map_changed_path (a selected name may not exist under tests/)" >&2
  exit 1
fi

PARALLEL_FILES=()
SERIAL_FILES=()
# Guarded on count first: "${ALL_FILES[@]}" on an empty array is itself an
# unbound-variable error under `set -u` in bash 3.2/macOS -- reachable
# whenever a selection (PATTERN, or now --for/--changed) legitimately
# matches zero files, not just via misuse.
if [ "${#ALL_FILES[@]}" -gt 0 ]; then
  for t in "${ALL_FILES[@]}"; do
    if grep -Eq '^# SERIAL[[:space:]]*$' "$t" 2>/dev/null; then
      SERIAL_FILES+=("$t")
    else
      PARALLEL_FILES+=("$t")
    fi
  done
fi
COMBINED=()
[ "${#PARALLEL_FILES[@]}" -gt 0 ] && COMBINED+=("${PARALLEL_FILES[@]}")
[ "${#SERIAL_FILES[@]}" -gt 0 ] && COMBINED+=("${SERIAL_FILES[@]}")
PARALLEL_COUNT=${#PARALLEL_FILES[@]}
TOTAL_COUNT=${#COMBINED[@]}

RUN_TMP=""
trap 'rm -rf "$RUN_TMP"' EXIT

# run_test_file TESTFILE LOGFILE EXITFILE STATUSFILE -- runs (or serves from
# cache) a single test file. Safe to background: writes results to files
# instead of returning them, since a backgrounded function's exit status and
# variables are invisible to the parent shell.
run_test_file() {
  local t="$1" logfile="$2" exitfile="$3" statusfile="$4" key=""
  if [ "$CACHE_ENABLED" -eq 1 ]; then
    key="$(cache_key_for "$t")"
    if [ -f "$CACHE_DIR/$key" ]; then
      : > "$logfile"
      printf '0' > "$exitfile"
      printf 'CACHED' > "$statusfile"
      return 0
    fi
  fi
  printf 'RAN' > "$statusfile"
  if bash "$t" > "$logfile" 2>&1; then
    printf '0' > "$exitfile"
    [ "$CACHE_ENABLED" -eq 1 ] && : > "$CACHE_DIR/$key"
  else
    printf '1' > "$exitfile"
  fi
}

# run_parallel_batch -- runs COMBINED[0..PARALLEL_COUNT) in batches of $JOBS
# concurrent background jobs, waiting for each batch before starting the
# next. No GNU parallel and no bash-4-only job control (`wait -n`) so this
# stays portable to bash 3.2 (macOS's default /bin/bash).
run_parallel_batch() {
  local i=0 k batch_end pids
  while [ "$i" -lt "$PARALLEL_COUNT" ]; do
    batch_end=$((i + JOBS))
    [ "$batch_end" -gt "$PARALLEL_COUNT" ] && batch_end=$PARALLEL_COUNT
    pids=""
    k=$i
    while [ "$k" -lt "$batch_end" ]; do
      run_test_file "${COMBINED[$k]}" "$RUN_TMP/$k.log" "$RUN_TMP/$k.exit" "$RUN_TMP/$k.status" &
      pids="$pids $!"
      k=$((k + 1))
    done
    wait $pids
    i=$batch_end
  done
}

# A targeted (--for/--changed) run that did not fall back to the full suite
# is a subset by design, same as a PATTERN filter -- skip Part A below.
TARGETED_SUBSET=0
[ "$TARGETED_ACTIVE" -eq 1 ] && [ "$FULL_SUITE" -eq 0 ] && TARGETED_SUBSET=1

# ── Repeat loop ────────────────────────────────────────────────────────────────
# --repeat N re-runs the block below N times, stopping at the first iteration
# that fails. For the default N=1 this loop body runs exactly once and prints
# nothing but what it always printed -- no banner, no iteration count -- so
# output is unchanged from before --repeat existed.
_repeat_iter=1
while [ "$_repeat_iter" -le "$REPEAT" ]; do
  [ "$REPEAT" -gt 1 ] && echo "===== repeat $_repeat_iter/$REPEAT ====="

  RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/talos-run-tests.XXXXXX")"

  run_parallel_batch

  # Serial files run after the entire parallel batch has finished, one at a time.
  i=$PARALLEL_COUNT
  while [ "$i" -lt "$TOTAL_COUNT" ]; do
    run_test_file "${COMBINED[$i]}" "$RUN_TMP/$i.log" "$RUN_TMP/$i.exit" "$RUN_TMP/$i.status"
    i=$((i + 1))
  done

  # ── Report, in stable (original file-list) order ──────────────────────────────
  total_files=0
  failed_files=0
  i=0
  while [ "$i" -lt "$TOTAL_COUNT" ]; do
    t="${COMBINED[$i]}"
    name="$(basename "$t")"
    status="$(cat "$RUN_TMP/$i.status" 2>/dev/null || echo RAN)"
    rc="$(cat "$RUN_TMP/$i.exit" 2>/dev/null || echo 1)"
    log="$RUN_TMP/$i.log"
    total_files=$((total_files + 1))
    [ "$rc" != "0" ] && failed_files=$((failed_files + 1))

    if [ "$QUIET" -eq 1 ]; then
      if [ "$status" = "CACHED" ]; then
        echo "CACHED tests/$name"
      elif [ "$rc" = "0" ]; then
        echo "PASS  tests/$name"
      else
        echo "FAIL  tests/$name"
        cat "$log"
      fi
    else
      echo "-- $name"
      if [ "$status" = "CACHED" ]; then
        echo "CACHED tests/$name"
      else
        cat "$log"
      fi
      echo ""
    fi
    i=$((i + 1))
  done

  rm -rf "$RUN_TMP"

  # ── Part A: test-file count check ────────────────────────────────────────────
  # Only applies when no pattern filter and no targeted subset are active
  # (both run a subset of the suite by design).
  if [ "$SKIP_COUNT_CHECK" -eq 0 ] && [ -z "$PATTERN" ] && [ "$TARGETED_SUBSET" -eq 0 ] && [ -n "$EXPECTED_FILES" ]; then
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
    if [ "$REPEAT" -gt 1 ]; then
      echo "RESULT: repeat $_repeat_iter/$REPEAT FAILED -- $failed_files of $total_files test file(s) FAILED"
    else
      echo "RESULT: $failed_files of $total_files test file(s) FAILED"
    fi
    exit 1
  fi

  if [ "$_repeat_iter" -eq "$REPEAT" ]; then
    if [ -n "$PATTERN" ]; then
      echo "RESULT: all $total_files test file(s) passed (FILTERED by '$PATTERN' -- count check skipped)"
    elif [ "$TARGETED_SUBSET" -eq 1 ]; then
      echo "RESULT: all $total_files test file(s) passed (TARGETED via --for/--changed -- count check skipped)"
    elif [ "$SKIP_COUNT_CHECK" -eq 1 ]; then
      echo "RESULT: all $total_files test file(s) passed (count check skipped -- base ref unresolvable)"
    else
      echo "RESULT: all $total_files test file(s) passed"
    fi
  fi

  _repeat_iter=$((_repeat_iter + 1))
done
