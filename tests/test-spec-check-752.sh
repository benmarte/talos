#!/usr/bin/env bash
# test-spec-check-752.sh -- spec-check and qa-run take Next.js route-group and
# dynamic-segment test paths, an unindented bullet list under a bare `Tests:`
# label, scan only the Tests line and its list for an open test file, and every
# refusal names its fix (#752).
#   AC1-AC6   `pipeline-criteria.sh spec-check <spec-file>` on files
#   AC7-AC8   `pipeline-criteria.sh qa-run` in a throwaway repo with a runner
#             stub that records the arguments it gets
# No GitHub write, no LLM call, no network.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

BASE_DIR="$SANDBOX"
CRIT="$TALOS_ROOT/scripts/pipeline-criteria.sh"
trap '_is_trap_owner && _sandbox_cleanup' EXIT

SPEC="$SANDBOX/spec.md"
GROUP='app/(routes)/farms/[id]/__tests__/a.test.tsx'

# spec LINE... -- one (test) criterion and one prose criterion, then the lines
spec() {
  {
    printf '**PM spec:** x\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 greet prints hello (test)\n'
    printf -- '- [ ] AC2 the README names it (prose: doc wording)\n\n'
    [ $# -eq 0 ] || printf '%s\n' "$@"
  } > "$SPEC"
}
sc() { OUT="$(bash "$CRIT" spec-check "$SPEC" 2>&1)"; RC=$?; }

# refused_case LABEL SLUG LINE... -- the spec is refused with spec-check: refused SLUG:
refused_case() {
  local label="$1" slug="$2"
  shift 2
  spec "$@"
  sc
  case "$RC:$OUT" in
    "1:spec-check: refused $slug: "*) _got=refused ;;
    *) _got="$RC:$OUT" ;;
  esac
  assert_eq "refused" "$_got" "$label"
}

# ── AC1: a route-group / dynamic-segment path passes spec-check ──────────────
spec "**Tests:** \`$GROUP\`"
sc
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC1 a Tests line with parentheses and square brackets in the path is ok, exit 0"

# ── AC2: the charset widens by ( ) [ ] only ──────────────────────────────────
refused_case "AC2 a semicolon in a path is still refused" tests-line-refused '**Tests:** `tests/a;b.sh`'
refused_case "AC2 a dollar sign in a path is still refused" tests-line-refused '**Tests:** `tests/a$b.sh`'
refused_case "AC2 a pipe in a path is still refused" tests-line-refused '**Tests:** `tests/a|b.sh`'
refused_case "AC2 an ampersand in a path is still refused" tests-line-refused '**Tests:** `tests/a&b.sh`'
refused_case "AC2 angle brackets in a path are still refused" tests-line-refused '**Tests:** `tests/a<b>.sh`'
refused_case "AC2 a backslash in a path is still refused" tests-line-refused '**Tests:** `tests/a\b.sh`'
refused_case "AC2 braces in a path are still refused" tests-line-refused '**Tests:** `tests/a{b}.sh`'
refused_case "AC2 a quote in a path is still refused" tests-line-refused "**Tests:** \`tests/a'b.sh\`"
refused_case "AC2 a space in a path is still refused" tests-line-refused '**Tests:** `tests/a b.sh`'
refused_case "AC2 .. in a path is still refused" tests-line-refused '**Tests:** `tests/../a.sh`'
refused_case "AC2 an absolute path is still refused" tests-line-refused '**Tests:** `/etc/a.sh`'
refused_case "AC2 a leading-dash path is still refused" tests-line-refused '**Tests:** `-tests/a.sh`'
refused_case "AC2 a directory path is still refused" tests-line-refused '**Tests:** `tests/`'
refused_case "AC2 a runner command is still refused" tests-line-refused '**Tests:** `npm test`'
refused_case "AC2 shell syntax beside the spans is still refused" tests-line-refused '**Tests:** `tests/a.sh` (new; AC1)'

# ── AC3: an unindented bullet list under a bare Tests label is the list ──────
spec '**Tests:**' '- `tests/test-a.sh`' '- `tests/test-b.sh`'
sc
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC3 backticked unindented bullets under a bare Tests label are the list"
spec '**Tests:**' '- tests/test-a.sh' '- tests/test-b.sh'
sc
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC3 bullets without backticks are the list too"
refused_case "AC3 the bullets are read as paths (a bad path in one is refused)" tests-line-refused \
  '**Tests:**' '- `tests/test-a.sh`' '- `../escape.sh`'
