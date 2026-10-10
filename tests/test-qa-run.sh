#!/usr/bin/env bash
# `pipeline-criteria.sh qa-run <issue> <pr>` (#549, epic #558): the QA criteria
# check as ONE call. It reads the spec's `Tests:` line, validates every item
# (the spec is data: nothing from it is ever executed), runs the targeted tests
# at the PR head and at the red commit, and prints one line per criterion plus
# one verdict line. Behavioural: each case builds a throwaway repo (a main
# branch, a tests-only red commit, a green commit), a stub pipeline-vcs.sh that
# answers the three verbs qa-run uses, and the real runner scripts.
#
# The injection cases carry a marker file the "test" would create if anything
# from the spec ran; the assertion is that the marker never appears.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

BASE_DIR="$SANDBOX"
BR=feat/issue-7-greet
WTS=()
cleanup_wts() { local w; for w in ${WTS[@]+"${WTS[@]}"}; do rm -rf "${w:?}"; done; }
trap '_is_trap_owner && cleanup_wts; _sandbox_cleanup' EXIT

# write_test PATH KIND -- the criterion test. It records that it ran. KIND:
#   impl    red until feature.txt exists (the "implementation"), then green
#   green   always green (a vacuous test)
#   red     always red
write_test() {
  case "$2" in
    impl)  body='if [ -f feature.txt ]; then printf "  ok  AC1 greet prints hello\n"; exit 0; fi' ;;
    green) body='printf "  ok  AC1 greet prints hello\n"; exit 0' ;;
    *)     body=':' ;;
  esac
  {
    printf '#!/usr/bin/env bash\n: > "${RAN_MARKER:-/dev/null}"\n%s\n' "$body"
    printf 'printf "FAIL  AC1 greet prints hello\\n" >&2\n'
    printf 'printf "      expected: hello | actual: <missing>\\n" >&2\nexit 1\n'
  } > "$1"
}

