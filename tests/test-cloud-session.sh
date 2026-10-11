#!/usr/bin/env bash
# test-cloud-session.sh -- the GitHub adapter in a Claude Code cloud session
# (#618): every gh subcommand GitHub serves from GraphQL fails there with
# `HTTP 403: GitHub GraphQL is not available from Claude Code sessions`, while
# REST (`gh api ...`) works, and a push to a branch the session may not write is
# refused with a 403. The gh stub plays that GitHub with STUB_GH_NO_GRAPHQL=1.
#   AC1 checkout-pr falls back to REST + git when `gh pr checkout` is refused
#   AC3 the issue's lifecycle verbs succeed with GraphQL refused (test-api-calls.sh)
#   AC4 a refused board move is one note naming GraphQL and one warn line
#   AC5 a refused push is one `push refused` line naming the missing access
#   AC9 ready-pr / draft-pr use the session's ccr REST route when GraphQL is refused
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
WT="$TALOS_ROOT/scripts/pipeline-worktree.sh"
export STUB_REPO=acme/widget TALOS_RETRY_SLEEP_SCALE=0
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > talos.pipeline.json
git config user.email t@t.invalid
git config user.name t
printf 'one\n' > f.txt && git add f.txt talos.pipeline.json && git commit -q -m init
git branch -M main
git init -q --bare "$SANDBOX/origin.git"
git remote remove origin 2>/dev/null || :
git remote add origin "$SANDBOX/origin.git"
git push -q origin main
BR=feat/issue-7-greet
git checkout -q -b "$BR"
printf 'two\n' > g.txt && git add g.txt && git commit -q -m "the PR"
PR_SHA="$(git rev-parse HEAD)"
git push -q origin "HEAD:refs/pull/9/head"
git checkout -q main
git branch -q -D "$BR"

# ── AC1: checkout-pr with GraphQL refused ────────────────────────────────────
printf '%s\n' "{\"number\":9,\"head\":{\"ref\":\"$BR\",\"sha\":\"$PR_SHA\"}}" > "$SANDBOX/gh.queue"
OUT="$(STUB_GH_NO_GRAPHQL=1 GH_QUEUE="$SANDBOX/gh.queue" bash "$VCS" checkout-pr 9 2>&1)"; RC=$?
assert_eq "0" "$RC" "AC1 checkout-pr exits 0 with GraphQL refused" "$OUT"
assert_eq "$BR" "$(git symbolic-ref -q --short HEAD)" "AC1 the PR's head branch is checked out"
assert_eq "$PR_SHA" "$(git rev-parse HEAD)" "AC1 HEAD is the PR head"
assert_contains "$(cat "$GH_LOG")" "pr checkout 9" "AC1 gh pr checkout was tried first (GraphQL is kept where it works)"
git checkout -q main

# ── AC2: with GraphQL available, a failed gh pr checkout stays gh's failure ──
# gh words its ordinary errors `GraphQL: ...` too (here: no such PR); only the
# session's refusal may take the REST path.
: > "$GH_LOG"
GQL_ERR="GraphQL: Could not resolve to a PullRequest with the number of 9. (repository.pullRequest)"
OUT="$(GH_FAIL_STDERR="$GQL_ERR" bash "$VCS" checkout-pr 9 2>&1)"; RC=$?
assert_eq "1" "$RC" "AC2 checkout-pr exits with gh's own status when gh pr checkout fails" "$OUT"
assert_contains "$OUT" "$GQL_ERR" "AC2 gh's stderr reaches the caller"
assert_eq "1" "$(grep -c . "$GH_LOG")" "AC2 gh pr checkout and nothing else (no REST read of the PR)" "$(cat "$GH_LOG")"
assert_not_contains "$OUT" "could not resolve head ref" "AC2 the REST path's own error is not printed"
assert_eq "main" "$(git symbolic-ref -q --short HEAD)" "AC2 no branch is checked out"

# ── AC9: ready-pr / draft-pr take the session's REST route ──────────────────
for _v in ready-pr:ready_for_review draft-pr:convert_to_draft; do
  : > "$GH_LOG.rest"
  printf '%s\n' '{"number":9,"node_id":"PR_kw9"}' '{}' > "$SANDBOX/gh.queue"
  OUT="$(STUB_GH_NO_GRAPHQL=1 GH_QUEUE="$SANDBOX/gh.queue" bash "$VCS" "${_v%%:*}" 9 2>&1)"; RC=$?
  assert_eq "0" "$RC" "AC9 ${_v%%:*} exits 0 with GraphQL refused" "$OUT"
  assert_contains "$(cat "$GH_LOG.rest")" "repos/acme/widget/pulls/9/ccr/${_v#*:}" "AC9 ${_v%%:*} posts to the session's ccr/${_v#*:} route"
done

# ── AC3: the lifecycle verbs with GraphQL refused ────────────────────────────
OUT="$(TALOS_API_CALLS_NO_GRAPHQL=1 bash "$TALOS_ROOT/tests/test-api-calls.sh" 2>&1)"; RC=$?
assert_eq "0" "$RC" "AC3 next, done, post-approval, gate, merge-pr and post-merge all exit 0 with GraphQL refused" \
  "$(printf '%s\n' "$OUT" | grep -E '^FAIL' -A2 | head -n 12)"

# ── AC4: a refused board move ────────────────────────────────────────────────
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "board": {"enabled": true, "project_number": 7, "owner": "acme"}}\n' > talos.pipeline.json
OUT="$(STUB_GH_NO_GRAPHQL=1 TALOS_BOARD_NO_CACHE=1 bash "$TALOS_ROOT/scripts/pipeline-status.sh" 42 "In progress" 2>&1)"; RC=$?
assert_eq "1" "$RC" "AC4 the refused board move exits 1 (talos.sh turns it into one warn line)"
assert_contains "$OUT" "pipeline-status: the board needs GitHub GraphQL, which this session refuses (HTTP 403); move skipped" \
  "AC4 the board note names the refused GraphQL, not an unresolved project"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c '^pipeline-status:')" "AC4 the refused move prints exactly one board line"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > talos.pipeline.json

# ── AC5: a refused push ──────────────────────────────────────────────────────
# A pre-receive hook answers like the session's git proxy does for a branch it
# may not write.
cat > "$SANDBOX/origin.git/hooks/pre-receive" <<'TALOS_q3Lm8Vx2Kc7P'
#!/bin/sh
echo "Claude doesn't have GitHub access to acme/widget for your organization." >&2
exit 1
TALOS_q3Lm8Vx2Kc7P
chmod +x "$SANDBOX/origin.git/hooks/pre-receive"
git checkout -q -b fix/issue-12-push
printf 'x\n' > p.txt
OUT="$(printf '%s' '{"stage":"developer step 3","criteria_done":[],"criteria_remaining":[1],"decisions":[],"next_step":"push"}' \
  | bash "$WT" checkpoint 12 2>&1)"; RC=$?
assert_eq "3" "$RC" "AC5 a refused push exits 3 (the commit is kept locally)"
assert_contains "$OUT" "pipeline-worktree: checkpoint: push refused: no push access to origin for fix/issue-12-push" \
  "AC5 the refusal names the missing push access"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'push refused')" "AC5 exactly one push-refused line"
assert_not_contains "$OUT" "push failed; the commit is kept locally" "AC5 the generic push-failed line is not printed as well"
git checkout -q main

finish
