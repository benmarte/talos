#!/usr/bin/env bash
# test-routing-e2e-gitlab.sh -- `talos.sh next --issue <N>` end to end on the
# gitlab provider (#738, part 4 of #687): one issue walked from pipeline:ready to
# the merge action, with the shipped scripts/ (the real pipeline-vcs.sh adapter,
# the real collect) and only the provider CLI stubbed (tests/stubs/glab). Before
# parts 1 to 3 of #687 (#735 to #737) the gitlab adapter lacked view-issue,
# has-spec, check-attempt, check-approval-sha and a working pr-checks-required,
# and every verb-level unit test still passed; here a missing verb or JSON key
# fails a routing step.
#
#   AC4  ready -> validator, confirmed with no spec -> pm, dev with no PR ->
#        developer, then an open non-draft MR follows the approval order qa,
#        docs, reviewer, security and ends at the merge action, with
#        pr-checks-required judged from the MR's head pipeline (merge.auto on)
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
BOT="talos-bot"
git remote set-url origin git@gitlab.com:acme/widget.git
export STUB_CURRENT_USER="$BOT"

# A small transcript keeps next's context-budget check (#605) quiet.
printf '{"timestamp": "2026-10-11T10:00:00Z", "message": {"id": "m1", "usage": {"input_tokens": 5, "cache_read_input_tokens": 1000, "output_tokens": 50}}}\n' > "$SANDBOX/session.jsonl"
export TALOS_TRANSCRIPT_PATH="$SANDBOX/session.jsonl"

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '%s\n' '{"vcs": {"provider": "gitlab", "repo": "acme/widget"},' \
  ' "roles": {"validator": true, "pm": true, "qa": true, "docs": true, "reviewer": true, "security": true},' \
  ' "pr": {"draft": false}, "merge": {"auto": true, "required_checks": ["test"]},' \
  ' "issues": {"max_parallel": 1}}' > "$PIPELINE_CONFIG"

LEASE="$SANDBOX/.git/talos-lease.ledger"
LEASE_RESET() { rm -f "$LEASE" "${LEASE:?}.lock.d"; }

# issue_state <label> : the open issue, as the listing and the single read serve it.
issue_state() {
  local _labels="[]"
  [ -z "$1" ] || _labels="[\"$1\"]"
  export STUB_GITLAB_ISSUE_LIST="[{\"iid\": $N, \"title\": \"routing e2e\", \"state\": \"opened\", \"labels\": $_labels, \"description\": \"\"}]"
  export STUB_GITLAB_ISSUE_VIEW="{\"id\": 9007, \"iid\": $N, \"title\": \"routing e2e\", \"state\": \"opened\", \"labels\": $_labels, \"description\": \"just prose\", \"assignees\": []}"
  export STUB_GITLAB_MR_LIST='[]'
}
# pr_state <label names...> : the issue's open non-draft MR carrying those
# labels, a note with the approval marker for the current head for each approval
# label, and a head pipeline whose "test" job passed.
pr_state() {
  local _labels="" _notes="" _l _role _k=0
  for _l in "$@"; do
    _labels="$_labels\"$_l\","
    case "$_l" in
      qa:pass) _role=qa ;;
      docs:done) _role=docs ;;
      review:approved) _role=reviewer ;;
      security:approved) _role=security ;;
      *) continue ;;
    esac
    _k=$((_k + 1))
    _notes="$_notes{\"id\": $((5000 + _k)), \"body\": \"ok\\n<!-- talos:approval sha=$HEAD_SHA role=$_role -->\", \"system\": false, \"author\": {\"username\": \"$BOT\"}, \"created_at\": \"2026-10-16T00:00:0${_k}Z\"},"
  done
  issue_state ""
  export STUB_GITLAB_MR_LIST="[{\"iid\": $PR, \"title\": \"fix\", \"state\": \"opened\", \"source_branch\": \"fix/issue-$N-routing\", \"target_branch\": \"main\", \"source_project_id\": 1, \"target_project_id\": 1, \"draft\": false, \"labels\": [${_labels%,}], \"description\": \"\"}]"
  export STUB_GITLAB_MR_VIEW="{\"iid\": $PR, \"state\": \"opened\", \"sha\": \"$HEAD_SHA\", \"target_branch\": \"main\", \"labels\": [${_labels%,}]}"
  export STUB_GITLAB_MR_NOTES="[${_notes%,}]"
  export STUB_GITLAB_MR_API="{\"iid\": $PR, \"sha\": \"$HEAD_SHA\", \"head_pipeline\": {\"id\": 501, \"status\": \"success\", \"sha\": \"$HEAD_SHA\"}}"
  export STUB_GITLAB_PIPELINE_JOBS='[{"id": 1, "name": "test", "status": "success"}]'
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

# ── AC4: the issue side, through the gitlab adapter ──────────────────────────
issue_state "pipeline:ready"
step "AC4" "ready issue" "action=dispatch stage=validator issue=$N"

issue_state "pipeline:confirmed"
step "AC4" "confirmed issue with no spec" "action=dispatch stage=pm issue=$N"

issue_state "pipeline:dev"
step "AC4" "dev issue with no PR" "action=dispatch stage=developer issue=$N"

# ── AC4: the MR side, in the approval order ──────────────────────────────────
pr_state
step "AC4" "MR with no approval" "action=dispatch stage=qa pr=$PR issue=$N"
pr_state qa:pass
step "AC4" "MR with qa:pass" "action=dispatch stage=docs pr=$PR issue=$N"
pr_state qa:pass docs:done
step "AC4" "MR with qa:pass docs:done" "action=dispatch stage=reviewer pr=$PR issue=$N"
pr_state qa:pass docs:done review:approved
step "AC4" "MR with review:approved" "action=dispatch stage=security pr=$PR issue=$N"
pr_state qa:pass docs:done review:approved security:approved
step "AC4" "MR with every approval and a passing head pipeline" "action=merge pr=$PR issue=$N"

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
  '  echo "pipeline-vcs: $1: not implemented for provider '"'"'gitlab'"'"'" >&2' \
  '  exit 1' \
  'fi' \
  'exec bash "$(dirname "$0")/pipeline-vcs-real.sh" "$@"' > "$UNSUP/pipeline-vcs.sh"

issue_state "pipeline:confirmed"
LEASE_RESET
OUT="$(STUB_UNSUPPORTED_VERB=has-spec bash "$UNSUP/talos.sh" next --issue "$N" 2>"$ERR")"; RC=$?
assert_eq "stop reason=unsupported-verb:has-spec" "$OUT" "AC6 a has-spec the provider lacks stops the router"
assert_eq "1" "$RC" "AC6 the unsupported-verb stop exits 1"

finish