spec '**Tests:**' '- `tests/test-a.sh`' '' '- [ ] AC9 a later checklist item; with | shell $syntax (prose: x)'
sc
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC3 a checklist line after a blank line is not read as a path"
spec '**Tests:**' '- `tests/test-a.sh`' 'Notes on these; tests | and more.'
sc
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC3 the list ends at the first non-bullet line"
spec '**Tests:**' '' '- `tests/test-a.sh`'
sc
assert_eq "1:spec-check: refused tests-line-missing: 1 test criteria and no usable Tests: line" "$RC:$OUT" \
  "AC3 a blank line right after the label leaves the list empty"
spec '**Tests:**' '  - `tests/test-a.sh`' '  - `tests/test-b.sh`'
sc
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC3 the indented-continuation form still parses"
spec '**Tests:** `tests/test-a.sh`' '- `tests/test-b.sh`'
sc
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC3 an inline Tests line still parses, with an unrelated bullet below it"

# ── AC4: the list shape the Azure comment round trip gives ───────────────────
printf '%s\n' '**PM spec:** x' '' '**Acceptance criteria**' \
  '- [ ] AC1 greet prints hello (test)' '- [ ] AC2 bye (test)' '' \
  '**Tests:**' \
  '- `tests/test-a.sh`' \
  '- `app/(routes)/farms/[id]/__tests__/a.test.tsx`' \
  '' '**Files likely to change:**' '- `src/a.sh`' > "$SPEC"
sc
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC4 the bare label then unindented '- ' bullets passes spec-check"

# ── AC5: the open-file scan covers the Tests line and its list only ──────────
OPEN_FILES="- a new or existing file of the developer's choosing"
spec '**Tests:** `tests/test-a.sh`' '' '**Files likely to change:**' "$OPEN_FILES"
sc
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC5 an open-file phrase in the Files section is ok"
spec '**Tests:** `tests/test-a.sh` plus a new or existing file'
sc
case "$RC:$OUT" in
  "1:spec-check: refused tests-line-open: "*) _got=refused ;;
  *) _got="$RC:$OUT" ;;
esac
assert_eq "refused" "$_got" "AC5 'new or existing file' on the Tests line is tests-line-open"
spec '**Tests:** `tests/test-a.sh` AC2 in a file of the developer'"'"'s choice'
sc
case "$RC:$OUT" in
  "1:spec-check: refused tests-line-open: "*) _got=refused ;;
  *) _got="$RC:$OUT" ;;
esac
assert_eq "refused" "$_got" "AC5 'developer's choice' on the Tests line is tests-line-open"
spec '**Tests:**' '- `tests/test-a.sh`' "$OPEN_FILES"
sc
case "$RC:$OUT" in
  "1:spec-check: refused tests-line-open: "*) _got=refused ;;
  *) _got="$RC:$OUT" ;;
esac
assert_eq "refused" "$_got" "AC5 an open-file phrase in the Tests list is tests-line-open"

# ── AC6: each refusal names its fix on one line ──────────────────────────────
spec '**Tests:** `tests/test-a.sh` (new; AC1)'
sc
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "AC6 the shell-syntax refusal is one line"
assert_contains "$OUT" "spec-check: refused tests-line-refused: " "AC6 the shell-syntax refusal keeps its prefix"
assert_contains "$OUT" "own line" "AC6 the shell-syntax refusal says to move the note to its own line"
spec '**Tests:** `tests/a b.sh`'
sc
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "AC6 the charset refusal is one line"
assert_contains "$OUT" "spec-check: refused tests-line-refused: " "AC6 the charset refusal keeps its prefix"
assert_contains "$OUT" "letters, digits, _ . / - ( ) [ ]" "AC6 the charset refusal says which characters are allowed"
spec
sc
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "AC6 the missing refusal is one line"
assert_contains "$OUT" "spec-check: refused tests-line-missing: " "AC6 the missing refusal keeps its prefix"
assert_contains "$OUT" "bullet list right under it" "AC6 the missing refusal says the paths go on the Tests line or in a list under it"
spec '**Tests:** `tests/test-a.sh` plus a new or existing file'
sc
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "AC6 the open refusal is one line"
assert_contains "$OUT" "spec-check: refused tests-line-open: " "AC6 the open refusal keeps its prefix"
assert_contains "$OUT" "name the file" "AC6 the open refusal says to name the file"

