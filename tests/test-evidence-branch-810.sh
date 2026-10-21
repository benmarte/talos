#!/usr/bin/env bash
# test-evidence-branch-810.sh -- `pipeline-vcs.sh attach-files <pr> <file>...` stores
# the QA evidence on the `talos-evidence` branch on azure and gitlab too (#810), as it
# does on github: one commit with every file at pr-<n>/<sha8>/<name>, linked from the
# one `talos:qa-evidence` comment. Offline: the az, glab and curl stubs only.
#   AC1  azure, branch absent: the branch is created from the default branch's head,
#        then ONE push carries every file as `add`, base64; no attachments call
#   AC2  azure, branch present: no creation; the push's oldObjectId is its head
#   AC3  azure, a second run at the same head: existing paths `edit`, new ones `add`
#   AC4  azure comment: screenshot inline, video a link, both to the items URL
#   AC5  azure, push or branch creation refused: every file listed, comment posted, exit 0
#   AC6  gitlab, branch absent: one commits call with start_branch; no uploads call
#   AC7  gitlab, a second run at the same head: `update` for existing, `create` for new
#   AC8  gitlab note: screenshot inline, video a link, both to the -/raw/ URL
#   AC9  gitlab, the commit refused: every file listed, note posted, exit 0
# (AC10 to AC15 are the existing suites and prose.)
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
EV="$SANDBOX/ev"
mkdir -p "$EV" || exit 1
printf '\211PNG\r\n\032\n\000\001binary-a' > "$EV/a.png"
printf 'WEBM-bytes\000\377end' > "$EV/b.webm"
printf '\211PNG\r\n\032\n\000\001binary-c' > "$EV/c.png"

# count_log <file> <ERE> -- matching lines (0 when none).
count_log() { local _n; _n="$(grep -cE -- "$2" "$1" || true)"; printf '%s' "${_n:-0}"; }

# check_changes <kind> <log> <n> <spec>... : the n-th logged push/commit has exactly
# the changes of the specs, in order: `<verb>:<name>:<file>` -- the verb, the path under
# pr-9/01234567/ and the local file whose bytes the content carries. Prints yes or no.
check_changes() {
  python3 -I - "$@" <<'TALOS_PY_ev810Zk4tQw'
import base64, json, sys
kind, log, n, specs = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4:]
lines = []
for line in open(log):
    if kind == "az" and line.startswith("PUSH\t"):
        lines.append(json.loads(line.split("\t", 1)[1]))
    if kind == "gl" and line.startswith("GLAB COMMIT: "):
        lines.append(json.loads(line[len("GLAB COMMIT: "):]))
if len(lines) < n:
    print("no")
    sys.exit(0)
d = lines[n - 1]
ok = True
if kind == "az":
    got = [(c["changeType"], c["item"]["path"], c["newContent"]) for c in d["commits"][0]["changes"]]
    ok = len(d["commits"]) == 1 and len(got) == len(specs)
    for (verb, path, content), spec in zip(got, specs):
        sv, name, f = spec.split(":")
        ok = ok and verb == sv and path == "/pr-9/01234567/" + name
        ok = ok and content["contentType"] == "base64encoded"
        ok = ok and base64.b64decode(content["content"]) == open(f, "rb").read()
else:
    got = d["actions"]
    ok = len(got) == len(specs)
    for a, spec in zip(got, specs):
        sv, name, f = spec.split(":")
        ok = ok and a["action"] == sv and a["file_path"] == "pr-9/01234567/" + name
        ok = ok and a["encoding"] == "base64"
        ok = ok and base64.b64decode(a["content"]) == open(f, "rb").read()
print("yes" if ok else "no")
TALOS_PY_ev810Zk4tQw
}
# push_field <log> <n> <expr> -- a field of the n-th azure push or branch creation.
log_field() {
  python3 -I - "$@" <<'TALOS_PY_ev810Lm7vRb'
import json, sys
log, kind, n, expr = sys.argv[1:5]
rows = [json.loads(l.split("\t", 1)[1]) for l in open(log) if l.startswith(kind + "\t")]
d = rows[int(n) - 1] if len(rows) >= int(n) else {}
try:
    print(eval(expr, {"d": d}))
except Exception:
    print("")
TALOS_PY_ev810Lm7vRb
}

