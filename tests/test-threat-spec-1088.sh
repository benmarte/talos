#!/usr/bin/env bash
# test-threat-spec-1088.sh -- the threat stage is dispatched once, not forever
# (#1088). Its prompt handed it a comment header, so the spec it re-posted with
# `## Threat model` was not seen as the spec and `next` dispatched it again.
#   AC1  the threat prompt asks for no comment header
#   AC2  `view-issue --spec` keeps a spec posted under the threat header
#   AC3  another role's header still makes no spec
#   AC4  `next` then routes to the developer
#   AC5  a threat run that leaves no `## Threat model` is not dispatched again
#   AC6  the other roles keep their comment header
# The real talos.sh and pipeline-vcs.sh run against the gh stub's stateful
# comment store: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
export STUB_CURRENT_USER=x
export STUB_ISSUE_TITLE="Login hardening"
export STUB_ISSUE_BODY="Plain body."
export STUB_ISSUE_LABELS_JSON='[{"name": "pipeline:dev"}]'
export STUB_COMMENT_STORE="$SANDBOX/comments.json"
ERR="$SANDBOX/stderr"

# ── fixture: a copy of the install, only the provider-free scripts stubbed ───
GS="$SANDBOX/scripts"
mkdir -p "$GS" "$SANDBOX/templates" "$SANDBOX/agents"
cp "$TALOS_ROOT"/scripts/* "$GS/" 2>/dev/null
cp -R "$TALOS_ROOT"/templates/. "$SANDBOX/templates/"
cp "$TALOS_ROOT"/agents/*.md "$SANDBOX/agents/"
TN="$GS/talos.sh"
VCS="$GS/pipeline-vcs.sh"
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusQm4wT8nRe'
#!/usr/bin/env bash
printf '%s' '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [], "held": [], "owners": [], "capped": []}'
exit 0
TALOS_stubstatusQm4wT8nRe
for s in pipeline-notify.sh pipeline-hooks.sh pipeline-status.sh pipeline-events.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$GS/$s"
done

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '%s\n' '{"vcs": {"provider": "github", "repo": "acme/widget"}, "comments": {"enabled": false}, "issues": {"max_parallel": 4}, "roles": {"validator": true, "planner": false, "pm": true, "pm_skip_when_spec_present": false}, "pipeline": {"risk_areas": ["auth/authz/MFA"]}}' > "$PIPELINE_CONFIG"

SPEC="**PM spec:** login

**Acceptance criteria:**
- [ ] AC1 a login with a bad MFA code is refused (test)

**Goal:** harden the auth/authz/MFA path.

**Tests:** \`tests/test-login.sh\`"
SPEC_MODEL="$SPEC

## Threat model
- [ ] AC2 a replayed MFA code is refused (test)"
SPEC_REVISED="$SPEC

A revised goal line."
THREAT_HDR='**Agent:** threat (talos)'
REVIEWER_HDR='**Agent:** reviewer (talos)'

# thread BODY...: the issue's comments, oldest first, by the account Talos runs
# as; the comment id is its 1-based position.
thread() {
  python3 -I -c '
import json, sys
json.dump([dict(id=i + 1, user=dict(login="x"), created_at="2026-01-%02dT00:00:00Z" % (i + 1), body=b)
           for i, b in enumerate(sys.argv[2:])], open(sys.argv[1], "w"))' "$STUB_COMMENT_STORE" "$@"
}
# post BODY: append one comment to the thread, as a stage would.
post() {
  python3 -I -c '
import json, sys
items = json.load(open(sys.argv[1]))
nid = max([c["id"] for c in items] + [0]) + 1
items.append(dict(id=nid, user=dict(login="x"), created_at="2026-02-01T00:00:00Z", body=sys.argv[2]))
json.dump(items, open(sys.argv[1], "w"))' "$STUB_COMMENT_STORE" "$1"
}
attempts() { grep -o 'talos:attempt stage=threat' "$STUB_COMMENT_STORE" | wc -l | tr -d ' '; }
kept() {  # the ids of the comments `view-issue --spec` keeps, comma-joined
  bash "$VCS" view-issue 22 --spec 2>"$ERR" \
    | python3 -I -c 'import json, sys; print(",".join(str(c["id"]) for c in json.load(sys.stdin)["comments"]))'
}
nx() { reset_leases; OUT="$(bash "$TN" next --issue 22 2>"$ERR")"; RC=$?; }
SUM="$SANDBOX/summary.txt"
printf 'threat model: done\n' > "$SUM"
# done_threat [extra args...]
done_threat() { OUT="$(bash "$TN" done threat --issue 22 --summary-file "$SUM" "$@" 2>"$ERR" < /dev/null)"; RC=$?; }
prompt_of() {  # the stage prompt of the fixture install, on stdout
  local _o _f
  _o="$(bash "$TN" prompt "$@" 2>"$ERR")" || { printf '%s\n' "$_o"; return 1; }
  _f="$(printf '%s\n' "$_o" | sed -n 's/^prompt_file=//p')"
  [ -n "$_f" ] && [ -f "$_f" ] || return 1
  cat "$_f"
  rm -f "${_f:?}"
}

# ── AC1: the threat prompt ───────────────────────────────────────────────────
thread "$SPEC"
P="$(prompt_of threat --issue 22)"; RC=$?
assert_eq "0" "$RC" "AC1 prompt threat renders"
assert_not_contains "$P" "Comment header:" "AC1 the threat prompt carries no Comment header line"
assert_contains "$P" "first line is \`**PM spec:**\`" "AC1 the threat prompt says the comment's first line is **PM spec:**"

# ── AC6: the other roles keep theirs ─────────────────────────────────────────
for role in validator reviewer; do
  P="$(prompt_of "$role" --issue 22 --pr 8)"
  assert_contains "$P" "Comment header: **Agent:** $role (talos)" "AC6 the $role prompt still carries its Comment header line"
done

# ── AC2: a spec under the threat header is the latest spec ───────────────────
thread "$SPEC" "$THREAT_HDR
$SPEC_MODEL"
assert_eq "2" "$(kept)" "AC2 view-issue --spec keeps the comment led by the threat header"
thread "$SPEC" "$THREAT_HDR

$SPEC_MODEL"
assert_eq "2" "$(kept)" "AC2 a blank line between the threat header and **PM spec:** is accepted"

# ── AC3: another role's header makes no spec ─────────────────────────────────
thread "$REVIEWER_HDR
$SPEC_MODEL"
assert_eq "" "$(kept)" "AC3 a reviewer-headed comment alone is no spec"
thread "$SPEC" "$THREAT_HDR
$SPEC_MODEL" "$REVIEWER_HDR
$SPEC_REVISED"
assert_eq "2" "$(kept)" "AC3 a later reviewer-headed comment does not replace the threat-headed spec"
thread "$SPEC" "$THREAT_HDR
a note before the spec
$SPEC_MODEL"
assert_eq "1" "$(kept)" "AC3 the threat header followed by other text is no spec"

# ── AC4: with the threat model in place the developer is next ────────────────
thread "$SPEC" "$THREAT_HDR
$SPEC_MODEL"
nx
assert_eq_ctx "action=dispatch stage=developer issue=22" "$OUT" "AC4 next routes to the developer, not to threat again" "$(cat "$ERR")"

# The spec under that header is the one `done threat` checks too: a bad Tests:
# line in it is refused, not skipped for the header above it.
thread "$SPEC" "$THREAT_HDR
${SPEC_MODEL/\*\*Tests:\*\* \`tests\/test-login.sh\`/no tests line}"
done_threat
assert_contains "$OUT" "spec_check=tests-line-missing" "AC2 done threat checks the Tests: line of a threat-headed spec"

# ── AC5: one run, no ## Threat model: stop, no second dispatch ───────────────
# The agent re-posted the spec without the section.
thread "$SPEC"
nx
assert_eq_ctx "action=dispatch stage=threat issue=22" "$OUT" "AC5 the first next dispatches the threat stage" "$(cat "$ERR")"
nx
assert_eq "action=dispatch stage=threat issue=22" "$OUT" "AC5 a dispatch that never reported done is offered again"
post "$SPEC_REVISED"
done_threat
assert_eq "0" "$RC" "AC5 done threat is accepted"
assert_contains "$OUT" "next=continue" "AC5 done threat leaves the stop to next"
nx
assert_eq_ctx "stop reason=threat-unresolved issue=22" "$OUT" "AC5 the next next stops threat-unresolved" "$(cat "$ERR")"
assert_not_contains "$OUT" "stage=threat" "AC5 no second threat dispatch"
assert_eq "1" "$RC" "AC5 the stop exits 1, like the other loop ceilings"
nx
assert_eq "stop reason=threat-unresolved issue=22" "$OUT" "AC5 the stop stands on every later next"

# A new spec is a new run: threat once more, then the same bound.
post "$SPEC_REVISED
Revised by the owner."
nx
assert_eq "action=dispatch stage=threat issue=22" "$OUT" "AC5 a spec posted after the stop is threat-modelled once"
# The operator's other way out: a spec that carries the section.
post "$SPEC_MODEL"
nx
assert_eq "action=dispatch stage=developer issue=22" "$OUT" "AC5 a spec with ## Threat model clears the stop"

# The agent posted nothing the spec reader takes.
thread "$SPEC"
post "$REVIEWER_HDR
$SPEC_MODEL"
done_threat
nx
assert_eq_ctx "stop reason=threat-unresolved issue=22" "$OUT" "AC5 a post the spec reader skips still counts as the one run" "$(cat "$ERR")"

# No PM spec comment: the issue body is the spec.
export STUB_ISSUE_BODY="Harden auth/authz/MFA."
thread
done_threat
nx
assert_eq_ctx "stop reason=threat-unresolved issue=22" "$OUT" "AC5 with the issue body as the spec the second dispatch stops too" "$(cat "$ERR")"
export STUB_ISSUE_BODY="Harden auth/authz/MFA, revised."
nx
assert_eq "action=dispatch stage=threat issue=22" "$OUT" "AC5 an edited issue body is a new spec"
export STUB_ISSUE_BODY="Plain body."

# A run that did its job, or ended BLOCKED, records nothing.
thread "$SPEC_MODEL"
done_threat
assert_eq "0" "$(attempts)" "AC5 a threat run that added the section records no attempt"
thread "$SPEC"
done_threat --verdict BLOCKED
assert_eq "0" "$(attempts)" "AC5 a BLOCKED threat run records no attempt, so it can be retried"

# The record is the bound: when it cannot be written, nothing goes on.
thread "$SPEC"
: > "$GH_LOG"; : > "$GH_LOG.rest"
export STUB_COMMENT_WRITE_FAIL=1
done_threat
unset STUB_COMMENT_WRITE_FAIL
assert_contains "$OUT" "next=stop" "AC5 an attempt record that cannot be written stops the run"
assert_contains "$(cat "$GH_LOG" "$GH_LOG.rest" 2>/dev/null)" "pipeline:blocked" "AC5 and blocks the issue"

finish
