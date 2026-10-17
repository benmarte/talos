#!/usr/bin/env bash
# QA attaches the e2e run's screenshots and videos to the PR (#776).
#   AC1  verify.e2e_artifacts unset: no attach-files call, no e2e artifacts line
#   AC2  set, a verify.e2e that writes a .png and a .webm: attach-files gets
#        exactly those two files and the PASS verdict is unchanged
#   AC3  a file older than the run is not attached
#   AC4  files the head run wrote survive the red run / re-run that empties dir
#   AC5  over max_files / max_mb: the permitted subset is attached, one note,
#        verdict and exit code unchanged
#   AC6  no matching files, or attach-files failing: one note, verdict and exit
#        code unchanged, also on a FAIL verdict
# Each case builds a throwaway repo with the real scripts and a stub
# pipeline-vcs.sh whose attach-files logs the file names and sizes it was given.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

BASE_DIR="$SANDBOX/repo"
BR=feat/issue-7-greet
trap '_is_trap_owner && _sandbox_cleanup' EXIT
export TALOS_RETRY_SLEEP_SCALE=0
mkdir -p "$BASE_DIR" || exit 1

# new_repo KIND -- a sandbox repo with the real scripts, a stub pipeline-vcs.sh,
# a red commit holding only tests/test-greet.sh and a green commit adding
# feature.txt. The test empties test-results/ on every run, as Playwright does.
# KIND: shots (green at head; writes test-results/head-shot.png),
#       failshots (the first run at the head writes fail-shot.png and fails; a
#       re-run empties the directory and fails again).
new_repo() {
  local kind="$1"
  cd "$BASE_DIR" || exit 1
  rm -rf "${BASE_DIR:?}"/* "${BASE_DIR:?}"/.git "${BASE_DIR:?}"/.talos "${BASE_DIR:?}"/talos.pipeline.json "${BASE_DIR:?}"/test-results
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  mkdir scripts tools tests
  cp "$TALOS_ROOT"/scripts/* scripts/
  cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh
  ATT_LOG="$BASE_DIR/.git/attach.log"
  cat > scripts/pipeline-vcs.sh <<'TALOS_q7m2x9k4dv81'
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
  attach-files)
    line="attach-files $2"
    for f in "${@:3}"; do line="$line $(basename "$f"):$(wc -c < "$f" | tr -d ' ')"; done
    echo "$line" >> "$QA_ATTACH_LOG"
    exit "$(cat "$QA_ATTACH_RC" 2>/dev/null || echo 0)" ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_q7m2x9k4dv81
  cat > tools/e2e-art.sh <<'TALOS_e2eart76k2'
#!/usr/bin/env bash
# Writes the files named in .git/e2e-files.spec (<path>:<bytes> per line).
while IFS=: read -r f n; do
  [ -n "$f" ] || continue
  mkdir -p "$(dirname "$f")"
  head -c "$n" /dev/zero | tr '\0' 'x' > "$f"
done < ".git/e2e-files.spec"
exit 0
TALOS_e2eart76k2
  printf 'base\n' > README.md
  git add -A
  git commit -q -m "base"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b "$BR"
  HEAD_LOG="$BASE_DIR/.git/qa-head.log"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'rm -rf test-results; mkdir -p test-results\n'
    printf 'if [ ! -f feature.txt ]; then printf "FAIL  AC1 greet prints hello\\n"; exit 1; fi\n'
    case "$kind" in
      shots)
        printf 'printf "PNG1" > test-results/head-shot.png\n'
        printf 'printf "  ok  AC1 greet prints hello\\n"; exit 0\n' ;;
      failshots)
        printf 'n=$(grep -c . "%s")\n' "$HEAD_LOG"
        printf 'echo x >> "%s"\n' "$HEAD_LOG"
        printf 'if [ "$n" -eq 0 ]; then printf "FAIL" > test-results/fail-shot.png; fi\n'
        printf 'printf "FAIL  AC1 greet prints hello\\n"; exit 1\n' ;;
    esac
  } > tests/test-greet.sh
  git add -A
  git commit -q -m "test(#7): AC1 greet (red first)"
  printf 'done\n' > feature.txt
  git add feature.txt
  git commit -q -m "feat(#7): greet"
  export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
  export QA_ATTACH_LOG="$ATT_LOG" QA_ATTACH_RC="$BASE_DIR/.git/attach.rc"
  rm -f "$ATT_LOG" "$QA_ATTACH_RC"
  : > "$HEAD_LOG"
}

spec() {  # AC1 (test) and AC2 (prose)
  {
    printf '**PM spec:** greeting\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n'
    printf -- '- [ ] AC2 the README names it (prose: doc wording)\n\n'
    printf '**Tests:** `tests/test-greet.sh`\n'
  } > "$QA_SPEC_FILE"
}
# art_cfg <artifacts-json> [e2e] -- the repo config; e2e runs tools/e2e-art.sh.
art_cfg() {
  local e2e=""
  [ "${2:-}" != e2e ] || e2e='"e2e":"bash tools/e2e-art.sh",'
  printf '{"verify":{%s"e2e_artifacts":%s}}' "$e2e" "$1" > "$BASE_DIR/talos.pipeline.json"
}
e2e_files() { printf '%s\n' "$@" > "$BASE_DIR/.git/e2e-files.spec"; }
qa_run() {
  OUT="$(TALOS_QA_RESULTS="$BASE_DIR/.git/qa-results" bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?
}
attach_calls() { if [ -f "$ATT_LOG" ]; then wc -l < "$ATT_LOG" | tr -d ' '; else echo 0; fi; }
attach_files() { if [ -f "$ATT_LOG" ]; then sed -n 1p "$ATT_LOG"; fi; }
notes() { grep -c '^qa-run: e2e artifacts' <<<"$OUT" || true; }
ART='{"dir":"test-results","include":["*.png","*.webm"]}'

# ── AC1: unset -> nothing new ────────────────────────────────────────────────
new_repo shots
spec
printf '{"verify":{"e2e":"bash tools/e2e-art.sh"}}' > talos.pipeline.json
e2e_files "test-results/x/shot.png:7"
qa_run
assert_eq "0" "$RC" "AC1 with e2e_artifacts unset the run is green"
assert_eq "0" "$(attach_calls)" "AC1 with e2e_artifacts unset there is no attach-files call"
assert_not_contains "$OUT" "e2e artifacts" "AC1 with e2e_artifacts unset the output has no e2e artifacts line"

# ── AC2: a .png and a .webm from verify.e2e ──────────────────────────────────
new_repo shots
spec
art_cfg "$ART" e2e
e2e_files "test-results/login-chromium/test-finished-1.png:7" "test-results/login-chromium/video.webm:4" "test-results/login-chromium/trace.zip:9"
qa_run
assert_eq "0" "$RC" "AC2 the exit code is the PASS exit code"
assert_contains "$OUT" "qa-run: verdict PASS" "AC2 the PASS verdict is printed"
assert_eq "1" "$(attach_calls)" "AC2 attach-files is called once"
assert_eq "attach-files 9 login-chromium-test-finished-1.png:7 login-chromium-video.webm:4" "$(attach_files)" "AC2 attach-files gets exactly the .png and the .webm of the e2e run"
assert_eq "0" "$(notes)" "AC2 a clean attach prints no e2e artifacts note"
assert_eq "1" "$(grep -c '^qa-run: verdict PASS (1 test criteria green, 1 prose to hand-check) e2e ok$' <<<"$OUT" || true)" "AC2 the verdict line is the one a run without artifacts prints"

# ── AC3: a stale file is not attached ────────────────────────────────────────
new_repo shots
spec
art_cfg '{"dir":"e2e-out","include":["*.png","*.webm"]}' e2e
mkdir -p e2e-out/old
printf 'old' > e2e-out/old/stale.png
touch -t 202001010000 e2e-out/old/stale.png
e2e_files "e2e-out/new/fresh.png:5"
qa_run
assert_eq "0" "$RC" "AC3 the run is green"
assert_eq "attach-files 9 new-fresh.png:5" "$(attach_files)" "AC3 only the file the run wrote is attached"

# ── AC4: files of the head run survive the red run that empties dir ──────────
new_repo shots
spec
art_cfg "$ART"
qa_run
assert_eq "0" "$RC" "AC4 the run is green (the red run ran after the head run)"
assert_eq "attach-files 9 head-shot.png:4" "$(attach_files)" "AC4 the head run's screenshot is attached though the red run emptied the directory"
assert_eq "1" "$(attach_calls)" "AC4 attach-files is called once, after the last run"

new_repo failshots
spec
art_cfg "$ART"
qa_run
assert_eq "1" "$RC" "AC4 a failing head run is a FAIL"
assert_contains "$OUT" "qa-run: verdict FAIL" "AC4 the FAIL verdict is printed"
assert_eq "attach-files 9 fail-shot.png:4" "$(attach_files)" "AC4 the failing run's screenshot is attached though the re-run emptied the directory"

# ── AC5: limits ──────────────────────────────────────────────────────────────
new_repo shots
spec
art_cfg '{"dir":"test-results","include":["*.png"],"max_files":3}' e2e
e2e_files "test-results/t/e.png:5" "test-results/t/a.png:5" "test-results/t/c.png:5" "test-results/t/b.png:5" "test-results/t/d.png:5"
qa_run
assert_eq "0" "$RC" "AC5 more files than max_files: the exit code is unchanged"
assert_contains "$OUT" "qa-run: verdict PASS" "AC5 more files than max_files: the verdict is unchanged"
assert_eq "attach-files 9 t-a.png:5 t-b.png:5 t-c.png:5" "$(attach_files)" "AC5 the first max_files files in sorted path order are attached"
assert_eq "1" "$(notes)" "AC5 more files than max_files: one e2e artifacts note"

new_repo shots
spec
art_cfg '{"dir":"test-results","include":["*.png"],"max_mb":1}' e2e
e2e_files "test-results/a.png:600000" "test-results/b.png:600000" "test-results/c.png:100"
qa_run
assert_eq "0" "$RC" "AC5 a total over max_mb: the exit code is unchanged"
assert_contains "$OUT" "qa-run: verdict PASS" "AC5 a total over max_mb: the verdict is unchanged"
assert_eq "attach-files 9 a.png:600000 c.png:100" "$(attach_files)" "AC5 a file that would push the total over max_mb is skipped, a later small one still fits"
assert_eq "1" "$(notes)" "AC5 a total over max_mb: one e2e artifacts note"

# ── AC6: no files, a failing attach-files, and a FAIL verdict ────────────────
new_repo shots
spec
art_cfg '{"dir":"test-results","include":["*.webm"]}' e2e
e2e_files "test-results/log.txt:5"
qa_run
assert_eq "0" "$RC" "AC6 no matching files: the exit code is unchanged"
assert_contains "$OUT" "qa-run: verdict PASS" "AC6 no matching files: the verdict is unchanged"
assert_eq "0" "$(attach_calls)" "AC6 no matching files: attach-files is not called"
assert_eq "1" "$(notes)" "AC6 no matching files: one e2e artifacts note"
assert_contains "$OUT" "qa-run: e2e artifacts none found in test-results" "AC6 the note names the directory"

new_repo shots
spec
art_cfg "$ART" e2e
e2e_files "test-results/s.png:5"
printf '3' > "$QA_ATTACH_RC"
qa_run
assert_eq "0" "$RC" "AC6 attach-files exiting 3: the exit code is unchanged"
assert_contains "$OUT" "qa-run: verdict PASS" "AC6 attach-files exiting 3: the verdict is unchanged"
assert_eq "1" "$(notes)" "AC6 attach-files exiting 3: one e2e artifacts note"
assert_contains "$OUT" "qa-run: e2e artifacts upload failed (exit 3)" "AC6 the note names the exit code"

new_repo failshots
spec
art_cfg "$ART"
printf '3' > "$QA_ATTACH_RC"
qa_run
assert_eq "1" "$RC" "AC6 a FAIL verdict with attach-files failing: exit 1 as before"
assert_contains "$OUT" "qa-run: verdict FAIL" "AC6 a FAIL verdict with attach-files failing: the verdict is unchanged"
assert_eq "1" "$(notes)" "AC6 a FAIL verdict with attach-files failing: one e2e artifacts note"
assert_contains "$OUT" "qa-run: e2e artifacts upload failed (exit 3)" "AC6 the FAIL verdict run names the exit code"

finish
