#!/usr/bin/env bash
# test-guards-shell-glob.sh -- guard discovery recognises shell glob walkers (#959).
#
# `pipeline-verify.sh --guards` lists git-tracked test files that walk the repo.
# A shell test walks it with `for f in "$ROOT"/tests/test-*.sh` or `find <dir> |
# while`, so those forms count; a loop over literal words does not. Pinned by id:
#   AC1  a `for f in "$ROOT"/tests/test-*.sh` loop is listed
#   AC2  a `find <dir> -name ...` walk is listed
#   AC3  a loop over literal words is not listed
#   AC4  on this repo, tests/test-shard-weights.sh is listed
#   AC5  docs/reference.md names the shell forms and the CHANGELOG has the line
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

GUARDS_SH="$TALOS_ROOT/scripts/pipeline-verify.sh"
REPO="$SANDBOX/repo"
mkdir -p "$REPO/tests"
(
  cd "$REPO" && git init -q && git config user.email t@t.invalid && git config user.name t
  printf '#!/usr/bin/env bash\nROOT=.\nfor f in "$ROOT"/tests/test-*.sh; do echo "$f"; done\n' > tests/test-glob-loop.sh
  printf '#!/usr/bin/env bash\nfor f in tests/*.json; do echo "$f"; done\n' > tests/test-glob-bare.sh
  printf '#!/usr/bin/env bash\nfind "$1" -name "*.sh" | while read -r f; do echo "$f"; done\n' > tests/test-find-pipe.sh
  printf '#!/usr/bin/env bash\nwhile read -r f; do echo "$f"; done < <(find tests -type f)\n' > tests/test-find-sub.sh
  printf '#!/usr/bin/env bash\nfor x in a b c; do echo "$x"; done\n' > tests/test-literal.sh
  printf '#!/usr/bin/env bash\nfor x in a/b c/d; do echo "$x"; done\nfor y in *.sh; do echo "$y"; done\n' > tests/test-no-path-glob.sh
  git add tests && git commit -q -m fixture
) >/dev/null 2>&1
bash "$GUARDS_SH" --guards --worktree "$REPO" > "$SANDBOX/out" 2> "$SANDBOX/err" < /dev/null
OUT="$(cat "$SANDBOX/out")"

assert_contains "$OUT" "tests/test-glob-loop.sh" "AC1 a for-loop over \"\$ROOT\"/tests/test-*.sh is listed"
assert_contains "$OUT" "tests/test-glob-bare.sh" "AC1 a for-loop over dir/*.json is listed"
assert_contains "$OUT" "tests/test-find-pipe.sh" "AC2 find <dir> -name piped into a loop is listed"
assert_contains "$OUT" "tests/test-find-sub.sh" "AC2 find <dir> in a process substitution loop is listed"
assert_not_contains "$OUT" "tests/test-literal.sh" "AC3 a loop over literal words is not listed"
assert_not_contains "$OUT" "tests/test-no-path-glob.sh" "AC3 a loop with no glob over a path is not listed"

REAL="$(bash "$GUARDS_SH" --guards --worktree "$TALOS_ROOT" 2>/dev/null < /dev/null)"
assert_contains "$REAL" "tests/test-shard-weights.sh" "AC4 --guards on this repo lists tests/test-shard-weights.sh"
assert_eq "true" "$([ "$(printf '%s\n' "$REAL" | wc -l | tr -d ' ')" -le 50 ] && echo true || echo false)" "AC4 the list stays within the 50 cap"

REF="$(cat "$TALOS_ROOT/docs/reference.md")"
assert_contains "$REF" 'for f in "$ROOT"/tests/test-*.sh' "AC5 docs/reference.md names the shell glob loop form"
assert_contains "$REF" "find <dir>" "AC5 docs/reference.md names the find form"
assert_contains "$(cat "$TALOS_ROOT/CHANGELOG.md")" "shell glob" "AC5 CHANGELOG names the shell glob walkers"

finish
