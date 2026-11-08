#!/usr/bin/env bash
# test-batching-834.sh -- batching (#834, part of #826): a lead issue with
# `Batched into: #<lead>` members gets one branch and one PR that closes the
# lead and every member. Each assertion label starts with its AC id.
#   AC1  pipeline-vcs.sh batch-members          AC5  post-merge runs the items for each member
#   AC2  next waits reason=batched for a member AC6  sweep heals a member left open
#   AC4  gate merge checks every member         AC7  qa-run / spec-usable need a criterion per member
# Every test runs on stubs: no GitHub read, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
ERR="$SANDBOX/stderr"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
NEXT="$TALOS_ROOT/scripts/pipeline-next.py"
ROOT_DIR="$SANDBOX"

# ── AC1: batch-members, on the gitlab adapter's list-issues ──────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab"}}
EOF
gl_items() {  # iid:description ... -> a glab issue list answer
  python3 -I -c '
import json, sys
print(json.dumps([{"iid": int(a.split(":", 1)[0]), "title": "t", "state": "opened",
                   "description": a.split(":", 1)[1].replace("\\n", "\n")} for a in sys.argv[1:]]))' "$@"
}
bm() { OUT="$(STUB_GITLAB_ISSUE_LIST="$1" bash "$VCS" batch-members "$2" 2>"$ERR")"; RC=$?; }

LIST="$(gl_items '11:Batched into: #5' '9:intro\nBatched into: #5\nmore' '7:Batched into: #5 (small)' \
  '12:Batched into: #50' '13:Batched into: #6' '14:no batch line, mentions #5' '5:the lead itself')"
bm "$LIST" 5
assert_eq "7
9
11" "$OUT" "AC1 batch-members prints the open members of the lead, ascending, one per line"
assert_eq "0" "$RC" "AC1 batch-members exits 0"
bm "$LIST" 50
assert_eq "12" "$OUT" "AC1 #50 is not matched by #5, and #5 not by #50 (the number is not followed by a digit)"
bm "$LIST" 99
assert_eq "" "$OUT" "AC1 a lead with no member prints nothing"
assert_eq "0" "$RC" "AC1 a lead with no member exits 0"
bm "this is not json" 5
assert_eq "" "$OUT" "AC1 an unreadable list prints nothing on stdout"
[ "$RC" -ne 0 ] && pass "AC1 an unreadable list exits non-zero" || fail "AC1 an unreadable list exits non-zero" "rc=$RC"
rm -f talos.pipeline.json

