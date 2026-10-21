#!/usr/bin/env bash
# test-attach-files-776.sh -- `pipeline-vcs.sh attach-files <pr> <file>...` (#776):
# upload files and post (or edit) ONE `talos:qa-evidence` comment per PR on
# azure, gitlab and github. Offline: the az, glab, gh and curl stubs only.
#   AC7  azure: every file is one push to the talos-evidence branch (#810); the
#        comment links the items URL of each file on the branch
#   AC8  gitlab: every file is one commit on the talos-evidence branch (#810); the
#        MR note links the -/raw/ URL of each file on the branch
#   AC9  github: each file committed to talos-evidence at pr-<n>/<sha8>/<name>;
#        the comment holds the ?raw=true blob links, images inline
#   AC10 a second attach-files edits the evidence comment; a failed upload is
#        listed as not attached, the comment is posted, exit 0 (#811; all three providers)
#   AC11 a symlink, a missing file or a non-numeric PR exits 1 before any
#        network call; the file provider exits 2
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export TALOS_RETRY_SLEEP_SCALE=0
git config user.email "test@talos.invalid"
git config user.name "talos-test"

SHA=0123456789abcdef0123456789abcdef01234567
SHA2=fedcba9876543210fedcba9876543210fedcba98
MARK='<!-- talos:qa-evidence -->'
EV="$SANDBOX/ev"; UP="$SANDBOX/up"
mkdir -p "$EV" "$UP" || exit 1
printf '\211PNG\r\n\032\n\000\001binary-a' > "$EV/a.png"
printf 'WEBM-bytes\000\377end' > "$EV/b.webm"
ln -s a.png "$EV/link.png"
export STUB_UPLOAD_DIR="$UP"
export STUB_GH_FIXTURES=1   # the curl stub answers GitHub from the fixtures too, as it does behind the gh stub

# count_log <file> <ERE> -- matching lines (0 when none).
count_log() { local _n; _n="$(grep -cE -- "$2" "$1" || true)"; printf '%s' "${_n:-0}"; }

# ── AC9 + AC10 (github): both transports, one stubbed GitHub ─────────────────
store_bodies() {  # the comment store's bodies, one JSON string per line
  python3 -I -c '
import json, sys
for c in json.load(open(sys.argv[1])):
    print(json.dumps(c["body"]))' "$1"
}
put_check() {  # <log> <file>...: every PUT carried the file, on the evidence branch, at its path
  python3 -I - "$@" <<'TALOS_PY_gh776Qm4xZ'
import base64, json, sys
log, files = sys.argv[1], sys.argv[2:]
puts = []
for line in open(log):
    f = line.rstrip("\n").split("\t")
    if len(f) >= 4 and f[3] == "PUT":
        puts.append((f[0], json.loads(f[1])))
ok = len(puts) == len(files)
for (url, body), path in zip(puts, files):
    name = path.rsplit("/", 1)[1]
    ok = ok and url.endswith("/contents/pr-7/01234567/" + name)
    ok = ok and body.get("branch") == "talos-evidence" and bool(body.get("message"))
    ok = ok and base64.b64decode(body["content"]) == open(path, "rb").read()
print("yes" if ok else "no")
TALOS_PY_gh776Qm4xZ
}

