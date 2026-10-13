#!/usr/bin/env bash
# qa-run takes the red proof from the red commit's own change (#658): merging a
# moved base branch into the PR branch must not make a tests-only red commit
# look "not tests-only". Each case builds a throwaway repo like test-qa-run.sh:
# main, a red commit on the PR branch, a green commit, then main moves (a
# non-test change) and is merged into the branch.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

BASE_DIR="$SANDBOX"
BR=feat/issue-7-greet
trap '_sandbox_cleanup' EXIT

write_test() {  # PATH KIND (impl = red until feature.txt exists, green = vacuous)
  case "$2" in
    impl) body='if [ -f feature.txt ]; then printf "  ok  AC1 greet prints hello\n"; exit 0; fi' ;;
    *)    body='printf "  ok  AC1 greet prints hello\n"; exit 0' ;;
  esac
  {
    printf '#!/usr/bin/env bash\n%s\n' "$body"
    printf 'printf "FAIL  AC1 greet prints hello\\n" >&2\nexit 1\n'
  } > "$1"
}

# new_repo KIND RED_EXTRA MERGE -- RED_EXTRA: a source file added in the red
# commit; MERGE=yes: main gains a non-test change and is merged into the branch.
new_repo() {
  local kind="$1" extra="$2" merge="$3"
  cd "$BASE_DIR" || exit 1
  rm -rf "${BASE_DIR:?}"/* "${BASE_DIR:?}"/.git
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  mkdir scripts tests
  cp "$TALOS_ROOT"/scripts/* scripts/
  cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh
  cat > scripts/pipeline-vcs.sh <<'TALOS_k7d2m9x4qw81'
#!/usr/bin/env bash
case "$1" in
  view-issue)
    python3 -I -c 'import json, sys
print(json.dumps({"title": "t", "body": "b", "labels": [],
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$QA_SPEC_FILE" ;;
  pr-mergeable) echo MERGEABLE ;;
  checkout-pr) : ;;
  pr-head) git rev-parse feat/issue-7-greet ;;
  pr-head-ref) echo feat/issue-7-greet ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_k7d2m9x4qw81
  printf 'base\n' > README.md
  git add -A
  git commit -q -m "base"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b "$BR"
  write_test tests/test-greet.sh "$kind"
  git add tests
  if [ -n "$extra" ]; then mkdir -p "$(dirname "$extra")"; printf 'x\n' > "$extra"; git add "$extra"; fi
  git commit -q -m "test(#7): AC1 greet (red first)"
  RED8="$(git rev-parse HEAD | cut -c1-8)"
  printf 'done\n' > feature.txt
  git add feature.txt
  git commit -q -m "feat(#7): greet"
  if [ "$merge" = yes ]; then
    git checkout -q main
    printf 'moved\n' > main-change.txt
    git add main-change.txt
    git commit -q -m "main moves"
    git update-ref refs/remotes/origin/main HEAD
    git checkout -q "$BR"
    git merge -q --no-edit origin/main >/dev/null 2>&1 || exit 1
  fi
  export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
  {
    printf '**PM spec:** greeting\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n\n'
    printf '**Tests:** `tests/test-greet.sh`\n'
  } > "$QA_SPEC_FILE"
}

qa_run() { OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?; }

# AC1/AC2: tests-only red commit, base merged into the branch: red proof taken.
new_repo impl "" yes
qa_run
assert_eq "0" "$RC" "AC2 merged base: exit 0"
assert_contains "$OUT" "red $RED8" "AC1 merged base: the header shows the red commit"
assert_not_contains "$OUT" "not tests-only" "AC1 merged base: no not-tests-only note"
assert_contains "$OUT" "AC1 red@$RED8 green@head" "AC2 merged base: criterion line is red then green"
assert_contains "$OUT" "qa-run: verdict PASS" "AC2 merged base: verdict PASS"

# AC3: a vacuous test is a FAIL after the merge.
new_repo green "" yes
qa_run
assert_eq "1" "$RC" "AC3 merged base vacuous: exit 1"
assert_contains "$OUT" "AC1 FAIL vacuous (green at red@$RED8)" "AC3 merged base vacuous: reported as FAIL"

# AC4: a red commit that adds a source file is still not tests-only.
for m in yes no; do
  new_repo impl src/greet.sh "$m"
  qa_run
  assert_contains "$OUT" "red commit $RED8 is not tests-only (src/greet.sh)" "AC4 source in red (merge=$m): noted not tests-only"
  assert_contains "$OUT" "red: missing" "AC4 source in red (merge=$m): red proof skipped"
done

finish
