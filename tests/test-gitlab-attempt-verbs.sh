#!/usr/bin/env bash
# test-gitlab-attempt-verbs.sh -- read-attempt, record-attempt, check-attempt,
# check-approval-sha and post-approval on the gitlab provider (#736, part 2 of
# #687). Before this fix the gitlab adapter answered each of them "unknown
# verb" (post-approval refused the provider outright), so the code driver could
# not count attempts or stamp an approval on a gitlab project. Uses the
# tests/stubs/glab stub; no credentials needed. Tests are named by the spec's
# criterion id (AC1 ...), numbered as the PM spec numbers them (AC4 ...).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
git remote set-url origin git@gitlab.com:acme/widget.git
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "gitlab", "repo": "acme/widget"},
 "markers": {"trusted_authors": ["bot"]},
 "limits": {"max_fix_attempts": 3, "max_total_dispatches": 10}}
EOF
git config user.email "test@talos.invalid"
git config user.name "talos-test"
git commit -q --allow-empty -m init   # a checkout HEAD that is not the MR's head
LOCAL_HEAD="$(git rev-parse HEAD)"
export STUB_CURRENT_USER="ci-user"

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# _attempt_notes <author> <count> <total> -- one issue note carrying the marker.
_attempt_notes() {
  printf '[{"id":1,"body":"Talos attempt record\\n<!-- talos:attempt stage=developer count=%s total=%s -->","system":false,"author":{"username":"%s"},"created_at":"2026-10-16T00:00:00Z"}]' \
    "$2" "$3" "$1"
}
# _mr [<label>...] -- the glab MR JSON at HEAD_SHA (labels are plain strings).
_mr() {
  local _l _out=""
  for _l in "$@"; do _out="$_out${_out:+,}\"$_l\""; done
  printf '{"iid":9,"state":"opened","sha":"%s","target_branch":"main","labels":[%s]}' "$HEAD_SHA" "$_out"
}
# _marker_notes <author> <sha> <role> -- one MR note carrying an approval marker.
_marker_notes() {
  printf '[{"id":1,"body":"approved\\n<!-- talos:approval sha=%s role=%s -->","system":false,"author":{"username":"%s"},"created_at":"2026-10-16T00:00:00Z"}]' \
    "$2" "$3" "$1"
}
# _last_line <notes file> -- the last line of the first note a state dir holds.
_last_line() {
  python3 -I -c 'import json,sys;print(json.loads(sys.stdin.readline())["body"].rstrip().splitlines()[-1])' < "$1"
}
_count() {  # <pattern> -- GLAB calls in the log starting with it
  grep -c "^GLAB $1" "$GH_LOG"
}

# ── AC4: record-attempt then read-attempt round trip ─────────────────────────
export STUB_GITLAB_STATE_DIR="$SANDBOX/state1"; mkdir -p "$STUB_GITLAB_STATE_DIR"
export STUB_GITLAB_POST_AUTHOR="bot"
: > "$GH_LOG"
out="$(bash "$VCS" record-attempt 5 developer 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC4 record-attempt exits 0 under the ceilings"
assert_eq "stage=developer count=1 total=1" "$out" "AC4 record-attempt prints the new counts"
assert_eq "1" "$(_count 'issue note 5 ')" "AC4 record-attempt posts one issue note"
assert_eq "<!-- talos:attempt stage=developer count=1 total=1 -->" \
  "$(_last_line "$STUB_GITLAB_STATE_DIR/issue_notes_5")" "AC4 the marker is the last line of the posted note"
out="$(bash "$VCS" read-attempt 5 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC4 read-attempt exits 0"
assert_eq "stage=developer count=1 total=1" "$out" "AC4 read-attempt reads back the recorded marker"
out="$(bash "$VCS" record-attempt 5 developer 2>/dev/null)"
assert_eq "stage=developer count=2 total=2" "$out" "AC4 a second record-attempt increments from the newest marker"

: > "$GH_LOG"
out="$(bash "$VCS" record-attempt 5 'bad stage!' 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC4 a stage with a character outside letters, digits, . _ - is refused"
assert_contains "$out" "stage may only use letters, digits" "AC4 names the stage rule"
assert_eq "0" "$(_count 'issue note')" "AC4 the refused stage posts nothing"
bash "$VCS" record-attempt abc developer >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC4 a non-numeric issue number is refused"

