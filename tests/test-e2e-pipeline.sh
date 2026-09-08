#!/usr/bin/env bash
# E2E pipeline simulation: install Talos into a fresh repo, then drive one
# issue through the full lifecycle the orchestrator skill prescribes —
# labels → validator → pm → developer/PR → qa → reviewer → security → docs →
# merge → close — using the INSTALLED scripts against stubbed gh/curl.
# Asserts the externally visible protocol: gh calls, chat payloads, threading.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs
install_talos

VCS="$HOME/.talos/scripts/pipeline-vcs.sh"
NOTIFY="$HOME/.talos/scripts/pipeline-notify.sh"
STATUS="$HOME/.talos/scripts/pipeline-status.sh"
export PIPELINE_THREAD_STATE="$SANDBOX/threads.json"
export SLACK_BOT_TOKEN=xoxb-test PIPELINE_SLACK_CHANNEL=C0TEST
export STUB_ISSUE_TITLE="Fix login crash" STUB_PR_TITLE="fix: guard null session"
export PIPELINE_ISSUE_TITLE="$STUB_ISSUE_TITLE"

cat > talos.pipeline.json <<'EOF'
{"board": {"enabled": true, "project_number": 7, "owner": "acme"}}
EOF

N=42

# ── Stage 0: bootstrap + dispatch ────────────────────────────────────────────
bash "$HOME/.talos/scripts/bootstrap-labels.sh" acme/widget >/dev/null
bash "$NOTIFY" dispatched "#$N" "kickoff" "$N" >/dev/null 2>&1

# ── Stage 1: validator confirms ──────────────────────────────────────────────
bash "$VCS" label-issue "$N" --add pipeline:confirmed --remove pipeline:ready >/dev/null 2>&1
bash "$VCS" comment-issue "$N" "**Agent:** validator — CONFIRMED: crash reproducible" >/dev/null 2>&1
bash "$STATUS" "$N" "In progress" >/dev/null 2>&1
bash "$NOTIFY" validator "#$N" "CONFIRMED: crash reproducible in auth.js:88" "$N" >/dev/null 2>&1

# ── Stage 2: pm spec, developer opens PR ─────────────────────────────────────
bash "$VCS" comment-issue "$N" "spec: guard null session in auth.js" >/dev/null 2>&1
bash "$VCS" label-issue "$N" --add pipeline:dev --remove pipeline:confirmed >/dev/null 2>&1
echo "Closes #$N" > pr-body.md
bash "$VCS" create-pr "fix/issue-$N" "fix: guard null session" pr-body.md >/dev/null 2>&1
PIPELINE_PR=9 PIPELINE_PR_TITLE="$STUB_PR_TITLE" \
  bash "$NOTIFY" pr-opened "#$N" "PR https://github.com/acme/widget/pull/9 opened" "$N" >/dev/null 2>&1

# ── Stage 3: qa / reviewer / security / docs sign off on the PR ──────────────
bash "$VCS" comment-pr 9 "QA: PASS — all acceptance criteria verified" >/dev/null 2>&1
bash "$VCS" label-pr 9 --add qa:pass >/dev/null 2>&1
bash "$VCS" approve-pr 9 "LGTM" >/dev/null 2>&1
bash "$VCS" label-pr 9 --add review:approved --add security:approved --add docs:done >/dev/null 2>&1
bash "$NOTIFY" qa "#$N" "PASS: criteria verified" "$N" >/dev/null 2>&1

# ── Stage 4: merge gates, then merge + close ─────────────────────────────────
# Reconciliation verb: a fresh session must be able to find the PR for #42
adopt="$(bash "$VCS" find-pr "$N")"
assert_contains "$adopt" '"headRefName": "fix/issue-42-guard"' \
  "e2e: find-pr locates the in-flight PR for adoption"

# Forbidden-files gate passes for a clean PR, blocks a secret-touching one
bash "$VCS" check-pr-files 9 >/dev/null 2>&1 \
  && pass "e2e: forbidden-files gate passes clean PR" \
  || fail "e2e: forbidden-files gate passes clean PR"
STUB_PR_FILES=".env" bash "$VCS" check-pr-files 9 >/dev/null 2>&1 \
  && fail "e2e: forbidden-files gate blocks .env" \
  || pass "e2e: forbidden-files gate blocks .env"

bash "$VCS" merge-pr 9 >/dev/null 2>&1
bash "$VCS" close-issue "$N" "resolved by PR #9" >/dev/null 2>&1
bash "$STATUS" "$N" "Done" >/dev/null 2>&1
PIPELINE_PR=9 bash "$NOTIFY" merged "#$N" "PR #9 merged" "$N" >/dev/null 2>&1
bash "$NOTIFY" issue-closed "#$N" "item resolved" "$N" >/dev/null 2>&1

# ── Assertions: VCS side ─────────────────────────────────────────────────────
log="$(cat "$GH_LOG")"
# NB: real-run label-issue goes through eval, so the shell strips the quotes
assert_contains "$log" "issue edit $N --add-label pipeline:confirmed --remove-label pipeline:ready" \
  "e2e: label state machine ready→confirmed"
