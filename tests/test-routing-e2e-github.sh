#!/usr/bin/env bash
# test-routing-e2e-github.sh -- `talos.sh next --issue <N>` end to end on the
# github provider (#738, part 4 of #687): one issue walked from pipeline:ready to
# the merge action, with the shipped scripts/ (the real pipeline-vcs.sh adapter,
# the real collect) and only the provider CLI stubbed (tests/stubs/gh). The
# verb-level stubs of test-talos-next.sh never run adapter code, so a missing
# verb or JSON key could pass every unit test; here it fails a routing step.
#
#   AC1  ready -> validator, confirmed with no spec -> pm, dev with no PR -> developer
#   AC2  an open non-draft PR follows the approval order qa, docs, reviewer,
#        security, then merge (merge.auto on, the required checks passing)
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

# A small transcript keeps next's context-budget check (#605) quiet.
printf '{"timestamp": "2026-10-11T10:00:00Z", "message": {"id": "m1", "usage": {"input_tokens": 5, "cache_read_input_tokens": 1000, "output_tokens": 50}}}\n' > "$SANDBOX/session.jsonl"
export TALOS_TRANSCRIPT_PATH="$SANDBOX/session.jsonl"

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '%s\n' '{"vcs": {"provider": "github", "repo": "acme/widget"},' \
  ' "roles": {"validator": true, "pm": true, "qa": true, "docs": true, "reviewer": true, "security": true},' \
  ' "pr": {"draft": false}, "merge": {"auto": true, "required_checks": ["test"]},' \
  ' "issues": {"max_parallel": 1}}' > "$PIPELINE_CONFIG"

LEASE="$SANDBOX/.git/talos-lease.ledger"
LEASE_RESET() { rm -f "$LEASE" "${LEASE:?}.lock.d"; }

# issue_state <labels json> : the open issue, as the listing and the single read serve it.
issue_state() {
  export STUB_ISSUE_LABELS_JSON="$1"
  export STUB_ISSUE_LIST="[{\"number\": $N, \"title\": \"routing e2e\", \"labels\": $1, \"body\": \"\"}]"
  export STUB_PR_LIST='[]'
}
# pr_state <labels json> <approval roles...> : the issue's open non-draft PR with
# the given labels, and the approval markers of the given roles for its head.
pr_state() {
  local _labels="$1" _c="" _r
  shift
  for _r in "$@"; do
    _c="$_c{\"body\": \"<!-- talos:approval sha=$HEAD_SHA role=$_r -->\"},"
  done
  export STUB_ISSUE_LABELS_JSON='[]'
  export STUB_ISSUE_LIST="[{\"number\": $N, \"title\": \"routing e2e\", \"labels\": [], \"body\": \"\"}]"
  export STUB_PR_LIST="[{\"number\": $PR, \"state\": \"OPEN\", \"title\": \"fix\", \"headRefName\": \"fix/issue-$N-routing\", \"baseRefName\": \"main\", \"isCrossRepository\": false, \"labels\": $_labels}]"
  export STUB_PR_LABELS_JSON="$_labels"
  export STUB_PR_COMMENTS_JSON="[${_c%,}]"
  export STUB_PR_HEAD_SHA="$HEAD_SHA"
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

# ── AC1: the issue side, through the github adapter ──────────────────────────
issue_state '[{"name": "pipeline:ready"}]'
step "AC1" "ready issue" "action=dispatch stage=validator issue=$N"

issue_state '[{"name": "pipeline:confirmed"}]'
step "AC1" "confirmed issue with no spec" "action=dispatch stage=pm issue=$N"

issue_state '[{"name": "pipeline:dev"}]'
step "AC1" "dev issue with no PR" "action=dispatch stage=developer issue=$N"

# ── AC2: the PR side, in the approval order ──────────────────────────────────
pr_state '[]'
step "AC2" "PR with no approval" "action=dispatch stage=qa pr=$PR issue=$N"
pr_state '[{"name": "qa:pass"}]' qa
step "AC2" "PR with qa:pass" "action=dispatch stage=docs pr=$PR issue=$N"
pr_state '[{"name": "qa:pass"}, {"name": "docs:done"}]' qa docs
step "AC2" "PR with qa:pass docs:done" "action=dispatch stage=reviewer pr=$PR issue=$N"
pr_state '[{"name": "qa:pass"}, {"name": "docs:done"}, {"name": "review:approved"}]' qa docs reviewer
step "AC2" "PR with review:approved" "action=dispatch stage=security pr=$PR issue=$N"
pr_state '[{"name": "qa:pass"}, {"name": "docs:done"}, {"name": "review:approved"}, {"name": "security:approved"}]' qa docs reviewer security
step "AC2" "PR with every approval and passing checks" "action=merge pr=$PR issue=$N"

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
  '  echo "pipeline-vcs: $1: not implemented for provider '"'"'github'"'"'" >&2' \
  '  exit 1' \
  'fi' \
  'exec bash "$(dirname "$0")/pipeline-vcs-real.sh" "$@"' > "$UNSUP/pipeline-vcs.sh"

issue_state '[{"name": "pipeline:confirmed"}]'
LEASE_RESET
OUT="$(STUB_UNSUPPORTED_VERB=has-spec bash "$UNSUP/talos.sh" next --issue "$N" 2>"$ERR")"; RC=$?
assert_eq "stop reason=unsupported-verb:has-spec" "$OUT" "AC6 a has-spec the provider lacks stops the router"
assert_eq "1" "$RC" "AC6 the unsupported-verb stop exits 1"

finish