export STUB_GITLAB_STATE_DIR="$SANDBOX/state2"; mkdir -p "$STUB_GITLAB_STATE_DIR"
export STUB_GITLAB_MR_VIEW="$(_mr)"
: > "$GH_LOG"
out="$(bash "$VCS" record-attempt 5 developer --pr 9 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC4 record-attempt --pr exits 0"
assert_eq "stage=developer count=1 total=1" "$out" "AC4 record-attempt --pr prints the new counts"
out="$(bash "$VCS" record-attempt 5 developer --pr 9 2>&1)"
assert_contains "$out" "duplicate --idempotency-key 'developer-$HEAD_SHA'" "AC4 --pr replays on the same head sha"
assert_eq "1" "$(_count 'issue note 5 ')" "AC4 the replay posts nothing"
assert_contains "$(bash "$VCS" read-attempt 5 2>/dev/null)" "key=developer-$HEAD_SHA" "AC4 the key is stored in the marker"
out="$(bash "$VCS" record-attempt 5 developer --pr 9 --idempotency-key abc 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC4 --pr with --idempotency-key is refused"
assert_contains "$out" "mutually exclusive" "AC4 names the conflict"
bash "$VCS" record-attempt 5 qa --idempotency-key abc.1 >/dev/null 2>&1
out="$(bash "$VCS" record-attempt 5 qa --idempotency-key abc.1 2>&1)"
assert_contains "$out" "duplicate --idempotency-key 'abc.1'" "AC4 --idempotency-key replays"
unset STUB_GITLAB_MR_VIEW STUB_GITLAB_POST_AUTHOR STUB_GITLAB_STATE_DIR

# ── AC5: read-attempt ─────────────────────────────────────────────────────────
out="$(bash "$VCS" read-attempt 5 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC5 read-attempt exits 0 with no marker"
assert_eq "stage= count=0 total=0" "$out" "AC5 read-attempt prints zero counts with no marker"
out="$(STUB_GITLAB_ISSUE_NOTES="$(_attempt_notes mallory 2 2)" bash "$VCS" read-attempt 5 2>/dev/null)"
assert_eq "stage= count=0 total=0" "$out" "AC5 read-attempt ignores a marker from an untrusted author"
out="$(STUB_GITLAB_ISSUE_NOTES="$(_attempt_notes bot 2 2)" bash "$VCS" read-attempt 5 2>/dev/null)"
assert_eq "stage=developer count=2 total=2" "$out" "AC5 read-attempt trusts an author in markers.trusted_authors"
out="$(STUB_GITLAB_ISSUE_NOTES="$(_attempt_notes ci-user 2 2)" bash "$VCS" read-attempt 5 2>/dev/null)"
assert_eq "stage=developer count=2 total=2" "$out" "AC5 read-attempt trusts the glab api user login (markers.verify_authors)"
out="$(STUB_GITLAB_API_FAIL=1 bash "$VCS" read-attempt 5 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC5 read-attempt exits 1 when the notes cannot be fetched"
assert_eq "" "$out" "AC5 read-attempt prints no counts when the notes cannot be fetched"
bash "$VCS" read-attempt >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC5 read-attempt exits 1 without an issue number"

# ── AC6: check-attempt ────────────────────────────────────────────────────────
export STUB_GITLAB_STATE_DIR="$SANDBOX/state3"; mkdir -p "$STUB_GITLAB_STATE_DIR"
out="$(STUB_GITLAB_ISSUE_NOTES="$(_attempt_notes bot 3 4)" bash "$VCS" check-attempt 5 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC6 check-attempt exits 1 at max_fix_attempts"
assert_contains "$out" "check-attempt: BLOCKED — developer consecutive attempts (3) >= max_fix_attempts (3)" "AC6 names the per-stage ceiling"
out="$(STUB_GITLAB_ISSUE_NOTES="$(_attempt_notes bot 1 10)" bash "$VCS" check-attempt 5 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC6 check-attempt exits 1 at max_total_dispatches"
assert_contains "$out" "check-attempt: BLOCKED — total dispatches (10) >= max_total_dispatches (10)" "AC6 names the total ceiling"
out="$(STUB_GITLAB_ISSUE_NOTES="$(_attempt_notes bot 1 2)" bash "$VCS" check-attempt 5 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC6 check-attempt exits 0 below the ceilings"
assert_contains "$out" "check-attempt: ok (stage=developer count=1 total=2" "AC6 reports ok with the counts"
assert_file_absent "$STUB_GITLAB_STATE_DIR/issue_notes_5" "AC6 check-attempt records nothing"
unset STUB_GITLAB_STATE_DIR

