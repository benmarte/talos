#!/usr/bin/env bash
# A test run must not dirty tracked files, and qa-run must survive one that does
# (#821). AC1: a red commit adds a 100644 stub that a later commit makes 100755;
# the red run changes its mode in the working copy, and qa-run still returns to
# the PR branch with a clean tree. AC2/AC3: run-tests.sh refuses a stub not
# committed executable instead of chmod'ing it. AC4: this repo's stubs pass.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

BASE_DIR="$SANDBOX"
BR=feat/issue-7-greet
trap '_sandbox_cleanup' EXIT

git_init() {
  cd "$BASE_DIR" || exit 1
  rm -rf "${BASE_DIR:?}"/* "${BASE_DIR:?}"/.git
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  mkdir -p scripts tests/stubs
}

# AC1: the runner here stands in for a test run that chmods tracked stubs in
# place (the old run-tests.sh did), so the restore is tested whatever the real
# runner does today.
git_init
cp "$TALOS_ROOT"/scripts/* scripts/
cat > tests/run-tests.sh <<'TALOS_h3w8c5r2ndpj'
#!/usr/bin/env bash
chmod +x tests/stubs/* 2>/dev/null
while [ $# -gt 0 ]; do
  case "$1" in --for) bash "$2"; exit $? ;; *) shift ;; esac
done
TALOS_h3w8c5r2ndpj
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
cat > tests/test-greet.sh <<'TALOS_t5n1y7b3zfqa'
#!/usr/bin/env bash
if [ -f feature.txt ]; then printf '  ok  AC1 greet prints hello\n'; exit 0; fi
printf 'FAIL  AC1 greet prints hello\n' >&2
exit 1
TALOS_t5n1y7b3zfqa
printf 'stub\n' > tests/stubs/evprune.py
chmod 644 tests/stubs/evprune.py
git add tests
git commit -q -m "test(#7): AC1 greet (red first)"
RED8="$(git rev-parse HEAD | cut -c1-8)"
printf 'done\n' > feature.txt
chmod 755 tests/stubs/evprune.py
git add feature.txt tests/stubs/evprune.py
git commit -q -m "feat(#7): greet"
export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
{
  printf '**PM spec:** greeting\n\n**Acceptance criteria**\n'
  printf -- '- [ ] AC1 `greet` prints hello (test)\n\n'
  printf '**Tests:** `tests/test-greet.sh`\n'
} > "$QA_SPEC_FILE"

OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?
assert_contains "$OUT" "AC1 red@$RED8 green@head" "AC1 the red run happened and the criterion is red then green"
assert_not_contains "$OUT" "could not return" "AC1 no could-not-return failure"
assert_eq "$BR" "$(git symbolic-ref -q --short HEAD)" "AC1 HEAD is back on the PR branch"
assert_eq "" "$(git status --porcelain --untracked-files=no)" "AC1 the working tree is clean"
assert_eq "0" "$RC" "AC1 qa-run exits 0"

# AC2/AC3: a sandbox repo holding a committed 100644 stub.
stub_repo() {  # MODE -- tests/stubs/s committed with MODE
  git_init
  cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh
  printf '#!/bin/sh\n' > tests/stubs/s
  chmod "$1" tests/stubs/s
  printf '#!/usr/bin/env bash\nexit 0\n' > tests/test-x.sh
  git add -A
  git commit -q -m "base"
}

stub_repo 644
ERR="$(bash tests/run-tests.sh 2>&1 >/dev/null)"; RC=$?
assert_eq "1" "$RC" "AC2 a 100644 stub fails the run"
assert_contains "$ERR" "tests/stubs/s" "AC2 stderr names the stub path"
assert_eq "" "$(git status --porcelain)" "AC2 the run leaves git status empty"
assert_eq "100644" "$(git ls-files -s tests/stubs/s | cut -c1-6)" "AC2 the committed mode is untouched"
assert_eq "no" "$([ -x tests/stubs/s ] && echo yes || echo no)" "AC2 the stub was not chmod'd in place"

ERR="$(bash tests/run-tests.sh --count-only --base-ref HEAD 2>&1 >/dev/null)"; RC=$?
assert_eq "1" "$RC" "AC3 --count-only fails on a 100644 stub"
assert_contains "$ERR" "tests/stubs/s" "AC3 --count-only names the stub path"

stub_repo 755
OUT="$(bash tests/run-tests.sh --count-only --base-ref HEAD 2>&1)"; RC=$?
assert_eq "0" "$RC" "AC3 --count-only passes with every stub 100755"

# AC4: this repo's stubs are all committed 100755, so the check is silent.
cd "$TALOS_ROOT" || exit 1
assert_eq "" "$(git ls-files -s tests/stubs | grep -v '^100755' || true)" "AC4 every stub here is committed 100755"
OUT="$(bash tests/run-tests.sh --list test-qa-restore-stub-mode 2>&1)"; RC=$?
assert_eq "0" "$RC" "AC4 run-tests.sh runs on this repo"
assert_not_contains "$OUT" "not committed executable" "AC4 no stub-mode complaint on this repo"

finish