# ── qa-run fixture ───────────────────────────────────────────────────────────
# new_repo -- a sandbox repo with the real scripts, a stub pipeline-vcs.sh, a
# stub tests/run-tests.sh and tools/rec.sh that log the arguments they get (one
# per line, to RUN_LOG / REC_LOG) and print ok / FAIL for AC1 by feature.txt, a
# red commit holding only the test file and a green commit adding feature.txt.
TP="$GROUP"
RUN_LOG="$BASE_DIR/.git/run.log"
REC_LOG="$BASE_DIR/.git/rec.log"
new_repo() {
  cd "$BASE_DIR" || exit 1
  rm -rf "${BASE_DIR:?}"/* "${BASE_DIR:?}"/.git "${BASE_DIR:?}"/.talos "${BASE_DIR:?}"/talos.pipeline.json
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  mkdir scripts tools tests
  cp "$TALOS_ROOT"/scripts/* scripts/
  cat > scripts/pipeline-vcs.sh <<'TALOS_k3v8p2w6zt15'
#!/usr/bin/env bash
case "$1" in
  view-issue)
    python3 -I -c 'import json, sys
print(json.dumps({"title": "t", "body": "issue body", "labels": [],
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$QA_SPEC_FILE" ;;
  pr-mergeable) echo MERGEABLE ;;
  checkout-pr) : ;;
  pr-head) git rev-parse feat/issue-7-greet ;;
  pr-head-ref) echo feat/issue-7-greet ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_k3v8p2w6zt15
  # The runner stubs: the arguments to a log, one per line; the same ok / FAIL lines as a test file.
  for stub in tests/run-tests.sh tools/rec.sh; do
    log="$RUN_LOG"; [ "$stub" = tools/rec.sh ] && log="$REC_LOG"
    {
      printf '#!/usr/bin/env bash\n'
      printf 'printf "%%s\\n" "$@" >> "%s"\n' "$log"
      printf 'if [ -f feature.txt ]; then echo "  ok  AC1 greet prints hello"; exit 0; fi\n'
      printf 'echo "FAIL  AC1 greet prints hello"; exit 1\n'
    } > "$stub"
  done
  printf 'base\n' > README.md
  git add -A
  git commit -q -m "base"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b feat/issue-7-greet
  mkdir -p "$(dirname "$TP")"
  printf '// the test\n' > "$TP"
  git add -A
  git commit -q -m "test(#7): AC1 greet (red first)"
  RED8="$(git rev-parse HEAD | cut -c1-8)"
  printf 'done\n' > feature.txt
  git add feature.txt
  git commit -q -m "feat(#7): greet"
  export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
  rm -f "$RUN_LOG" "$REC_LOG"
  {
    printf '**PM spec:** greeting\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n\n'
    printf '**Tests:** `%s`\n' "$TP"
  } > "$QA_SPEC_FILE"
}
qa_run() { OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?; }
cfg_file() { printf '%s' "$1" > "$BASE_DIR/talos.pipeline.json"; }

# ── AC7: qa-run runs a route-group path as one intact argument ───────────────
new_repo
qa_run
assert_not_contains "$OUT" "verdict BLOCKED spec" "AC7 a path with parentheses and square brackets is not BLOCKED spec"
assert_eq "0" "$RC" "AC7 the route-group Tests file runs: exit 0"
assert_contains "$OUT" "AC1 red@$RED8 green@head" "AC7 the criterion reads red then green"
assert_eq "$TP" "$(grep -xF -- "$TP" "$RUN_LOG" 2>/dev/null | head -n 1)" "AC7 the runner got the path as one intact argument"

# ── AC8: {file} and {dir} reach bash -c shell-quoted ─────────────────────────
ENTRY='{"match":"app/**/*.tsx","run":"bash tools/rec.sh {file} {dir}"}'
new_repo
cfg_file "{\"verify\":{\"targeted_commands\":[$ENTRY]}}"
qa_run
assert_not_contains "$OUT" "verdict BLOCKED spec" "AC8 an entry-matched route-group path is not BLOCKED spec"
assert_eq "0" "$RC" "AC8 the entry ran: exit 0"
assert_eq "$TP
$(dirname "$TP")" "$(head -n 2 "$REC_LOG" 2>/dev/null)" "AC8 {file} and {dir} arrive as two intact arguments"
assert_eq "4" "$(wc -l < "$REC_LOG" 2>/dev/null | tr -d ' ')" "AC8 no extra argument from a split or a glob (two per run, head and red)"
OLD='svc/tests/GreetTests.cs'
TP="$OLD"
ENTRY='{"match":"svc/**/*.cs","run":"bash tools/rec.sh {file} {class} {dir}"}'
new_repo
cfg_file "{\"verify\":{\"targeted_commands\":[$ENTRY]}}"
qa_run
assert_eq "0" "$RC" "AC8 a path inside the old charset: exit 0"
assert_eq "$OLD
GreetTests
svc/tests" "$(head -n 3 "$REC_LOG" 2>/dev/null)" "AC8 a path inside the old charset is substituted unchanged"

finish
