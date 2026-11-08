#!/usr/bin/env bash
# QA attaches only the recordings of the e2e specs the PR adds or touches (#827).
#   AC1  the four verify.walk.* keys: defaults, validation, repo-only
#   AC2  verify.walk.specs unset/empty: the #776 behaviour, no work video line
#   AC3  only the touched spec's recordings are attached
#   AC4  longest-slug attribution: login-failure-* is not login's
#   AC5  per folder: every video, the last image, nothing else
#   AC6  verify.walk.max_mb: the sorted-order files that fit, a skipped line
#   AC7  not attached lines: no spec touched / no recording / upload failed
#   AC8  the walk runs on a FAIL verdict too, ahead of the verdict line
#   AC9  verify.walk.require_video (+ ui_paths) refuses a PASS without a video
#   AC10 the real attach-files over the GitHub stubs: round 2 edits one comment
#   AC11 the qa prompt names the walk only when verify.walk.specs is set
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

# new_repo KIND [TOUCH...] -- a sandbox repo with the real scripts, a stub
# pipeline-vcs.sh, three specs at the base (web/e2e/login, login-failure and
# checkout .spec.ts), a red commit holding only tests/test-greet.sh and a green
# commit adding feature.txt and changing each TOUCH file.
# KIND: plain (green at head, writes nothing), failshot (the first head run writes
# test-results/login-fails-chromium/test-failed-1.png and fails), real (plain,
# with the real attach-files behind the stub, for the GitHub stubs).
new_repo() {
  local kind="$1" f
  shift
  cd "$BASE_DIR" || exit 1
  rm -rf "${BASE_DIR:?}"/* "${BASE_DIR:?}"/.git "${BASE_DIR:?}"/.talos "${BASE_DIR:?}"/talos.pipeline.json "${BASE_DIR:?}"/test-results
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  mkdir scripts tools tests web web/e2e
  cp "$TALOS_ROOT"/scripts/* scripts/
  cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh
  ATT_LOG="$BASE_DIR/.git/attach.log"
  if [ "$kind" = real ]; then
    mv scripts/pipeline-vcs.sh scripts/pipeline-vcs-real.sh
  fi
  cat > scripts/pipeline-vcs.sh <<'TALOS_w8v2x9k4dq61'
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
    if [ -f "$(dirname "$0")/pipeline-vcs-real.sh" ]; then
      exec bash "$(dirname "$0")/pipeline-vcs-real.sh" "$@"
    fi
    line="attach-files $2"
    for f in "${@:3}"; do line="$line $(basename "$f"):$(wc -c < "$f" | tr -d ' ')"; done
    echo "$line" >> "$QA_ATTACH_LOG"
    exit "$(cat "$QA_ATTACH_RC" 2>/dev/null || echo 0)" ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_w8v2x9k4dq61
  cat > tools/e2e-art.sh <<'TALOS_e2ewalk82k7'
#!/usr/bin/env bash
# Writes the files named in .git/e2e-files.spec (<path>:<bytes> per line).
while IFS=: read -r f n; do
  [ -n "$f" ] || continue
  mkdir -p "$(dirname "$f")"
  head -c "$n" /dev/zero | tr '\0' 'x' > "$f"
done < ".git/e2e-files.spec"
exit 0
TALOS_e2ewalk82k7
  printf 'base\n' > README.md
  for f in login login-failure checkout; do printf 'test("%s")\n' "$f" > "web/e2e/$f.spec.ts"; done
  mkdir -p web/src
  printf 'app\n' > web/src/app.ts
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
      plain | real)
        printf 'printf "  ok  AC1 greet prints hello\\n"; exit 0\n' ;;
      failshot)
        printf 'n=$(grep -c . "%s")\n' "$HEAD_LOG"
        printf 'echo x >> "%s"\n' "$HEAD_LOG"
        printf 'if [ "$n" -eq 0 ]; then mkdir -p test-results/login-fails-chromium; printf "FAIL" > test-results/login-fails-chromium/test-failed-1.png; fi\n'
        printf 'printf "FAIL  AC1 greet prints hello\\n"; exit 1\n' ;;
    esac
  } > tests/test-greet.sh
  git add -A
  git commit -q -m "test(#7): AC1 greet (red first)"
  printf 'done\n' > feature.txt
  git add feature.txt
  for f in "$@"; do
    mkdir -p "$(dirname "$f")"
    printf 'changed\n' >> "$f"
    git add "$f"
  done
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
# walk_cfg <walk-json> [<e2e_artifacts-json>] [noe2e] -- the repo config.
ART='{"dir":"test-results","include":["*.png","*.webm","*.zip"]}'
walk_cfg() {
  local art="${2:-$ART}" e2e='"e2e":"bash tools/e2e-art.sh",'
  [ "${3:-}" != noe2e ] || e2e=""
  printf '{"verify":{%s"e2e_artifacts":%s,"walk":%s}}' "$e2e" "$art" "$1" > "$BASE_DIR/talos.pipeline.json"
}
WALK='{"specs":["web/e2e/**/*.spec.ts"]}'
e2e_files() { printf '%s\n' "$@" > "$BASE_DIR/.git/e2e-files.spec"; }
qa_run() {
  OUT="$(TALOS_QA_RESULTS="$BASE_DIR/.git/qa-results" bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?
}
attach_calls() { if [ -f "$ATT_LOG" ]; then wc -l < "$ATT_LOG" | tr -d ' '; else echo 0; fi; }
attach_files() { if [ -f "$ATT_LOG" ]; then sed -n 1p "$ATT_LOG"; fi; }
wv_lines() { grep -c '^qa-run: work video' <<<"$OUT" || true; }
wv() { grep '^qa-run: work video' <<<"$OUT" | head -n 1; }
line_no() { grep -n -- "$1" <<<"$OUT" | head -n 1 | cut -d: -f1; }
LOGIN_V="test-results/login-signs-in-chromium/video.webm:4"
LOGIN_P="test-results/login-signs-in-chromium/test-finished-1.png:7"
CHECK_V="test-results/checkout-pays-chromium/video.webm:5"
CHECK_P="test-results/checkout-pays-chromium/test-finished-1.png:6"

# ── AC1: the four keys ───────────────────────────────────────────────────────
CFGD="$SANDBOX/cfg"; GH="$SANDBOX/gh-home"
mkdir -p "$CFGD" "$GH" || exit 1
CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
cfg_get() { (cd "$CFGD" && TALOS_HOME="$GH" bash "$CFG_SH" "$1" 2>"$SANDBOX/cfg.err"); }
rm -f "${CFGD:?}"/talos.pipeline.* "${GH:?}"/talos.pipeline.*
assert_eq "" "$(cfg_get verify.walk.specs)" "AC1 verify.walk.specs defaults to empty"
assert_eq "50" "$(cfg_get verify.walk.max_mb)" "AC1 verify.walk.max_mb defaults to 50"
assert_eq "false" "$(cfg_get verify.walk.require_video)" "AC1 verify.walk.require_video defaults to false"
assert_eq "" "$(cfg_get verify.walk.ui_paths)" "AC1 verify.walk.ui_paths defaults to empty"
printf '{"verify":{"walk":{"specs":["a/**/*.spec.ts","b/*.spec.ts"],"max_mb":7,"require_video":true,"ui_paths":["web/**"]}}}' > "$CFGD/talos.pipeline.json"
assert_eq "a/**/*.spec.ts
b/*.spec.ts" "$(cfg_get verify.walk.specs)" "AC1 verify.walk.specs reads the repo list"
assert_eq "7" "$(cfg_get verify.walk.max_mb)" "AC1 verify.walk.max_mb reads the repo value"
assert_eq "true" "$(cfg_get verify.walk.require_video)" "AC1 verify.walk.require_video reads the repo value"
assert_eq "web/**" "$(cfg_get verify.walk.ui_paths)" "AC1 verify.walk.ui_paths reads the repo list"
for bad in 0 10241 '"abc"'; do
  printf '{"verify":{"walk":{"max_mb":%s}}}' "$bad" > "$CFGD/talos.pipeline.json"
  assert_eq "50" "$(cfg_get verify.walk.max_mb)" "AC1 verify.walk.max_mb $bad is refused and falls back to 50"
  assert_contains "$(cat "$SANDBOX/cfg.err")" "pipeline-config: verify.walk.max_mb must be" "AC1 verify.walk.max_mb $bad warns and names the key"
done
rm -f "${CFGD:?}"/talos.pipeline.*
printf '{"verify":{"walk":{"specs":["x/*.spec.ts"],"max_mb":9,"require_video":true,"ui_paths":["web/**"]}}}' > "$GH/talos.pipeline.json"
assert_eq "" "$(cfg_get verify.walk.specs)" "AC1 verify.walk.specs from the user-level file is dropped"
assert_eq "50" "$(cfg_get verify.walk.max_mb)" "AC1 verify.walk.max_mb from the user-level file is dropped"
assert_eq "false" "$(cfg_get verify.walk.require_video)" "AC1 verify.walk.require_video from the user-level file is dropped"
assert_contains "$(cat "$SANDBOX/cfg.err")" "verify.walk.specs" "AC1 the drop is one stderr note naming the key"
rm -f "${GH:?}"/talos.pipeline.*

# ── AC2: unset or empty -> the #776 behaviour ────────────────────────────────
for w in '' '{}' '{"specs":[]}'; do
  new_repo plain web/e2e/login.spec.ts
  spec
  if [ -z "$w" ]; then
    printf '{"verify":{"e2e":"bash tools/e2e-art.sh","e2e_artifacts":%s}}' "$ART" > talos.pipeline.json
  else
    walk_cfg "$w"
  fi
  e2e_files "$LOGIN_P" "$LOGIN_V" "$CHECK_V" "test-results/login-signs-in-chromium/trace.zip:9"
  qa_run
  assert_eq "0" "$RC" "AC2 [$w] specs unset: the run is green"
  assert_eq "0" "$(wv_lines)" "AC2 [$w] specs unset: no work video line"
  assert_eq "attach-files 9 checkout-pays-chromium-video.webm:5 login-signs-in-chromium-test-finished-1.png:7 login-signs-in-chromium-trace.zip:9 login-signs-in-chromium-video.webm:4" "$(attach_files)" "AC2 [$w] specs unset: attach-files gets what #776 gives it"
  assert_eq "1" "$(grep -c '^qa-run: verdict PASS (1 test criteria green, 1 prose to hand-check) e2e ok$' <<<"$OUT" || true)" "AC2 [$w] specs unset: the verdict line is #776's"
done

# ── AC3: only the touched spec's recordings ──────────────────────────────────
new_repo plain web/e2e/login.spec.ts
spec
walk_cfg "$WALK"
e2e_files "$LOGIN_V" "$LOGIN_P" "$CHECK_V" "$CHECK_P"
qa_run
assert_eq "0" "$RC" "AC3 the run is green"
assert_eq "1" "$(attach_calls)" "AC3 attach-files is called once"
assert_eq "attach-files 9 login-signs-in-chromium-test-finished-1.png:7 login-signs-in-chromium-video.webm:4" "$(attach_files)" "AC3 attach-files gets only the login recordings"
assert_eq "qa-run: work video attached (2 file(s))" "$(wv)" "AC3 the work video line counts the files"
assert_eq "1" "$(wv_lines)" "AC3 exactly one work video line"
assert_not_contains "$OUT" "e2e artifacts" "AC3 no #776 e2e artifacts line"
assert_eq "1" "$(grep -c '^qa-run: verdict PASS ' <<<"$OUT" || true)" "AC3 the PASS verdict is printed"
[ "$(line_no 'qa-run: work video')" -lt "$(line_no 'qa-run: verdict PASS')" ] && pass "AC3 the work video line is ahead of the verdict line" || fail "AC3 the work video line is ahead of the verdict line"

# ── AC4: longest-slug attribution ────────────────────────────────────────────
new_repo plain web/e2e/login.spec.ts
spec
walk_cfg "$WALK"
e2e_files "test-results/login-failure-bad-pw-chromium/video.webm:3" "test-results/login-failure-bad-pw-chromium/test-failed-1.png:2" "$LOGIN_V"
qa_run
assert_eq "attach-files 9 login-signs-in-chromium-video.webm:4" "$(attach_files)" "AC4 login-failure-* is not login's: only login-* is attached"
assert_eq "qa-run: work video attached (1 file(s))" "$(wv)" "AC4 one file is attached"

new_repo plain web/e2e/login-failure.spec.ts
spec
walk_cfg "$WALK"
e2e_files "test-results/login-failure-bad-pw-chromium/video.webm:3" "$LOGIN_V"
qa_run
assert_eq "attach-files 9 login-failure-bad-pw-chromium-video.webm:3" "$(attach_files)" "AC4 touching login-failure.spec.ts attaches login-failure-* only"

# ── AC5: per folder, every video and the last image ──────────────────────────
new_repo plain web/e2e/login.spec.ts
spec
walk_cfg "$WALK"
e2e_files "test-results/login-a-chromium/video.webm:4" "test-results/login-a-chromium/test-failed-1.png:5" "test-results/login-a-chromium/test-failed-2.png:6" "test-results/login-a-chromium/trace.zip:9"
qa_run
assert_eq "attach-files 9 login-a-chromium-test-failed-2.png:6 login-a-chromium-video.webm:4" "$(attach_files)" "AC5 the video and the last image of the folder; the first image and the zip are not attached"
assert_eq "qa-run: work video attached (2 file(s))" "$(wv)" "AC5 two files attached"

# ── AC6: the cap ─────────────────────────────────────────────────────────────
new_repo plain web/e2e/login.spec.ts
spec
walk_cfg '{"specs":["web/e2e/**/*.spec.ts"],"max_mb":1}'
e2e_files "test-results/login-a-chromium/video.webm:600000" "test-results/login-b-chromium/video.webm:600000" "test-results/login-b-chromium/test-finished-1.png:100"
qa_run
assert_eq "0" "$RC" "AC6 over the cap: the exit code is unchanged"
assert_eq "attach-files 9 login-a-chromium-video.webm:600000 login-b-chromium-test-finished-1.png:100" "$(attach_files)" "AC6 the sorted-order files that fit are attached"
assert_contains "$OUT" "qa-run: work video attached (2 file(s))" "AC6 the attached line"
assert_contains "$OUT" "qa-run: work video skipped 1 file(s) over the 1 MB cap" "AC6 the skipped line"

new_repo plain web/e2e/login.spec.ts
spec
walk_cfg '{"specs":["web/e2e/**/*.spec.ts"],"max_mb":1}'
e2e_files "test-results/login-a-chromium/video.webm:2000000"
qa_run
assert_eq "0" "$RC" "AC6 no video fits: the exit code is unchanged"
assert_eq "0" "$(attach_calls)" "AC6 no video fits: attach-files is not called"
assert_eq "qa-run: work video not attached (over the 1 MB cap)" "$(wv)" "AC6 no video fits: the not attached line"
assert_eq "1" "$(wv_lines)" "AC6 no video fits: exactly one work video line"

# ── AC7: the not attached lines ──────────────────────────────────────────────
new_repo plain web/src/app.ts
spec
walk_cfg "$WALK"
e2e_files "$LOGIN_V"
qa_run
assert_eq "0" "$RC" "AC7 no spec touched: the exit code is unchanged"
assert_eq "0" "$(attach_calls)" "AC7 no spec touched: attach-files is not called"
assert_eq "qa-run: work video not attached (no e2e spec touched by the PR)" "$(wv)" "AC7 no spec touched: the line"
assert_eq "1" "$(grep -c '^qa-run: verdict PASS ' <<<"$OUT" || true)" "AC7 no spec touched: the verdict is unchanged"

new_repo plain web/e2e/login.spec.ts
spec
walk_cfg "$WALK"
e2e_files "$CHECK_V"
qa_run
assert_eq "0" "$RC" "AC7 no recording: the exit code is unchanged"
assert_eq "0" "$(attach_calls)" "AC7 no recording: attach-files is not called"
assert_eq "qa-run: work video not attached (no recording found for the touched spec(s))" "$(wv)" "AC7 no recording: the line"

new_repo plain web/e2e/login.spec.ts
spec
walk_cfg "$WALK"
e2e_files "$LOGIN_V"
printf '3' > "$QA_ATTACH_RC"
qa_run
assert_eq "0" "$RC" "AC7 upload failed: the exit code is unchanged"
assert_eq "qa-run: work video not attached (upload failed (exit 3))" "$(wv)" "AC7 upload failed: the line"
assert_eq "1" "$(grep -c '^qa-run: verdict PASS ' <<<"$OUT" || true)" "AC7 upload failed: the verdict is unchanged"

new_repo plain web/e2e/login.spec.ts
spec
walk_cfg "$WALK" '{}'
e2e_files "$LOGIN_V"
qa_run
assert_eq "0" "$RC" "AC7 dir and include unset: the exit code is unchanged"
assert_eq "qa-run: work video not attached (verify.e2e_artifacts.dir and include are not set)" "$(wv)" "AC7 dir and include unset: the line"

# ── AC8: a FAIL verdict still attaches ───────────────────────────────────────
new_repo failshot web/e2e/login.spec.ts
spec
walk_cfg "$WALK" "$ART" noe2e
qa_run
assert_eq "1" "$RC" "AC8 a failing head run is a FAIL"
assert_eq "attach-files 9 login-fails-chromium-test-failed-1.png:4" "$(attach_files)" "AC8 the failing run's screenshot of the touched spec is attached"
assert_eq "qa-run: work video attached (1 file(s))" "$(wv)" "AC8 the work video line is printed"
[ "$(line_no 'qa-run: work video')" -lt "$(line_no 'qa-run: verdict FAIL')" ] && pass "AC8 the line is ahead of the FAIL verdict" || fail "AC8 the line is ahead of the FAIL verdict"

# ── AC9: verify.walk.require_video ───────────────────────────────────────────
REQ='{"specs":["web/e2e/**/*.spec.ts"],"require_video":true,"max_mb":1}'
new_repo plain web/src/app.ts
spec
walk_cfg "$REQ"
e2e_files "$LOGIN_V"
qa_run
assert_eq "1" "$RC" "AC9 no spec touched: exit 1"
assert_contains "$OUT" "qa-run: verdict FAIL work video not attached (no e2e spec touched by the PR)" "AC9 no spec touched: the FAIL verdict names the reason"

new_repo plain web/e2e/login.spec.ts
spec
walk_cfg "$REQ"
e2e_files "$CHECK_V"
qa_run
assert_eq "1" "$RC" "AC9 no recording: exit 1"
assert_contains "$OUT" "qa-run: verdict FAIL work video not attached (no recording found for the touched spec(s))" "AC9 no recording: the FAIL verdict names the reason"

new_repo plain web/e2e/login.spec.ts
spec
walk_cfg "$REQ"
e2e_files "test-results/login-a-chromium/video.webm:2000000"
qa_run
assert_eq "1" "$RC" "AC9 over the cap: exit 1"
assert_contains "$OUT" "qa-run: verdict FAIL work video not attached (over the 1 MB cap)" "AC9 over the cap: the FAIL verdict names the reason"

new_repo plain web/e2e/login.spec.ts
spec
walk_cfg "$REQ"
e2e_files "$LOGIN_V"
qa_run
assert_eq "0" "$RC" "AC9 a video attached: PASS"
assert_contains "$OUT" "qa-run: verdict PASS" "AC9 a video attached: the PASS verdict"

new_repo plain web/e2e/login.spec.ts
spec
walk_cfg "$REQ"
e2e_files "$LOGIN_V"
printf '3' > "$QA_ATTACH_RC"
qa_run
assert_eq "0" "$RC" "AC9 upload failed: still PASS"

new_repo plain web/e2e/login.spec.ts
spec
walk_cfg "$REQ"
e2e_files "$LOGIN_P"
qa_run
assert_eq "1" "$RC" "AC9 only a screenshot attached: no video, exit 1"
assert_contains "$OUT" "qa-run: verdict FAIL work video not attached (" "AC9 only a screenshot attached: the FAIL verdict"

new_repo plain web/src/app.ts
spec
walk_cfg '{"specs":["web/e2e/**/*.spec.ts"],"require_video":false}'
qa_run
assert_eq "0" "$RC" "AC9 require_video false: PASS"

new_repo plain
spec
walk_cfg '{"specs":["web/e2e/**/*.spec.ts"],"require_video":true,"ui_paths":["web/src/**"]}'
qa_run
assert_eq "0" "$RC" "AC9 a PR outside ui_paths: PASS"
assert_contains "$OUT" "qa-run: work video not attached (no e2e spec touched by the PR)" "AC9 a PR outside ui_paths: the line is still printed"

new_repo plain web/src/app.ts
spec
walk_cfg '{"specs":["web/e2e/**/*.spec.ts"],"require_video":true,"ui_paths":["web/src/**"]}'
qa_run
assert_eq "1" "$RC" "AC9 a PR inside ui_paths: exit 1"
assert_contains "$OUT" "qa-run: verdict FAIL work video not attached (no e2e spec touched by the PR)" "AC9 a PR inside ui_paths: the FAIL verdict"

# ── AC10: the real attach-files over the GitHub stubs ────────────────────────
new_repo real web/e2e/login.spec.ts
spec
printf '{"vcs":{"provider":"github","repo":"acme/widget"},"verify":{"e2e":"bash tools/e2e-art.sh","e2e_artifacts":%s,"walk":%s}}' "$ART" "$WALK" > talos.pipeline.json
EVD="$SANDBOX/evid-walk"; STORE="$SANDBOX/store-walk.json"
mkdir -p "$EVD" || exit 1
printf '[]' > "$STORE"
export STUB_EVIDENCE_DIR="$EVD" STUB_COMMENT_STORE="$STORE" STUB_CURRENT_USER=owner
export STUB_PR_HEAD_SHA=0123456789abcdef0123456789abcdef01234567
e2e_files "$LOGIN_V" "$LOGIN_P" "$CHECK_V" "$CHECK_P"
qa_run
assert_eq "0" "$RC" "AC10 round 1 is green"
assert_eq "qa-run: work video attached (2 file(s))" "$(wv)" "AC10 round 1 attaches the touched spec's video and screenshot"
store_count() { python3 -I -c 'import json, sys
print(len([c for c in json.load(open(sys.argv[1])) if "talos:qa-evidence" in c["body"]]))' "$STORE"; }
store_text() { python3 -I -c 'import json, sys
print("\n".join(c["body"] for c in json.load(open(sys.argv[1]))))' "$STORE"; }
assert_eq "1" "$(store_count)" "AC10 round 1 leaves one evidence comment"
export STUB_PR_HEAD_SHA=fedcba9876543210fedcba9876543210fedcba98
qa_run
assert_eq "0" "$RC" "AC10 round 2 is green"
assert_eq "1" "$(store_count)" "AC10 round 2 edits the same comment: still one in the store"
body="$(store_text)"
assert_contains "$body" "QA evidence for fedcba98" "AC10 the comment now names the new head"
assert_contains "$body" "login-signs-in-chromium-video.webm" "AC10 the comment holds the issue's video"
assert_contains "$body" "login-signs-in-chromium-test-finished-1.png" "AC10 the comment holds the issue's screenshot"
assert_not_contains "$body" "checkout" "AC10 the comment names no file of another spec"
uploaded="$(find "$EVD" -type f 2>/dev/null | sort | tr '\n' ' ')"
assert_contains "$uploaded" "login-signs-in-chromium-video.webm" "AC10 the video is uploaded"
assert_not_contains "$uploaded" "checkout" "AC10 no file of another spec is uploaded"
unset STUB_EVIDENCE_DIR STUB_COMMENT_STORE STUB_CURRENT_USER STUB_PR_HEAD_SHA

# ── AC11: the qa prompt ──────────────────────────────────────────────────────
cd "$SANDBOX" || exit 1
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
P_OUT="$SANDBOX/prompt.stdout"; P_ERR="$SANDBOX/prompt.stderr"
TREE="$SANDBOX/tree"
mkdir -p "$TREE"
cp -R "$TALOS_ROOT/scripts" "$TREE/scripts"
cp -R "$TALOS_ROOT/templates" "$TREE/templates"
printf '#!/usr/bin/env bash\n[ "${1:-}" = pr-is-draft ] || exit 0\nprintf "%%s" "${GATE_PRD_OUT:-}"\nexit "${GATE_PRD_RC:-2}"\n' > "$TREE/scripts/pipeline-vcs.sh"
render_qa() {
  local pf
  bash "$1/scripts/talos.sh" prompt qa --issue 827 --pr 9 --worktree "$SANDBOX/wt" > "$P_OUT" 2> "$P_ERR"
  pf="$(sed -n 's/^prompt_file=//p' "$P_OUT")"
  if [ -n "$pf" ]; then cat "$pf"; rm -f "${pf:?}"; else cat "$P_OUT"; fi
}
mkdir -p "$SANDBOX/wt/tests"; : > "$SANDBOX/wt/tests/run-tests.sh"
export GATE_PRD_RC=1 GATE_PRD_OUT=ready
printf '{"verify": {"qa_mode": "ci"}, "merge": {"required_checks": ["ci / test"]}}' > "$SANDBOX/talos.pipeline.json"
unset_text="$(render_qa "$TREE")"
cp -R "$TREE" "$SANDBOX/tree-old"
grep -v '^{{QA_WALK_LINE}}$' "$TREE/templates/prompts/qa.md" > "$SANDBOX/tree-old/templates/prompts/qa.md"
old_text="$(render_qa "$SANDBOX/tree-old")"
old_text="$(printf '%s' "$old_text" | sed 's|/tree-old/|/tree/|g')"
assert_eq "$old_text" "$unset_text" "AC11 specs unset: the qa prompt is the one without the walk line"
assert_not_contains "$unset_text" "work video" "AC11 specs unset: no work video text"
printf '{"verify": {"qa_mode": "ci", "walk": {"specs": ["web/e2e/**/*.spec.ts"]}}, "merge": {"required_checks": ["ci / test"]}}' > "$SANDBOX/talos.pipeline.json"
set_text="$(render_qa "$TREE")"
assert_contains "$set_text" "work video" "AC11 specs set: the prompt has the walk line"
assert_contains "$set_text" "Results table" "AC11 specs set: the line asks for a Results table"
for w in "pass/fail counts" "known flakes" "lint" "gitleaks" "generate-gate"; do
  assert_contains "$set_text" "$w" "AC11 specs set: the line names $w"
done
assert_not_contains "$set_text" "{{" "AC11 specs set: no marker left over"

finish
