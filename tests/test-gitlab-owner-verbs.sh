#!/usr/bin/env bash
# test-gitlab-owner-verbs.sh -- upsert-pr-comment, mark-needs-owner and
# list-needs-owner on the gitlab provider (#763, slice 3 of #753). Before this
# change the pre-dispatch gate answered exit 2 `not implemented for provider
# 'gitlab'` for the three verbs, so the spend comment and the owner question
# never reached a merge request. The verbs act on merge requests only, as on
# azure. Uses the tests/stubs/glab stub; no credentials needed. Tests are named
# by the spec's criterion id (AC1 ...).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
git remote set-url origin git@gitlab.com:acme/widget.git
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"},
 "markers": {"trusted_authors": ["bot", "owner"]}}
EOF
git config user.email "test@talos.invalid"
git config user.name "talos-test"

export STUB_CURRENT_USER="bot"
export STUB_GITLAB_POST_AUTHOR="bot"
PROJ="projects/acme%2Fwidget"
NOTES_URL="$PROJ/merge_requests/9/notes"
LABEL="pipeline:needs-owner"

# _note <id> <author> <body> <created> -- one raw MR note.
_note() {
  python3 -I -c '
import json, sys
i, who, body, when = sys.argv[1:5]
print(json.dumps({"id": int(i), "body": body, "system": False, "author": {"username": who}, "created_at": when}))' "$@"
}
# _fresh -- a new stub state dir (notes and labels the stub writes back).
_fresh() {
  STUB_GITLAB_STATE_DIR="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-gl-owner.XXXXXX")" || exit 1
  export STUB_GITLAB_STATE_DIR
  : > "$GH_LOG"
}
# _seed <mr> <note-json>... -- notes the stub serves for MR <mr>.
_seed() {
  local _mr="$1"; shift
  printf '%s\n' "$@" >> "$STUB_GITLAB_STATE_DIR/mr_notes_$_mr"
}
# _count <regex> -- the number of logged glab calls matching it.
_count() { local _n; _n="$(grep -c -- "$1" "$GH_LOG" || true)"; printf '%s' "${_n:-0}"; }
_posts() { _count "^GLAB api --method POST $NOTES_URL"; }
_puts() { _count "^GLAB api --method PUT $NOTES_URL/"; }
_writes() { _count '^GLAB api --method \(POST\|PUT\)'; }
# _bodies -- the "body" of each logged write, one per line, newlines as \n.
_bodies() {
  grep '^GLAB BODY: ' "$GH_LOG" | sed 's/^GLAB BODY: //' | python3 -I -c '
import json, sys
for l in sys.stdin:
    print(json.loads(l)["body"].replace("\n", "\\n"))'
}

FIX="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-gl-owner-fix.XXXXXX")" || exit 1
printf 'Spend line' > "$FIX/f"
MARK='<!-- talos:spend -->'
BODY_NEW='Spend line\n\n<!-- talos:spend -->'

# ── AC1: upsert creates ──────────────────────────────────────────────────────
_fresh
out="$(bash "$VCS" upsert-pr-comment 9 --marker spend --body-file "$FIX/f" 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC1 upsert-pr-comment exits 0 with no marker note"
assert_eq "1" "$(_posts)" "AC1 one note is POSTed to the MR's notes endpoint"
assert_eq "0" "$(_puts)" "AC1 no PUT"
assert_eq "$BODY_NEW" "$(_bodies)" "AC1 the note is the file text, a blank line, then the marker"
assert_eq "upserted pr=9 comment=created" "$(printf '%s\n' "$out" | tail -1)" "AC1 stdout ends with upserted pr=9 comment=created"

# ── AC2: upsert updates the newest own marker note ───────────────────────────
_fresh
_seed 9 "$(_note 10 bot $'Older\n\n'"$MARK" 2026-10-16T00:00:01Z)" \
        "$(_note 11 bot $'Old\n\n'"$MARK" 2026-10-16T00:00:02Z)" \
        "$(_note 12 owner $'Theirs\n\n'"$MARK" 2026-10-16T00:00:03Z)"
