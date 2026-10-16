#!/usr/bin/env bash
# test-routing-e2e-azure.sh -- `talos.sh next --issue <N>` end to end on the
# azure provider (#738, part 4 of #687): one work item walked from pipeline:ready
# to the merge action, with the shipped scripts/ (the real pipeline-vcs.sh
# adapter, the real collect) and only the provider CLI stubbed (tests/stubs/az).
# The verb-level stubs of test-talos-next.sh never run adapter code, so a missing
# verb or JSON key could pass every unit test; here it fails a routing step.
#
#   AC3  ready -> validator, confirmed with no spec -> pm, dev with no PR ->
#        developer, then an open non-draft PR follows the approval order qa,
#        docs, reviewer, security and ends at the merge action (merge.auto on,
#        the required checks passing)
#   AC5  every answer is an exact whole-line compare; next exits 0 and never
#        prints a stop reason=unsupported-verb: line
#   AC6  an adapter verb that answers `not implemented for provider` is a
#        stop reason=unsupported-verb:<verb> with exit 1, never swallowed
#
# No sleeps, no network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
TALOS="$TALOS_ROOT/scripts/talos.sh"
ERR="$SANDBOX/stderr"
N=7
PR=12
HEAD_SHA="1111111111111111111111111111111111111111"
PROJ="6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c"
BOT="bot@acme.com"
git remote set-url origin https://dev.azure.com/acme/proj/_git/widget

# A small transcript keeps next's context-budget check (#605) quiet.
printf '{"timestamp": "2026-10-11T10:00:00Z", "message": {"id": "m1", "usage": {"input_tokens": 5, "cache_read_input_tokens": 1000, "output_tokens": 50}}}\n' > "$SANDBOX/session.jsonl"
export TALOS_TRANSCRIPT_PATH="$SANDBOX/session.jsonl"

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '%s\n' '{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}},' \
  ' "roles": {"validator": true, "pm": true, "qa": true, "docs": true, "reviewer": true, "security": true},' \
  ' "pr": {"draft": false}, "merge": {"auto": true, "required_checks": ["CI build"]},' \
  ' "markers": {"trusted_authors": ["bot@acme.com"]}, "issues": {"max_parallel": 1}}' > "$PIPELINE_CONFIG"

LEASE="$SANDBOX/.git/talos-lease.ledger"
LEASE_RESET() { rm -f "$LEASE" "${LEASE:?}.lock.d"; }

# issue_state <System.Tags> : the open work item, as the WIQL listing and the single read serve it.
issue_state() {
  export STUB_AZURE_WORKITEM_LIST="[{\"id\": $N, \"fields\": {\"System.Title\": \"routing e2e\", \"System.State\": \"New\", \"System.Tags\": \"$1\"}}]"
  export STUB_AZURE_WORKITEM_JSON="{\"id\": $N, \"fields\": {\"System.Title\": \"routing e2e\", \"System.State\": \"New\", \"System.Tags\": \"$1\", \"System.Description\": \"just prose\"}}"
  export STUB_AZURE_WI_COMMENTS='{"comments": []}'
  export STUB_AZURE_PR_LIST='[]'
}
# pr_state <label names...> : the work item's open non-draft PR carrying those
# labels, and an approval marker (for the current head) for each approval label.
pr_state() {
  local _labels="" _threads="" _l _role
  for _l in "$@"; do
    _labels="$_labels{\"id\": \"1\", \"name\": \"$_l\", \"active\": true},"
    case "$_l" in
      qa:pass) _role=qa ;;
      docs:done) _role=docs ;;
      review:approved) _role=reviewer ;;
      security:approved) _role=security ;;
      *) continue ;;
    esac
    _threads="$_threads{\"id\": 1, \"comments\": [{\"id\": 1, \"content\": \"ok\\n<!-- talos:approval sha=$HEAD_SHA role=$_role -->\", \"commentType\": \"text\", \"author\": {\"displayName\": \"B\", \"uniqueName\": \"$BOT\"}, \"publishedDate\": \"2026-10-15T00:00:00Z\"}]},"
  done
  issue_state ""
  export STUB_AZURE_PR_LIST="[{\"pullRequestId\": $PR, \"title\": \"fix\", \"status\": \"active\", \"isDraft\": false, \"labels\": [${_labels%,}], \"sourceRefName\": \"refs/heads/fix/issue-$N-routing\", \"targetRefName\": \"refs/heads/main\"}]"
  export "STUB_AZURE_PR_$PR={\"pullRequestId\": $PR, \"status\": \"active\", \"targetRefName\": \"refs/heads/main\", \"repository\": {\"id\": \"r1\", \"project\": {\"id\": \"$PROJ\"}}, \"lastMergeSourceCommit\": {\"commitId\": \"$HEAD_SHA\"}}"
  export STUB_AZURE_PR_LABELS="{\"value\": [${_labels%,}]}"
  export STUB_AZURE_PR_THREADS="{\"value\": [${_threads%,}]}"
  export STUB_AZURE_PR_EVALUATIONS='{"count": 1, "value": [{"configuration": {"type": {"displayName": "Build"}, "settings": {"displayName": "CI build"}}, "status": "approved", "evaluationId": "00000001-0000-0000-0000-000000000000"}]}'
}
# step <AC id> <label> <expected action line> : one `next --issue N`, the lease
# cleared first (next leases the issue on a dispatch or merge answer).
step() {
  LEASE_RESET
  OUT="$(bash "$TALOS" next --issue "$N" 2>"$ERR")"; RC=$?
  assert_eq "$3" "$OUT" "$1 $2: next answers $3"
  assert_eq "0" "$RC" "AC5 $2: next exits 0"
  assert_not_contains "$OUT$(cat "$ERR")" "stop reason=unsupported-verb:" "AC5 $2: no unsupported-verb stop"
}

