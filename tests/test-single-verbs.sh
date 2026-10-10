#!/usr/bin/env bash
# Single verbs instead of multi-turn procedures (#549, epic #558). Every agent
# turn re-reads the whole context, so a confirmation the profile asked for in a
# second command now happens inside the first:
#   - post-approval verifies its own stamp and prints ONE result line
#     ("stamp ok" / "stamp FAILED"); no stage runs `check-approval-sha` after it
#   - create-pr prints the PR number and URL, so the developer's view-pr goes
#   - post-approval --issue <N> tags the stage's worktree (no `tag` step in
#     the profiles)
# qa-run (the QA criteria check) is covered by tests/test-qa-run.sh.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
AGENTS="$TALOS_ROOT/agents"
git config user.email t@t.invalid
git config user.name t
printf 'x\n' > f.txt
git add f.txt
git commit -q -m init

export STUB_CURRENT_USER=bot
SHA="aabb1122ccdd3344eeff556677889900aabb1122"
OLD="1111111111111111111111111111111111111111"
marker() {  # role sha -> a comments array holding that approval marker
  python3 -I -c 'import json, sys
print(json.dumps([{"body": "<!-- talos:approval sha=%s role=%s -->" % (sys.argv[2], sys.argv[1]),
                   "user": {"login": "bot"}, "author": {"login": "bot"}}]))' "$1" "$2"
}
LABEL_QA='[{"name":"qa:pass"}]'

# pa ROLE LABELS_JSON SEED_COMMENTS_JSON [extra args] -- run post-approval against the
# stateful comment store: SEED is what the PR already holds, the verb's own
# POST appends to it, and check-approval-sha then reads the store back. The
# labels are what GitHub reports once the verb has applied its label.
STORE="$SANDBOX/comments.json"
export STUB_COMMENT_STORE="$STORE"
pa() {
  local role="$1" labels="$2" seed="$3"
  shift 3
  printf '%s' "$seed" > "$STORE"
  STUB_PR_HEAD_SHA="$SHA" STUB_PR_BASE_REF_NAME=main STUB_PR_LABELS_JSON="$labels" \
    bash "$VCS" post-approval 9 "$role" "$@" 2>"$SANDBOX/pa.err"
}

# ── post-approval: the stamp is verified inside the verb ─────────────────────
out="$(pa qa "$LABEL_QA" '[]')"; rc=$?
assert_eq "0" "$rc" "post-approval: a good stamp exits 0"
assert_contains "$out" "post-approval: PR #9 qa marker posted and qa:pass label applied" "post-approval: still reports the post"
assert_contains "$out" "stamp ok" "post-approval: reports 'stamp ok' when check-approval-sha agrees"
assert_eq "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "post-approval: one result line on stdout"
assert_not_contains "$out" "FAILED" "post-approval: no failure text on a good stamp"

# The label never landed: check-approval-sha says "no approval labels present"
# (exit 0), which must not count as a verified stamp.
out="$(pa qa '[]' '[]')"; rc=$?
assert_eq "1" "$rc" "post-approval: no label after the post exits 1"
assert_contains "$out" "stamp FAILED" "post-approval: no label after the post is a failed stamp"
assert_contains "$out" "qa" "post-approval: the failure line names the role"
assert_not_contains "$out" "stamp ok" "post-approval: no label is not an ok stamp"
assert_eq "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "post-approval: a failed stamp is also one result line"

# Another role's approval is stale (older head): fail closed, as the follow-up did.
out="$(pa qa '[{"name":"qa:pass"},{"name":"review:approved"}]' "$(marker reviewer "$OLD")")"; rc=$?
assert_eq "1" "$rc" "post-approval: a stale approval on the PR exits 1"
assert_contains "$out" "stamp FAILED" "post-approval: a stale approval on the PR is a failed stamp"

# The duplicate path (marker already there at this head) verifies too.
out="$(pa qa "$LABEL_QA" "$(marker qa "$SHA")")"; rc=$?
assert_eq "0" "$rc" "post-approval: an already-present marker with a good stamp exits 0"
assert_contains "$out" "already present" "post-approval: the duplicate path says so"
assert_contains "$out" "stamp ok" "post-approval: the duplicate path verifies its stamp too"
assert_eq "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "post-approval: the duplicate path is one result line"