# ── azure ────────────────────────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}
EOF
export STUB_CURRENT_USER="bot@acme.com" STUB_AZURE_POST_AUTHOR="bot@acme.com"
export STUB_AZURE_PR_9="{\"pullRequestId\":9,\"lastMergeSourceCommit\":{\"commitId\":\"$SHA\"}}"
export CURL_ARGV_LOG="$SANDBOX/curl.argv.log"
export STUB_AZURE_GIT_LOG="$SANDBOX/az-git.log"
GB="https://dev.azure.com/acme/proj/_apis/git/repositories/widget"
ZERO="$(printf '0%.0s' $(seq 1 40))"
MAIN_OID="$(printf 'a%.0s' $(seq 1 40))"
BRANCH_OID="$(printf 'b%.0s' $(seq 1 40))"
az_fresh() {  # a fresh Azure: no threads, no evidence branch
  STUB_AZURE_STATE_DIR="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-az-810.XXXXXX")" || exit 1
  STUB_AZURE_GIT_DIR="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-azg-810.XXXXXX")" || exit 1
  export STUB_AZURE_STATE_DIR STUB_AZURE_GIT_DIR
  : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CURL_ARGV_LOG"; : > "$STUB_AZURE_GIT_LOG"
}
az_attach() {  # <file>...: attach-files on PR 9; sets RC and OUT
  OUT="$(bash "$VCS" attach-files 9 "$@" 2>"$SANDBOX/err")"; RC=$?
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
az_url() { printf '%s/items?path=/pr-9/01234567/%s&versionDescriptor.version=talos-evidence&versionDescriptor.versionType=branch&$format=octetStream&api-version=7.1' "$GB" "$1"; }

# AC1: the branch is absent.
az_fresh
az_attach "$EV/a.png" "$EV/b.webm"
assert_eq "0" "$RC" "AC1 azure attach-files exits 0"
assert_eq "1" "$(count_log "$STUB_AZURE_GIT_LOG" '^REFS')" "AC1 azure: the missing talos-evidence branch is created once"
assert_eq "refs/heads/talos-evidence" "$(log_field "$STUB_AZURE_GIT_LOG" REFS 1 'd[0]["name"]')" "AC1 azure: the branch is refs/heads/talos-evidence"
assert_eq "$MAIN_OID" "$(log_field "$STUB_AZURE_GIT_LOG" REFS 1 'd[0]["newObjectId"]')" "AC1 azure: it starts at the default branch's head"
assert_eq "$ZERO" "$(log_field "$STUB_AZURE_GIT_LOG" REFS 1 'd[0]["oldObjectId"]')" "AC1 azure: it is created, not moved"
assert_eq "1" "$(count_log "$STUB_AZURE_GIT_LOG" '^PUSH')" "AC1 azure: exactly one push"
assert_eq "yes" "$(check_changes az "$STUB_AZURE_GIT_LOG" 1 "add:a.png:$EV/a.png" "add:b.webm:$EV/b.webm")" "AC1 azure: the push carries both files as add at /pr-9/01234567/<name>, base64 of the bytes"
assert_eq "refs/heads/talos-evidence" "$(log_field "$STUB_AZURE_GIT_LOG" PUSH 1 'd["refUpdates"][0]["name"]')" "AC1 azure: the push updates the evidence branch"
assert_eq "0" "$(count_log "$CURL_LOG" '/attachments/')" "AC1 azure: no call to the PR attachments endpoint"
assert_eq "0" "$(count_log "$CURL_ARGV_LOG" 'stub-ado-token')" "AC1 azure: the token is not on the curl command line"

# AC2: the branch is present.
az_fresh
printf '%s' "$BRANCH_OID" > "$STUB_AZURE_GIT_DIR/branch"
az_attach "$EV/a.png" "$EV/b.webm"
assert_eq "0" "$RC" "AC2 azure: attach-files on an existing branch exits 0"
assert_eq "0" "$(count_log "$STUB_AZURE_GIT_LOG" '^REFS')" "AC2 azure: the existing branch is not created again"
assert_eq "$BRANCH_OID" "$(log_field "$STUB_AZURE_GIT_LOG" PUSH 1 'd["refUpdates"][0]["oldObjectId"]')" "AC2 azure: the push's oldObjectId is the branch's current head"
assert_eq "yes" "$(check_changes az "$STUB_AZURE_GIT_LOG" 1 "add:a.png:$EV/a.png" "add:b.webm:$EV/b.webm")" "AC2 azure: both files are pushed"

# AC3: a second run at the same head.
az_fresh
az_attach "$EV/a.png" "$EV/b.webm"
az_attach "$EV/a.png" "$EV/b.webm" "$EV/c.png"
assert_eq "0" "$RC" "AC3 azure: a second run at the same head exits 0"
assert_eq "2" "$(count_log "$STUB_AZURE_GIT_LOG" '^PUSH')" "AC3 azure: one push per run"
assert_eq "yes" "$(check_changes az "$STUB_AZURE_GIT_LOG" 2 "edit:a.png:$EV/a.png" "edit:b.webm:$EV/b.webm" "add:c.png:$EV/c.png")" "AC3 azure: existing paths go in as edit, the new path as add"
assert_eq "1" "$(az_posts)" "AC3 azure: no second thread is posted"
assert_eq "1" "$(az_patches)" "AC3 azure: the evidence comment is edited"

# AC4: the comment.
az_fresh
az_attach "$EV/a.png" "$EV/b.webm"
C="$(az_content 1)"
assert_eq "1" "$(az_posts)" "AC4 azure: exactly one comment thread is posted"
assert_contains "$C" 'QA evidence for 01234567' "AC4 azure: the heading names the head sha"
assert_contains "$C" "![a.png]($(az_url a.png))" "AC4 azure: the screenshot is inline with the branch items URL"
assert_contains "$C" "[b.webm]($(az_url b.webm))" "AC4 azure: the video is a link with the branch items URL"
assert_not_contains "$C" '![b.webm]' "AC4 azure: the video is not an inline image"
assert_eq "$MARK" "$(printf '%s' "$C" | tail -n1)" "AC4 azure: the comment ends with the talos:qa-evidence marker"

# AC5: the push or the branch creation is refused.
listed_missing() {  # <comment> <reason-needle> <name>...
  local _c="$1" _r="$2" _n _ok=yes; shift 2
  for _n in "$@"; do
    printf '%s\n' "$_c" | grep -F -- "$_n: not attached (" | grep -qF -- "$_r" || _ok=no
  done
  printf '%s' "$_ok"
}
az_fresh
STUB_AZURE_PUSH_FAIL="403:TF401027: you need the GenericContribute permission" az_attach "$EV/a.png" "$EV/b.webm"
assert_eq "0" "$RC" "AC5 azure: a refused push exits 0"
assert_eq "1" "$(az_posts)" "AC5 azure: a refused push still posts the comment"
assert_eq "yes" "$(listed_missing "$(az_content 1)" "403: TF401027: you need the GenericContribute permission" a.png b.webm)" "AC5 azure: each file is listed as not attached with the status and the message"
assert_not_contains "$(az_content 1)" '![a.png](' "AC5 azure: a refused file has no image"
az_fresh
STUB_AZURE_REF_FAIL="400:the ref name is refused" az_attach "$EV/a.png" "$EV/b.webm"
assert_eq "0" "$RC" "AC5 azure: a refused branch creation exits 0"
assert_eq "1" "$(az_posts)" "AC5 azure: a refused branch creation still posts the comment"
assert_eq "yes" "$(listed_missing "$(az_content 1)" "400: the ref name is refused" a.png b.webm)" "AC5 azure: a refused branch creation lists every file with the status and the message"
assert_eq "0" "$(count_log "$STUB_AZURE_GIT_LOG" '^PUSH')" "AC5 azure: no push after a refused branch creation"

# ── gitlab ───────────────────────────────────────────────────────────────────
git remote set-url origin git@gitlab.com:acme/widget.git
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}
EOF
export STUB_CURRENT_USER="bot" STUB_GITLAB_POST_AUTHOR="bot"
export STUB_GITLAB_MR_VIEW="{\"iid\":9,\"sha\":\"$SHA\"}"
GL_NOTES="projects/acme%2Fwidget/merge_requests/9/notes"
gl_fresh() {
  STUB_GITLAB_STATE_DIR="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-gl-810.XXXXXX")" || exit 1
  export STUB_GITLAB_STATE_DIR
  : > "$GH_LOG"
}
gl_attach() {  # <file>...: attach-files on MR 9; sets RC and OUT
  OUT="$(bash "$VCS" attach-files 9 "$@" 2>"$SANDBOX/err")"; RC=$?
}
gl_bodies() {  # the "body" of each logged note write, one per line (newlines as \n)
  grep '^GLAB BODY: ' "$GH_LOG" | sed 's/^GLAB BODY: //' | python3 -I -c '
import json, sys
for l in sys.stdin:
    print(json.loads(l)["body"].replace("\n", "\\n"))'
}
gl_commit_field() {  # <n> <expr> -- a field of the n-th logged commit
  grep '^GLAB COMMIT: ' "$GH_LOG" | sed 's/^GLAB COMMIT: //' | sed -n "${1}p" | python3 -I -c '
import json, sys
line = sys.stdin.readline()
d = json.loads(line) if line.strip() else {}
try:
    print(eval(sys.argv[1], {"d": d}))
except Exception:
    print("")' "$2"
}
GLRAW="https://gitlab.com/acme/widget/-/raw/talos-evidence/pr-9/01234567"

