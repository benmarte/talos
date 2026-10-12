#!/usr/bin/env bash
# test-stamp-recovery.sh -- a lost approval stamp is recovered on evidence at the
# current head, never by hand and never across a head change (#521).
#   AC1 check-approval-sha --evidence-list: present / lost / missing per role
#   AC2 a marker that fails the inherited rules is never `lost`
#   AC3 post-approval --recover-only applies the label on evidence, posts nothing
#   AC4 gate merge: a lost role is recovered, a never-earned one waits and is named
#   AC5 gate merge: only lost roles missing -> recovered=, the gate goes on
#   AC6 the collect does not route a lost role as the PR's stage
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export PIPELINE_CONFIG="$SANDBOX/cfg.json" TALOS_RETRY_SLEEP_SCALE=0 CLAUDE_CONFIG_DIR="$SANDBOX/cc"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
OLD_SHA="fedcba9876543210fedcba9876543210fedcba98"
mk() {  # body-lines author -> one comment object
  python3 -I -c 'import json, sys; print(json.dumps({"body": sys.argv[1], "author": {"login": sys.argv[2]}}))' "$1" "$2"
}
marker() { printf '<!-- talos:approval sha=%s role=%s -->' "$1" "$2"; }

# ── AC1, AC2: the evidence verb ──────────────────────────────────────────────
ev() {  # labels-json comments-json -> OUT, RC
  OUT="$(STUB_CURRENT_USER=bot STUB_PR_HEAD_SHA="$HEAD_SHA" STUB_PR_LABELS_JSON="$1" STUB_PR_COMMENTS_JSON="$2" \
    bash "$VCS" check-approval-sha 9 --evidence-list 2>/dev/null)"; RC=$?
}
C1="$(mk "reviewed
$(marker "$HEAD_SHA" reviewer)" bot)"
ev '[{"name":"qa:pass"}]' "[$C1]"
assert_eq "0" "$RC" "AC1 --evidence-list exits 0"
assert_contains "$OUT" "evidence role=qa label=qa:pass state=present" "AC1 a label on the PR is present"
assert_contains "$OUT" "evidence role=reviewer label=review:approved state=lost" "AC1 an absent label whose trusted marker pins the head is lost"
assert_contains "$OUT" "evidence role=security label=security:approved state=missing" "AC1 an absent label with no marker is missing"
assert_eq "5" "$(printf '%s\n' "$OUT" | grep -c '^evidence ')" "AC1 one line per contract approval role"

NOT_LAST="$(mk "$(marker "$HEAD_SHA" reviewer)
quoted above" bot)"
UNTRUSTED="$(mk "ok
$(marker "$HEAD_SHA" security)" eve)"
ABBREV="$(mk "ok
$(marker 0123456 docs)" bot)"
WRONG_ROLE="$(mk "ok
$(marker "$HEAD_SHA" qa)" bot)"
OLD_HEAD="$(mk "ok
$(marker "$OLD_SHA" adversarial)" bot)"
ev '[]' "[$NOT_LAST, $UNTRUSTED, $ABBREV, $WRONG_ROLE, $OLD_HEAD]"
assert_contains "$OUT" "evidence role=reviewer label=review:approved state=missing" "AC2 a marker that is not its comment's last line is not evidence"
assert_contains "$OUT" "evidence role=security label=security:approved state=missing" "AC2 a marker from an untrusted author is not evidence"
assert_contains "$OUT" "evidence role=docs label=docs:done state=missing" "AC2 an abbreviated sha is not evidence"
assert_contains "$OUT" "evidence role=adversarial label=adversarial:approved state=missing" "AC2 a marker pinning an older head is not evidence"
assert_contains "$OUT" "evidence role=qa label=qa:pass state=lost" "AC2 control: the qa marker at the head is evidence for qa only"
# One rule for "a marker at the current head": the exact line post-approval
# writes. A hand-made marker --recover-only would refuse is not evidence either,
# or the role would be skipped by `next` and never recovered by the gate.
LOOSE="$(mk "ok
<!--  talos:approval sha=$HEAD_SHA role=reviewer --> signed by hand" bot)"
ev '[]' "[$LOOSE]"
assert_contains "$OUT" "evidence role=reviewer label=review:approved state=missing" "AC2 a marker that is not the exact line post-approval writes is not evidence"
: > "$GH_LOG"
OUT="$(STUB_CURRENT_USER=bot STUB_PR_HEAD_SHA="$HEAD_SHA" STUB_PR_COMMENTS_JSON="[$LOOSE]" bash "$VCS" post-approval 9 reviewer --recover-only 2>&1)"; RC=$?
assert_eq "3" "$RC" "AC2 control: --recover-only refuses that same marker"

