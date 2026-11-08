#!/usr/bin/env bash
# test-dev-tests-832.sh -- verify.dev_tests and automatic guard-test discovery (#832).
#
# `verify.dev_tests` is the developer's verification set: repo commands for the
# touched packages and their importers, plus the repo-wide guard tests Talos
# finds itself with `pipeline-verify.sh --guards`. This file pins, by criterion id:
#   AC1  the key: a table row, validated, repo-only
#   AC2  the developer prompt carries the set block with both commands and the guards
#   AC3  --guards lists walkers and parsers, nothing else; tracked, sorted, capped at 50
#   AC4  --guards is read-only and silent when nothing matches
#   AC5  key unset or []: the prompt is today's, byte for byte, discovery not run
#   AC6  the template carries the DEV_TESTS_LINE marker and the renderer allows it
#   AC7  agents/developer.md and docs/reference.md tell the developer to run the set
# Every test runs in a sandbox: no provider read, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TMPDIR="$SANDBOX/tmp"
export TALOS_RETRY_SLEEP_SCALE=0
mkdir -p "$TMPDIR"
unset TALOS_PROMPT_GUIDE_MAX_BYTES
ERR="$SANDBOX/stderr"
OUT="$SANDBOX/stdout"
CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
GHOME="$SANDBOX/talos-home"
mkdir -p "$GHOME"
export TALOS_HOME="$GHOME"
MARK='{''{DEV_TESTS_LINE}''}'

git config user.email "test@talos.invalid"
git config user.name "talos-test"

# ── fixture: a checkout holding guard and non-guard test files ───────────────
mkdir -p pkg/a pkg/b web src py
printf 'package a\nimport "path/filepath"\nfunc TestWalk() { filepath.WalkDir(".", nil) }\n' > pkg/a/walk_test.go
printf 'package b\nimport "go/parser"\nfunc TestParse() { _ = parser.ParseFile }\n' > pkg/b/parse_test.go
printf 'package b\nfunc TestPlain() {}\n' > pkg/b/plain_test.go
printf 'package b\nimport "path/filepath"\nfunc Walker() { filepath.Walk(".", nil) }\n' > pkg/b/walker.go
printf 'import os\ndef test_tree():\n    for r, d, f in os.walk("."):\n        pass\n' > py/test_tree.py
printf 'def test_plain():\n    pass\n' > py/test_plain.py
printf 'import fs from "fs";\ntest("t", () => { fs.readdirSync(".", { recursive: true }); });\n' > web/tree.test.ts
printf 'test("t", () => {});\n' > web/plain.test.ts
printf 'import os\nos.walk(".")\n' > src/helper.py
git add pkg py web src
git commit -q -m "fixture"
git init -q --bare "$SANDBOX/origin.git"
git remote set-url origin "$SANDBOX/origin.git" 2>/dev/null || git remote add origin "$SANDBOX/origin.git"
git push -q origin HEAD:main 2>/dev/null
git fetch -q origin 2>/dev/null
# Untracked on purpose: it holds a walk but is not in the index.
printf 'package u\nimport "path/filepath"\nfunc TestUntracked() { filepath.WalkDir(".", nil) }\n' > pkg/untracked_test.go

GUARDS_SH="$TALOS_ROOT/scripts/pipeline-verify.sh"
guards() { bash "$GUARDS_SH" --guards > "$OUT" 2> "$ERR" < /dev/null; RC=$?; }

# ── AC3: discovery ────────────────────────────────────────────────────────────
guards
assert_eq "0" "$RC" "AC3 --guards exits 0"
WANT="pkg/a/walk_test.go
pkg/b/parse_test.go
py/test_tree.py
web/tree.test.ts"
assert_eq "$WANT" "$(cat "$OUT")" "AC3 --guards lists the walk and parse tests, sorted, and nothing else (no pattern-free test, no non-test source, no untracked file)"
assert_eq "" "$(cat "$ERR")" "AC3 --guards writes nothing to stderr"