out="$(bash "$VCS" upsert-pr-comment 9 --marker spend --body-file "$FIX/f" 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC2 upsert-pr-comment exits 0 on an update"
assert_eq "0" "$(_posts)" "AC2 no POST"
assert_eq "1" "$(_puts)" "AC2 one PUT"
assert_eq "1" "$(_count "^GLAB api --method PUT $NOTES_URL/11 ")" "AC2 the newest matching own note (11) is the one rewritten"
assert_eq "$BODY_NEW" "$(_bodies)" "AC2 the PUT body is the new text with the marker last"
assert_eq "upserted pr=9 comment=updated" "$(printf '%s\n' "$out" | tail -1)" "AC2 stdout ends with upserted pr=9 comment=updated"

# ── AC3: identical own note makes no write; another user's is never edited ────
_fresh
_seed 9 "$(_note 11 bot $'Spend line\n\n'"$MARK" 2026-10-16T00:00:02Z)"
out="$(bash "$VCS" upsert-pr-comment 9 --marker spend --body-file "$FIX/f" 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC3 an identical own marker note exits 0"
assert_eq "0" "$(_writes)" "AC3 an identical own marker note makes no write"
assert_eq "upserted pr=9 comment=unchanged" "$(printf '%s\n' "$out" | tail -1)" "AC3 stdout ends with upserted pr=9 comment=unchanged"
_fresh
_seed 9 "$(_note 11 owner $'Old\n\n'"$MARK" 2026-10-16T00:00:02Z)"
out="$(bash "$VCS" upsert-pr-comment 9 --marker spend --body-file "$FIX/f" 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC3 a marker note by another user exits 0"
assert_eq "0" "$(_puts)" "AC3 a marker note by another user is never edited"
assert_eq "1" "$(_posts)" "AC3 a new note is POSTed instead"
assert_eq "upserted pr=9 comment=created" "$(printf '%s\n' "$out" | tail -1)" "AC3 stdout ends with comment=created"

# ── AC4: upsert is fail-closed ───────────────────────────────────────────────
_fresh
out="$(STUB_GITLAB_USER_FAIL=1 bash "$VCS" upsert-pr-comment 9 --marker spend --body-file "$FIX/f" 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC4 a failed identity lookup exits 1"
assert_contains "$out" "pipeline-vcs: upsert-pr-comment:" "AC4 the failure carries the upsert-pr-comment message"
assert_eq "0" "$(_writes)" "AC4 a failed identity lookup writes nothing"
out="$(STUB_CURRENT_USER="" bash "$VCS" upsert-pr-comment 9 --marker spend --body-file "$FIX/f" 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC4 an identity with no username exits 1"
assert_contains "$out" "pipeline-vcs: upsert-pr-comment:" "AC4 an empty username carries the upsert-pr-comment message"
assert_eq "0" "$(_writes)" "AC4 an empty username writes nothing"
out="$(STUB_GITLAB_MR_NOTES_FAIL=1 bash "$VCS" upsert-pr-comment 9 --marker spend --body-file "$FIX/f" 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC4 an unreadable notes list exits 1"
assert_contains "$out" "pipeline-vcs: upsert-pr-comment:" "AC4 an unreadable list carries the upsert-pr-comment message"
assert_eq "0" "$(_writes)" "AC4 an unreadable notes list writes nothing"
out="$(STUB_GITLAB_NOTE_WRITE_FAIL=1 bash "$VCS" upsert-pr-comment 9 --marker spend --body-file "$FIX/f" 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC4 a failed write exits 1"
assert_contains "$out" "pipeline-vcs: upsert-pr-comment:" "AC4 a failed write carries the upsert-pr-comment message"