# ── AC3: post-approval --recover-only ────────────────────────────────────────
: > "$GH_LOG"
OUT="$(STUB_CURRENT_USER=bot STUB_PR_HEAD_SHA="$HEAD_SHA" STUB_PR_LABELS_JSON='[{"name":"review:approved"}]' STUB_PR_COMMENTS_JSON="[$C1]" bash "$VCS" post-approval 9 reviewer --recover-only 2>&1)"; RC=$?
assert_eq "0" "$RC" "AC3 --recover-only with the marker at the head exits 0" "$OUT"
assert_contains "$(cat "$GH_LOG")" "review:approved" "AC3 the label is applied"
assert_not_contains "$(cat "$GH_LOG")" "issues/9/comments -X POST" "AC3 no comment is posted"
: > "$GH_LOG"
OUT="$(STUB_PR_HEAD_SHA="$HEAD_SHA" STUB_PR_COMMENTS_JSON="[$OLD_HEAD]" bash "$VCS" post-approval 9 adversarial --recover-only 2>&1)"; RC=$?
assert_eq "3" "$RC" "AC3 --recover-only with no marker at the head exits 3"
assert_not_contains "$(cat "$GH_LOG")" "-X POST" "AC3 no marker is posted without evidence"
assert_not_contains "$(cat "$GH_LOG")" "adversarial:approved" "AC3 no label is applied without evidence"

# ── AC4, AC5: gate merge ─────────────────────────────────────────────────────
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cat > "$GS/pipeline-vcs.sh" <<'TALOS_srVcsQm7Wn3Kx'
#!/usr/bin/env bash
# Gate stub: the PR's labels live in $STUB_DIR/pr.labels (one per line); a
# successful post-approval --recover-only adds its role's label there.
# recover.rc and evidence.rc, when present, fail that call with the code inside.
d="${STUB_DIR:?}"
printf 'vcs %s\n' "$*" >> "$d/journal"
lj() { python3 -I -c 'import json, sys; print(json.dumps({"labels": [{"name": l} for l in sys.stdin.read().split()]}))'; }
case "$1" in
  view-pr) lj < "$d/pr.labels" ;;
  view-issue) echo '{"labels": [{"name": "pipeline:review"}]}' ;;
  check-approval-sha)
    case " $* " in
      *" --evidence-list "*) [ ! -f "$d/evidence.rc" ] || exit "$(cat "$d/evidence.rc")"; cat "$d/evidence" ;;
      *) echo "check-approval-sha: all approval labels are current" ;;
    esac ;;
  post-approval)
    [ ! -f "$d/recover.rc" ] || exit "$(cat "$d/recover.rc")"
    case "$3" in reviewer) l=review:approved ;; security) l=security:approved ;; docs) l=docs:done ;; *) l="$3:pass" ;; esac
    if grep -q "role=$3 .*state=lost" "$d/evidence"; then echo "$l" >> "$d/pr.labels"; echo "post-approval: PR #$2 $3 recovered; stamp ok"; exit 0; fi
    exit 3 ;;
  check-pr-files) exit 0 ;;
  pr-head) echo 0123456789abcdef0123456789abcdef01234567 ;;
  *) exit 0 ;;