# AC6: the branch is absent.
gl_fresh
gl_attach "$EV/a.png" "$EV/b.webm"
assert_eq "0" "$RC" "AC6 gitlab attach-files exits 0"
assert_eq "1" "$(count_log "$GH_LOG" '^GLAB api --method POST projects/acme%2Fwidget/repository/commits')" "AC6 gitlab: exactly one POST to the commits API"
assert_eq "talos-evidence" "$(gl_commit_field 1 'd["branch"]')" "AC6 gitlab: the commit is on talos-evidence"
assert_eq "main" "$(gl_commit_field 1 'd["start_branch"]')" "AC6 gitlab: a missing branch starts from the default branch"
assert_eq "yes" "$(check_changes gl "$GH_LOG" 1 "create:a.png:$EV/a.png" "create:b.webm:$EV/b.webm")" "AC6 gitlab: one create action per file at pr-9/01234567/<name>, base64"
assert_eq "0" "$(count_log "$GH_LOG" '^GLAB api --method POST projects/acme%2Fwidget/uploads')" "AC6 gitlab: no call to the uploads endpoint"

# AC7: a second run at the same head.
gl_fresh
gl_attach "$EV/a.png" "$EV/b.webm"
gl_attach "$EV/a.png" "$EV/b.webm" "$EV/c.png"
assert_eq "0" "$RC" "AC7 gitlab: a second run at the same head exits 0"
assert_eq "2" "$(count_log "$GH_LOG" '^GLAB COMMIT: ')" "AC7 gitlab: one commit per run"
assert_eq "yes" "$(check_changes gl "$GH_LOG" 2 "update:a.png:$EV/a.png" "update:b.webm:$EV/b.webm" "create:c.png:$EV/c.png")" "AC7 gitlab: existing paths go in as update, the new path as create"
assert_eq "" "$(gl_commit_field 2 'd.get("start_branch", "")')" "AC7 gitlab: an existing branch gets no start_branch"
assert_eq "1" "$(count_log "$GH_LOG" "^GLAB api --method POST $GL_NOTES")" "AC7 gitlab: no second note is posted"
assert_eq "1" "$(count_log "$GH_LOG" "^GLAB api --method PUT $GL_NOTES/")" "AC7 gitlab: the evidence note is edited"