# ── AC5: mark-needs-owner posts and labels ───────────────────────────────────
_fresh
out="$(bash "$VCS" mark-needs-owner 9 "Which option?" 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC5 mark-needs-owner exits 0"
assert_eq "1" "$(_count '^GLAB mr note 9 ')" "AC5 one MR note is posted via glab mr note"
assert_eq "1" "$(_count "^GLAB mr update 9 --label $LABEL")" "AC5 the label is added via glab mr update --label"
assert_eq "$(printf 'Which option?\n\n<!-- talos:needs-owner -->')" "$(python3 -I -c 'import json,sys; sys.stdout.write(json.loads(open(sys.argv[1]).readline())["body"])' "$STUB_GITLAB_STATE_DIR/mr_notes_9")" \
  "AC5 the note is the text, a blank line, then the marker last"
assert_eq "marked n=9 comment=posted" "$(printf '%s\n' "$out" | tail -1)" "AC5 stdout is marked n=9 comment=posted"

# ── AC6: mark-needs-owner is idempotent while unanswered, fail-closed ────────
_fresh
_seed 9 "$(_note 20 bot $'Which option?\n\n<!-- talos:needs-owner -->' 2026-10-16T00:00:01Z)"
out="$(bash "$VCS" mark-needs-owner 9 "Which option?" 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC6 an unanswered same-body marker note exits 0"
assert_eq "0" "$(_count '^GLAB mr note ')" "AC6 no second note is posted"
assert_eq "1" "$(_count "^GLAB mr update 9 --label $LABEL")" "AC6 the label is still added"
assert_eq "marked n=9 comment=existing" "$(printf '%s\n' "$out" | tail -1)" "AC6 stdout is marked n=9 comment=existing"
_fresh
out="$(STUB_GITLAB_MR_NOTES_FAIL=1 bash "$VCS" mark-needs-owner 9 "Which option?" 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC6 a failed notes read exits 1"
assert_eq "0" "$(_count '^GLAB mr update ')" "AC6 a failed notes read adds no label"
_fresh
out="$(STUB_GITLAB_NOTE_POST_FAIL=1 bash "$VCS" mark-needs-owner 9 "Which option?" 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC6 a failed post exits 1"
assert_eq "0" "$(_count '^GLAB mr update ')" "AC6 a failed post adds no label"

# ── AC7: list-needs-owner ────────────────────────────────────────────────────
_mr() {  # <iid> <label>... -- one raw MR
  python3 -I -c '
import json, sys
print(json.dumps({"iid": int(sys.argv[1]), "state": "opened", "title": "t", "labels": sys.argv[2:]}))' "$@"
}
_fresh
_seed 12 "$(_note 30 bot $'Q twelve?\n\n<!-- talos:needs-owner -->' 2026-10-16T00:00:01Z)" \
         "$(_note 31 owner 'Go with A' 2026-10-16T00:00:02Z)"
_seed 5 "$(_note 40 bot $'Q five?\n\n<!-- talos:needs-owner -->' 2026-10-16T00:00:01Z)"
PAGES="[$(_mr 12 "$LABEL" bug),$(_mr 8 bug),$(_mr 5 "$LABEL")]"
out="$(STUB_GITLAB_MR_PAGES="$PAGES" bash "$VCS" list-needs-owner 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC7 list-needs-owner exits 0"
assert_eq "needs-owner n=5 kind=pr answered=no question=Q five?
needs-owner n=12 kind=pr answered=yes question=Q twelve?" "$out" \
  "AC7 one line per labelled MR sorted by iid; the unlabelled MR is omitted"
out="$(STUB_GITLAB_MR_PAGES="$PAGES" bash "$VCS" list-needs-owner --json 2>&1)"; rc=$?
assert_eq '[{"n": 5, "kind": "pr", "answered": "no", "question": "Q five?"}, {"n": 12, "kind": "pr", "answered": "yes", "question": "Q twelve?"}]' \
  "$(printf '%s' "$out" | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))')" \
  "AC7 --json prints the array of n, kind, answered, question"