# ── AC3: the issue side, through the azure adapter ───────────────────────────
issue_state "pipeline:ready"
step "AC3" "ready work item" "action=dispatch stage=validator issue=$N"

issue_state "pipeline:confirmed"
step "AC3" "confirmed work item with no spec" "action=dispatch stage=pm issue=$N"

issue_state "pipeline:dev"
step "AC3" "dev work item with no PR" "action=dispatch stage=developer issue=$N"

# ── AC3: the PR side, in the approval order ──────────────────────────────────
pr_state
step "AC3" "PR with no approval" "action=dispatch stage=qa pr=$PR issue=$N"
pr_state qa:pass
step "AC3" "PR with qa:pass" "action=dispatch stage=docs pr=$PR issue=$N"
pr_state qa:pass docs:done
step "AC3" "PR with qa:pass docs:done" "action=dispatch stage=reviewer pr=$PR issue=$N"
pr_state qa:pass docs:done review:approved
step "AC3" "PR with review:approved" "action=dispatch stage=security pr=$PR issue=$N"
pr_state qa:pass docs:done review:approved security:approved
step "AC3" "PR with every approval and passing checks" "action=merge pr=$PR issue=$N"

# ── AC6: a verb the adapter cannot serve is a stop, not a guess ──────────────
# The adapter prints "not implemented for provider" itself, for a verb its
# provider case lacks; no provider CLI answer can make it. So this one case runs
# a copy of scripts/ whose pipeline-vcs.sh refuses the verb named by
# STUB_UNSUPPORTED_VERB with that text and otherwise execs the shipped adapter.
UNSUP="$SANDBOX/unsup-scripts"
mkdir -p "$UNSUP"
cp "$TALOS_ROOT"/scripts/* "$UNSUP/"
mv "$UNSUP/pipeline-vcs.sh" "$UNSUP/pipeline-vcs-real.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "${STUB_UNSUPPORTED_VERB:-}" ]; then' \
  '  echo "pipeline-vcs: $1: not implemented for provider '"'"'azure'"'"'" >&2' \
  '  exit 1' \
  'fi' \
  'exec bash "$(dirname "$0")/pipeline-vcs-real.sh" "$@"' > "$UNSUP/pipeline-vcs.sh"

issue_state "pipeline:confirmed"
LEASE_RESET
OUT="$(STUB_UNSUPPORTED_VERB=has-spec bash "$UNSUP/talos.sh" next --issue "$N" 2>"$ERR")"; RC=$?
assert_eq "stop reason=unsupported-verb:has-spec" "$OUT" "AC6 a has-spec the provider lacks stops the router"
assert_eq "1" "$RC" "AC6 the unsupported-verb stop exits 1"

finish