for LEG in gh curl; do
  github_leg "$LEG"
  EVD="$SANDBOX/evid-$LEG"; STORE="$SANDBOX/store-$LEG.json"
  mkdir -p "$EVD" || exit 1
  export STUB_EVIDENCE_DIR="$EVD" STUB_COMMENT_STORE="$STORE" STUB_CURRENT_USER=owner STUB_PR_HEAD_SHA="$SHA"
  printf '[]' > "$STORE"; : > "$CURL_LOG"; : > "$GH_LOG"

  out="$(bash "$VCS" attach-files 7 "$EV/a.png" "$EV/b.webm" 2>"$SANDBOX/err")"; rc=$?
  assert_eq "0" "$rc" "AC9 [$LEG] attach-files exits 0"
  [ "$rc" -eq 0 ] || cat "$SANDBOX/err" >&2
  assert_eq "yes" "$(put_check "$CURL_LOG" "$EV/a.png" "$EV/b.webm")" "AC9 [$LEG] each file is committed to talos-evidence at pr-7/01234567/<name>"
  assert_eq "1" "$(awk -F'\t' '$4=="POST" && $1 ~ /\/git\/refs$/' "$CURL_LOG" | wc -l | tr -d ' ')" "AC9 [$LEG] the missing talos-evidence branch is created once"
  assert_contains "$(awk -F'\t' '$4=="POST" && $1 ~ /\/git\/refs$/ {print $2}' "$CURL_LOG")" "refs/heads/talos-evidence" "AC9 [$LEG] the branch ref is refs/heads/talos-evidence"
  body="$(store_bodies "$STORE")"
  assert_eq "1" "$(printf '%s\n' "$body" | grep -c .)" "AC9 [$LEG] exactly one evidence comment is posted"
  assert_contains "$body" 'QA evidence for 01234567' "AC9 [$LEG] the heading names the head sha"
  assert_contains "$body" '![a.png](https://github.com/acme/widget/blob/talos-evidence/pr-7/01234567/a.png?raw=true)' "AC9 [$LEG] the image is inline with a ?raw=true blob link"
  assert_contains "$body" '[b.webm](https://github.com/acme/widget/blob/talos-evidence/pr-7/01234567/b.webm?raw=true)' "AC9 [$LEG] the video is a link"
  assert_not_contains "$body" '![b.webm]' "AC9 [$LEG] the video is not an inline image"
  assert_contains "$body" "$MARK\"" "AC9 [$LEG] the comment ends with the talos:qa-evidence marker"
  assert_contains "$out" "issuecomment" "AC9 [$LEG] the comment URL is printed"

  # AC10: the next round (a new head) edits that comment.
  export STUB_PR_HEAD_SHA="$SHA2"
  : > "$CURL_LOG"
  out="$(bash "$VCS" attach-files 7 "$EV/a.png" 2>"$SANDBOX/err")"; rc=$?
  assert_eq "0" "$rc" "AC10 [$LEG] a second attach-files exits 0"
  body="$(store_bodies "$STORE")"
  assert_eq "1" "$(printf '%s\n' "$body" | grep -c .)" "AC10 [$LEG] a second attach-files leaves one evidence comment"
  assert_contains "$body" 'QA evidence for fedcba98' "AC10 [$LEG] the comment now names the new head"
  assert_eq "1" "$(awk -F'\t' '$4=="PATCH"' "$CURL_LOG" | wc -l | tr -d ' ')" "AC10 [$LEG] the existing comment is PATCHed"
  assert_eq "0" "$(awk -F'\t' '$4=="POST" && $1 ~ /\/comments$/' "$CURL_LOG" | wc -l | tr -d ' ')" "AC10 [$LEG] no second comment is POSTed"
  assert_eq "0" "$(awk -F'\t' '$4=="POST" && $1 ~ /\/git\/refs$/' "$CURL_LOG" | wc -l | tr -d ' ')" "AC10 [$LEG] the existing branch is reused"

  # AC10: a failed upload is listed as not attached; the comment is posted and the verb exits 0 (#811).
  rm -rf "${EVD:?}"/*; printf '[]' > "$STORE"; : > "$CURL_LOG"
  export STUB_EVIDENCE_PUT_FAIL=b.webm STUB_PR_HEAD_SHA="$SHA"
  out="$(bash "$VCS" attach-files 7 "$EV/a.png" "$EV/b.webm" 2>"$SANDBOX/err")"; rc=$?
  unset STUB_EVIDENCE_PUT_FAIL
  assert_eq "0" "$rc" "AC10 [$LEG] a failed upload still exits 0"
  assert_eq "1" "$(store_bodies "$STORE" | grep -c .)" "AC10 [$LEG] a failed upload still posts the comment"
  assert_contains "$(store_bodies "$STORE")" 'b.webm: not attached (500: Server Error)' "AC10 [$LEG] the failed file is listed as not attached with its reason"
done

# ── AC7 + AC10 (azure) ───────────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}
EOF
export STUB_CURRENT_USER="bot@acme.com" STUB_AZURE_POST_AUTHOR="bot@acme.com"
export STUB_AZURE_PR_9="{\"pullRequestId\":9,\"lastMergeSourceCommit\":{\"commitId\":\"$SHA\"}}"
export CURL_ARGV_LOG="$SANDBOX/curl.argv.log"
export STUB_AZURE_GIT_LOG="$SANDBOX/az-git.log"
az_fresh() {
  STUB_AZURE_STATE_DIR="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-az-776.XXXXXX")" || exit 1
  STUB_AZURE_GIT_DIR="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-azg-776.XXXXXX")" || exit 1
  export STUB_AZURE_STATE_DIR STUB_AZURE_GIT_DIR
  : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CURL_ARGV_LOG"; : > "$STUB_AZURE_GIT_LOG"
}
# pushed_bytes <log> <file>... -- the push carries each file at /pr-9/01234567/<name>, byte for byte.
pushed_bytes() {
  python3 -I - "$@" <<'TALOS_PY_pb776Hq3nVd'
import base64, json, sys
log, files = sys.argv[1], sys.argv[2:]
got = {}
for line in open(log):
    if line.startswith("PUSH\t"):
        for c in json.loads(line.split("\t", 1)[1])["commits"][0]["changes"]:
            got[c["item"]["path"]] = base64.b64decode(c["newContent"]["content"])
ok = all(got.get("/pr-9/01234567/" + f.rsplit("/", 1)[1]) == open(f, "rb").read() for f in files)
print("yes" if ok else "no")
TALOS_PY_pb776Hq3nVd
}
az_content() {  # <n> the n-th thread body's comment text
  sed -n 's/^AZ BODY: //p' "$GH_LOG" | sed -n "${1}p" | python3 -I -c '
import json, sys
line = sys.stdin.readline()
if line.strip():
    d = json.loads(line)
    sys.stdout.write(d["comments"][0]["content"] if "comments" in d else d["content"])'
}
az_posts() { count_log "$GH_LOG" '^AZ ARGS: \[rest\] \[--method\] \[post\].*pullRequests/9/threads'; }
az_patches() { count_log "$GH_LOG" '^AZ ARGS: \[rest\] \[--method\] \[patch\].*pullRequests/9/threads/.*/comments/'; }