# new_repo [KIND [RED_EXTRA]] -- a fresh sandbox repo: scripts/ (the real
# scripts, with a stub pipeline-vcs.sh), tests/run-tests.sh, a base commit on
# main, a red commit on $BR (the test; RED_EXTRA, when given, is a source file
# added in the same commit, making it not tests-only) and a green commit.
# Leaves the repo on $BR at the green commit.
new_repo() {
  local kind="${1:-impl}" extra="${2:-}"
  cd "$BASE_DIR" || exit 1
  rm -rf "${BASE_DIR:?}"/* "${BASE_DIR:?}"/.git "${BASE_DIR:?}"/.talos
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  mkdir scripts tests
  cp "$TALOS_ROOT"/scripts/* scripts/
  cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh
  cat > scripts/pipeline-vcs.sh <<'TALOS_a3p8v1c6ne52'
#!/usr/bin/env bash
# Stub for the verbs qa-run calls. The branch is already checked out.
printf '%s\n' "$*" >> "${QA_VCS_LOG:-/dev/null}"
case "$1" in
  view-issue)
    python3 -I -c 'import json, sys
print(json.dumps({"title": "t", "body": "issue body", "labels": [],
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$QA_SPEC_FILE" ;;
  pr-mergeable) echo "${QA_MERGEABLE:-MERGEABLE}"; [ "${QA_MERGEABLE:-MERGEABLE}" != CONFLICTING ] ;;
  checkout-pr) : ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_a3p8v1c6ne52
  printf 'base\n' > README.md
  git add -A
  git commit -q -m "base"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b "$BR"
  write_test tests/test-greet.sh "$kind"
  git add tests
  if [ -n "$extra" ]; then mkdir -p "$(dirname "$extra")"; printf 'x\n' > "$extra"; git add "$extra"; fi
  git commit -q -m "test(#7): AC1 greet (red first)"
  RED_SHA="$(git rev-parse HEAD)"
  RED8="${RED_SHA:0:8}"
  printf 'done\n' > feature.txt
  git add feature.txt
  git commit -q -m "feat(#7): greet"
  export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
  export RAN_MARKER="$BASE_DIR/.git/qa-ran.marker"
  export QA_VCS_LOG="$BASE_DIR/.git/qa-vcs.log"
  unset QA_MERGEABLE
  rm -f "$RAN_MARKER" "$BASE_DIR/pwned" "$QA_VCS_LOG"
}

# spec TESTS_LINE -- write a PM spec with AC1 (test) and AC2 (prose); TESTS_LINE
# is the whole `Tests:` line ("" omits it). The spec lives outside the repo.
spec() {
  {
    printf '**PM spec:** greeting\n\n**Goal:** greet.\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n'
    printf -- '- [ ] AC2 the README names it (prose: doc wording)\n\n'
    [ -z "${1:-}" ] || printf '%s\n' "$1"
    printf '**Files likely to change:** `feature.txt`\n'
  } > "$QA_SPEC_FILE"
}

qa_run() {  # sets OUT and RC
  OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?
}

# ── 1. happy path: red at the red commit, green at head, back on the branch ──
new_repo
spec '**Tests:** `tests/test-greet.sh`'
qa_run
assert_eq "0" "$RC" "happy path: exit 0"
assert_contains "$OUT" "AC1 red@$RED8 green@head" "happy path: the test criterion is red at the red commit, green at head"
assert_contains "$OUT" "AC2 prose hand-checked" "happy path: the prose criterion is hand-checked"
assert_contains "$OUT" "qa-run: verdict PASS" "happy path: a PASS verdict line"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c '^qa-run: verdict')" "happy path: exactly one verdict line"
assert_eq "$BR" "$(git symbolic-ref --short HEAD)" "happy path: HEAD is back on the PR branch after the red run"
assert_eq "" "$(git status --porcelain)" "happy path: the worktree is clean afterwards"
assert_file_exists "$RAN_MARKER" "happy path: the test file was run"
assert_contains "$(cat "$QA_VCS_LOG")" "checkout-pr 9" "happy path: checks out the PR itself"
assert_contains "$(cat "$QA_VCS_LOG")" "pr-mergeable 9" "happy path: checks mergeability before running anything"
assert_contains "$(cat "$QA_VCS_LOG")" "view-issue 7 --spec" "happy path: reads the spec itself"

# A bare-path Tests: line (no backticks), plus a valid name filter, also works.
new_repo
spec '**Tests:** tests/test-greet.sh AC1'
qa_run
assert_eq "0" "$RC" "bare Tests: line with a valid name filter: exit 0"
assert_contains "$OUT" "AC1 red@$RED8 green@head" "bare Tests: line with a valid name filter: red then green"

# ── 3. vacuous: the test is already green at the red commit ──────────────────
new_repo green
spec '**Tests:** `tests/test-greet.sh`'
qa_run
assert_eq "1" "$RC" "vacuous: exit 1"
assert_contains "$OUT" "AC1 FAIL vacuous (green at red@$RED8)" "vacuous: a test green at the red commit is FAIL (vacuous)"
assert_contains "$OUT" "qa-run: verdict FAIL" "vacuous: a FAIL verdict line"
assert_eq "$BR" "$(git symbolic-ref --short HEAD)" "vacuous: HEAD is back on the PR branch"

# ── 4. red at head: the test never goes green ────────────────────────────────
new_repo red
spec '**Tests:** `tests/test-greet.sh`'
qa_run
assert_eq "1" "$RC" "failing at head: exit 1"
assert_contains "$OUT" "AC1 FAIL head=fail" "failing at head: names the head result"
assert_contains "$OUT" "expected: hello" "failing at head: quotes the failing assertion's detail"
assert_contains "$OUT" "qa-run: verdict FAIL" "failing at head: a FAIL verdict line"

# ── 5. a missing test file ───────────────────────────────────────────────────
new_repo
spec '**Tests:** `tests/test-nope.sh`'
qa_run
assert_eq "1" "$RC" "missing test file: exit 1"
assert_contains "$OUT" "tests/test-nope.sh" "missing test file: names the file"
assert_contains "$OUT" "missing" "missing test file: reported as missing"
assert_contains "$OUT" "AC1 FAIL head=missing" "missing test file: the criterion has no result at head"
assert_contains "$OUT" "qa-run: verdict FAIL" "missing test file: a FAIL verdict line"
assert_file_absent "$RAN_MARKER" "missing test file: nothing ran"

# One real file and one missing: the real one runs, the verdict still fails.
new_repo
spec '**Tests:** `tests/test-greet.sh`, `tests/test-nope.sh`'
qa_run
assert_eq "1" "$RC" "one file missing: exit 1"
assert_contains "$OUT" "tests/test-nope.sh" "one file missing: names the missing file"
assert_contains "$OUT" "AC1 red@$RED8 green@head" "one file missing: the existing file's criterion is still proven"

# ── 6. injection shapes: nothing from the spec runs, the verdict fails ───────
# Each line is one Tests: value; the test file would create $RAN_MARKER if run.
injection_case() {  # $1=label $2=the Tests: line
  new_repo
  spec "$2"
  qa_run
  assert_eq "1" "$RC" "refused ($1): exit 1"
  assert_contains "$OUT" "refused" "refused ($1): the output says the Tests: value was refused"
  assert_contains "$OUT" "qa-run: verdict FAIL" "refused ($1): a FAIL verdict line"
  assert_file_absent "$RAN_MARKER" "refused ($1): no test ran"
  assert_file_absent "$BASE_DIR/pwned" "refused ($1): nothing from the spec executed"
  assert_not_contains "$OUT" "red@" "refused ($1): no criterion line claims a result"
  assert_eq "$BR" "$(git symbolic-ref --short HEAD)" "refused ($1): HEAD untouched"
}
injection_case "semicolon rm"      '**Tests:** `tests/test-greet.sh; touch pwned`'
injection_case "bare semicolon"    '**Tests:** tests/test-greet.sh ; touch pwned'
injection_case "command subst"     '**Tests:** `tests/$(touch pwned).sh`'
injection_case "backtick subst"    '**Tests:** `tests/test-greet.sh` $(touch pwned)'
injection_case "ampersand chain"   '**Tests:** `tests/test-greet.sh` && touch pwned'
injection_case "pipe"              '**Tests:** `tests/test-greet.sh | sh`'
injection_case "space in path"     '**Tests:** `tests/my test.sh`'
injection_case "dotdot"            '**Tests:** `tests/../tests/test-greet.sh`'
injection_case "leading dotdot"    '**Tests:** `../outside.sh`'
injection_case "absolute path"     '**Tests:** `/etc/passwd`'
injection_case "leading dash"      '**Tests:** `-rf`'
injection_case "dash flag path"    '**Tests:** `--for tests/test-greet.sh`'
injection_case "runner command"    '**Tests:** `npm test -- --grep AC1`'
injection_case "bash runner"       '**Tests:** `bash tests/test-greet.sh`'
injection_case "redirect"          '**Tests:** `tests/test-greet.sh > pwned`'
injection_case "glob"              '**Tests:** `tests/*.sh`'
injection_case "bad filter"        '**Tests:** `tests/test-greet.sh` `AC1 -x`'
injection_case "filter metachar"   '**Tests:** `tests/test-greet.sh` `AC1$HOME`'
injection_case "unbalanced tick"   '**Tests:** `tests/test-greet.sh'

# A refusal prints the offending value only as sanitised data: control bytes and
# a long value are cut.
new_repo
spec "**Tests:** \`tests/$(printf 'a%.0s' $(seq 1 300)).sh;\`"
qa_run
assert_eq "1" "$RC" "long bad value: exit 1"
assert_eq "0" "$(printf '%s\n' "$OUT" | awk '{ if (length($0) > 400) n++ } END { print n+0 }')" \
  "long bad value: no output line is longer than 400 bytes"

# ── 7. no Tests: line ────────────────────────────────────────────────────────
new_repo
spec ''
qa_run
assert_eq "1" "$RC" "no Tests: line with a (test) criterion: exit 1"
assert_contains "$OUT" "no Tests: line" "no Tests: line: says so"
assert_contains "$OUT" "qa-run: verdict FAIL" "no Tests: line: a FAIL verdict line"
assert_file_absent "$RAN_MARKER" "no Tests: line: nothing ran"

# An all-prose spec needs no tests: hand-checked, verdict PASS, nothing ran.
new_repo
printf '**PM spec:** x\n- [ ] AC1 the README is clear (prose: wording)\n' > "$QA_SPEC_FILE"
qa_run
assert_eq "0" "$RC" "all-prose spec: exit 0"
assert_contains "$OUT" "AC1 prose hand-checked" "all-prose spec: hand-checked"
assert_contains "$OUT" "qa-run: verdict PASS" "all-prose spec: a PASS verdict line"
assert_file_absent "$RAN_MARKER" "all-prose spec: nothing ran"

# ── 8. not mergeable: nothing runs ───────────────────────────────────────────
new_repo
spec '**Tests:** `tests/test-greet.sh`'
export QA_MERGEABLE=CONFLICTING
qa_run
assert_eq "1" "$RC" "conflicting PR: exit 1"
assert_contains "$OUT" "CONFLICTING" "conflicting PR: says why"
assert_contains "$OUT" "qa-run: verdict FAIL" "conflicting PR: a FAIL verdict line"
assert_file_absent "$RAN_MARKER" "conflicting PR: no test ran"
unset QA_MERGEABLE

# ── 9. the red commit is not tests-only: noted, red proof skipped ────────────
new_repo impl src/feature.js
spec '**Tests:** `tests/test-greet.sh`'
qa_run
assert_eq "0" "$RC" "red commit with source: exit 0 (a note, not a failure)"
assert_contains "$OUT" "not tests-only" "red commit with source: noted"
assert_contains "$OUT" "AC1 green@head (red: missing)" "red commit with source: the red proof is skipped, green at head still reported"
assert_eq "$BR" "$(git symbolic-ref --short HEAD)" "red commit with source: HEAD untouched"

# ── 10. a dirty tree after the head run: the red checkout is skipped ─────────
new_repo
cat > tests/test-greet.sh <<'TALOS_h5d9t2y7bk30'
#!/usr/bin/env bash
: > "${RAN_MARKER:-/dev/null}"
echo scribble >> README.md
printf '  ok  AC1 greet prints hello\n'
TALOS_h5d9t2y7bk30
git add tests; git commit -q -m "test: a test that dirties a tracked file"
spec '**Tests:** `tests/test-greet.sh`'
qa_run
assert_eq "0" "$RC" "dirty tree after head run: exit 0"
assert_contains "$OUT" "red proof skipped" "dirty tree after head run: the red proof is skipped with a note"
assert_eq "$BR" "$(git symbolic-ref --short HEAD)" "dirty tree after head run: HEAD untouched"
git checkout -q -- README.md

# ── 11. a linked worktree (detached HEAD): tagged, and HEAD restored ─────────
new_repo
spec '**Tests:** `tests/test-greet.sh`'
WT="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-qa-wt.XXXXXX")" || exit 1
WTS+=("$WT")
rmdir "$WT"
git worktree add -q --detach "$WT" HEAD
HEAD_BEFORE="$(git -C "$WT" rev-parse HEAD)"
( cd "$WT" && OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; echo "rc=$?" > "$BASE_DIR/wt.rc"; printf '%s\n' "$OUT" > "$BASE_DIR/wt.out" )
assert_eq "rc=0" "$(cat "$BASE_DIR/wt.rc")" "linked worktree: exit 0"
assert_contains "$(cat "$BASE_DIR/wt.out")" "AC1 red@$RED8 green@head" "linked worktree: red then green"
assert_eq "$HEAD_BEFORE" "$(git -C "$WT" rev-parse HEAD)" "linked worktree: detached HEAD restored to the PR head"
assert_contains "$(cat "$WT/.talos/env" 2>/dev/null)" "TALOS_ISSUE_NUMBER=7" "linked worktree: qa-run tagged the worktree for issue 7 (no profile step)"
# The main checkout is never tagged (tag refuses it).
assert_file_absent "$BASE_DIR/.talos/env" "main checkout: qa-run does not tag it"

# ── 12. usage ────────────────────────────────────────────────────────────────
new_repo
bash scripts/pipeline-criteria.sh qa-run x 9 >/dev/null 2>&1
assert_eq "2" "$?" "qa-run: a non-numeric issue exits 2"
bash scripts/pipeline-criteria.sh qa-run 7 >/dev/null 2>&1
assert_eq "2" "$?" "qa-run: a missing PR exits 2"
bash scripts/pipeline-criteria.sh qa-run 7 '9;id' >/dev/null 2>&1
assert_eq "2" "$?" "qa-run: a PR id with shell syntax exits 2"

finish