esac
TALOS_srVcsQm7Wn3Kx
for s in pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-mergebase.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$GS/$s"
done
printf '#!/usr/bin/env bash\necho false\n' > "$GS/pipeline-draft-check.sh"
printf '{"vcs": {"provider": "github"}, "comments": {"enabled": false}, "roles": {"docs": false}}\n' > "$PIPELINE_CONFIG"
gate() {  # labels-on-pr evidence-lines [post-approval rc] [evidence read rc] -> OUT
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  printf '%s\n' $1 > "$STUB_DIR/pr.labels"
  printf '%s\n' "$2" > "$STUB_DIR/evidence"
  [ -z "${3:-}" ] || echo "$3" > "$STUB_DIR/recover.rc"
  [ -z "${4:-}" ] || echo "$4" > "$STUB_DIR/evidence.rc"
  OUT="$(bash "$GS/talos.sh" gate merge 9 42 2>/dev/null)"
}
EVID="evidence role=qa label=qa:pass state=present
evidence role=reviewer label=review:approved state=lost
evidence role=security label=security:approved state=missing
evidence role=adversarial label=adversarial:approved state=missing
evidence role=docs label=docs:done state=missing"
gate "qa:pass pipeline:review" "$EVID"
assert_contains "$(cat "$STUB_DIR/journal")" "post-approval 9 reviewer --recover-only" "AC4 the lost reviewer stamp is recovered through post-approval --recover-only"
assert_not_contains "$(cat "$STUB_DIR/journal")" "post-approval 9 security" "AC4 the never-earned security stamp is never re-applied"
assert_contains "$OUT" "verdict=wait" "AC4 the gate waits on the never-earned role"
assert_contains "$OUT" "missing=security:approved" "AC4 missing= names only the never-earned label"
assert_contains "$OUT" "never_approved=security" "AC4 never_approved= names its role"
assert_not_contains "$(cat "$STUB_DIR/journal")" "recover-only --issue" "AC4 the recovery call carries no --issue, so it tags no worktree"

# never_approved= is for the roles with no evidence only. A lost stamp whose
# re-apply failed stays in missing=; so does a label the evidence shows as present.
gate "qa:pass pipeline:review" "$EVID" 1
assert_contains "$OUT" "verdict=wait" "AC4 a failed recovery waits"
assert_contains "$OUT" "missing=review:approved,security:approved" "AC4 a failed recovery leaves the lost label in missing="
assert_eq "never_approved=security" "$(grep '^never_approved=' <<<"$OUT")" "AC4 never_approved= does not name a lost role whose recovery failed"
assert_not_contains "$OUT" "recovered=" "AC4 a failed recovery is not reported as recovered"
gate "qa:pass pipeline:review" "$EVID" "" 1
assert_contains "$OUT" "verdict=wait" "AC4 a failed evidence read waits"
assert_contains "$OUT" "missing=review:approved,security:approved" "AC4 a failed evidence read leaves every missing label in missing="
assert_not_contains "$OUT" "never_approved=" "AC4 a failed evidence read names no role as never approved"
assert_not_contains "$(cat "$STUB_DIR/journal")" "post-approval" "AC4 a failed evidence read re-applies nothing"

EVID5="evidence role=qa label=qa:pass state=present
evidence role=reviewer label=review:approved state=lost
evidence role=security label=security:approved state=present
evidence role=adversarial label=adversarial:approved state=missing
evidence role=docs label=docs:done state=missing"
gate "qa:pass security:approved pipeline:review" "$EVID5"
assert_contains "$OUT" "recovered=reviewer" "AC5 a recovered stamp is named"
assert_not_contains "$OUT" "reason=approvals-missing" "AC5 with every stamp back, the gate goes on"
assert_contains "$(cat "$STUB_DIR/journal")" "check-approval-sha 9 --stale-list" "AC5 the gate goes on to its stale check"
# The security label is off the PR although the evidence read saw it (it landed
# between the two reads): the gate waits one more run, and blames no role.
gate "qa:pass pipeline:review" "$EVID5"
assert_contains "$OUT" "missing=security:approved" "AC4 a label the evidence shows as present but the PR read missed still waits"
assert_not_contains "$OUT" "never_approved=" "AC4 never_approved= does not name a role the evidence shows as present"