az_fresh
out="$(bash "$VCS" attach-files 9 "$EV/a.png" "$EV/b.webm" 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "AC7 azure attach-files exits 0"
AZITEMS='https://dev.azure.com/acme/proj/_apis/git/repositories/widget/items?path=/pr-9/01234567'
AZQ='&versionDescriptor.version=talos-evidence&versionDescriptor.versionType=branch&$format=octetStream&api-version=7.1'
assert_eq "1" "$(count_log "$STUB_AZURE_GIT_LOG" '^PUSH')" "AC7 both files are one push to the evidence branch"
assert_eq "0" "$(count_log "$CURL_LOG" '/attachments/')" "AC7 the PR attachments endpoint is not used"
assert_eq "0" "$(count_log "$CURL_ARGV_LOG" 'stub-ado-token')" "AC7 the token is not on the curl command line"
assert_eq "yes" "$(pushed_bytes "$STUB_AZURE_GIT_LOG" "$EV/a.png" "$EV/b.webm")" "AC7 the pushed bytes are the files' bytes"
assert_eq "1" "$(az_posts)" "AC7 exactly one comment thread is posted"
C="$(az_content 1)"
assert_contains "$C" 'QA evidence for 01234567' "AC7 the heading names the head sha"
assert_contains "$C" "![a.png]($AZITEMS/a.png$AZQ)" "AC7 the image is inline with the items URL on the branch"
assert_contains "$C" "[b.webm]($AZITEMS/b.webm$AZQ)" "AC7 the video is a link with the items URL on the branch"
assert_not_contains "$C" '](a.png)' "AC7 no bare filename is used as a link target"
assert_eq "$MARK" "$(printf '%s' "$C" | tail -n1)" "AC7 the comment ends with the talos:qa-evidence marker"

out="$(bash "$VCS" attach-files 9 "$EV/a.png" 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "AC10 azure: a second attach-files exits 0"
assert_eq "1" "$(az_posts)" "AC10 azure: a second attach-files posts no second thread"
assert_eq "1" "$(az_patches)" "AC10 azure: a second attach-files edits the evidence comment"

az_fresh
out="$(STUB_AZURE_PUSH_FAIL='500:Server Error' bash "$VCS" attach-files 9 "$EV/a.png" "$EV/b.webm" 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "AC10 azure: a refused push still exits 0"
assert_eq "1" "$(az_posts)" "AC10 azure: a refused push still posts the comment"
assert_contains "$(az_content 1)" 'b.webm: not attached (500: Server Error)' "AC10 azure: the refused file is listed as not attached with its reason"

# ── AC8 + AC10 (gitlab) ──────────────────────────────────────────────────────
git remote set-url origin git@gitlab.com:acme/widget.git
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}
EOF
export STUB_CURRENT_USER="bot" STUB_GITLAB_POST_AUTHOR="bot"
export STUB_GITLAB_MR_VIEW="{\"iid\":9,\"sha\":\"$SHA\"}"
GL_NOTES="projects/acme%2Fwidget/merge_requests/9/notes"
gl_fresh() {
  STUB_GITLAB_STATE_DIR="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-gl-776.XXXXXX")" || exit 1
  export STUB_GITLAB_STATE_DIR
  : > "$GH_LOG"
}
# committed_bytes <log> <file>... -- the commit carries each file at pr-9/01234567/<name>, byte for byte.
committed_bytes() {
  python3 -I - "$@" <<'TALOS_PY_cb776Wp5jTe'
import base64, json, sys
log, files = sys.argv[1], sys.argv[2:]
got = {}
for line in open(log):
    if line.startswith("GLAB COMMIT: "):
        for a in json.loads(line[len("GLAB COMMIT: "):])["actions"]:
            got[a["file_path"]] = base64.b64decode(a["content"])
ok = all(got.get("pr-9/01234567/" + f.rsplit("/", 1)[1]) == open(f, "rb").read() for f in files)
print("yes" if ok else "no")
TALOS_PY_cb776Wp5jTe
}
gl_bodies() {  # the "body" of each logged note write, one per line (newlines as \n)
  grep '^GLAB BODY: ' "$GH_LOG" | sed 's/^GLAB BODY: //' | python3 -I -c '
import json, sys
for l in sys.stdin:
    print(json.loads(l)["body"].replace("\n", "\\n"))'
}

