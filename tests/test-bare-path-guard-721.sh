#!/usr/bin/env bash
# test-bare-path-guard-721.sh — the bare-path body guard (#94) also refuses a
# RELATIVE path (#721): a positional or --body body that is one token naming a
# readable regular file is refused with the --body-file hint, nothing posted.
# A --body-file / stdin body is file content and is never treated as a path.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

mkdir -p .talos
echo "verdict: PASS" > .talos/x.body
echo "other sandbox file" > "$SANDBOX/other.txt"

# Run a verb for the current provider; sets OUT, ERR, RC and POSTED (1 when the
# provider's log shows a comment was sent).
run_verb() {  # $1=verb, rest = args after the verb
  local verb="$1"; shift
  : > "$GH_LOG"; : > "$CURL_LOG"
  printf '%s\n' \
    '{"state":"open","merged_at":null,"number":9}' \
    '{"id":701,"html_url":"https://github.com/acme/widget/pull/9#issuecomment-701"}' \
    > "$CURL_QUEUE"
  ERR="$(STUB_ISSUE_STATE=OPEN bash "$VCS" "$verb" "$@" 2>&1 >"$SANDBOX/out.txt")"; RC=$?
  OUT="$(cat "$SANDBOX/out.txt")"
  POSTED=0
  if grep -q 'payload=' "$GH_LOG" || grep -qi 'POST' "$CURL_LOG"; then POSTED=1; fi
  LOGS="$(cat "$GH_LOG" "$CURL_LOG")"
}

for provider in github github-api; do
  if [ "$provider" = "github-api" ]; then
    cat > talos.pipeline.json <<'JSON'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
JSON
    export GITHUB_TOKEN="test-token-721"
  else
    rm -f talos.pipeline.json
  fi

  for verb in comment-issue comment-pr; do
    t="$provider/$verb"

    # AC1 is comment-issue, AC2 is comment-pr: one literal id per assertion
    # label so qa-run and `placement` map each criterion to its own results.
    run_verb "$verb" 9 .talos/x.body
    case "$verb" in
      comment-issue)
        assert_eq "1" "$RC" "AC1 $t: relative positional path exits 1"
        assert_contains "$ERR" "--body-file" "AC1 $t: relative path error names --body-file"
        assert_contains "$ERR" ".talos/x.body" "AC1 $t: relative path error names the path"
        assert_eq "0" "$POSTED" "AC1 $t: relative path posts nothing"
        ;;
      comment-pr)
        assert_eq "1" "$RC" "AC2 $t: relative positional path exits 1"
        assert_contains "$ERR" "--body-file" "AC2 $t: relative path error names --body-file"
        assert_contains "$ERR" ".talos/x.body" "AC2 $t: relative path error names the path"
        assert_eq "0" "$POSTED" "AC2 $t: relative path posts nothing"
        ;;
    esac

    run_verb "$verb" 9 --body .talos/x.body
    assert_eq "1" "$RC" "AC3 $t: --body relative path exits 1"
    assert_contains "$ERR" "--body-file" "AC3 $t: --body relative path names --body-file"
    assert_eq "0" "$POSTED" "AC3 $t: --body relative path posts nothing"

    run_verb "$verb" 9 "$SANDBOX/other.txt"
    assert_eq "1" "$RC" "AC3 $t: absolute positional path still exits 1"
    assert_eq "0" "$POSTED" "AC3 $t: absolute path posts nothing"

    for body in .talos/nope.body . .talos LGTM; do
      run_verb "$verb" 9 "$body"
      assert_eq "0" "$RC" "AC4 $t: single token '$body' (not a file) exits 0"
      assert_eq "1" "$POSTED" "AC4 $t: single token '$body' is posted as text"
      assert_contains "$LOGS" "$body" "AC4 $t: '$body' reaches the provider as text"
    done
    # Contrast: the same shape of token that IS a readable file is refused, so
    # the posts above are the existence check at work, not a missing guard.
    run_verb "$verb" 9 .talos/x.body
    assert_eq "1" "$RC" "AC4 $t: a single token that is a readable file is refused, unlike a non-file token"

    printf '%s' "$SANDBOX/other.txt" > "$SANDBOX/path-body.txt"
    run_verb "$verb" 9 --body-file "$SANDBOX/path-body.txt"
    assert_eq "0" "$RC" "AC5 $t: --body-file holding a path exits 0"
    assert_eq "1" "$POSTED" "AC5 $t: --body-file holding a path is posted"
    assert_contains "$LOGS" "$SANDBOX/other.txt" "AC5 $t: --body-file path text reaches the provider"

    run_verb "$verb" 9 --body-file - <<< "$SANDBOX/other.txt"
    assert_eq "0" "$RC" "AC5 $t: stdin body holding a path exits 0"
    assert_eq "1" "$POSTED" "AC5 $t: stdin body holding a path is posted"

    run_verb "$verb" 9 ".talos/x.body is the file"
    assert_eq "0" "$RC" "AC6 $t: multi-word body starting with a path exits 0"
    assert_eq "1" "$POSTED" "AC6 $t: multi-word body is posted"

    run_verb "$verb" 9 $'.talos/x.body\nsecond line'
    assert_eq "0" "$RC" "AC6 $t: multi-line body whose first line is a path exits 0"
    assert_eq "1" "$POSTED" "AC6 $t: multi-line body is posted"

    # Contrast: the path alone, with no whitespace or second line, is refused,
    # so the two posts above are the single-token rule at work.
    run_verb "$verb" 9 .talos/x.body
    assert_eq "1" "$RC" "AC6 $t: the same path as the whole body is refused, unlike a multi-word or multi-line body"
  done
done

finish