# ── AC6: the collect's routing ───────────────────────────────────────────────
SCR="$SANDBOX/cs"
FX="$SANDBOX/fx"
export SF_FX="$FX"
mkdir -p "$FX"
cp -R "$TALOS_ROOT/scripts" "$SCR"
cat > "$SCR/pipeline-vcs.sh" <<'TALOS_srCollectVcs5Rp'
#!/usr/bin/env bash
FX="${SF_FX:?}"
verb="${1:-}"; shift
printf '%s %s\n' "$verb" "$*" >> "$FX/calls.log"
case "$verb" in
  list-prs) cat "$FX/prs.json" ;;
  list-issues) echo '[{"number": 12, "title": "i", "labels": [{"name": "pipeline:review"}], "body": ""}]' ;;
  pr-head) echo 0123456789abcdef0123456789abcdef01234567 ;;
  check-approval-sha)
    case " $* " in
      *" --evidence-list "*) [ ! -f "$FX/evidence.rc" ] || exit "$(cat "$FX/evidence.rc")"; cat "$FX/evidence" ;;
      *) echo "check-approval-sha: all approval labels are current" ;;
    esac ;;
  pr-checks-required) exit 0 ;;
  pr-is-draft) [ ! -f "$FX/draft" ] || exit 0; echo ready; exit 1 ;;
  current-user) exit 1 ;;
  list-needs-owner) echo '[]' ;;
  *) exit 99 ;;
esac
TALOS_srCollectVcs5Rp
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main", "pr": {"draft": false}, "roles": {"docs": false}, "merge": {"auto": true}}\n' > "$PIPELINE_CONFIG"
printf '[{"number": 12, "title": "PR 12", "headRefName": "fix/issue-12-x", "baseRefName": "main", "isCrossRepository": false, "labels": [{"name": "pipeline:review"}, {"name": "qa:pass"}, {"name": "security:approved"}]}]' > "$FX/prs.json"
stage12() { bash "$SCR/pipeline-status-file.sh" collect 2>/dev/null | python3 -I -c 'import json, sys; print([p["stage"] for p in json.load(sys.stdin)["prs"] if p["n"] == 12][0])'; }
printf '%s\n' "$EVID5" > "$FX/evidence"
assert_eq "merge" "$(stage12)" "AC6 a PR whose only missing approval is lost is not routed to that role"
printf '%s\n' "$EVID5" | sed 's/role=reviewer label=review:approved state=lost/role=reviewer label=review:approved state=missing/' > "$FX/evidence"
assert_eq "reviewer" "$(stage12)" "AC6 control: with no evidence the missing role is the stage, as today"
echo 1 > "$FX/evidence.rc"
bash "$SCR/pipeline-status-file.sh" collect > /dev/null 2> "$SANDBOX/collect.err"; RC=$?
assert_eq "1" "$RC" "AC6 a failed evidence read ends the collect, it never routes on a guess"
assert_contains "$(cat "$SANDBOX/collect.err")" "check-approval-sha --evidence-list failed for PR #12" "AC6 the failed evidence read is named"
rm -f "${FX:?}/evidence.rc"

# The draft window's QA pre-CI gate (pr.ready_gate qa-local) routes qa last, in
# its own branch: a lost qa:pass is not a reason to run QA again there either.
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main", "pr": {"draft": true, "ready_gate": "qa-local"}, "roles": {"docs": false}, "merge": {"auto": true}}\n' > "$PIPELINE_CONFIG"
printf '[{"number": 12, "title": "PR 12", "headRefName": "fix/issue-12-x", "baseRefName": "main", "isCrossRepository": false, "labels": [{"name": "pipeline:review"}, {"name": "review:approved"}, {"name": "security:approved"}]}]' > "$FX/prs.json"
: > "$FX/draft"
EVIDQ="evidence role=qa label=qa:pass state=lost
evidence role=reviewer label=review:approved state=present
evidence role=security label=security:approved state=present
evidence role=adversarial label=adversarial:approved state=missing
evidence role=docs label=docs:done state=missing"
printf '%s\n' "$EVIDQ" > "$FX/evidence"
assert_eq "ready" "$(stage12)" "AC6 a draft PR whose qa:pass is lost is not routed to qa again"
printf '%s\n' "$EVIDQ" | sed 's/role=qa label=qa:pass state=lost/role=qa label=qa:pass state=missing/' > "$FX/evidence"
assert_eq "qa" "$(stage12)" "AC6 control: a draft PR with no qa evidence routes qa, as today"

finish