# ── AC4: read-only, silent when nothing matches ───────────────────────────────
git status --porcelain > "$SANDBOX/status.before"
guards
git status --porcelain > "$SANDBOX/status.after"
if cmp -s "$SANDBOX/status.before" "$SANDBOX/status.after"; then pass "AC4 git status --porcelain is unchanged by --guards"
else fail "AC4 git status --porcelain is unchanged by --guards"; fi
EMPTY="$SANDBOX/empty-repo"
mkdir -p "$EMPTY"
( cd "$EMPTY" && git init -q && git config user.email t@t.invalid && git config user.name t \
  && printf 'package x\nfunc TestX() {}\n' > x_test.go && git add x_test.go && git commit -q -m i ) >/dev/null 2>&1
bash "$GUARDS_SH" --guards --worktree "$EMPTY" > "$OUT" 2> "$ERR" < /dev/null
assert_eq "0" "$?" "AC4 --guards exits 0 when nothing matches"
assert_eq "" "$(cat "$OUT")" "AC4 --guards prints nothing when nothing matches"

# ── AC3: the cap ──────────────────────────────────────────────────────────────
CAP="$SANDBOX/cap-repo"
mkdir -p "$CAP/t"
( cd "$CAP" && git init -q && git config user.email t@t.invalid && git config user.name t \
  && i=0 && while [ "$i" -lt 60 ]; do
       printf 'package t\nfunc TestW() { filepath.Walk(".", nil) }\n' > "$(printf 't/w%02d_test.go' "$i")"; i=$((i + 1))
     done && git add t && git commit -q -m i ) >/dev/null 2>&1
bash "$GUARDS_SH" --guards --worktree "$CAP" > "$OUT" 2> "$ERR" < /dev/null
assert_eq "50" "$(wc -l < "$OUT" | tr -d ' ')" "AC3 --guards caps the list at 50 paths"
assert_eq "t/w00_test.go" "$(head -n 1 "$OUT")" "AC3 the cap keeps the first of the sorted paths"
assert_eq "t/w49_test.go" "$(tail -n 1 "$OUT")" "AC3 the cap drops the paths after the 50th"

# ── AC1: the key ──────────────────────────────────────────────────────────────
PROJ="$SANDBOX/project"
mkdir -p "$PROJ"
proj_json() { printf '%s' "$1" > "$PROJ/talos.pipeline.json"; }
get() { ( cd "$PROJ" && PIPELINE_CONFIG="$PROJ/talos.pipeline.json" bash "$CFG_SH" verify.dev_tests 2>"$ERR"; echo $? > "$SANDBOX/grc" ); }
errlines() { wc -l < "$ERR" | tr -d ' '; }
ROW="$(printf 'verify.dev_tests\tlist\t\t-\t-\trepo')"
assert_eq "1" "$(grep -Fxc -- "$ROW" "$TALOS_ROOT/scripts/pipeline-defaults.sh")" "AC1 pipeline-defaults.sh has the list row (default empty, scope repo)"
proj_json '{"base_branch": "main"}'
out="$(get)"
assert_eq "" "$out" "AC1 unset: prints nothing"
assert_eq "0" "$(cat "$SANDBOX/grc")" "AC1 unset: exits 0"
assert_eq "0" "$(errlines)" "AC1 unset: no stderr"
proj_json '{"verify": {"dev_tests": ["go test ./pkg/a/...", "bash scripts/guards.sh"]}}'
out="$(get)"
assert_eq "go test ./pkg/a/...
bash scripts/guards.sh" "$out" "AC1 a repo-file list is read one entry per line"
assert_eq "0" "$(errlines)" "AC1 a valid list: no stderr"
# the user-level file is dropped, with one line naming the key
printf '%s' '{"verify": {"dev_tests": ["echo from-user"]}}' > "$GHOME/talos.pipeline.json"
proj_json '{"base_branch": "main"}'
out="$(get)"
assert_eq "" "$out" "AC1 the user-level list is dropped"
assert_eq "1" "$(errlines)" "AC1 the user-level list: one stderr line"
case "$(cat "$ERR")" in *verify.dev_tests*) pass "AC1 the user-level stderr line names the key" ;; *) fail "AC1 the user-level stderr line names the key" "$(cat "$ERR")" ;; esac
rm -f "$GHOME/talos.pipeline.json"
for bad in '[1]' '[""]' '["go test ./...", 2]' '["go test ./...", ""]'; do
  proj_json "{\"verify\": {\"dev_tests\": $bad}}"
  out="$(get)"
  assert_eq "" "$out" "AC1 invalid $bad reads as empty"
  assert_eq "0" "$(cat "$SANDBOX/grc")" "AC1 invalid $bad exits 0"
  assert_eq "1" "$(errlines)" "AC1 invalid $bad: one stderr line"
  case "$(cat "$ERR")" in "pipeline-config: verify.dev_tests"*) pass "AC1 invalid $bad: the line starts with pipeline-config: verify.dev_tests" ;; *) fail "AC1 invalid $bad: the line starts with pipeline-config: verify.dev_tests" "$(cat "$ERR")" ;; esac
