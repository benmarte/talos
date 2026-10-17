#!/usr/bin/env bash
# test-attach-files-776.sh -- `pipeline-vcs.sh attach-files <pr> <file>...` (#776):
# upload files and post (or edit) ONE `talos:qa-evidence` comment per PR on
# azure, gitlab and github. Offline: the az, glab, gh and curl stubs only.
#   AC7  azure: each file POSTed to the attachments endpoint as
#        application/octet-stream; the comment uses the full URLs it returned
#   AC8  gitlab: each file uploaded to /projects/:id/uploads; the MR note is
#        built from the returned markdown
#   AC9  github: each file committed to talos-evidence at pr-<n>/<sha8>/<name>;
#        the comment holds the ?raw=true blob links, images inline
#   AC10 a second attach-files edits the evidence comment; a failed upload
#        posts nothing and exits 1 (all three providers)
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

# same_bytes <uploaded-copy> <original> -- the stub received the file byte for byte.
same_bytes() { [ -f "$1" ] && [ "$(cksum < "$1")" = "$(cksum < "$2")" ]; }
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

  # AC10: a failed upload posts nothing and exits 1.
  rm -rf "${EVD:?}"/*; printf '[]' > "$STORE"; : > "$CURL_LOG"
  export STUB_EVIDENCE_PUT_FAIL=b.webm STUB_PR_HEAD_SHA="$SHA"
  out="$(bash "$VCS" attach-files 7 "$EV/a.png" "$EV/b.webm" 2>"$SANDBOX/err")"; rc=$?
  unset STUB_EVIDENCE_PUT_FAIL
  assert_eq "1" "$rc" "AC10 [$LEG] a failed upload exits 1"
  assert_eq "0" "$(store_bodies "$STORE" | grep -c .)" "AC10 [$LEG] a failed upload posts no comment"
done

# ── AC7 + AC10 (azure) ───────────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}
EOF
export STUB_CURRENT_USER="bot@acme.com" STUB_AZURE_POST_AUTHOR="bot@acme.com"
export STUB_AZURE_PR_9="{\"pullRequestId\":9,\"lastMergeSourceCommit\":{\"commitId\":\"$SHA\"}}"
export CURL_ARGV_LOG="$SANDBOX/curl.argv.log"
az_fresh() {
  STUB_AZURE_STATE_DIR="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-az-776.XXXXXX")" || exit 1
  export STUB_AZURE_STATE_DIR
  rm -rf "${UP:?}"/*; : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CURL_ARGV_LOG"
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
assert_eq "1" "$(count_log "$CURL_LOG" '/pullRequests/9/attachments/a\.png\?api-version=7\.1-preview\.1')" "AC7 a.png is POSTed to the attachments endpoint"
assert_eq "1" "$(count_log "$CURL_LOG" '/pullRequests/9/attachments/b\.webm\?api-version=7\.1-preview\.1')" "AC7 b.webm is POSTed to the attachments endpoint"
assert_eq "2" "$(count_log "$CURL_ARGV_LOG" 'Content-Type: application/octet-stream')" "AC7 each upload is application/octet-stream"
assert_eq "0" "$(count_log "$CURL_ARGV_LOG" 'stub-ado-token')" "AC7 the token is not on the curl command line"
if same_bytes "$UP/a.png" "$EV/a.png" && same_bytes "$UP/b.webm" "$EV/b.webm"; then
  pass "AC7 the uploaded bytes are the files' bytes"
else
  fail "AC7 the uploaded bytes are the files' bytes"
fi
assert_eq "1" "$(az_posts)" "AC7 exactly one comment thread is posted"
C="$(az_content 1)"
assert_contains "$C" 'QA evidence for 01234567' "AC7 the heading names the head sha"
assert_contains "$C" '![a.png](https://dev.azure.com/acme/proj/_apis/git/repositories/widget/pullRequests/9/attachments/a.png)' "AC7 the image is inline with the full returned URL"
assert_contains "$C" '[b.webm](https://dev.azure.com/acme/proj/_apis/git/repositories/widget/pullRequests/9/attachments/b.webm)' "AC7 the video is a link with the full returned URL"
assert_not_contains "$C" '](a.png)' "AC7 no bare filename is used as a link target"
assert_eq "$MARK" "$(printf '%s' "$C" | tail -n1)" "AC7 the comment ends with the talos:qa-evidence marker"

out="$(bash "$VCS" attach-files 9 "$EV/a.png" 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "AC10 azure: a second attach-files exits 0"
assert_eq "1" "$(az_posts)" "AC10 azure: a second attach-files posts no second thread"
assert_eq "1" "$(az_patches)" "AC10 azure: a second attach-files edits the evidence comment"

az_fresh
out="$(STUB_AZURE_UPLOAD_FAIL=b.webm bash "$VCS" attach-files 9 "$EV/a.png" "$EV/b.webm" 2>"$SANDBOX/err")"; rc=$?
assert_eq "1" "$rc" "AC10 azure: a failed upload exits 1"
assert_eq "0" "$(az_posts)" "AC10 azure: a failed upload posts nothing"

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
  rm -rf "${UP:?}"/*; : > "$GH_LOG"
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
assert_eq "1" "$(count_log "$GH_LOG" '^GLAB UPLOAD: a\.png [0-9]+ multipart/form-data; boundary=')" "AC8 a.png is uploaded as multipart/form-data"
assert_eq "1" "$(count_log "$GH_LOG" '^GLAB UPLOAD: b\.webm [0-9]+ multipart/form-data; boundary=')" "AC8 b.webm is uploaded as multipart/form-data"
assert_eq "2" "$(count_log "$GH_LOG" '^GLAB api --method POST projects/acme%2Fwidget/uploads')" "AC8 two uploads go to /projects/:id/uploads"
if same_bytes "$UP/a.png" "$EV/a.png" && same_bytes "$UP/b.webm" "$EV/b.webm"; then
  pass "AC8 the uploaded bytes are the files' bytes"
else
  fail "AC8 the uploaded bytes are the files' bytes"
fi
assert_eq "1" "$(count_log "$GH_LOG" "^GLAB api --method POST $GL_NOTES")" "AC8 exactly one MR note is posted"
B="$(gl_bodies)"
assert_contains "$B" '![a.png](/uploads/0123abcd/a.png)' "AC8 the note uses the markdown the upload returned (image)"
assert_contains "$B" '[b.webm](/uploads/0123abcd/b.webm)' "AC8 the note uses the markdown the upload returned (video)"
assert_not_contains "$B" '![b.webm]' "AC8 the video is not an inline image"
assert_contains "$B" "QA evidence for 01234567" "AC8 the heading names the head sha"
assert_contains "$B" "\\n\\n$MARK" "AC8 the note ends with the talos:qa-evidence marker"

out="$(bash "$VCS" attach-files 9 "$EV/a.png" 2>"$SANDBOX/err")"; rc=$?
assert_eq "0" "$rc" "AC10 gitlab: a second attach-files exits 0"
assert_eq "1" "$(count_log "$GH_LOG" "^GLAB api --method POST $GL_NOTES")" "AC10 gitlab: a second attach-files posts no second note"
assert_eq "1" "$(count_log "$GH_LOG" "^GLAB api --method PUT $GL_NOTES/")" "AC10 gitlab: a second attach-files edits the evidence note"

gl_fresh
out="$(STUB_GITLAB_UPLOAD_FAIL=b.webm bash "$VCS" attach-files 9 "$EV/a.png" "$EV/b.webm" 2>"$SANDBOX/err")"; rc=$?
assert_eq "1" "$rc" "AC10 gitlab: a failed upload exits 1"
assert_eq "0" "$(count_log "$GH_LOG" "^GLAB api --method (POST|PUT) $GL_NOTES")" "AC10 gitlab: a failed upload posts nothing"

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

finish