assert_contains "$log" "issue comment $N --body **Agent:** validator — CONFIRMED: crash reproducible" \
  "e2e: validator findings comment lands on the issue"
assert_contains "$log" "pr create --base main --head fix/issue-$N" "e2e: PR opened against base branch"
assert_contains "$log" "issue comment 9 --body QA: PASS" "e2e: QA verdict lands on the PR"
assert_contains "$log" "pr review 9 --approve" "e2e: reviewer approval posted"
assert_contains "$log" "pr merge 9 --squash --delete-branch" "e2e: PR squash-merged"
assert_contains "$log" "issue close $N" "e2e: issue closed at the end"
assert_contains "$log" "project item-edit --id ITEM_42" "e2e: board status updated"

# ── Assertions: chat side — one thread, links, complete conversation ─────────
payloads="$(cut -f2 "$CURL_LOG")"
roots="$(grep -c -v thread_ts "$CURL_LOG" || true)"
assert_eq "1" "$roots" "e2e: exactly one root post — all later events threaded"
assert_contains "$payloads" '"thread_ts": "1111.2222"' "e2e: replies reference the dispatch anchor"
assert_contains "$payloads" "New comment by validator agent on #$N: $STUB_ISSUE_TITLE" \
  "e2e: validator relay rendered from template"
assert_contains "$payloads" "<https://github.com/acme/widget/issues/$N|" "e2e: issue link present in thread"
assert_contains "$payloads" "<https://github.com/acme/widget/pull/9|" "e2e: PR link present in thread"
assert_contains "$payloads" "merged, work complete" "e2e: merged template rendered"
assert_contains "$payloads" "closed" "e2e: issue-closed event announced"

# Message count: dispatched, validator, pr-opened, qa, merged, issue-closed = 6
assert_eq "6" "$(wc -l < "$CURL_LOG" | tr -d ' ')" "e2e: six chat messages, no dupes or drops"

# ── Step 1.6: epic auto-close sweep gate (#168) ──────────────────────────────
# An epic whose children have all closed must NOT auto-close while its own
# `- [ ]` acceptance boxes are still unticked; it gets pipeline:epic-children-done
# and a comment instead, and stays open. An epic with all boxes ticked (or no
# checkboxes) still closes exactly as before.

# Epic #100: all sub-issues closed, but the epic's own body has an unticked box.
: > "$GH_LOG"
export STUB_EPIC_BODY='Epic description.

- [ ] Bring the full stack up and prove it communicates'
bash "$VCS" check-epic-acceptance 100 >/dev/null 2>&1
sweep_rc=$?
if [ "$sweep_rc" -ne 0 ]; then
  bash "$VCS" label-issue 100 --add pipeline:epic-children-done >/dev/null 2>&1
  bash "$VCS" comment-issue 100 "All sub-issues are closed, but this epic's own acceptance criteria still have unticked boxes -- needs human review:
- Bring the full stack up and prove it communicates" >/dev/null 2>&1
fi
sweep_log="$(cat "$GH_LOG")"
assert_contains "$sweep_log" "issue edit 100 --add-label pipeline:epic-children-done" \
  "e2e: epic with unticked boxes gets pipeline:epic-children-done"
assert_contains "$sweep_log" "issue comment 100" \
  "e2e: epic with unticked boxes gets a comment naming what's outstanding"
assert_not_contains "$sweep_log" "issue close 100" \
  "e2e: epic with unticked boxes is NOT closed"

# Epic #200: all sub-issues closed, and every acceptance box is ticked.
: > "$GH_LOG"
export STUB_EPIC_BODY='Epic description.

- [x] Bring the full stack up and prove it communicates'
bash "$VCS" check-epic-acceptance 200 >/dev/null 2>&1
sweep_rc=$?
if [ "$sweep_rc" -eq 0 ]; then
  bash "$VCS" close-issue 200 "All sub-issues resolved." >/dev/null 2>&1
fi
sweep_log="$(cat "$GH_LOG")"
assert_contains "$sweep_log" "issue close 200" \
  "e2e: epic with all boxes ticked still closes"
assert_not_contains "$sweep_log" "epic-children-done" \
  "e2e: epic with all boxes ticked does not get pipeline:epic-children-done"

# Epic #300: all sub-issues closed, and the epic has no checkboxes at all.
: > "$GH_LOG"
export STUB_EPIC_BODY='Epic description with no checklist at all.'
bash "$VCS" check-epic-acceptance 300 >/dev/null 2>&1
sweep_rc=$?
if [ "$sweep_rc" -eq 0 ]; then
  bash "$VCS" close-issue 300 "All sub-issues resolved." >/dev/null 2>&1
fi
sweep_log="$(cat "$GH_LOG")"
assert_contains "$sweep_log" "issue close 300" \
  "e2e: epic with no checkboxes still closes"

# ── Idempotency across repeated sweeps (PR #190 reviewer finding) ───────────
# The label+comment action must fire exactly once per epic, not on every
# sweep, while check-epic-acceptance keeps running every sweep so an epic
# whose boxes get ticked later still auto-closes -- and the flag label gets
# removed on that close (mirrors the "does NOT yet carry pipeline:ready"
# guard idiom Step 1.7 already uses).
epic400_labeled=false