# ── AC2: next waits on a member while its lead is open ───────────────────────
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$STUB_DIR"
cat > "$SANDBOX/vcs.sh" <<'TALOS_stubvcs834Kq9'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_DIR:?}/calls.log"
[ "$1" = "view-issue" ] || exit 1
f="$STUB_DIR/view-issue.$2.json"
[ -f "$f" ] || exit 1
cat "$f"
TALOS_stubvcs834Kq9
issue() {  # n labels|- state body
  python3 -I -c "
import json, sys
labels = [] if sys.argv[2] == '-' else [{'name': x} for x in sys.argv[2].split(',')]
print(json.dumps({'number': int(sys.argv[1]), 'title': 'issue ' + sys.argv[1], 'labels': labels,
                  'state': sys.argv[3], 'body': sys.argv[4], 'comments': []}))" \
    "$1" "$2" "$3" "$4" > "$STUB_DIR/view-issue.$1.json"
}
state() {  # queued
  python3 -I -c "
import json, sys
d = {'prs': [], 'pr_total': 0, 'ignored': 0, 'blocked': [], 'queued': [int(x) for x in sys.argv[1].split(',')],
     'held': [], 'inflight': [], 'owners': [], 'capped': []}
print(json.dumps(d))" "$1" > "$SANDBOX/state.json"
}
walk() {  # [issue]
  OUT="$(python3 -I "$NEXT" issue-side "$SANDBOX/state.json" --vcs "$SANDBOX/vcs.sh" --issue "${1:-}" \
    --roles validator --label-filter pipeline:ready --skip-labels '' --max-parallel 4 --pm-skip false --leased '' 2>/dev/null)"
}
reset() { rm -f "$STUB_DIR"/*; }

reset
issue 5 "pipeline:confirmed" open "lead"
issue 6 "pipeline:ready" open $'small one\n\nBatched into: #5\n'
state "6"
walk 6
assert_eq "action=wait reason=batched" "$OUT" "AC2 next --issue <member> waits reason=batched while the lead is open"
walk
assert_eq "action=wait reason=batched" "$OUT" "AC2 the untargeted next waits reason=batched, never a dispatch"

issue 5 "-" closed "lead"
walk 6
assert_eq "action=dispatch stage=validator issue=6" "$OUT" "AC2 with the lead closed, next --issue <member> routes as today"
walk
assert_eq "action=dispatch stage=validator issue=6" "$OUT" "AC2 with the lead closed, the untargeted next routes as today"

reset
issue 6 "pipeline:ready" open "no batch line here, see #5"
state "6"
walk 6
assert_eq "action=dispatch stage=validator issue=6" "$OUT" "AC2 an issue with no Batched into: line routes as today"
issue 50 "-" closed "other"
issue 6 "pipeline:ready" open "Batched into: #50"
walk 6
assert_eq "action=dispatch stage=validator issue=6" "$OUT" "AC2 #50 closed does not make #5's member wait: the line names #50, which is closed"

# A member in the queue does not hide a ready lead behind it.
reset
issue 5 "pipeline:ready" open "lead"
issue 6 "pipeline:ready" open "Batched into: #5"
state "5,6"
walk
assert_eq "action=dispatch stage=validator issue=5" "$OUT" "AC2 a queued member is passed over; the lead is dispatched"

# ── AC4: gate merge checks the closing keyword for the lead and each member ──
GS="$SANDBOX/gs"
GSTUB="$SANDBOX/gstub"
export GSTUB
mkdir -p "$GS" "$GSTUB"
cp "$TALOS_ROOT"/scripts/* "$GS/"
# <key> is verb.<arg3>, then verb.<arg2>, then verb: $GSTUB/<key>.{out,err,rc}.
STUB_BODY='#!/usr/bin/env bash
d="${GSTUB:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then cands="${1:-}.${2:-}.${3:-} ${1:-}.${3:-} ${1:-}.${2:-} ${1:-}"; else cands="$n.${1:-} $n"; fi
key=""
for c in $cands; do
  if [ -e "$d/$c.out" ] || [ -e "$d/$c.err" ] || [ -e "$d/$c.rc" ]; then key="$c"; break; fi
done
printf "%s %s\n" "$n" "$*" >> "$d/journal"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then { printf "[%s]\n" "$*"; cat "$a"; } >> "$d/bodies"; cp "$a" "$d/last-body"; fi
  prev="$a"
done
if [ -n "$key" ]; then
  if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
  if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
  if [ -f "$d/$key.rc" ]; then exit "$(cat "$d/$key.rc")"; fi
fi
exit 0
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-mergebase.sh \
         pipeline-draft-check.sh pipeline-status.sh pipeline-worktree.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
GATE="$GS/talos.sh"
HEAD_SHA="0123456789abcdef0123456789abcdef01234567"

gset() {  # key rc [out] [err]
  printf '%s\n' "$2" > "$GSTUB/$1.rc"
  printf '%s' "${3:-}" > "$GSTUB/$1.out"
  printf '%s' "${4:-}" > "$GSTUB/$1.err"
}
gjournal() { cat "$GSTUB/journal" 2>/dev/null; }
gcalled() { gjournal | grep -c "^vcs $1 "; }
gate_reset() {
  rm -rf "${GSTUB:?}"; mkdir -p "$GSTUB"
  rm -f "$SANDBOX/talos.pipeline.json"
  gset view-pr 0 '{"labels":[{"name":"qa:pass"},{"name":"review:approved"},{"name":"security:approved"},{"name":"docs:done"},{"name":"pipeline:review"}]}'
  gset view-issue 0 '{"labels":[{"name":"pipeline:review"}]}'
  gset pr-head 0 "$HEAD_SHA"
  gset read-comments 0 '{"comments":[]}'
  gset draft-check 0 "false"
  gset batch-members 0 "43
44
"
  gset pr-closes-issue.9.43 0 "closes"
  gset pr-closes-issue.9.44 0 "closes"
}
gm() { OUT="$(bash "$GATE" gate merge 9 42 2>"$ERR")"; RC=$?; }

gate_reset
gm
assert_eq "verdict=merge" "$OUT" "AC4 a PR body closing the lead and every member passes the gate"
assert_contains "$(gjournal)" "vcs check-closing-keyword 9 42" "AC4 the closing-keyword check runs for the lead"
assert_contains "$(gjournal)" "vcs check-closing-keyword 9 43" "AC4 the closing-keyword check runs for the first member"
assert_contains "$(gjournal)" "vcs check-closing-keyword 9 44" "AC4 the closing-keyword check runs for the second member"

gate_reset
gset pr-closes-issue.9.44 0 "part-of"
gm
assert_eq "verdict=block
reason=closing-keyword" "$OUT" "AC4 a PR body with no closing keyword for one member blocks as closing-keyword"
assert_contains "$(gjournal)" "vcs label-pr 9 --add pipeline:blocked" "AC4 the PR is labelled pipeline:blocked"
assert_contains "$(cat "$GSTUB/bodies" 2>/dev/null)" "#44" "AC4 the comment names the member that is not closed"
assert_eq "0" "$(gcalled pr-checks-required)" "AC4 no later gate runs after the block"

gate_reset
gset check-closing-keyword.9.43 1 "" "pipeline-vcs: check-closing-keyword: PR #9 closes but open sibling PR(s)"
gm
assert_eq "verdict=block
reason=closing-keyword" "$OUT" "AC4 a member closed while a sibling PR is open blocks as closing-keyword, as for the lead"

gate_reset
gset batch-members 0 ""
gm
assert_eq "verdict=merge" "$OUT" "AC4 a PR with no member merges"
assert_eq "1" "$(gcalled check-closing-keyword)" "AC4 a PR with no member runs the one check it runs today"
assert_eq "0" "$(gcalled pr-closes-issue)" "AC4 a PR with no member asks nothing about members"

# ── AC5, AC6: post-merge and the sweep ───────────────────────────────────────
PSTUB="$SANDBOX/pstub"
export PSTUB
mkdir -p "$PSTUB"
PGS="$SANDBOX/pgs"
mkdir -p "$PGS"
cp "$TALOS_ROOT"/scripts/* "$PGS/"
PSTUB_BODY="$(printf '%s' "$STUB_BODY" | sed 's/GSTUB/PSTUB/g')"
# the post-merge stub also keys the other scripts by their first argument
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-mergebase.sh \
         pipeline-status.sh pipeline-worktree.sh pipeline-events.sh; do
  printf '%s' "$PSTUB_BODY" > "$PGS/$s"
done
PM="$PGS/talos.sh"
pset() {  # key rc [out] [err]
  printf '%s\n' "$2" > "$PSTUB/$1.rc"
  printf '%s' "${3:-}" > "$PSTUB/$1.out"
  printf '%s' "${4:-}" > "$PSTUB/$1.err"
}
pjournal() { cat "$PSTUB/journal" 2>/dev/null; }
pcalled() { pjournal | grep -c "^$1 \|^vcs $1 "; }
issue_json() {  # number "labels,..." body -> one list-issues item
  python3 -I -c '
import json, sys
print(json.dumps({"number": int(sys.argv[1]), "title": "t", "body": sys.argv[3],
                  "labels": [{"name": l} for l in sys.argv[2].split(",") if l]}))' "$1" "$2" "${3:-}"
}
list_of() { printf '[%s]' "$(IFS=,; echo "$*")"; }
marker_comments() {  # a read-comments answer: one comment by the bot with this body
  python3 -I -c 'import json, sys; print(json.dumps({"comments": [{"author": {"login": "bot"}, "body": sys.argv[1]}]}))' "$1"
}
post_reset() {
  rm -rf "${PSTUB:?}"; mkdir -p "$PSTUB"
  printf '%s' '{"vcs": {"provider": "github"}}' > "$SANDBOX/talos.pipeline.json"
  pset current-user 0 "bot"
  pset list-prs 0 "[]"
  pset read-comments 0 '{"comments":[]}'
  pset worktree.to-base 0 "talos:checkout state=kept"
  pset pr-closes-issue.9.42 0 "closes"
}
pm() { OUT="$(bash "$PM" post-merge "$@" 2>"$ERR")"; RC=$?; }
sw() { OUT="$(bash "$PM" sweep "$@" 2>"$ERR")"; RC=$?; }

post_reset
pset list-issues 0 "$(list_of "$(issue_json 42 "")" "$(issue_json 43 "" "Batched into: #42")" "$(issue_json 44 "" "Batched into: #42")" \
  "$(issue_json 45 "" "Batched into: #42")" "$(issue_json 46 "" "Batched into: #42")")"
pset batch-members 0 "43
44
45
46
"
pset pr-closes-issue.9.43 0 "closes"
pset pr-closes-issue.9.44 0 "part-of"
pset pr-closes-issue.9.45 2 "" "could not read"
pset pr-closes-issue.9.46 0 "closes"
pm 9 42
assert_eq "0" "$RC" "AC5 post-merge exits 0"
assert_contains "$(pjournal)" "vcs close-issue 42 closed by PR #9" "AC5 the lead is closed as before"
assert_contains "$(pjournal)" "vcs close-issue 43 closed by PR #9" "AC5 a member the PR body closes gets close-issue"
assert_contains "$(pjournal)" "status 43 Done" "AC5 a member the PR body closes goes to board Done"
assert_contains "$(cat "$PSTUB/bodies")" "<!-- talos:issue-closed pr=9 -->" "AC5 a closed member gets the issue-closed comment"
assert_contains "$(pjournal)" "vcs comment-issue 43 " "AC5 the issue-closed comment is posted on the member"
assert_not_contains "$(pjournal)" "vcs close-issue 44" "AC5 a member the body only mentions as Part of stays open"
assert_contains "$(pjournal)" "status 44 In progress" "AC5 a Part of member goes to In progress"
assert_contains "$OUT" "warn reason=closing-unverified issue=45 pr=9" "AC5 a member whose item fails prints its warn"
assert_not_contains "$(pjournal)" "vcs close-issue 45" "AC5 a member that cannot be verified is not closed"
assert_contains "$(pjournal)" "vcs close-issue 46 closed by PR #9" "AC5 the other members still run after one fails"

# idempotent per member: the issue-closed marker on #43 suppresses its comment.
post_reset
pset list-issues 0 "$(list_of "$(issue_json 42 "")" "$(issue_json 43 "" "Batched into: #42")")"
pset batch-members 0 "43
"
pset pr-closes-issue.9.43 0 "closes"
pset read-comments.43 0 "$(marker_comments "<!-- talos:issue-closed pr=9 -->")"
pm 9 42
assert_eq "0" "$(pjournal | grep -c '^vcs comment-issue 43 ')" "AC5 a member with the issue-closed marker gets no second comment"
assert_contains "$OUT" "recorded=yes" "AC5 the member's run sees its marker"

# An unbatched issue: members are asked once, nothing else changes.
post_reset
pset list-issues 0 "$(list_of "$(issue_json 42 "")")"
pm 9 42
assert_eq "0" "$RC" "AC5 an unbatched issue: post-merge exits 0"
assert_eq "1" "$(pcalled close-issue)" "AC5 an unbatched issue: exactly one close-issue"

# AC6: the sweep heals a member left open after its lead was merged.
post_reset
pset list-issues 0 "$(list_of "$(issue_json 6 "" "Batched into: #5")" "$(issue_json 8 "" "Batched into: #7")" "$(issue_json 7 "pipeline:confirmed")")"
pset find-pr.5 0 '{"number":9}'
pset pr-closes-issue.9.6 0 "closes"
sw
assert_eq "0" "$RC" "AC6 sweep exits 0"
assert_contains "$OUT" "heal=6 pr=9" "AC6 the member whose lead is closed is healed with the lead's merged PR"
assert_contains "$(pjournal)" "vcs find-pr 5 merged" "AC6 the lead's merged PR is looked up"
assert_contains "$(pjournal)" "vcs close-issue 6 closed by PR #9" "AC6 the healed member is closed"
assert_contains "$(pjournal)" "status 6 Done" "AC6 the healed member goes to board Done"
assert_not_contains "$(pjournal)" "close-issue 8" "AC6 an open member whose lead is still open is left alone"
assert_not_contains "$(pjournal)" "status 8" "AC6 an open member whose lead is still open gets no board change"

# ── AC7: a criterion per member ──────────────────────────────────────────────
BASE_DIR="$ROOT_DIR"
trap '_is_trap_owner && :; _sandbox_cleanup' EXIT
new_repo() {
  cd "$BASE_DIR" || exit 1
  rm -rf "${BASE_DIR:?}"/* "${BASE_DIR:?}"/.git "${BASE_DIR:?}"/.talos
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  mkdir scripts tests
  cp "$TALOS_ROOT"/scripts/* scripts/
  cp "$TALOS_ROOT/tests/run-tests.sh" tests/run-tests.sh
  cat > scripts/pipeline-vcs.sh <<'TALOS_Zr4Wn7QbL2xP'
#!/usr/bin/env bash
case "$1" in
  view-issue)
    python3 -I -c 'import json, sys
print(json.dumps({"title": "t", "body": "issue body", "labels": [],
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$QA_SPEC_FILE" ;;
  batch-members) printf '%s' "${QA_MEMBERS:-}" ;;
  pr-mergeable) echo MERGEABLE ;;
  checkout-pr) : ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_Zr4Wn7QbL2xP
  git add -A
  git commit -q -m "base"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b feat/issue-5-batch
  export QA_SPEC_FILE="$BASE_DIR/.git/qa-spec.md"
}
spec() {
  printf '**PM spec:** batch\n\n**Acceptance criteria**\n' > "$QA_SPEC_FILE"
  printf '%s\n' "$@" >> "$QA_SPEC_FILE"
}
usable() { OUT="$(bash scripts/pipeline-criteria.sh spec-usable 5 2>&1)"; RC=$?; }
TESTS='**Tests:** `tests/test-greet.sh`'

new_repo
export QA_MEMBERS=$'6\n7\n'
spec '- [ ] AC1 #5 greet prints hello (test)' '- [ ] AC2 #6 farewell prints bye (test)' '' "$TESTS"
usable
assert_eq "4" "$RC" "AC7 a member with no criterion exits 4"
assert_eq "spec-usable: BLOCKED spec: batch member #7 has no criterion" "$OUT" "AC7 spec-usable names the member with no criterion"
OUT="$(bash scripts/pipeline-criteria.sh qa-run 5 9 2>&1)"; RC=$?
assert_eq "4" "$RC" "AC7 qa-run on a lead with an uncovered member exits 4"
assert_contains "$OUT" "qa-run: verdict BLOCKED spec: batch member #7 has no criterion" "AC7 qa-run ends BLOCKED spec naming the member"

spec '- [ ] AC1 #5 greet prints hello (test)' '- [ ] AC2 #6 farewell prints bye (test)' '- [ ] AC3 #7 thanks prints thanks (test)' '' "$TESTS"
usable
assert_eq "spec-usable: ok" "$OUT" "AC7 a criterion naming every member makes the spec usable"
assert_eq "0" "$RC" "AC7 the covered batch exits 0"

spec '- [ ] AC1 #5 greet prints hello (test)' '- [ ] AC2 #6 farewell prints bye (test)' '- [ ] AC3 #70 other issue (test)' '' "$TESTS"
usable
assert_eq "spec-usable: BLOCKED spec: batch member #7 has no criterion" "$OUT" "AC7 #70 in a criterion does not cover #7"

spec '- [ ] AC1 #5 greet prints hello (test)' '- [ ] AC2 #6 farewell prints bye (test)' '- [ ] AC3 #7 thanks prints thanks (prose: wording)' '' "$TESTS"
usable
assert_eq "spec-usable: ok" "$OUT" "AC7 a (prose) criterion naming the member covers it"

# an issue with no member is unchanged; so is one whose provider cannot answer.
export QA_MEMBERS=""
spec '- [ ] AC1 greet prints hello (test)' '' "$TESTS"
usable
assert_eq "spec-usable: ok" "$OUT" "AC7 an issue with no member is unchanged"
unset QA_MEMBERS
sed -i.bak 's/^  batch-members) .*$//' scripts/pipeline-vcs.sh && rm -f scripts/pipeline-vcs.sh.bak
usable
assert_eq "spec-usable: ok" "$OUT" "AC7 a provider that cannot answer batch-members behaves as unbatched"

finish