done

# ── prompt fixtures: a copied scripts dir, stubbed providers ─────────────────
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR" "$SANDBOX/templates/prompts"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cp -R "$TALOS_ROOT/templates/prompts/." "$SANDBOX/templates/prompts/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null
STUB_BODY='#!/usr/bin/env bash
printf "%s %s\n" "$(basename "$0" .sh)" "$*" >> "${STUB_DIR:?}/journal"
exit 0
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-mergebase.sh pipeline-draft-check.sh pipeline-status.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
# The tree as it was before the change: the template without the marker.
OLD="$SANDBOX/old"
mkdir -p "$OLD/scripts" "$OLD/templates/prompts"
cp "$GS"/* "$OLD/scripts/"
cp -R "$SANDBOX/templates/comments" "$OLD/templates/" 2>/dev/null
for t in "$SANDBOX"/templates/prompts/*; do
  grep -Fvx -- "$MARK" "$t" > "$OLD/templates/prompts/$(basename "$t")"
done
RUN="$GS/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
cfg_with() {
  printf '{"vcs": {"provider": "github"}, "base_branch": "main", "verify": {"timeout_ms": 600000, "ci_wait_s": 900%s}}' \
    "${1:-}" > "$SANDBOX/talos.pipeline.json"
}
: > "$SANDBOX/no-prompt"
setpf() {
  PF="$(sed -n 's/^prompt_file=//p' "$OUT")"
  [ -n "$PF" ] && [ -f "$PF" ] || PF="$SANDBOX/no-prompt"
}
render() { bash "$RUN" prompt "$@" > "$OUT" 2> "$ERR" < /dev/null; RC=$?; setpf; }
render_old() {
  bash "$OLD/scripts/talos.sh" prompt "$@" > "$OUT" 2> "$ERR" < /dev/null; RC=$?; setpf
  if [ "$PF" != "$SANDBOX/no-prompt" ]; then
    sed "s|$(cd "$OLD/scripts" && pwd)|$(cd "$GS" && pwd)|g; s|$(cd "$OLD/templates" && pwd)|$(cd "$SANDBOX/templates" && pwd)|g" "$PF" > "$PF.n" && mv "$PF.n" "$PF"
  fi
}

# ── AC2: the set block ────────────────────────────────────────────────────────
cfg_with ', "dev_tests": ["go test ./pkg/a/...", "bash scripts/check-guards.sh"]'
render developer --issue 9
assert_eq "0" "$RC" "AC2 the developer prompt renders (exit 0)"
P="$(cat "$PF")"
assert_contains "$P" "Developer verification set (run this, not the full suites):
go test ./pkg/a/...
bash scripts/check-guards.sh
Guard tests (discovered, run each by its file):
pkg/a/walk_test.go
pkg/b/parse_test.go
py/test_tree.py
web/tree.test.ts" "AC2 the block carries both commands and the discovered guard paths in order"
assert_eq "1" "$(grep -c '^Targeted iteration:' "$PF")" "AC2 the Targeted iteration line stays"
assert_eq "" "$(cat "$ERR")" "AC2 no stderr output"
# no guard in the checkout: none found
cfg_with ', "dev_tests": ["make t"]'
( cd "$EMPTY" \
  && git init -q --bare "$SANDBOX/origin-e.git" && git remote add origin "$SANDBOX/origin-e.git" && git push -q origin HEAD:main && git fetch -q origin \
  && bash "$RUN" prompt developer --issue 9 > "$OUT" 2> "$ERR" < /dev/null ) >/dev/null 2>&1
setpf
assert_contains "$(cat "$PF")" "Guard tests (discovered, run each by its file):
none found" "AC2 with no guard in the checkout the block says none found"

# ── AC5: unset or [] is today's prompt, discovery not run ─────────────────────
cfg_with ""
render_old developer --issue 9
cp "$PF" "$SANDBOX/prompt.old"
printf '%s' '#!/usr/bin/env bash
printf "%s\n" "$*" >> "${STUB_DIR:?}/discovery"
exit 0
' > "$GS/pipeline-verify.sh"
for variant in "" ', "dev_tests": []'; do
  rm -f "$STUB_DIR/discovery"
  cfg_with "$variant"
  render developer --issue 9
  assert_eq "0" "$RC" "AC5 [${variant:-unset}] exit 0"
  assert_eq "" "$(cat "$ERR")" "AC5 [${variant:-unset}] no stderr"
  if cmp -s "$PF" "$SANDBOX/prompt.old"; then pass "AC5 [${variant:-unset}] the prompt is today's, byte for byte"
  else fail "AC5 [${variant:-unset}] the prompt is today's, byte for byte"; fi
  assert_eq "no" "$([ -e "$STUB_DIR/discovery" ] && echo yes || echo no)" "AC5 [${variant:-unset}] discovery is not run"
done

# ── AC6: the template and the allowed names ───────────────────────────────────
assert_eq "1" "$(grep -Fxc -- "$MARK" "$TALOS_ROOT/templates/prompts/developer.md")" "AC6 developer.md carries the DEV_TESTS_LINE marker on its own line"
assert_eq "yes" "$(awk -v m="$MARK" '/^Targeted iteration:/ { t = NR } $0 == m { d = NR } END { print (t && d == t + 1) ? "yes" : "no" }' "$TALOS_ROOT/templates/prompts/developer.md")" "AC6 the marker follows the Targeted iteration line"
assert_eq "1" "$(sed -n '/^_TALOS_PROMPT_NAMES=/,/"$/p' "$TALOS_ROOT/scripts/talos.sh" | grep -c 'DEV_TESTS_LINE')" "AC6 _TALOS_PROMPT_NAMES allows DEV_TESTS_LINE"

# ── AC7: the docs ─────────────────────────────────────────────────────────────
for f in agents/developer.md docs/reference.md; do
  txt="$(cat "$TALOS_ROOT/$f")"
  assert_contains "$txt" "verify.dev_tests" "AC7 $f names verify.dev_tests"
  assert_contains "$txt" "--guards" "AC7 $f names --guards"
done
assert_contains "$(cat "$TALOS_ROOT/agents/developer.md")" "Developer verification set" "AC7 agents/developer.md names the set the prompt carries"
assert_contains "$(cat "$TALOS_ROOT/agents/developer.md")" "not the full suites" "AC7 agents/developer.md says to run the set, not the full suites"
assert_contains "$(cat "$TALOS_ROOT/agents/developer.md")" "exactly once" "AC7 agents/developer.md keeps the once-before-final-commit rule"

finish