sweep_epic_400() {
  local items rc
  items="$(bash "$VCS" check-epic-acceptance 400 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    bash "$VCS" close-issue 400 "All sub-issues resolved." >/dev/null 2>&1
    if [ "$epic400_labeled" = "true" ]; then
      bash "$VCS" label-issue 400 --remove pipeline:epic-children-done >/dev/null 2>&1
      epic400_labeled=false
    fi
  else
    if [ "$epic400_labeled" != "true" ]; then
      bash "$VCS" label-issue 400 --add pipeline:epic-children-done >/dev/null 2>&1
      bash "$VCS" comment-issue 400 "All sub-issues are closed, but this epic's own acceptance criteria still have unticked boxes -- needs human review:
- Bring the full stack up and prove it communicates" >/dev/null 2>&1
      epic400_labeled=true
    fi
  fi
}

: > "$GH_LOG"
export STUB_EPIC_BODY='Epic description.

- [ ] Bring the full stack up and prove it communicates'
sweep_epic_400   # sweep 1: unticked -> labels + comments
sweep_epic_400   # sweep 2: still unticked, already labeled -> must not repeat

sweep_log="$(cat "$GH_LOG")"
label_calls="$(grep -c "issue edit 400 --add-label pipeline:epic-children-done" <<<"$sweep_log")"
comment_calls="$(grep -c "issue comment 400" <<<"$sweep_log")"
assert_eq "1" "$label_calls" \
  "e2e: two sweeps of a still-unticked epic add pipeline:epic-children-done exactly once"
assert_eq "1" "$comment_calls" \
  "e2e: two sweeps of a still-unticked epic comment exactly once"

# Sweep 3: a human ticks the box since the last sweep -> the epic auto-closes
# and the flag label added earlier is removed.
: > "$GH_LOG"
export STUB_EPIC_BODY='Epic description.

- [x] Bring the full stack up and prove it communicates'
sweep_epic_400
sweep_log="$(cat "$GH_LOG")"
assert_contains "$sweep_log" "issue close 400" \
  "e2e: epic closes once its boxes are ticked on a later sweep"
assert_contains "$sweep_log" "issue edit 400 --remove-label pipeline:epic-children-done" \
  "e2e: pipeline:epic-children-done is removed once the epic closes"

# ── Untrusted checklist text must never reach a shell command literal ───────
# (PR #190 security finding, HIGH). check-epic-acceptance's stdout is
# unescaped text taken straight from the epic body -- reporter-controlled.
# The sweep must capture it into a variable and render it through the
# templates/comments recipe, then pass the fully-rendered variable to
# comment-issue -- never splice the item text into a command string.
: > "$GH_LOG"
rm -f INJECTED_MARKER
export STUB_EPIC_BODY='Epic description.

- [ ] " ; touch INJECTED_MARKER #'
items="$(bash "$VCS" check-epic-acceptance 500 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  TMPL="$HOME/.talos/templates/comments/epic-acceptance-pending.md"
  comment_body="$(
    HEADER='**Agent:** orchestrator (talos)' DETAILS="$items" \
    python3 -c "
import os, string, sys
with open(sys.argv[1]) as f:
    t = string.Template(f.read())
print(t.safe_substitute(os.environ).strip())
" "$TMPL"
  )"
  bash "$VCS" comment-issue 500 "$comment_body" >/dev/null 2>&1
fi
sweep_log="$(cat "$GH_LOG")"
assert_contains "$sweep_log" '" ; touch INJECTED_MARKER #' \
  "e2e: malicious checklist text is rendered verbatim in the posted comment"
if [ -f INJECTED_MARKER ]; then
  fail "e2e: checklist metacharacters must never execute during the sweep"
else
  pass "e2e: checklist metacharacters do not execute during the sweep"
fi

unset STUB_EPIC_BODY

# ── #195: verify: runs once per PR; QA trusts CI under qa_mode: ci ──────────
# Stub-driven simulation of the developer + QA verify policy this playbook
# documents (skills/pipeline/SKILL.md 3c/3d, agents/developer.md, agents/qa.md):
# the developer runs the full verify: list exactly once, immediately before
# its final commit -- targeted iteration (verify.targeted) never shows up
# here, only the one required run does. QA does not run verify: at all under
# qa_mode: ci (it polls pr-checks in the foreground instead, fail-closed) and
# runs it exactly once more under qa_mode: local. Uses the `verify` PATH stub
# (tests/stubs/verify, logs to $VERIFY_LOG) the same way GH_LOG/CURL_LOG track
# gh/curl invocations, and the gh stub's "pr checks" case for the CI oracle.
CFG="$HOME/.talos/scripts/pipeline-config.sh"

simulate_developer_verify() {
  verify >/dev/null
}

simulate_qa_verify() {  # $1 = qa_mode ("ci" | "local")
  if [ "$1" = "local" ]; then
    verify >/dev/null
    return 0
  fi
  # ci: never run verify: locally -- poll pr-checks in the foreground,
  # bounded (no sleep-loop workaround), fail closed on anything but "pass".
  local out i=0
  while [ "$i" -lt 3 ]; do
    out="$(bash "$VCS" pr-checks 9 2>&1)"
    case "$out" in
      *$'\t'pass$'\t'*) return 0 ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# qa_mode resolves to ci when merge.required_checks is non-empty: developer
