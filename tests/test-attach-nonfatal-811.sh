#!/usr/bin/env bash
# test-attach-nonfatal-811.sh -- `pipeline-vcs.sh attach-files` never prevents the
# evidence comment (#811): a file that cannot be uploaded becomes a
# `<name>: not attached (<reason>)` line and the `talos:qa-evidence` comment is
# still posted, on github, azure and gitlab. Offline: the az, glab, gh and curl
# stubs only.
#   AC1  github: success / 400 + message / success -> two links, one not-attached line, exit 0
#   AC2  github: every upload fails -> comment posted, every file listed, exit 0
#   AC3  github: the repository read, the default-branch head read or the branch
#        creation fails -> comment posted, every file listed, the reason named
#   AC4  github: the PR head SHA cannot be resolved -> `QA evidence for PR #<n>`
#   AC5  azure: success / 400 + message / success
#   AC6  azure: every upload fails
#   AC7  azure: no access token, or the head SHA unresolved
#   AC8  gitlab: success / failed upload / success
#   AC9  gitlab: every upload fails, or the head SHA is unresolved
#   AC10 a reason is one line, cut at 120 characters and cannot start an image
#   AC11 bad input is refused before any call; only a failed comment write exits non-zero
#   AC12 qa-run with attach-files failing: the verdict line and its exit code stand
# (AC13 is prose.)
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export TALOS_RETRY_SLEEP_SCALE=0
git config user.email "test@talos.invalid"
git config user.name "talos-test"

SHA=0123456789abcdef0123456789abcdef01234567
MARK='<!-- talos:qa-evidence -->'
EV="$SANDBOX/ev"; UP="$SANDBOX/up"
mkdir -p "$EV" "$UP" || exit 1
printf '\211PNG\r\n\032\n\000\001binary-a' > "$EV/a.png"
printf 'WEBM-bytes\000\377end' > "$EV/b.webm"
printf '\211PNG\r\n\032\n\000\001binary-c' > "$EV/c.png"
export STUB_UPLOAD_DIR="$UP"
export STUB_GH_FIXTURES=1   # the curl stub answers GitHub from the fixtures too, as it does behind the gh stub

# count_log <file> <ERE> -- matching lines (0 when none).
count_log() { local _n; _n="$(grep -cE -- "$2" "$1" || true)"; printf '%s' "${_n:-0}"; }
# lines_with <text> <needle> -- how many lines of <text> hold <needle> (fixed string).
lines_with() { local _n; _n="$(printf '%s\n' "$1" | grep -cF -- "$2" || true)"; printf '%s' "${_n:-0}"; }

# listed_missing <comment> <reason-needle> <name>... -- every name has a not-attached line naming the reason.
listed_missing() {
  local _c="$1" _r="$2" _n _ok=yes; shift 2
  for _n in "$@"; do
    printf '%s\n' "$_c" | grep -F -- "$_n: not attached (" | grep -qF -- "$_r" || _ok=no
  done
  printf '%s' "$_ok"
}

