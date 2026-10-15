#!/usr/bin/env bash
# test-azure-pr-comment-verbs.sh -- upsert-pr-comment, mark-needs-owner and
# list-needs-owner on the azure provider, and merge.method on azure create-pr
# and merge-pr (#709). Before this change the pre-dispatch gate answered exit 2
# `not implemented for provider 'azure'` for the three verbs, so the spend
# comment and the owner question never reached an ADO PR, and merge-pr/create-pr
# passed no completion option, so a squash-only branch policy never read as met.
# Uses the tests/stubs/az stub; no credentials needed. Tests are named by the
# spec's criterion id (AC1 ...).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
git config user.email "test@talos.invalid"
git config user.name "talos-test"

# _cfg [<merge.method>] -- the azure project config.
_cfg() {
  local _mm=""
  [ -n "${1:-}" ] && _mm=",\"merge\":{\"method\":\"$1\"}"
  cat > talos.pipeline.json <<EOF
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}},
 "markers": {"trusted_authors": ["bot@acme.com", "owner@acme.com"]}$_mm}
EOF
}
_cfg

export STUB_CURRENT_USER="bot@acme.com"
export STUB_AZURE_POST_AUTHOR="bot@acme.com"
MARK='<!-- talos:spend -->'
NO_MARK='<!-- talos:needs-owner -->'

# _thr <thread-id> <comment-id> <author> <content> <date> -- one thread, one comment.
_thr() {
  python3 -I -c '
import json, sys
t, c, who, content, when = sys.argv[1:6]
print(json.dumps({"id": int(t), "comments": [{"id": int(c), "content": content, "commentType": "text",
    "author": {"displayName": "Some One", "uniqueName": who}, "publishedDate": when}]}))' "$@"
}
# _threads <thread-json>... -- the raw threads REST body.
_threads() {
  local _o="" _t
  for _t in "$@"; do _o="$_o${_o:+,}$_t"; done
  printf '{"value":[%s]}' "$_o"
}
# _labels <id:name>... -- the PR labels REST body.
_labels() {
  local _o="" _l
  for _l in "$@"; do _o="$_o${_o:+,}{\"id\":\"${_l%%:*}\",\"name\":\"${_l#*:}\",\"active\":true}"; done
  printf '{"count":%s,"value":[%s]}' "$#" "$_o"
}
# _count <regex> -- the number of logged az calls matching it.
_count() { local _n; _n="$(grep -c -- "$1" "$GH_LOG" || true)"; printf '%s' "${_n:-0}"; }
_thread_posts() { _count '^AZ ARGS: \[rest\] \[--method\] \[post\].*pullRequests/9/threads'; }
_patches() { _count '^AZ ARGS: \[rest\] \[--method\] \[patch\].*pullRequests/9/threads/.*/comments/'; }
_label_posts() { _count '^AZ ARGS: \[rest\] \[--method\] \[post\].*pullRequests/9/labels'; }
# _last_line <n> -- the last line of the n-th logged request body's comment content.
_last_line() {
  _content "$1" | python3 -I -c '
import sys
print(sys.stdin.read().rstrip("\n").split("\n")[-1])'
}
# _content <n> -- the n-th logged request body's comment content (nothing when there is none).
_content() {
  sed -n 's/^AZ BODY: //p' "$GH_LOG" | sed -n "${1}p" | python3 -I -c '
import json, sys
line = sys.stdin.readline()
if line.strip():
    d = json.loads(line)
    sys.stdout.write(d["comments"][0]["content"] if "comments" in d else d["content"])'
}

printf 'spend: 12k tokens\n' > f
NEW="$(printf 'spend: 12k tokens\n\n%s' "$MARK")"
OLD="$(printf 'spend: 3k tokens\n\n%s' "$MARK")"
EMPTY_THREADS='{"value":[]}'