# AC8: the note.
gl_fresh
gl_attach "$EV/a.png" "$EV/b.webm"
B="$(gl_bodies)"
assert_eq "1" "$(count_log "$GH_LOG" "^GLAB api --method POST $GL_NOTES")" "AC8 gitlab: exactly one MR note is posted"
assert_contains "$B" "QA evidence for 01234567" "AC8 gitlab: the heading names the head sha"
assert_contains "$B" "![a.png]($GLRAW/a.png)" "AC8 gitlab: the screenshot is inline with the -/raw/ URL"
assert_contains "$B" "[b.webm]($GLRAW/b.webm)" "AC8 gitlab: the video is a link with the -/raw/ URL"
assert_not_contains "$B" '![b.webm]' "AC8 gitlab: the video is not an inline image"
assert_contains "$B" "\\n\\n$MARK" "AC8 gitlab: the note ends with the talos:qa-evidence marker"

# AC9: the commit is refused.
gl_fresh
STUB_GITLAB_COMMIT_FAIL="ERROR: 403 Forbidden" gl_attach "$EV/a.png" "$EV/b.webm"
assert_eq "0" "$RC" "AC9 gitlab: a refused commit exits 0"
assert_eq "1" "$(count_log "$GH_LOG" "^GLAB api --method POST $GL_NOTES")" "AC9 gitlab: a refused commit still posts the note"
assert_eq "yes" "$(listed_missing "$(gl_bodies)" "ERROR: 403 Forbidden" a.png b.webm)" "AC9 gitlab: each file is listed as not attached with the glab error"

# ── AC10 to AC12 (same): the suites that pin the other behaviour stay green ──
# AC10 github is untouched, AC11 the azure and gitlab legs re-pointed at the branch
# model keep their idempotence, naming and exit-0 rules, AC12 the gate is untouched.
same_green() {  # <test file> <id>:<what>...: one run of the suite, one assertion per id
  local _t="$1" _w _rc; shift
  bash "$TALOS_ROOT/tests/$_t" > "$SANDBOX/same.out" 2>&1; _rc=$?
  for _w in "$@"; do
    assert_eq "0" "$_rc" "${_w%%:*} tests/$_t stays green (${_w#*:})"
  done
  [ "$_rc" -eq 0 ] || tail -n 8 "$SANDBOX/same.out" >&2
}
same_green test-attach-files-776.sh "AC10:the github legs" "AC11:the azure and gitlab legs on the branch model"
same_green test-attach-nonfatal-811.sh "AC10:the github legs" "AC11:the azure and gitlab legs on the branch model"
same_green test-e2e-artifacts-776.sh "AC12:no attach-files without verify.e2e_artifacts"

finish
