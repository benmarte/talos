#!/usr/bin/env bash
# test-post-approval-stdin.sh — post-approval reads a non-regular --body-file once (#699).
#  AC1 /dev/stdin posts the text     AC2 `-` posts the text
#  AC3 `-` empty / whitespace refused  AC4 /dev/stdin empty refused
#  AC5 a stdin body is never stale     AC7 reviewer/security profiles give the stdin form
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

# run_pa <role> [post-approval args...]: stdin of this function is the body;
# rc in $RC, stderr in $ERR, gh calls in $GH_LOG.
run_pa() {
  local role="$1" lbl="review:approved"; shift
  [ "$role" = "security" ] && lbl="security:approved"
  printf '[]' > "$CSTORE"; export STUB_COMMENT_STORE="$CSTORE"
  : > "$GH_LOG"
  ERR="$(STUB_PR_HEAD_SHA="$STUB_SHA" STUB_PR_LABELS_JSON='[{"name":"'"$lbl"'"}]' \
    bash "$VCS" post-approval 9 "$role" --issue 5 "$@" 2>&1 >/dev/null)"; RC=$?
}
refused() {  # $1="ACn what": exit 1, one "empty" line, nothing posted, no label
  assert_exit_code 1 "$RC" "$1: exits 1"
  assert_eq "1" "$(printf '%s\n' "$ERR" | grep -c .)" "$1: one stderr line"
  assert_contains "$ERR" "empty" "$1: the reason says the body is empty"
  assert_not_contains "$(cat "$GH_LOG")" "talos:approval" "$1: no comment posted"
  assert_not_contains "$(cat "$GH_LOG")" "approved" "$1: no label applied"
}

STATE="$(. "$TALOS_ROOT/scripts/pipeline-paths.sh" && _talos_state_dir)"
mkdir -p "$STATE/stage-start"

# AC1
run_pa reviewer --body-file /dev/stdin <<'TALOS_Hn4Rt8YcM2sB'
stdin review text one
TALOS_Hn4Rt8YcM2sB
assert_exit_code 0 "$RC" "AC1 reviewer /dev/stdin exits 0"
assert_contains "$(cat "$GH_LOG")" "stdin review text one" "AC1 the heredoc text is posted"
assert_contains "$(cat "$GH_LOG")" "role=reviewer -->" "AC1 the reviewer marker is posted"

# AC2
run_pa security --body-file - <<'TALOS_Vb5Jf1LqW6eN'
stdin sign-off text two
TALOS_Vb5Jf1LqW6eN
assert_exit_code 0 "$RC" "AC2 security '-' exits 0"
assert_contains "$(cat "$GH_LOG")" "stdin sign-off text two" "AC2 the heredoc text is posted"
assert_contains "$(cat "$GH_LOG")" "role=security -->" "AC2 the security marker is posted"

# AC3
for r in reviewer security; do
  run_pa "$r" --body-file - < /dev/null
  refused "AC3 $r empty stdin"
  run_pa "$r" --body-file - <<< $' \n\t'
  refused "AC3 $r whitespace stdin"
done

# AC4
run_pa reviewer --body-file /dev/stdin < /dev/null
refused "AC4 reviewer /dev/stdin empty"
run_pa security --body-file /dev/stdin < /dev/null
refused "AC4 security /dev/stdin empty"

# AC5: a stage start newer than any file time is recorded; a stdin body still posts.
for r in reviewer security; do
  printf '%s\n' "$(( $(date +%s) + 100000 ))" > "$STATE/stage-start/$r-pr9"
  run_pa "$r" --body-file /dev/stdin <<'TALOS_Zc9Kd3PxA7mU'
fresh stdin body
TALOS_Zc9Kd3PxA7mU
  assert_exit_code 0 "$RC" "AC5 $r stdin body is not stale"
  assert_contains "$(cat "$GH_LOG")" "fresh stdin body" "AC5 $r stdin body posted"
  rm -f "$STATE/stage-start/$r-pr9"
done

# AC7
for r in reviewer security; do
  prof="$(cat "$TALOS_ROOT/agents/$r.md")"
  assert_contains "$prof" "post-approval <PR> $r --body-file - --issue <issue-n>" "AC7 $r profile gives the stdin form"
  assert_contains "$prof" "<<'TALOS_<rand>'" "AC7 $r profile feeds it a heredoc"
  assert_not_contains "$prof" "to a path unique" "AC7 $r profile no longer says to write a file"
  assert_not_contains "$prof" "--body-file <review-file>" "AC7 $r approval line no review-file"
  assert_not_contains "$prof" "--body-file <signoff-file>" "AC7 $r approval line no signoff-file"
done

finish