# ── AC1: no marker comment -> one new thread ──────────────────────────────────
: > "$GH_LOG"
out="$(STUB_AZURE_PR_THREADS="$EMPTY_THREADS" bash "$VCS" upsert-pr-comment 9 --marker spend --body-file f 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC1 upsert-pr-comment exits 0 with no marker comment"
assert_eq "1" "$(_thread_posts)" "AC1 makes exactly one thread POST"
assert_eq "$MARK" "$(_last_line 1)" "AC1 the comment content's last line is the marker"
assert_eq "0" "$(_patches)" "AC1 patches nothing"
assert_contains "$out" "upserted pr=9 comment=created" "AC1 reports created"

# ── AC2: own marker comment -> PATCH the newest ───────────────────────────────
# Thread 5 (comment 2) is the newest by date though it is listed first.
t_new="$(_thr 5 2 bot@acme.com "$OLD" 2026-10-15T00:00:09Z)"
t_old="$(_thr 3 1 bot@acme.com "$OLD" 2026-10-15T00:00:01Z)"
: > "$GH_LOG"
out="$(STUB_AZURE_PR_THREADS="$(_threads "$t_new" "$t_old")" bash "$VCS" upsert-pr-comment 9 --marker spend --body-file f 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC2 upsert-pr-comment exits 0 when it updates"
assert_eq "1" "$(_patches)" "AC2 sends exactly one PATCH"
assert_eq "1" "$(_count '^AZ ARGS: \[rest\] \[--method\] \[patch\].*pullRequests/9/threads/5/comments/2?')" "AC2 patches the newest marker comment (thread 5, comment 2)"
assert_eq "0" "$(_thread_posts)" "AC2 makes no thread POST"
assert_eq "$NEW" "$(_content 1)" "AC2 the PATCH carries the new body"
assert_contains "$out" "upserted pr=9 comment=updated" "AC2 reports updated"

# ── AC3: identical body -> no write ───────────────────────────────────────────
: > "$GH_LOG"
out="$(STUB_AZURE_PR_THREADS="$(_threads "$(_thr 5 2 bot@acme.com "$NEW" 2026-10-15T00:00:09Z)")" bash "$VCS" upsert-pr-comment 9 --marker spend --body-file f 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC3 upsert-pr-comment exits 0 when the body is unchanged"
assert_eq "0" "$(_patches)" "AC3 sends no PATCH"
assert_eq "0" "$(_thread_posts)" "AC3 sends no thread POST"
assert_contains "$out" "upserted pr=9 comment=unchanged" "AC3 reports unchanged"

# ── AC4: someone else's marker comment is never patched ───────────────────────
: > "$GH_LOG"
out="$(STUB_AZURE_PR_THREADS="$(_threads "$(_thr 5 2 mallory@acme.com "$OLD" 2026-10-15T00:00:09Z)")" bash "$VCS" upsert-pr-comment 9 --marker spend --body-file f 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC4 upsert-pr-comment exits 0 next to someone else's marker comment"
assert_eq "0" "$(_patches)" "AC4 never patches another author's comment"
assert_eq "1" "$(_thread_posts)" "AC4 creates a new thread"

# ── AC5: an unreadable PR or an unknown identity posts nothing ────────────────
: > "$GH_LOG"
STUB_AZURE_PR_THREADS_FAIL=1 bash "$VCS" upsert-pr-comment 9 --marker spend --body-file f >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC5 a failed threads read exits non-zero"
assert_eq "0" "$(( $(_thread_posts) + $(_patches) ))" "AC5 a failed threads read posts nothing"
: > "$GH_LOG"
STUB_CURRENT_USER="" STUB_AZURE_PR_THREADS="$EMPTY_THREADS" bash "$VCS" upsert-pr-comment 9 --marker spend --body-file f >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC5 an unresolved authenticated user exits non-zero"
assert_eq "0" "$(( $(_thread_posts) + $(_patches) ))" "AC5 an unresolved authenticated user posts nothing"