# ── github: both transports, one stubbed GitHub ──────────────────────────────
store_text() {  # the body of the newest stored comment
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.stdout.write(d[-1]["body"] if d else "")' "$1"
}
store_count() { python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' "$1"; }

gh_case() {  # <file>...: a fresh evidence branch and comment store, then attach-files on PR 7
  rm -rf "${EVD:?}"/*; printf '[]' > "$STORE"; : > "$CURL_LOG"; : > "$GH_LOG"
  OUT="$(bash "$VCS" attach-files 7 "$@" 2>"$SANDBOX/err")"; RC=$?
  COMMENT="$(store_text "$STORE")"
}

for LEG in gh curl; do
  github_leg "$LEG"
  EVD="$SANDBOX/evid-$LEG"; STORE="$SANDBOX/store-$LEG.json"
  mkdir -p "$EVD" || exit 1
  export STUB_EVIDENCE_DIR="$EVD" STUB_COMMENT_STORE="$STORE" STUB_CURRENT_USER=owner STUB_PR_HEAD_SHA="$SHA"
  RAW='https://github.com/acme/widget/blob/talos-evidence/pr-7/01234567'

  # AC1: success, 400 with a message, success.
  STUB_EVIDENCE_PUT_FAIL=b.webm STUB_EVIDENCE_PUT_STATUS=400 STUB_EVIDENCE_PUT_MESSAGE="File too large" \
    gh_case "$EV/a.png" "$EV/b.webm" "$EV/c.png"
  assert_eq "0" "$RC" "AC1 [$LEG] a 400 on one of three uploads still exits 0"
  assert_eq "1" "$(store_count "$STORE")" "AC1 [$LEG] exactly one evidence comment is posted"
  assert_contains "$COMMENT" "![a.png]($RAW/a.png?raw=true)" "AC1 [$LEG] the first file is attached"
  assert_contains "$COMMENT" "![c.png]($RAW/c.png?raw=true)" "AC1 [$LEG] the third file is attached"
  assert_contains "$COMMENT" "- b.webm: not attached (400: File too large)" "AC1 [$LEG] the refused file is a not-attached line with the code and the message"
  assert_not_contains "$COMMENT" "[b.webm](" "AC1 [$LEG] the refused file has no link"
  assert_eq "$MARK" "$(printf '%s' "$COMMENT" | tail -n1)" "AC1 [$LEG] the comment ends with the marker"

  # AC2: every upload fails.
  STUB_EVIDENCE_PUT_FAIL=. STUB_EVIDENCE_PUT_STATUS=403 STUB_EVIDENCE_PUT_MESSAGE="Resource not accessible" \
    gh_case "$EV/a.png" "$EV/b.webm"
  assert_eq "0" "$RC" "AC2 [$LEG] every upload failing exits 0"
  assert_eq "1" "$(store_count "$STORE")" "AC2 [$LEG] the comment is still posted"
  assert_eq "yes" "$(listed_missing "$COMMENT" "403: Resource not accessible" a.png b.webm)" "AC2 [$LEG] each file is listed as not attached with its reason"
  assert_contains "$COMMENT" "QA evidence for 01234567" "AC2 [$LEG] the heading still names the head"

  # AC3: the repository read, the default-branch head read, the branch creation.
  for F in repo:"the repository" head:"default branch" branch:"talos-evidence"; do
    STUB_EVIDENCE_FAIL="${F%%:*}" gh_case "$EV/a.png" "$EV/b.webm"
    assert_eq "0" "$RC" "AC3 [$LEG] ${F%%:*} failing exits 0"
    assert_eq "1" "$(store_count "$STORE")" "AC3 [$LEG] ${F%%:*} failing still posts the comment"
    assert_eq "yes" "$(listed_missing "$COMMENT" "${F#*:}" a.png b.webm)" "AC3 [$LEG] ${F%%:*} failing lists every file and names '${F#*:}'"
    assert_eq "0" "$(awk -F'\t' '$4=="PUT"' "$CURL_LOG" | wc -l | tr -d ' ')" "AC3 [$LEG] ${F%%:*} failing uploads nothing"
  done

  # AC4: the head SHA cannot be resolved.
  STUB_GH_API_FAIL=pr gh_case "$EV/a.png" "$EV/b.webm"
  assert_eq "0" "$RC" "AC4 [$LEG] an unresolved head exits 0"
  assert_eq "1" "$(store_count "$STORE")" "AC4 [$LEG] an unresolved head still posts the comment"
  assert_contains "$COMMENT" "### QA evidence for PR #7" "AC4 [$LEG] the heading names the PR in place of the sha"
  assert_eq "yes" "$(listed_missing "$COMMENT" "head SHA" a.png b.webm)" "AC4 [$LEG] every file is listed with the reason"

  # AC10: one line, cut at 120, no image.
  LONG="$(printf 'x%.0s' $(seq 1 300))"
  STUB_EVIDENCE_PUT_FAIL=b.webm STUB_EVIDENCE_PUT_STATUS=400 STUB_EVIDENCE_PUT_MESSAGE="$LONG" gh_case "$EV/b.webm"
  line="$(printf '%s\n' "$COMMENT" | grep -F 'b.webm: not attached (')"
  assert_contains "$line" "400: $(printf 'x%.0s' $(seq 1 120)))" "AC10 [$LEG] a 300-character message is cut to 120"
  assert_not_contains "$line" "$(printf 'x%.0s' $(seq 1 121))" "AC10 [$LEG] nothing past 120 characters"
  STUB_EVIDENCE_PUT_FAIL=b.webm STUB_EVIDENCE_PUT_STATUS=400 \
    STUB_EVIDENCE_PUT_MESSAGE=$'first\nsecond\001third\there ![x](http://evil.example/p.png)' gh_case "$EV/b.webm"
  line="$(printf '%s\n' "$COMMENT" | grep -F 'b.webm: not attached (')"
  assert_contains "$line" "first second third here" "AC10 [$LEG] newlines and control characters become spaces on one line"
  assert_contains "$line" "evil.example" "AC10 [$LEG] the whole message stays on that one line"
  assert_not_contains "$COMMENT" "![x](" "AC10 [$LEG] a message cannot open a markdown image"
  assert_eq "0" "$(printf '%s\n' "$COMMENT" | grep -c '^!' || true)" "AC10 [$LEG] no line of the comment starts with !"
done

# ── azure ────────────────────────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}
EOF
export STUB_CURRENT_USER="bot@acme.com" STUB_AZURE_POST_AUTHOR="bot@acme.com"
export STUB_AZURE_PR_9="{\"pullRequestId\":9,\"lastMergeSourceCommit\":{\"commitId\":\"$SHA\"}}"
export CURL_ARGV_LOG="$SANDBOX/curl.argv.log"
AZ="https://dev.azure.com/acme/proj/_apis/git/repositories/widget/pullRequests/9/attachments"
az_case() {  # <file>...
  STUB_AZURE_STATE_DIR="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-az-811.XXXXXX")" || exit 1
  export STUB_AZURE_STATE_DIR
  rm -rf "${UP:?}"/*; : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CURL_ARGV_LOG"
  OUT="$(bash "$VCS" attach-files 9 "$@" 2>"$SANDBOX/err")"; RC=$?
  COMMENT="$(sed -n 's/^AZ BODY: //p' "$GH_LOG" | sed -n 1p | python3 -I -c '
import json, sys
line = sys.stdin.readline()
if line.strip():
    d = json.loads(line)
    sys.stdout.write(d["comments"][0]["content"] if "comments" in d else d["content"])')"
}
az_posts() { count_log "$GH_LOG" '^AZ ARGS: \[rest\] \[--method\] \[post\].*pullRequests/9/threads'; }

STUB_AZURE_UPLOAD_FAIL=b.webm STUB_AZURE_UPLOAD_STATUS=400 STUB_AZURE_UPLOAD_MESSAGE="File too large" az_case "$EV/a.png" "$EV/b.webm" "$EV/c.png"
assert_eq "0" "$RC" "AC5 azure: a 400 on one of three uploads exits 0"
assert_eq "1" "$(az_posts)" "AC5 azure: one evidence thread is posted"
assert_contains "$COMMENT" "![a.png]($AZ/01234567-a.png)" "AC5 azure: the first file is attached"
assert_contains "$COMMENT" "![c.png]($AZ/01234567-c.png)" "AC5 azure: the third file is attached"
assert_contains "$COMMENT" "- b.webm: not attached (400: File too large)" "AC5 azure: the refused file carries the code and the message"
assert_not_contains "$COMMENT" "[b.webm](" "AC5 azure: the refused file has no link"

STUB_AZURE_UPLOAD_FAIL=. STUB_AZURE_UPLOAD_STATUS=401 STUB_AZURE_UPLOAD_MESSAGE="Unauthorized" az_case "$EV/a.png" "$EV/b.webm"
assert_eq "0" "$RC" "AC6 azure: every upload failing exits 0"
assert_eq "1" "$(az_posts)" "AC6 azure: the comment is still posted"
assert_eq "yes" "$(listed_missing "$COMMENT" "401: Unauthorized" a.png b.webm)" "AC6 azure: each file is listed with its reason"

STUB_AZURE_TOKEN_FAIL=1 az_case "$EV/a.png" "$EV/b.webm"
assert_eq "0" "$RC" "AC7 azure: no access token exits 0"
assert_eq "1" "$(az_posts)" "AC7 azure: no access token still posts the comment"
assert_eq "yes" "$(listed_missing "$COMMENT" "access token" a.png b.webm)" "AC7 azure: no access token lists every file with the reason"
assert_eq "0" "$(count_log "$CURL_LOG" '/attachments/')" "AC7 azure: no access token uploads nothing"

STUB_AZURE_PR_9='{"pullRequestId":9}' az_case "$EV/a.png" "$EV/b.webm"
assert_eq "0" "$RC" "AC7 azure: an unresolved head exits 0"
assert_eq "1" "$(az_posts)" "AC7 azure: an unresolved head still posts the comment"
assert_contains "$COMMENT" "### QA evidence for PR #9" "AC7 azure: the heading names the PR in place of the sha"
assert_eq "yes" "$(listed_missing "$COMMENT" "head SHA" a.png b.webm)" "AC7 azure: an unresolved head lists every file with the reason"

LONG="$(printf 'y%.0s' $(seq 1 300))"
STUB_AZURE_UPLOAD_FAIL=b.webm STUB_AZURE_UPLOAD_STATUS=400 STUB_AZURE_UPLOAD_MESSAGE="$LONG" az_case "$EV/b.webm"
line="$(printf '%s\n' "$COMMENT" | grep -F 'b.webm: not attached (')"
assert_contains "$line" "400: $(printf 'y%.0s' $(seq 1 120)))" "AC10 azure: a 300-character message is cut to 120"

# ── gitlab ───────────────────────────────────────────────────────────────────
git remote set-url origin git@gitlab.com:acme/widget.git
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}
EOF
export STUB_CURRENT_USER="bot" STUB_GITLAB_POST_AUTHOR="bot"
export STUB_GITLAB_MR_VIEW="{\"iid\":9,\"sha\":\"$SHA\"}"
GL_NOTES="projects/acme%2Fwidget/merge_requests/9/notes"
gl_case() {  # <file>...
  STUB_GITLAB_STATE_DIR="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-gl-811.XXXXXX")" || exit 1
  export STUB_GITLAB_STATE_DIR
  rm -rf "${UP:?}"/*; : > "$GH_LOG"
  OUT="$(bash "$VCS" attach-files 9 "$@" 2>"$SANDBOX/err")"; RC=$?
  COMMENT="$(grep '^GLAB BODY: ' "$GH_LOG" | sed 's/^GLAB BODY: //' | sed -n 1p | python3 -I -c '
import json, sys
line = sys.stdin.readline()
if line.strip():
    sys.stdout.write(json.loads(line)["body"])')"
}
gl_posts() { count_log "$GH_LOG" "^GLAB api --method POST $GL_NOTES"; }

STUB_GITLAB_UPLOAD_FAIL=b.webm STUB_GITLAB_UPLOAD_MESSAGE="glab: 400 Bad Request: file too large" gl_case "$EV/a.png" "$EV/b.webm" "$EV/c.png"
assert_eq "0" "$RC" "AC8 gitlab: a failed upload among three exits 0"
assert_eq "1" "$(gl_posts)" "AC8 gitlab: one MR note is posted"
assert_contains "$COMMENT" '![a.png](/uploads/0123abcd/a.png)' "AC8 gitlab: the first upload is in the note"
assert_contains "$COMMENT" '![c.png](/uploads/0123abcd/c.png)' "AC8 gitlab: the third upload is in the note"
assert_contains "$COMMENT" "- b.webm: not attached (glab: 400 Bad Request: file too large)" "AC8 gitlab: the failed file carries the glab error"
assert_not_contains "$COMMENT" "[b.webm](" "AC8 gitlab: the failed file has no link"

STUB_GITLAB_UPLOAD_FAIL=. STUB_GITLAB_UPLOAD_MESSAGE="glab: 500 Server Error" gl_case "$EV/a.png" "$EV/b.webm"
assert_eq "0" "$RC" "AC9 gitlab: every upload failing exits 0"
assert_eq "1" "$(gl_posts)" "AC9 gitlab: the note is still posted"
assert_eq "yes" "$(listed_missing "$COMMENT" "glab: 500 Server Error" a.png b.webm)" "AC9 gitlab: each file is listed with its reason"

STUB_GITLAB_MR_VIEW='{"iid":9}' gl_case "$EV/a.png" "$EV/b.webm"
assert_eq "0" "$RC" "AC9 gitlab: an unresolved head exits 0"
assert_eq "1" "$(gl_posts)" "AC9 gitlab: an unresolved head still posts the note"
assert_contains "$COMMENT" "### QA evidence for PR #9" "AC9 gitlab: the heading names the PR in place of the sha"
assert_eq "yes" "$(listed_missing "$COMMENT" "head SHA" a.png b.webm)" "AC9 gitlab: an unresolved head lists every file with the reason"

LONG="$(printf 'z%.0s' $(seq 1 300))"
STUB_GITLAB_UPLOAD_FAIL=b.webm STUB_GITLAB_UPLOAD_MESSAGE="$LONG" gl_case "$EV/b.webm"
line="$(printf '%s\n' "$COMMENT" | grep -F 'b.webm: not attached (')"
assert_contains "$line" "($(printf 'z%.0s' $(seq 1 120)))" "AC10 gitlab: a 300-character glab error is cut to 120"

# ── AC11: only a failed comment write is non-zero; bad input is refused before any call ──
ln -s a.png "$EV/link.png"
no_calls() {  # <label> <args...>: exit 1, and not one request or CLI call
  local _l="$1"; shift
  : > "$GH_LOG"; : > "$CURL_LOG"
  OUT="$(bash "$VCS" attach-files "$@" 2>&1)"; RC=$?
  assert_eq "1" "$RC" "AC11 $_l: exit 1"
  assert_eq "0" "$(wc -c < "$GH_LOG" | tr -d ' ')" "AC11 $_l: no gh/glab/az call"
  assert_eq "0" "$(wc -c < "$CURL_LOG" | tr -d ' ')" "AC11 $_l: no curl call"
}
for P in azure gitlab github; do
  case "$P" in
    azure) printf '%s\n' '{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}' > talos.pipeline.json ;;
    gitlab) printf '%s\n' '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}' > talos.pipeline.json ;;
    github) github_leg gh ;;
  esac
  no_calls "$P a symlink" 9 "$EV/link.png"
  no_calls "$P a missing file" 9 "$EV/nope.png"
  no_calls "$P a non-numeric PR" x9 "$EV/a.png"
done
printf '%s\n' '{"vcs": {"provider": "file"}}' > talos.pipeline.json
OUT="$(bash "$VCS" attach-files 9 "$EV/a.png" 2>&1)"; RC=$?
assert_eq "2" "$RC" "AC11 the file provider exits 2"
assert_contains "$OUT" "not implemented for provider 'file'" "AC11 the file provider says not implemented"

# the comment write itself failing is the one non-zero exit
printf '%s\n' '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}' > talos.pipeline.json
STUB_GITLAB_NOTE_WRITE_FAIL=1 gl_case "$EV/a.png"
assert_eq "1" "$RC" "AC11 gitlab: a failed note write exits 1"
printf '%s\n' '{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}' > talos.pipeline.json
STUB_AZURE_POST_FAIL=1 az_case "$EV/a.png"
assert_eq "1" "$RC" "AC11 azure: a failed thread write exits 1"

# ── AC12: qa-run keeps its verdict and exit code whatever attach-files does ──
BASE_DIR="$SANDBOX/repo"
BR=feat/issue-7-greet
mkdir -p "$BASE_DIR" || exit 1
ATT_LOG="$BASE_DIR/.git/attach.log"

# new_qa_repo -- a throwaway repo with the real scripts, a red test commit, a green
# commit, and a stub pipeline-vcs.sh. Its attach-files hands over to the real
# script when QA_REAL_VCS is set (github stubs), else exits QA_ATTACH_RC.
new_qa_repo() {
  cd "$BASE_DIR" || exit 1
  rm -rf "${BASE_DIR:?}"/* "${BASE_DIR:?}"/.git "${BASE_DIR:?}"/.talos "${BASE_DIR:?}"/talos.pipeline.json "${BASE_DIR:?}"/test-results
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  mkdir scripts tools tests
  cp "$TALOS_ROOT"/scripts/* scripts/
  cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh
  cat > scripts/pipeline-vcs.sh <<'TALOS_qv8h2n5c7r3a'
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
    echo "attach-files $2" >> "$QA_ATTACH_LOG"
    if [ -n "${QA_REAL_VCS:-}" ]; then exec bash "$QA_REAL_VCS" "$@"; fi
    exit "$(cat "$QA_ATTACH_RC" 2>/dev/null || echo 0)" ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_qv8h2n5c7r3a
  printf 'base\n' > README.md
  git add -A
  git commit -q -m "base"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b "$BR"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'rm -rf test-results; mkdir -p test-results\n'
    printf 'if [ ! -f feature.txt ]; then printf "FAIL  AC1 greet prints hello\\n"; exit 1; fi\n'
    printf 'printf "PNG1" > test-results/head-shot.png; printf "VID1" > test-results/head-video.webm\n'
    printf 'printf "  ok  AC1 greet prints hello\\n"; exit 0\n'
  } > tests/test-greet.sh
  git add -A
  git commit -q -m "test(#7): AC1 greet (red first)"
  printf 'done\n' > feature.txt
  git add feature.txt
  git commit -q -m "feat(#7): greet"
  export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
  export QA_ATTACH_LOG="$ATT_LOG" QA_ATTACH_RC="$BASE_DIR/.git/attach.rc"
  rm -f "$ATT_LOG" "$QA_ATTACH_RC"
  {
    printf '**PM spec:** greeting\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n\n'
    printf '**Tests:** `tests/test-greet.sh`\n'
  } > "$QA_SPEC_FILE"
}
qa_run() {
  OUT="$(TALOS_QA_RESULTS="$BASE_DIR/.git/qa-results" bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?
}
notes() { grep -c '^qa-run: e2e artifacts' <<<"$OUT" || true; }
VERDICT='^qa-run: verdict PASS'

# attach-files exits 1 (a post that failed): the verdict and its exit code stand.
new_qa_repo
printf '{"verify":{"e2e_artifacts":{"dir":"test-results","include":["*.png","*.webm"]}}}' > talos.pipeline.json
printf '1' > "$QA_ATTACH_RC"
qa_run
assert_eq "0" "$RC" "AC12 attach-files exiting 1: the exit code is the verdict's own"
assert_eq "1" "$(grep -c "$VERDICT" <<<"$OUT" || true)" "AC12 attach-files exiting 1: the verdict line is printed"
assert_eq "1" "$(notes)" "AC12 attach-files exiting 1: one e2e artifacts line"

# every upload fails (the real attach-files on the github stub): the comment is
# posted, the verdict line is printed and the exit code is the verdict's own.
new_qa_repo
github_leg gh ',"verify": {"e2e_artifacts": {"dir": "test-results", "include": ["*.png", "*.webm"]}}'
EVD="$SANDBOX/evid-qa"; STORE="$SANDBOX/store-qa.json"
mkdir -p "$EVD" || exit 1
printf '[]' > "$STORE"
export QA_REAL_VCS="$VCS" STUB_EVIDENCE_DIR="$EVD" STUB_COMMENT_STORE="$STORE" STUB_CURRENT_USER=owner
export STUB_PR_HEAD_SHA="$SHA" STUB_EVIDENCE_PUT_FAIL=. STUB_EVIDENCE_PUT_STATUS=400 STUB_EVIDENCE_PUT_MESSAGE="Bad Request"
qa_run
unset QA_REAL_VCS STUB_EVIDENCE_PUT_FAIL STUB_EVIDENCE_PUT_STATUS STUB_EVIDENCE_PUT_MESSAGE
assert_eq "0" "$RC" "AC12 every upload failing: the exit code is the verdict's own"
assert_eq "1" "$(grep -c "$VERDICT" <<<"$OUT" || true)" "AC12 every upload failing: the verdict line is printed"
assert_eq "1" "$(store_count "$STORE")" "AC12 every upload failing: the evidence comment is posted"
assert_contains "$(store_text "$STORE")" "not attached (400: Bad Request)" "AC12 every upload failing: the comment says why"
assert_eq "0" "$(notes)" "AC12 every upload failing: no upload-failed line (attach-files exited 0)"

finish