# runs verify: once, QA runs it zero times -- at most 1 execution total.
cat > talos.pipeline.json <<'EOF'
{"merge": {"required_checks": ["test"]}}
EOF
qa_mode="$(bash "$CFG" verify.qa_mode local)"
assert_eq "ci" "$qa_mode" \
  "e2e: verify.qa_mode resolves to ci when merge.required_checks is set (#195)"
: > "$VERIFY_LOG"
simulate_developer_verify
simulate_qa_verify "$qa_mode" >/dev/null 2>&1
qa_rc=$?
count_ci="$(wc -l < "$VERIFY_LOG" | tr -d ' ')"
assert_eq "1" "$count_ci" \
  "e2e: verify: runs at most once per PR under qa_mode: ci (#195)"
assert_eq "0" "$qa_rc" \
  "e2e: QA passes under qa_mode: ci when pr-checks is green (#195)"

# qa_mode: local (no required_checks configured) -- developer runs verify:
# once, QA runs it once more -- at most 2 executions total, never more.
rm -f talos.pipeline.json
qa_mode="$(bash "$CFG" verify.qa_mode local)"
assert_eq "local" "$qa_mode" \
  "e2e: verify.qa_mode resolves to local when merge.required_checks is empty/absent (#195)"
: > "$VERIFY_LOG"
simulate_developer_verify
simulate_qa_verify "$qa_mode" >/dev/null 2>&1
count_local="$(wc -l < "$VERIFY_LOG" | tr -d ' ')"
assert_eq "2" "$count_local" \
  "e2e: verify: runs at most twice per PR under qa_mode: local (#195)"

# qa_mode: ci, pr-checks NOT green -- QA fails closed and still never runs
# verify: locally (the whole point of trusting CI as the oracle).
cat > talos.pipeline.json <<'EOF'
{"merge": {"required_checks": ["test"]}}
EOF
: > "$VERIFY_LOG"
simulate_developer_verify
STUB_PR_CHECKS="$(printf 'test\tfail\t1m2s\thttps://example/checks')" STUB_PR_CHECKS_EXIT=1 \
  simulate_qa_verify ci >/dev/null 2>&1
qa_rc=$?
count_ci_fail="$(wc -l < "$VERIFY_LOG" | tr -d ' ')"
assert_eq "1" "$count_ci_fail" \
  "e2e: QA under qa_mode: ci never runs verify: even when pr-checks is red (#195)"
if [ "$qa_rc" -ne 0 ]; then
  pass "e2e: QA fails closed under qa_mode: ci when pr-checks is not green (#195)"
else
  fail "e2e: QA fails closed under qa_mode: ci when pr-checks is not green (#195)"
fi
rm -f talos.pipeline.json

# qa_mode: ci explicitly set, but required_checks is empty -- the fail-open
# trap from review finding #3: trusting CI as the oracle for an empty check
# list would let QA pass vacuously without ever running verify: or observing
# a real CI signal. pipeline-config.sh resolves this combination to "local"
# instead, so QA must fall back to running verify: once itself, exactly like
# genuine qa_mode: local -- not pass without running anything.
cat > talos.pipeline.json <<'EOF'
{"merge": {"required_checks": []}, "verify": {"qa_mode": "ci"}}
EOF
qa_mode="$(bash "$CFG" verify.qa_mode local 2>/dev/null)"
assert_eq "local" "$qa_mode" \
  "e2e: explicit qa_mode: ci with empty required_checks resolves to local, not a vacuous ci pass (#195)"
: > "$VERIFY_LOG"
simulate_developer_verify
simulate_qa_verify "$qa_mode" >/dev/null 2>&1
qa_rc=$?
count_fail_open="$(wc -l < "$VERIFY_LOG" | tr -d ' ')"
assert_eq "2" "$count_fail_open" \
  "e2e: qa_mode: ci with empty required_checks -- QA runs verify: once (local behavior), not zero times (#195)"
assert_eq "0" "$qa_rc" \
  "e2e: qa_mode: ci with empty required_checks -- QA passes only after actually running verify: (#195)"
rm -f talos.pipeline.json

# ── #196: selective stage re-runs -- only stale roles re-dispatch ────────────
# Stub-driven simulation of the SKILL.md Step 4 Approval-SHA gate decision
# list: strip only the labels `check-approval-sha --stale-list` reports stale,
# dispatch qa/reviewer/security whenever stale, and dispatch docs only when
# the delta since its approved SHA touches a docs-relevant path -- otherwise
# re-stamp docs:done directly with no subagent dispatch.
_ALL4_LABELS_196='[{"name":"qa:pass"},{"name":"review:approved"},{"name":"security:approved"},{"name":"docs:done"}]'