# ── AC7: check-approval-sha ───────────────────────────────────────────────────
out="$(STUB_GITLAB_MR_VIEW="$(_mr qa:pass)" STUB_GITLAB_MR_NOTES="$(_marker_notes bot "$HEAD_SHA" qa)" \
  bash "$VCS" check-approval-sha 9 --stale-list 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC7 a trusted marker at the head sha is current (exit 0)"
assert_contains "$out" "check-approval-sha: all approval labels are current" "AC7 reports all approval labels current"

out="$(STUB_GITLAB_MR_VIEW="$(_mr qa:pass)" STUB_GITLAB_MR_NOTES="$(_marker_notes bot "$OLD_SHA" qa)" \
  bash "$VCS" check-approval-sha 9 --stale-list 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC7 a marker at an older sha is stale (exit 1)"
assert_contains "$out" "stale role=qa label=qa:pass" "AC7 names the stale role and label"

out="$(STUB_GITLAB_MR_VIEW="$(_mr qa:pass)" STUB_GITLAB_MR_NOTES='[]' bash "$VCS" check-approval-sha 9 --stale-list 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC7 a label with no marker is stale (exit 1)"

out="$(STUB_GITLAB_MR_VIEW="$(_mr qa:pass)" STUB_GITLAB_MR_NOTES="$(_marker_notes mallory "$HEAD_SHA" qa)" \
  bash "$VCS" check-approval-sha 9 --stale-list 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC7 a marker from an untrusted author does not count (exit 1)"

cur="$(STUB_GITLAB_MR_VIEW="$(_mr qa:pass)" STUB_GITLAB_MR_NOTES="$(_marker_notes bot "$HEAD_SHA" qa)" \
  bash "$VCS" check-approval-sha 9 --evidence-list 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC7 --evidence-list exits 0"
lost="$(STUB_GITLAB_MR_VIEW="$(_mr)" STUB_GITLAB_MR_NOTES="$(_marker_notes bot "$HEAD_SHA" qa)" \
  bash "$VCS" check-approval-sha 9 --evidence-list 2>&1)"
miss="$(STUB_GITLAB_MR_VIEW="$(_mr)" STUB_GITLAB_MR_NOTES="$(_marker_notes bot "$OLD_SHA" qa)" \
  bash "$VCS" check-approval-sha 9 --evidence-list 2>&1)"
assert_contains "$cur" "evidence role=qa label=qa:pass state=present" "AC7 evidence is present for a labelled MR"
assert_contains "$lost" "evidence role=qa label=qa:pass state=lost" "AC7 evidence is lost for a marker at the head with no label"
assert_contains "$miss" "evidence role=qa label=qa:pass state=missing" "AC7 evidence is missing for a marker at an older sha"

out="$(STUB_GITLAB_MR_VIEW="$(_mr)" bash "$VCS" check-approval-sha 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC7 no approval label on the MR exits 0"
assert_contains "$out" "no approval labels" "AC7 prints the no-approval-labels message"
out="$(STUB_GITLAB_MR_VIEW_FAIL=1 bash "$VCS" check-approval-sha 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC7 an unreadable MR exits 1"
assert_contains "$out" "could not fetch PR #9 data" "AC7 names the failed fetch"
out="$(STUB_GITLAB_MR_VIEW="$(_mr qa:pass)" STUB_GITLAB_MR_NOTES_FAIL=1 bash "$VCS" check-approval-sha 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC7 an unreadable notes list exits 1"
assert_contains "$out" "could not fetch PR #9 data" "AC7 names the failed notes fetch"
bash "$VCS" check-approval-sha abc >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC7 a non-numeric MR id exits 1"

# ── AC8: post-approval ────────────────────────────────────────────────────────
export STUB_GITLAB_POST_AUTHOR="bot"
export STUB_GITLAB_MR_VIEW="$(_mr)"
export STUB_GITLAB_STATE_DIR="$SANDBOX/state4"; mkdir -p "$STUB_GITLAB_STATE_DIR"
: > "$GH_LOG"
out="$(bash "$VCS" post-approval 9 qa 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC8 post-approval exits 0"
assert_contains "$out" "stamp ok" "AC8 prints stamp ok"
assert_eq "1" "$(_count 'mr note 9 ')" "AC8 posts one MR note"
assert_eq "<!-- talos:approval sha=$HEAD_SHA role=qa -->" \
  "$(_last_line "$STUB_GITLAB_STATE_DIR/mr_notes_9")" "AC8 the note's last line is the marker at the MR's head sha"