# ── AC8: --clear-answered ────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(STUB_GITLAB_MR_PAGES="$PAGES" bash "$VCS" list-needs-owner --clear-answered 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC8 --clear-answered exits 0"
assert_eq "1" "$(_count '^GLAB mr update ')" "AC8 exactly one MR is touched"
assert_eq "1" "$(_count "^GLAB mr update 12 --unlabel $LABEL")" "AC8 the label is removed from the answered MR via glab mr update --unlabel"
assert_contains "$out" "cleared n=12" "AC8 cleared n=12 is printed"
assert_not_contains "$out" "cleared n=5" "AC8 the unanswered MR is not cleared"
: > "$GH_LOG"
out="$(STUB_GITLAB_MR_LIST_FAIL=1 STUB_GITLAB_MR_PAGES="$PAGES" bash "$VCS" list-needs-owner --clear-answered 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC8 a failed MR-list fetch exits 1"
assert_eq "" "$out" "AC8 a failed MR-list fetch prints nothing"
assert_eq "0" "$(_count '^GLAB mr update ')" "AC8 a failed MR-list fetch clears nothing"

# ── AC9: --dry-run ───────────────────────────────────────────────────────────
for v in "upsert-pr-comment 9 --marker spend --body-file $FIX/f" "mark-needs-owner 9 text" "list-needs-owner --clear-answered"; do
  : > "$GH_LOG"
  out="$(bash "$VCS" --dry-run $v 2>&1)"; rc=$?
  assert_eq "0" "$rc" "AC9 --dry-run ${v%% *} exits 0"
  assert_contains "$out" "[dry-run]" "AC9 --dry-run ${v%% *} prints a [dry-run] plan"
  case "$v" in
    list-needs-owner*) assert_contains "$out" "merge_requests" "AC9 the list plan names the merge_requests list" ;;
    *) assert_contains "$out" "merge_requests/9/notes" "AC9 the ${v%% *} plan names the MR notes endpoint" ;;
  esac
  assert_eq "0" "$(_writes)" "AC9 --dry-run ${v%% *} makes no write call"
  assert_eq "0" "$(_count '^GLAB mr ')" "AC9 --dry-run ${v%% *} makes no glab mr call"
done

# ── AC10: the gate lets gitlab through; file still exits 2 ───────────────────
for v in "upsert-pr-comment 9 --marker spend --body-file $FIX/f" "mark-needs-owner 9 text" "list-needs-owner"; do
  out="$(bash "$VCS" --dry-run $v 2>&1)"; rc=$?
  assert_not_contains "$out" "not implemented for provider" "AC10 gitlab ${v%% *} passes the pre-dispatch gate"
done
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "file"}}
EOF
for v in "upsert-pr-comment 9 --marker spend --body-file $FIX/f" "mark-needs-owner 9 text" "list-needs-owner"; do
  out="$(bash "$VCS" $v 2>&1)"; rc=$?
  assert_eq "2" "$rc" "AC10 file ${v%% *} still exits 2"
  assert_contains "$out" "not implemented for provider 'file'" "AC10 file ${v%% *} still says not implemented"
done

# ── AC11: the parity table has no gitlab exception for the three verbs ───────
PARITY="$TALOS_ROOT/tests/test-vcs-provider-parity.sh"
for v in upsert-pr-comment mark-needs-owner list-needs-owner; do
  assert_eq "0" "$(grep -c "^gitlab $v PARITY-EXCEPTION" "$PARITY" || true)" "AC11 the parity table has no gitlab $v line"
done
assert_contains "$(cat "$PARITY")" "AC5 the table no longer records" "AC11 the parity AC5 loop asserts the lines are gone"
parity_out="$(bash "$PARITY" 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC11 the parity test passes"
[ "$rc" -eq 0 ] || printf '%s\n' "$parity_out" >&2

# ── AC12: azure behaviour unchanged ──────────────────────────────────────────
azure_out="$(env -u STUB_GITLAB_STATE_DIR -u STUB_GITLAB_POST_AUTHOR -u STUB_CURRENT_USER bash "$TALOS_ROOT/tests/test-azure-pr-comment-verbs.sh" 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC12 the azure suite stays green"
[ "$rc" -eq 0 ] || printf '%s\n' "$azure_out" >&2

finish
