#!/usr/bin/env bash
# test-post-approval-body.sh — post-approval needs a fresh review body (#661).
#  AC1 reviewer without --body-file is refused    AC2 same for security
#  AC3 empty / whitespace-only body refused       AC4 stale body refused, fresh accepted
#  AC5 consumed body file removed after posting   AC6 qa/docs/--recover-only unchanged
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
git config user.email "test@talos.invalid"
git config user.name "talos-test"
STUB_SHA="aabb1122ccdd3344eeff556677889900aabb1122"
export STUB_CURRENT_USER=bot
CSTORE="$SANDBOX/cs.json"
GH_LOG="${GH_LOG:-$SANDBOX/gh.log}"

# run_pa <role> [post-approval args...]: fresh comment store, one run; rc in
# $RC, stderr in $ERR, gh calls in $GH_LOG.
run_pa() {
  local role="$1" lbl="review:approved"; shift
  [ "$role" = "security" ] && lbl="security:approved"
  [ "$role" = "qa" ] && lbl="qa:pass"
  printf '[]' > "$CSTORE"; export STUB_COMMENT_STORE="$CSTORE"
  : > "$GH_LOG"
  ERR="$(STUB_PR_HEAD_SHA="$STUB_SHA" STUB_PR_LABELS_JSON='[{"name":"'"$lbl"'"}]' \
    bash "$VCS" post-approval 9 "$role" --issue 5 "$@" 2>&1 >/dev/null)"; RC=$?
}
refused() {  # $1=id $2=what: non-zero, one line, nothing posted, no label
  assert_exit_code 1 "$RC" "$1 $2: exits non-zero"
  assert_eq "1" "$(printf '%s\n' "$ERR" | grep -c .)" "$1 $2: one stderr line"
  assert_not_contains "$(cat "$GH_LOG")" "talos:approval" "$1 $2: no comment posted"
  assert_not_contains "$(cat "$GH_LOG")" "approved" "$1 $2: no label applied"
}

STATE="$(. "$TALOS_ROOT/scripts/pipeline-paths.sh" && _talos_state_dir)"
mkdir -p "$STATE/stage-start"

# AC1 / AC2
run_pa reviewer
refused AC1 "reviewer without --body-file"
assert_contains "$ERR" "--body-file" "AC1 the line says a review body is required"
run_pa security
refused AC2 "security without --body-file"
assert_contains "$ERR" "--body-file" "AC2 the line says a review body is required"

# AC3
for r in reviewer security; do
  : > "$SANDBOX/empty.md"
  run_pa "$r" --body-file "$SANDBOX/empty.md"
  refused AC3 "$r empty body"
  printf ' \n\t\n' > "$SANDBOX/ws.md"
  run_pa "$r" --body-file "$SANDBOX/ws.md"
  refused AC3 "$r whitespace body"
  assert_contains "$ERR" "empty" "AC3 the reason says the body is empty"
done

# AC4: stage start recorded now; the body is older, then refreshed.
for r in reviewer security; do
  printf '%s\n' "$(date +%s)" > "$STATE/stage-start/$r-pr9"
  printf 'old review\n' > "$SANDBOX/body.md"
  touch -t 202001010000 "$SANDBOX/body.md"
  run_pa "$r" --body-file "$SANDBOX/body.md"
  refused AC4 "$r stale body"
  assert_contains "$ERR" "stale" "AC4 $r reason names staleness"
  touch "$SANDBOX/body.md"
  run_pa "$r" --body-file "$SANDBOX/body.md"
  assert_exit_code 0 "$RC" "AC4 $r fresh body accepted"
  assert_contains "$(cat "$GH_LOG")" "role=$r -->" "AC4 $r marker posted"
  assert_contains "$(cat "$GH_LOG")" "old review" "AC4 $r review text posted"
  # AC5
  assert_file_absent "$SANDBOX/body.md" "AC5 $r consumed body file removed"
  rm -f "$STATE/stage-start/$r-pr9"
done

# AC4 manual use: no recorded start, a non-empty old body is accepted.
printf 'manual review\n' > "$SANDBOX/body.md"; touch -t 202001010000 "$SANDBOX/body.md"
run_pa reviewer --body-file "$SANDBOX/body.md"
assert_exit_code 0 "$RC" "AC4 no recorded start: only AC1/AC3 apply"

# AC8: only a reviewer or security body is consumed; docs and qa keep theirs.
for r in docs qa; do
  printf 'stamp body\n' > "$SANDBOX/body.md"
  run_pa "$r" --body-file "$SANDBOX/body.md"
  assert_exit_code 0 "$RC" "AC8 $r post succeeds"
  assert_file_exists "$SANDBOX/body.md" "AC8 $r body file left in place"
done

# AC6
run_pa qa
assert_exit_code 0 "$RC" "AC6 qa keeps its bare marker"
run_pa reviewer --recover-only
assert_not_contains "$ERR" "requires --body-file" "AC6 --recover-only untouched"

finish