assert_eq "1" "$(_count 'mr update 9 --label qa:pass')" "AC8 adds the qa:pass label with glab mr update --label"
assert_eq "qa:pass" "$(cat "$STUB_GITLAB_STATE_DIR/labels_9")" "AC8 the label lands on the MR"
assert_not_contains "$(_last_line "$STUB_GITLAB_STATE_DIR/mr_notes_9")" "$LOCAL_HEAD" "AC8 the marker's sha is the MR head from pr-head, not the local checkout's"

# ── AC9: second post-approval, --recover-only ────────────────────────────────
: > "$GH_LOG"
out="$(bash "$VCS" post-approval 9 qa 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC9 a second post-approval at the same head exits 0"
assert_eq "0" "$(_count 'mr note 9 ')" "AC9 posts no second note"
assert_eq "1" "$(wc -l < "$STUB_GITLAB_STATE_DIR/mr_notes_9" | tr -d ' ')" "AC9 the MR still holds one note"
assert_eq "1" "$(_count 'mr update 9 --label qa:pass')" "AC9 still ensures the label"
assert_contains "$out" "stamp ok" "AC9 still prints stamp ok"

export STUB_GITLAB_STATE_DIR="$SANDBOX/state5"; mkdir -p "$STUB_GITLAB_STATE_DIR"
: > "$GH_LOG"
bash "$VCS" post-approval 9 qa --recover-only >/dev/null 2>&1; rc=$?
assert_eq "3" "$rc" "AC9 --recover-only with no marker at the head exits 3"
assert_file_absent "$STUB_GITLAB_STATE_DIR/mr_notes_9" "AC9 --recover-only posts nothing"
assert_eq "0" "$(_count 'mr update')" "AC9 --recover-only applies no label"

# ── AC10: shared refusals ─────────────────────────────────────────────────────
export STUB_GITLAB_STATE_DIR="$SANDBOX/state6"; mkdir -p "$STUB_GITLAB_STATE_DIR"
: > "$GH_LOG"
out="$(bash "$VCS" post-approval 9 reviewer 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC10 reviewer without a body file is refused"
assert_contains "$out" "requires --body-file" "AC10 names the missing body file"
bash "$VCS" post-approval 9 security >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC10 security without a body file is refused"
: > empty.md
out="$(bash "$VCS" post-approval 9 reviewer --body-file empty.md 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC10 reviewer with an empty body file is refused"
assert_contains "$out" "is empty" "AC10 names the empty body file"
bash "$VCS" post-approval 9 wizard >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC10 an unknown role is refused"
bash "$VCS" post-approval abc qa >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "AC10 a non-numeric MR id is refused"
assert_eq "0" "$(_count 'mr note')" "AC10 the refusals post no note"
assert_eq "0" "$(_count 'mr update')" "AC10 the refusals apply no label"

printf 'All checks pass.\nSecond line.\n' > body.md
out="$(bash "$VCS" post-approval 9 docs --body-file body.md 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC8 post-approval with --body-file exits 0"
assert_eq "All checks pass.|Second line.||<!-- talos:approval sha=$HEAD_SHA role=docs -->" \
  "$(python3 -I -c 'import json,sys;print("|".join(json.loads(sys.stdin.readline())["body"].rstrip("\n").split("\n")))' < "$STUB_GITLAB_STATE_DIR/mr_notes_9")" \
  "AC8 the body stays above the marker line"
unset STUB_GITLAB_MR_VIEW STUB_GITLAB_POST_AUTHOR STUB_GITLAB_STATE_DIR

# ── AC11: --dry-run ───────────────────────────────────────────────────────────
export STUB_GITLAB_STATE_DIR="$SANDBOX/state7"; mkdir -p "$STUB_GITLAB_STATE_DIR"
for v in "read-attempt 5" "check-attempt 5" "record-attempt 5 developer" "check-approval-sha 9" "post-approval 9 qa"; do
  : > "$GH_LOG"
  out="$(bash "$VCS" --dry-run $v 2>&1)"; rc=$?
  assert_eq "0" "$rc" "AC11 --dry-run $v exits 0"
  assert_contains "$out" "[dry-run]" "AC11 --dry-run $v prints a [dry-run] line"
  assert_eq "0" "$(( $(_count 'issue note') + $(_count 'mr note') + $(_count 'mr update') ))" "AC11 --dry-run $v calls no write"
done
assert_eq "" "$(ls "$STUB_GITLAB_STATE_DIR")" "AC11 --dry-run writes nothing"

finish