is_docs_relevant_delta() {  # $1 = base sha, $2 = head sha
  local changed f
  changed="$(git diff --name-only "$1..$2")"
  for f in $changed; do
    case "$f" in
      tests/*) continue ;;
      README.md|docs/*|CHANGELOG.md|templates/*|*.md) return 0 ;;
    esac
  done
  return 1
}

simulate_selective_redispatch() {  # $1=base sha $2=head sha $3=comments JSON $4=labels JSON (default: all four)
  local labels="${4:-$_ALL4_LABELS_196}"
  local stale_out role
  stale_out="$(STUB_PR_HEAD_SHA="$2" STUB_PR_LABELS_JSON="$labels" STUB_PR_COMMENTS_JSON="$3" \
               bash "$VCS" check-approval-sha 9 --stale-list 2>/dev/null)"
  while IFS= read -r line; do
    case "$line" in
      "stale role="*)
        role="${line#stale role=}"; role="${role%% label=*}"
        case "$role" in
          qa)       echo "dispatch:qa"       >> "$DISPATCH_LOG" ;;
          reviewer) echo "dispatch:reviewer" >> "$DISPATCH_LOG" ;;
          security) echo "dispatch:security" >> "$DISPATCH_LOG" ;;
          docs)
            if is_docs_relevant_delta "$1" "$2"; then
              echo "dispatch:docs" >> "$DISPATCH_LOG"
            else
              echo "restamp:docs" >> "$DISPATCH_LOG"
            fi
            ;;
        esac
        ;;
    esac
  done <<< "$stale_out"
}

# Real commits in the sandbox repo: all four approvals earned at SHA_BASE,
# then a fix commit that touches only scripts/x.sh (non-waivable, docs-irrelevant).
printf 'base\n' > base.txt
git add base.txt
git commit -q -m "base commit"
SHA_BASE="$(git rev-parse HEAD)"
mkdir -p scripts
printf '#!/bin/bash\necho fix\n' > scripts/x.sh
git add scripts/x.sh
git commit -q -m "fix: guard null session (scripts/x.sh only)"
SHA_FIX="$(git rev-parse HEAD)"

_all4_markers='[{"body":"<!-- talos:approval sha=BASESHA role=qa -->"},{"body":"<!-- talos:approval sha=BASESHA role=reviewer -->"},{"body":"<!-- talos:approval sha=BASESHA role=security -->"},{"body":"<!-- talos:approval sha=BASESHA role=docs -->"}]'
_all4_markers="${_all4_markers//BASESHA/$SHA_BASE}"

DISPATCH_LOG="$SANDBOX/dispatch.log"
: > "$DISPATCH_LOG"
simulate_selective_redispatch "$SHA_BASE" "$SHA_FIX" "$_all4_markers"

dispatch_out="$(cat "$DISPATCH_LOG")"
assert_contains "$dispatch_out" "dispatch:qa"       "e2e #196: scripts/x.sh-only fix re-dispatches QA"
assert_contains "$dispatch_out" "dispatch:reviewer" "e2e #196: scripts/x.sh-only fix re-dispatches reviewer"
assert_contains "$dispatch_out" "dispatch:security" "e2e #196: scripts/x.sh-only fix re-dispatches security"
assert_not_contains "$dispatch_out" "dispatch:docs" "e2e #196: scripts/x.sh-only fix does NOT dispatch docs"
assert_contains "$dispatch_out" "restamp:docs"       "e2e #196: docs is re-stamped instead of dispatched"
assert_eq "1" "$(grep -c '^dispatch:qa$' "$DISPATCH_LOG")"       "e2e #196: QA dispatched exactly once"
assert_eq "1" "$(grep -c '^dispatch:reviewer$' "$DISPATCH_LOG")" "e2e #196: reviewer dispatched exactly once"
assert_eq "1" "$(grep -c '^dispatch:security$' "$DISPATCH_LOG")" "e2e #196: security dispatched exactly once"
assert_eq "0" "$(grep -c '^dispatch:docs$' "$DISPATCH_LOG")"     "e2e #196: docs dispatch count is zero"

# Counter-case: a docs-relevant delta DOES re-dispatch docs. README.md alone
# is fully waivable (covered by DEFAULT_WAIVER for every role, docs included)
# so it would never show up as stale on its own -- pair it with a non-waivable
# scripts/ change so the label goes stale at all, same as the primary case,
# but this time the stale delta also touches a docs-relevant path.
_orig_branch_196="$(git symbolic-ref --short HEAD)"
git checkout -q -b tmp-readme-fix-196 "$SHA_BASE"
printf 'updated readme\n' > README.md
mkdir -p scripts
printf '#!/bin/bash\necho other fix\n' > scripts/y.sh
git add README.md scripts/y.sh
git commit -q -m "fix: guard null session + update readme"
SHA_README="$(git rev-parse HEAD)"
git checkout -q "$_orig_branch_196"

_docs_only_marker='[{"body":"<!-- talos:approval sha=BASESHA role=docs -->"}]'
_docs_only_marker="${_docs_only_marker//BASESHA/$SHA_BASE}"
: > "$DISPATCH_LOG"
simulate_selective_redispatch "$SHA_BASE" "$SHA_README" "$_docs_only_marker" '[{"name":"docs:done"}]'
assert_contains "$(cat "$DISPATCH_LOG")" "dispatch:docs" \
  "e2e #196: README.md-touching delta DOES re-dispatch docs (counter-case)"
assert_not_contains "$(cat "$DISPATCH_LOG")" "restamp:docs" \
  "e2e #196: README.md-touching delta is NOT silently re-stamped (counter-case)"

# ── #196: docs stage never pushes an empty commit ────────────────────────────
# Stub-driven simulation of the docs commit guard (agents/docs.md /
# SKILL.md Docs prompt): before committing, check both the working tree and
# the index; if BOTH are clean, skip commit + push entirely and still apply
# docs:done via post-approval (which re-fetches the head SHA regardless).
COMMIT_LOG_BEFORE="$(git rev-parse HEAD)"
simulate_docs_commit_guard() {
  if git diff --quiet && git diff --quiet --cached; then
    echo "skip-commit-and-push"
    return 0
  fi
  git commit -q -m "docs: update for #$N"
  echo "committed"
}
guard_out="$(simulate_docs_commit_guard)"
COMMIT_LOG_AFTER="$(git rev-parse HEAD)"
assert_eq "skip-commit-and-push" "$guard_out" "e2e #196: docs guard skips commit when nothing changed"
assert_eq "$COMMIT_LOG_BEFORE" "$COMMIT_LOG_AFTER" "e2e #196: no new commit created (no empty commit, no push)"
# docs:done is still applied, independent of whether a commit was made.
bash "$VCS" label-pr 9 --add docs:done >/dev/null 2>&1
log="$(cat "$GH_LOG")"
assert_contains "$log" "pr edit 9 --add-label docs:done" "e2e #196: docs:done still applied when nothing to commit"

# ── #199: skip the PM stage when the issue body is already a usable spec ────
# Simulates the Step 3b decision this playbook prescribes: has-spec gates
# whether a PM subagent is ever dispatched for a pipeline:confirmed issue.
# This stub harness has no live-agent dispatcher to count real subagent
# spawns against, so a "**PM spec:**" comment on the issue stands in for one
# PM dispatch -- the skip path must post zero of them.
CFG_PM="$HOME/.talos/scripts/pipeline-config.sh"

simulate_stage_3b() {  # $1 = issue number
  local n="$1" skip_cfg
  skip_cfg="$(bash "$CFG_PM" roles.pm_skip_when_spec_present true)"
  if [ "$skip_cfg" = "true" ] && bash "$VCS" has-spec "$n" >/dev/null 2>&1; then
    bash "$VCS" comment-issue "$n" "**PM:** skipped, issue body is the spec" >/dev/null 2>&1
    bash "$VCS" label-issue "$n" --add pipeline:dev --remove pipeline:confirmed >/dev/null 2>&1
    return 0
  fi
  bash "$VCS" comment-issue "$n" "**PM spec:** goal, acceptance criteria, branch" >/dev/null 2>&1
  bash "$VCS" label-issue "$n" --add pipeline:dev --remove pipeline:confirmed >/dev/null 2>&1
  return 1
}

# (a) body has '## Acceptance criteria' + a checkbox -> zero PM dispatches,
#     issue reaches pipeline:dev directly.
: > "$GH_LOG"
export STUB_ISSUE_BODY='Goal: fix the thing.

## Acceptance criteria
- [ ] It is fixed'
simulate_stage_3b 601
log="$(cat "$GH_LOG")"
pm_calls="$(grep -c "PM spec:" <<<"$log" || true)"
assert_eq "0" "$pm_calls" "e2e: issue with acceptance criteria dispatches zero PM subagents (#199)"
assert_contains "$log" "**PM:** skipped, issue body is the spec" "e2e: skip comment posted (#199)"
assert_contains "$log" "issue edit 601 --add-label pipeline:dev --remove-label pipeline:confirmed" \
  "e2e: skip path advances straight to pipeline:dev (#199)"

# (b) body has no acceptance-criteria heading -> PM still runs (one dispatch).
: > "$GH_LOG"
export STUB_ISSUE_BODY='Just a plain description, no structure.'
simulate_stage_3b 602
log="$(cat "$GH_LOG")"
pm_calls="$(grep -c "PM spec:" <<<"$log" || true)"
assert_eq "1" "$pm_calls" "e2e: issue without acceptance criteria still dispatches PM (#199)"
assert_not_contains "$log" "PM:** skipped" "e2e: no skip comment when PM ran (#199)"

# (c) roles.pm_skip_when_spec_present: false -> PM dispatches even though the
#     body qualifies for the skip.
: > "$GH_LOG"
cat > talos.pipeline.json <<'EOF'
{"roles": {"pm_skip_when_spec_present": false}}
EOF
export STUB_ISSUE_BODY='Goal: fix the thing.

## Acceptance criteria
- [ ] It is fixed'
simulate_stage_3b 603
log="$(cat "$GH_LOG")"
pm_calls="$(grep -c "PM spec:" <<<"$log" || true)"
assert_eq "1" "$pm_calls" \
  "e2e: roles.pm_skip_when_spec_present: false restores PM dispatch even with criteria present (#199)"
rm -f talos.pipeline.json
unset STUB_ISSUE_BODY

# ── #200: lean docs stage -- gate dispatch on the developer's own diff ───────
# Simulates the SKILL.md Step 3e Phase 1 decision this playbook prescribes:
# under roles.docs_mode: auto, check pr-files before ever dispatching a docs
# subagent; under always, dispatch unconditionally exactly as before #200.
# This stub harness has no live-agent dispatcher to count real subagent
# spawns against, so a "**Docs:** posted" comment on the PR stands in for one
# docs dispatch -- the gated path must post zero of them.
DOCS_SHA_200="aabb1122ccdd3344eeff556677889900aabb1122"

docs_gate_matches() {  # $1 = newline-separated changed paths
  CHANGED="$1" python3 -c "
import os, sys
paths = [p for p in os.environ['CHANGED'].splitlines() if p.strip()]
has_changelog = 'CHANGELOG.md' in paths
has_readme = 'README.md' in paths
has_docs_dir = any(p.startswith('docs/') for p in paths)
cond1 = has_changelog and (has_readme or has_docs_dir)
allowed = ('scripts/', 'tests/')
non_changelog = [p for p in paths if p != 'CHANGELOG.md']
cond2 = has_changelog and bool(non_changelog) and all(p.startswith(allowed) for p in non_changelog)
sys.exit(0 if (cond1 or cond2) else 1)
"
}

simulate_stage_3e_phase1() {  # $1 = PR number, $2 = changed-paths (STUB_PR_FILES form)
  local pr="$1" files="$2" docs_mode
  docs_mode="$(bash "$CFG_PM" roles.docs_mode auto)"
  if [ "$docs_mode" = "always" ]; then
    bash "$VCS" comment-pr "$pr" "**Docs:** posted -- full diff (docs_mode: always)" >/dev/null 2>&1
    printf 'docs posted (always)\n' > docs-body-200.md
    STUB_PR_HEAD_SHA="$DOCS_SHA_200" bash "$VCS" post-approval "$pr" docs --body-file docs-body-200.md >/dev/null 2>&1
    rm -f docs-body-200.md
    return 0
  fi
  # Drive the gate off the real pr-files verb (#200), not a hand-rolled list --
  # this is what actually proves the new verb and the gate compose correctly.
  local changed
  changed="$(STUB_PR_FILES="$files" bash "$VCS" pr-files "$pr")"
  if docs_gate_matches "$changed"; then
    printf 'docs verified by developer diff (docs_mode: auto)\n' > docs-body-200.md
    STUB_PR_HEAD_SHA="$DOCS_SHA_200" bash "$VCS" post-approval "$pr" docs --body-file docs-body-200.md >/dev/null 2>&1
    rm -f docs-body-200.md
    return 0
  fi
  bash "$VCS" comment-pr "$pr" "**Docs:** posted -- filtered context (docs_mode: auto)" >/dev/null 2>&1
  printf 'docs posted (auto, dispatched)\n' > docs-body-200.md
  STUB_PR_HEAD_SHA="$DOCS_SHA_200" bash "$VCS" post-approval "$pr" docs --body-file docs-body-200.md >/dev/null 2>&1
  rm -f docs-body-200.md
}

# (a) scripts + tests + CHANGELOG -> gate matches -> zero docs dispatches,
#     docs:done still applied.
: > "$GH_LOG"
simulate_stage_3e_phase1 9 "$(printf 'scripts/x.sh\ntests/test-x.sh\nCHANGELOG.md')"
log="$(cat "$GH_LOG")"
docs_calls="$(grep -c "Docs:\*\* posted" <<<"$log" || true)"
assert_eq "0" "$docs_calls" \
  "e2e: scripts+tests+CHANGELOG PR dispatches zero docs subagents (#200)"
assert_contains "$log" "pr edit 9 --add-label docs:done" \
  "e2e: scripts+tests+CHANGELOG PR still reaches docs:done via direct stamp (#200)"
assert_contains "$log" "docs verified by developer diff (docs_mode: auto)" \
  "e2e: gate auto-stamp carries the synthetic summary text (#200)"

# (b) scripts only, no CHANGELOG -> gate does not match -> docs dispatches.
: > "$GH_LOG"
simulate_stage_3e_phase1 9 "$(printf 'scripts/x.sh\ntests/test-x.sh')"
log="$(cat "$GH_LOG")"
docs_calls="$(grep -c "Docs:\*\* posted" <<<"$log" || true)"
assert_eq "1" "$docs_calls" \
  "e2e: scripts-only PR (no CHANGELOG) dispatches docs exactly once (#200)"
assert_contains "$log" "filtered context" \
  "e2e: dispatched-under-auto docs run is flagged as filtered context, not full diff (#200)"
assert_contains "$log" "pr edit 9 --add-label docs:done" \
  "e2e: dispatched docs run still reaches docs:done (#200)"

# (b2) #211 review fix: the auto-skip prefix list is exactly scripts/** and
#      tests/** -- agents/** does NOT qualify, so a PR touching agents/x.md
#      plus CHANGELOG.md must still dispatch docs (the gate must not match).
: > "$GH_LOG"
simulate_stage_3e_phase1 9 "$(printf 'agents/x.md\nCHANGELOG.md')"
log="$(cat "$GH_LOG")"
docs_calls="$(grep -c "Docs:\*\* posted" <<<"$log" || true)"
assert_eq "1" "$docs_calls" \
  "e2e: #211 review fix -- agents/x.md + CHANGELOG.md dispatches docs (agents/ is not in the auto-skip list)"
assert_contains "$log" "filtered context" \
  "e2e: agents/x.md + CHANGELOG.md dispatched-under-auto docs run is filtered context, not the auto-stamp path"

# (c) roles.docs_mode: always -> docs dispatches regardless of files, even
#     when the same diff would have gated in auto mode.
: > "$GH_LOG"
cat > talos.pipeline.json <<'EOF'
{"roles": {"docs_mode": "always"}}
EOF
simulate_stage_3e_phase1 9 "$(printf 'scripts/x.sh\ntests/test-x.sh\nCHANGELOG.md')"
log="$(cat "$GH_LOG")"
docs_calls="$(grep -c "Docs:\*\* posted" <<<"$log" || true)"
assert_eq "1" "$docs_calls" \
  "e2e: docs_mode: always dispatches docs even for a gate-qualifying diff (#200)"
assert_contains "$log" "full diff" \
  "e2e: docs_mode: always uses the full-diff path, not the filtered one (#200)"
rm -f talos.pipeline.json

# ── #214: CONFLICTING PR never dispatches QA; ci-mode QA fails within one poll ──
# Stub-driven simulation of the SKILL.md Step 3c "Mergeability gate" (before
# Step 3d dispatches QA) and the QA-prompt's own pr-mergeable check
# (agents/qa.md step 2, SKILL.md 3d step 2). Both drive the real
# `pr-mergeable` verb against the gh stub's controllable `mergeable` field
# (STUB_PR_MERGEABLE, added on this branch): CONFLICTING (exit 1) must never
# reach QA, and must never let QA's own ci-mode poll touch pr-checks even
# once. Reuses simulate_qa_verify's pr-checks poll loop from #195 so a
# CONFLICTING short-circuit provably skips it (zero pr-checks calls logged).
simulate_pre_qa_mergeable_gate() {  # $1 = PR number
  local pr="$1" rc
  bash "$VCS" pr-mergeable "$pr" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "dispatch:developer-merge" >> "$DISPATCH_LOG"
  else
    echo "dispatch:qa" >> "$DISPATCH_LOG"
  fi
}

# (a) CONFLICTING -> zero QA dispatches, exactly one developer merge-base
#     dispatch. Once the merge lands and pr-mergeable settles MERGEABLE, the
#     gate is re-run and dispatches QA exactly once -- not zero, not twice.
: > "$DISPATCH_LOG"
STUB_PR_MERGEABLE="CONFLICTING" simulate_pre_qa_mergeable_gate 9
assert_eq "0" "$(grep -c '^dispatch:qa$' "$DISPATCH_LOG")" \
  "e2e: a CONFLICTING PR dispatches zero QA subagents (#214)"
assert_eq "1" "$(grep -c '^dispatch:developer-merge$' "$DISPATCH_LOG")" \
  "e2e: a CONFLICTING PR dispatches exactly one developer merge-base task (#214)"

STUB_PR_MERGEABLE="MERGEABLE" simulate_pre_qa_mergeable_gate 9
assert_eq "1" "$(grep -c '^dispatch:qa$' "$DISPATCH_LOG")" \
  "e2e: once the merge lands and pr-mergeable reports MERGEABLE, the gate dispatches QA exactly once (#214)"
assert_eq "1" "$(grep -c '^dispatch:developer-merge$' "$DISPATCH_LOG")" \
  "e2e: the earlier developer merge-base dispatch is not re-counted or duplicated (#214)"

# (b) qa_mode: ci -- QA's own pr-mergeable check on a CONFLICTING PR fails
#     within one poll: exactly one pr-mergeable call, zero pr-checks calls,
#     and the failure reason names the conflict.
cat > talos.pipeline.json <<'EOF'
{"merge": {"required_checks": ["test"]}}
EOF
qa_mode="$(bash "$CFG" verify.qa_mode local)"
assert_eq "ci" "$qa_mode" \
  "e2e: verify.qa_mode resolves to ci ahead of the CONFLICTING-PR QA check (#214)"

simulate_qa_ci_mode_conflicting() {  # $1 = PR number
  local pr="$1" rc
  bash "$VCS" pr-mergeable "$pr" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "FAIL: PR conflicts with base; no CI run will be scheduled"
    return 1
  fi
  simulate_qa_verify ci
}

: > "$GH_LOG"
out="$(STUB_PR_MERGEABLE="CONFLICTING" simulate_qa_ci_mode_conflicting 9)"
qa_rc=$?
log="$(cat "$GH_LOG")"
assert_eq "1" "$qa_rc" \
  "e2e: QA in ci mode fails within one poll on a CONFLICTING PR (#214)"
assert_contains "$out" "conflicts with base" \
  "e2e: QA's CONFLICTING-PR failure reason names the conflict (#214)"
assert_eq "1" "$(grep -c '^pr view 9 --json mergeable -q \.mergeable' <<<"$log")" \
  "e2e: QA in ci mode calls pr-mergeable exactly once on a CONFLICTING PR (#214)"
assert_eq "0" "$(grep -c '^pr checks 9' <<<"$log")" \
  "e2e: QA in ci mode never polls pr-checks after a CONFLICTING pr-mergeable result (#214)"
rm -f talos.pipeline.json

finish