gl_fresh
out="$(bash "$VCS" attach-files 9 "$EV/a.png" "$EV/b.webm" 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "AC8 gitlab attach-files exits 0"
assert_eq "1" "$(count_log "$GH_LOG" '^GLAB api --method POST projects/acme%2Fwidget/repository/commits')" "AC8 both files are one commit on the evidence branch"
assert_eq "0" "$(count_log "$GH_LOG" '^GLAB api --method POST projects/acme%2Fwidget/uploads')" "AC8 the project uploads endpoint is not used"
assert_eq "yes" "$(committed_bytes "$GH_LOG" "$EV/a.png" "$EV/b.webm")" "AC8 the committed bytes are the files' bytes"
assert_eq "1" "$(count_log "$GH_LOG" "^GLAB api --method POST $GL_NOTES")" "AC8 exactly one MR note is posted"
B="$(gl_bodies)"
GLRAW='https://gitlab.com/acme/widget/-/raw/talos-evidence/pr-9/01234567'
assert_contains "$B" "![a.png]($GLRAW/a.png)" "AC8 the note links the -/raw/ URL on the branch (image)"
assert_contains "$B" "[b.webm]($GLRAW/b.webm)" "AC8 the note links the -/raw/ URL on the branch (video)"
assert_not_contains "$B" '![b.webm]' "AC8 the video is not an inline image"
assert_contains "$B" "QA evidence for 01234567" "AC8 the heading names the head sha"
assert_contains "$B" "\\n\\n$MARK" "AC8 the note ends with the talos:qa-evidence marker"

out="$(bash "$VCS" attach-files 9 "$EV/a.png" 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "AC10 gitlab: a second attach-files exits 0"
assert_eq "1" "$(count_log "$GH_LOG" "^GLAB api --method POST $GL_NOTES")" "AC10 gitlab: a second attach-files posts no second note"
assert_eq "1" "$(count_log "$GH_LOG" "^GLAB api --method PUT $GL_NOTES/")" "AC10 gitlab: a second attach-files edits the evidence note"

gl_fresh
out="$(STUB_GITLAB_COMMIT_FAIL='ERROR: 500 Internal Server Error' bash "$VCS" attach-files 9 "$EV/a.png" "$EV/b.webm" 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "AC10 gitlab: a refused commit still exits 0"
assert_eq "1" "$(count_log "$GH_LOG" "^GLAB api --method POST $GL_NOTES")" "AC10 gitlab: a refused commit still posts the note"
assert_contains "$(gl_bodies)" 'b.webm: not attached (ERROR: 500 Internal Server Error)' "AC10 gitlab: the refused file is listed as not attached with the glab error"

# ── AC11: refused before any network call ────────────────────────────────────
no_calls() {  # <label> <args...>: exit 1, and not one request or CLI call
  local _l="$1"; shift
  : > "$GH_LOG"; : > "$CURL_LOG"
  out="$(bash "$VCS" attach-files "$@" 2>&1)"; rc=$?
  assert_eq "1" "$rc" "AC11 $_l: exit 1"
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
  no_calls "$P a symlink beside a good file" 9 "$EV/a.png" "$EV/link.png"
  no_calls "$P a missing file" 9 "$EV/nope.png"
  no_calls "$P a directory" 9 "$EV"
  no_calls "$P a non-numeric PR" x9 "$EV/a.png"
  no_calls "$P no PR number" ""
done
printf '%s\n' '{"vcs": {"provider": "file"}}' > talos.pipeline.json
out="$(bash "$VCS" attach-files 9 "$EV/a.png" 2>&1)"; rc=$?
assert_eq "2" "$rc" "AC11 the file provider exits 2"
assert_contains "$out" "not implemented for provider 'file'" "AC11 the file provider says not implemented"

# ── AC12 (same): the suites that pin verbs, parity, config keys and markers stay green ─
for T in test-verb-parity.sh test-vcs-provider-parity.sh test-config-defaults-table.sh test-marker-contract.sh; do
  bash "$TALOS_ROOT/tests/$T" > "$SANDBOX/ac12.out" 2>&1; rc=$?
  assert_eq "0" "$rc" "AC12 tests/$T stays green"
  [ "$rc" -eq 0 ] || tail -n 5 "$SANDBOX/ac12.out" >&2
done

finish
