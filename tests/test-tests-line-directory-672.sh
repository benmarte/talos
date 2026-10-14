#!/usr/bin/env bash
# A `Tests:` path that is a directory is a fault of the spec (#672):
#   AC1  spec-check refuses a path ending in / and names it
#   AC2  qa-run answers BLOCKED spec (exit 4), not FAIL, for a path ending in /
#   AC3  qa-run answers BLOCKED spec for a directory named without the slash
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
trap '_sandbox_cleanup' EXIT

SPEC="$SANDBOX/spec.md"
write_spec() {  # $1 = file, $2 = the Tests: line
  {
    printf '**PM spec:** greeting\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n\n'
    printf '%s\n' "$2"
  } > "$1"
}

# ── AC1: spec-check ──────────────────────────────────────────────────────────
write_spec "$SPEC" '**Tests:** `tests/test-greet.sh`, `tests/stubs/`'
OUT="$(bash "$TALOS_ROOT/scripts/pipeline-criteria.sh" spec-check "$SPEC" 2>&1)"; RC=$?
assert_eq "1:spec-check: refused tests-line-refused: test path is a directory: tests/stubs/" "$RC:$OUT" \
  "AC1 spec-check refuses a Tests: path ending in / and names it"

# ── qa-run fixture: a repo with a test file and the directory tests/stubs ────
cd "$SANDBOX" || exit 1
git init -q
git checkout -q -B main
git remote add origin git@github.com:acme/widget.git 2>/dev/null || true
git config user.email t@t.invalid
git config user.name t
mkdir scripts tests
cp "$TALOS_ROOT"/scripts/* scripts/
cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh
cat > scripts/pipeline-vcs.sh <<'TALOS_k7d2m9x4q1wz'
#!/usr/bin/env bash
case "$1" in
  view-issue)
    python3 -I -c 'import json, sys
print(json.dumps({"title": "t", "body": "issue body", "labels": [],
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$QA_SPEC_FILE" ;;
  pr-mergeable) echo MERGEABLE ;;
  checkout-pr) ;;
  pr-head) git rev-parse feat/issue-7-greet ;;
  pr-head-ref) echo feat/issue-7-greet ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_k7d2m9x4q1wz
printf 'base\n' > README.md
git add -A
git commit -q -m base
git update-ref refs/remotes/origin/main HEAD
git checkout -q -b feat/issue-7-greet
mkdir tests/stubs
printf 'x\n' > tests/stubs/claude
printf '#!/usr/bin/env bash\nprintf "  ok  AC1 greet\\n"\n' > tests/test-greet.sh
git add tests
git commit -q -m "test(#7): AC1 (red first)"
export QA_SPEC_FILE="$SANDBOX/.git/qa-spec.md"

qa_run() {  # $1 = the Tests: line; sets OUT and RC
  write_spec "$QA_SPEC_FILE" "$1"
  OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?
}

# ── AC2: a path ending in / ──────────────────────────────────────────────────
qa_run '**Tests:** `tests/test-greet.sh`, `tests/stubs/`'
assert_eq "4" "$RC" "AC2 qa-run: a Tests: path ending in / exits 4"
assert_contains "$OUT" "qa-run: verdict BLOCKED spec:" "AC2 qa-run: a BLOCKED spec verdict line"
assert_contains "$OUT" "tests/stubs/" "AC2 qa-run: names the directory"
assert_not_contains "$OUT" "qa-run: verdict FAIL" "AC2 qa-run: no FAIL verdict line"

# ── AC3: a directory at the PR head, no trailing slash ───────────────────────
qa_run '**Tests:** `tests/test-greet.sh`, `tests/stubs`'
assert_eq "4" "$RC" "AC3 qa-run: a directory without the slash exits 4"
assert_contains "$OUT" "qa-run: verdict BLOCKED spec:" "AC3 qa-run: a BLOCKED spec verdict line"
assert_not_contains "$OUT" "test file(s) missing" "AC3 qa-run: no missing-file FAIL"
assert_not_contains "$OUT" "qa-run: verdict FAIL" "AC3 qa-run: no FAIL verdict line"

finish