# ── AC6: a failed write exits non-zero ────────────────────────────────────────
STUB_AZURE_PATCH_FAIL=1 STUB_AZURE_PR_THREADS="$(_threads "$t_old")" bash "$VCS" upsert-pr-comment 9 --marker spend --body-file f >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC6 a failed PATCH exits non-zero"
STUB_AZURE_POST_FAIL=1 STUB_AZURE_PR_THREADS="$EMPTY_THREADS" bash "$VCS" upsert-pr-comment 9 --marker spend --body-file f >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC6 a failed thread POST exits non-zero"

# ── AC7 / AC8: mark-needs-owner ───────────────────────────────────────────────
printf 'Which approach: A or B?\n' > q
: > "$GH_LOG"
out="$(STUB_AZURE_PR_THREADS="$EMPTY_THREADS" bash "$VCS" mark-needs-owner 9 --body-file q 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC7 mark-needs-owner exits 0"
assert_eq "1" "$(_thread_posts)" "AC7 creates exactly one thread"
assert_eq "$NO_MARK" "$(_last_line 1)" "AC7 the thread's last line is the needs-owner marker"
assert_contains "$(_content 1)" "Which approach: A or B?" "AC7 the thread carries the question"
assert_eq "1" "$(_label_posts)" "AC7 adds one label"
assert_contains "$(sed -n 's/^AZ BODY: //p' "$GH_LOG" | grep '"name"')" '"name": "pipeline:needs-owner"' "AC7 the label is pipeline:needs-owner"

: > "$GH_LOG"
STUB_AZURE_POST_FAIL=1 STUB_AZURE_PR_THREADS="$EMPTY_THREADS" bash "$VCS" mark-needs-owner 9 --body-file q >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC8 a failed thread post exits non-zero"
assert_eq "0" "$(_label_posts)" "AC8 a failed thread post does not add the label"

# ── AC9 - AC11: list-needs-owner ──────────────────────────────────────────────
PRS='[{"pullRequestId":9,"status":"active"},{"pullRequestId":10,"status":"active"}]'
Q="$(printf 'Which approach: A or B?\n\n%s' "$NO_MARK")"
QT="$(_thr 4 1 bot@acme.com "$Q" 2026-10-15T00:00:01Z)"
RT="$(_thr 5 1 owner@acme.com "Use option A" 2026-10-15T00:00:05Z)"
export STUB_AZURE_PR_LIST="$PRS"
export STUB_AZURE_PR_LABELS_9="$(_labels L1:pipeline:needs-owner)"
export STUB_AZURE_PR_LABELS_10="$(_labels L2:bug)"

: > "$GH_LOG"
out="$(STUB_AZURE_PR_THREADS="$(_threads "$QT")" bash "$VCS" list-needs-owner 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC9 list-needs-owner exits 0"
assert_eq "needs-owner n=9 kind=pr answered=no question=Which approach: A or B?" "$out" "AC9 lists the labelled PR with its unanswered question and nothing for the PR without the label"

: > "$GH_LOG"
out="$(STUB_AZURE_PR_THREADS="$(_threads "$QT" "$RT")" bash "$VCS" list-needs-owner --clear-answered 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC10 --clear-answered exits 0"
assert_contains "$out" "answered=yes" "AC10 the answered PR is listed as answered"
assert_contains "$out" "cleared n=9" "AC10 prints cleared n=9"
assert_eq "1" "$(_count '^AZ ARGS: \[rest\] \[--method\] \[delete\].*pullRequests/9/labels/L1?')" "AC10 deletes the label by its id"
assert_eq "0" "$(_count 'delete.*needs-owner')" "AC10 never puts the label name (a ':') in the URL path"

STUB_AZURE_LABEL_DELETE_FAIL=1 STUB_AZURE_PR_THREADS="$(_threads "$QT" "$RT")" bash "$VCS" list-needs-owner --clear-answered >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC10 a failed label delete exits non-zero"