# ── post-approval --issue <N>: the stage's worktree is tagged in code ────────
WT="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-sv-wt.XXXXXX")" || exit 1
rmdir "$WT"
git worktree add -q --detach "$WT" HEAD
printf '[]' > "$STORE"
( cd "$WT" && STUB_PR_HEAD_SHA="$SHA" STUB_PR_BASE_REF_NAME=main STUB_PR_LABELS_JSON="$LABEL_QA" \
    bash "$VCS" post-approval 9 qa --issue 7 >/dev/null 2>&1 )
assert_contains "$(cat "$WT/.talos/env" 2>/dev/null)" "TALOS_ISSUE_NUMBER=7" "post-approval --issue 7: tags the stage worktree"
# Not a stage worktree (the main checkout): refused quietly, the verb still works.
printf '[]' > "$STORE"
out="$(STUB_PR_HEAD_SHA="$SHA" STUB_PR_BASE_REF_NAME=main STUB_PR_LABELS_JSON="$LABEL_QA" \
  bash "$VCS" post-approval 9 qa --issue 7 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "post-approval --issue 7 in the main checkout: still exit 0"
assert_file_absent "$SANDBOX/.talos/env" "post-approval --issue 7 in the main checkout: the main checkout is never tagged"
bash "$VCS" post-approval 9 qa --issue 'x;id' >/dev/null 2>&1
assert_eq "1" "$?" "post-approval --issue: a non-numeric issue is refused"
git worktree remove --force "$WT" 2>/dev/null
rm -rf "${WT:?}"

# ── create-pr prints the PR number and URL ───────────────────────────────────
printf 'body\n' > pr-body.txt
for leg in gh curl; do
  github_leg "$leg" ',"base_branch":"main"'
  printf '%s\n' '{"number":99,"html_url":"https://github.com/acme/widget/pull/99"}' > "$CURL_QUEUE"
  out="$(bash "$VCS" create-pr fix/issue-3-login "fix: login bug" pr-body.txt 2>/dev/null)"; rc=$?
  assert_eq "0" "$rc" "create-pr ($leg): exit 0"
  assert_eq "PR #99 https://github.com/acme/widget/pull/99" "$out" "create-pr ($leg): prints the PR number and URL on one line"

  # A response with neither a number nor a URL is a failure, never a guessed PR.
  printf '%s\n' '{"message":"ok"}' > "$CURL_QUEUE"
  out="$(bash "$VCS" create-pr fix/issue-3-login "fix: login bug" pr-body.txt 2>/dev/null)"; rc=$?
  assert_eq "1" "$rc" "create-pr ($leg): an answer without a PR number exits 1"
  assert_eq "" "$out" "create-pr ($leg): nothing on stdout for it"

  # Draft opens through the same output.
  printf '%s\n' '{"number":100,"html_url":"https://github.com/acme/widget/pull/100"}' > "$CURL_QUEUE"
  out="$(bash "$VCS" create-pr fix/issue-3-login "fix: login bug" pr-body.txt --draft 2>/dev/null)"
  assert_eq "PR #100 https://github.com/acme/widget/pull/100" "$out" "create-pr --draft ($leg): same output shape"
done

# ── the profiles no longer instruct the removed follow-ups ───────────────────
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }
for role in qa reviewer security docs adversarial; do
  text="$(flat "$AGENTS/$role.md")"
  assert_not_contains "$text" "check-approval-sha <PR>; echo rc" "$role profile: no check-approval-sha follow-up after post-approval"
  assert_not_contains "$text" "pipeline-worktree.sh tag" "$role profile: no worktree tag step"
  assert_contains "$text" "post-approval <PR> $role " "$role profile: still posts its approval with post-approval"
done
assert_not_contains "$(flat "$AGENTS/developer.md")" "view-pr <branch>" "developer profile: no view-pr confirmation after create-pr"
assert_contains "$(flat "$AGENTS/developer.md")" "create-pr" "developer profile: still opens the PR with create-pr"

finish