for _f in STUB_AZURE_PR_LIST_FAIL STUB_AZURE_PR_LABELS_FAIL STUB_AZURE_PR_THREADS_FAIL; do
  : > "$GH_LOG"
  out="$(env "$_f=1" STUB_AZURE_PR_THREADS="$(_threads "$QT" "$RT")" bash "$VCS" list-needs-owner --clear-answered 2>/dev/null)"; rc=$?
  assert_eq "1" "$rc" "AC11 $_f exits non-zero"
  assert_eq "" "$out" "AC11 $_f prints nothing"
  assert_eq "0" "$(_count '\[delete\]')" "AC11 $_f removes no label"
done
unset STUB_AZURE_PR_LIST STUB_AZURE_PR_LABELS_9 STUB_AZURE_PR_LABELS_10

# ── AC12 - AC14: merge.method on merge-pr and create-pr ───────────────────────
export STUB_AZURE_PR_TITLE="fix: guard the thing"
printf 'pr body' > body.txt

_cfg
: > "$GH_LOG"
bash "$VCS" merge-pr 9 >/dev/null 2>&1; rc=$?
log="$(cat "$GH_LOG")"
assert_eq "0" "$rc" "AC12 merge-pr exits 0"
assert_contains "$log" "[repos] [pr] [update] [--id] [9]" "AC12 merge-pr completes the PR"
assert_contains "$log" "[--status] [completed]" "AC12 merge-pr sets status completed"
assert_contains "$log" "[--squash] [true]" "AC12 an unset merge.method squashes"
assert_contains "$log" "[--merge-commit-message] [fix: guard the thing]" "AC12 the squash message is the PR title"

_cfg squash
: > "$GH_LOG"
bash "$VCS" merge-pr 9 >/dev/null 2>&1
assert_contains "$(cat "$GH_LOG")" "[--squash] [true]" "AC12 merge.method squash squashes"

: > "$GH_LOG"
STUB_AZURE_PR_SHOW_FAIL=1 bash "$VCS" merge-pr 9 >/dev/null 2>&1; rc=$?
log="$(cat "$GH_LOG")"
assert_eq "0" "$rc" "AC12 an unreadable title does not fail merge-pr"
assert_contains "$log" "[--squash] [true]" "AC12 an unreadable title keeps --squash"
assert_not_contains "$log" "--merge-commit-message" "AC12 an unreadable title omits only the message flag"

_cfg merge
: > "$GH_LOG"
bash "$VCS" merge-pr 9 >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "[--squash] [false]" "AC13 merge.method merge passes --squash false"
assert_not_contains "$log" "--squash] [true]" "AC13 merge.method merge never squashes"

: > "$GH_LOG"
bash "$VCS" create-pr feature/x "PR title" body.txt >/dev/null 2>&1
assert_contains "$(cat "$GH_LOG")" "[--squash] [false]" "AC14 create-pr passes --squash false for merge"
_cfg squash
: > "$GH_LOG"
bash "$VCS" create-pr feature/x "PR title" body.txt >/dev/null 2>&1
assert_contains "$(cat "$GH_LOG")" "[--squash] [true]" "AC14 create-pr passes --squash true for squash"

# ── AC15 (prose guard): rebase and the other providers are unchanged ──────────
_cfg rebase
: > "$GH_LOG"
bash "$VCS" merge-pr 9 >/dev/null 2>&1
bash "$VCS" create-pr feature/x "PR title" body.txt >/dev/null 2>&1
assert_not_contains "$(cat "$GH_LOG")" "--squash" "AC15 rebase passes no --squash on merge-pr or create-pr"
assert_contains "$(cat "$GH_LOG")" "[--status] [completed]" "AC15 rebase still completes the PR"

for _p in gitlab file; do
  printf '{"vcs": {"provider": "%s"}}\n' "$_p" > talos.pipeline.json
  for _v in "upsert-pr-comment 9 --marker spend --body-file f" "mark-needs-owner 9 --body-file q" "list-needs-owner"; do
    out="$(bash "$VCS" $_v 2>&1)"; rc=$?
    assert_eq "2" "$rc" "AC15 $_p ${_v%% *} exits 2"
    assert_contains "$out" "not implemented for provider '$_p'" "AC15 $_p ${_v%% *} says not implemented"
  done
done

finish
