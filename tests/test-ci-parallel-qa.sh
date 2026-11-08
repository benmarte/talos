#!/usr/bin/env bash
# test-ci-parallel-qa.sh -- CI is the single full-suite run, in parallel with the
# final QA (#836, part A of #828).
#   AC1  with ci.parallel_with_qa on, the draft-complete pass calls ready-pr once and
#        dispatches QA with no pr-checks-required call between; a PR not at the ready
#        stage (a fix round) gets no ready-pr
#   AC2  with parallel_with_qa off, or no required_checks, today's order (the qa_mode ci wait before QA)
#   AC3  the defaults rows, and `pipeline-draft-check.sh ci-parallel` per its rule
#   AC4  the parallel QA prompt: no full-suite instruction, the CI wait after the local
#        checks and before post-approval; the verdict template and agents/qa.md name
#        the `CI per-job results` table
#   AC5  post-approval qa in parallel mode refuses on a missing / pending / failed
#        required check (no marker, no label) and posts when they are green
#   AC6  check-approval-sha --require-ci: exit 1 with the `ci:` line, no `stale role=`
#   AC7  a red known flake gets exactly one rerun-ci and is accepted when green; a second
#        red, a name outside the list or an existing marker is refused with no rerun
#   AC8  check-approval-sha without --require-ci is unchanged (pending CI never strips qa:pass)
#   AC9  a QA FAIL still runs draft-pr (done)
#   AC10 in parallel mode a gate merge ci-failed redispatch runs draft-pr first
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
DC="$TALOS_ROOT/scripts/pipeline-draft-check.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
ERR="$SANDBOX/stderr"
mkdir -p "$SANDBOX/proj" || exit 1   # no .github/workflows: the CI check answers `none`, draft stays true

# ── AC3: the defaults rows and the resolver ──────────────────────────────────
row() { ( . "$TALOS_ROOT/scripts/pipeline-defaults.sh"; _talos_defaults_row "$1"; printf '%s|%s|%s|%s' "$_TD_TYPE" "$_TD_DEFAULT" "$_TD_DERIVED" "$_TD_SCOPE" ); }
assert_eq "bool|true|-|any" "$(row ci.parallel_with_qa)" "AC3 ci.parallel_with_qa defaults true (bool, any)"
assert_eq "list||-|repo" "$(row ci.known_flakes)" "AC3 ci.known_flakes defaults empty (list, repo)"

# par_in JSON: prints "<value>|<stderr>".
par_in() {
  printf '%s\n' "$1" > "$SANDBOX/cfg.json"
  ( cd "$SANDBOX/proj" && PIPELINE_CONFIG="$SANDBOX/cfg.json" bash "$DC" ci-parallel 2>"$SANDBOX/err" | tr -d '\n'; printf '|%s' "$(cat "$SANDBOX/err")" )
}
BASE='"vcs":{"provider":"github"},"merge":{"required_checks":["ci-complete"]}'
assert_eq "true|" "$(par_in "{$BASE}")" "AC3 ci-parallel is true by default with required_checks, pr.draft and QA on"
assert_eq "false|" "$(par_in '{"vcs":{"provider":"github"},"ci":{"parallel_with_qa":false},"merge":{"required_checks":["ci-complete"]}}')" "AC3 parallel_with_qa false reads false"
ON='"ci":{"parallel_with_qa":true}'
assert_contains "$(par_in "{$BASE,$ON,\"pr\":{\"draft\":false}}")" "false|pipeline: ci.parallel_with_qa ignored: pr.draft is off" "AC3 pr.draft false reads false with one stderr line"
assert_contains "$(par_in "{$BASE,$ON,\"roles\":{\"qa\":false}}")" "false|pipeline: ci.parallel_with_qa ignored: roles.qa is off" "AC3 roles.qa off reads false with one stderr line"
assert_contains "$(par_in "{\"vcs\":{\"provider\":\"github\"},$ON}")" "false|pipeline: ci.parallel_with_qa ignored: merge.required_checks is empty" "AC3 no required_checks reads false with one stderr line"
assert_contains "$(par_in "{$BASE,$ON,\"pr\":{\"ready_gate\":\"qa-local\"}}")" "false|pipeline: ci.parallel_with_qa ignored: pr.ready_gate is qa-local" "AC3 pr.ready_gate qa-local reads false with one stderr line"
assert_eq "false|" "$(par_in '{"vcs":{"provider":"github"}}')" "AC3 a defaulted key with no required_checks reads false and silent"
assert_eq "false|" "$(par_in "{$BASE,\"pr\":{\"draft\":false}}")" "AC3 a defaulted key with pr.draft false reads false and silent"
assert_eq "false|" "$(par_in '{"vcs":{"provider":"github"},"ci":{"parallel_with_qa":false},"pr":{"draft":false}}')" "AC3 not asked for: false and silent"

# ── AC1: the draft-complete pass ─────────────────────────────────────────────
# A copied scripts dir with a journaling provider stub (the shape of test-draft-complete-qa-fresh.sh).
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR" "$SANDBOX/templates/prompts"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cp -R "$TALOS_ROOT/templates/prompts/." "$SANDBOX/templates/prompts/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="${1:-}"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
if [ -f "$d/hook.$key" ]; then . "$d/hook.$key"; fi
if [ "$key" = "list-prs" ] || [ "$key" = "list-needs-owner" ] || [ "$key" = "list-issues" ]; then printf "[]"; exit 0; fi
if [ "$n" = "hooks" ]; then cat > "$d/hooks.stdin"; fi
a1="${2:-}"
if [ -f "$d/$key.$a1.out" ]; then cat "$d/$key.$a1.out"
elif [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.$a1.rc" ]; then rc="$(cat "$d/$key.$a1.rc")"; elif [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
cat > "$GS/pipeline-agent.sh" <<'TALOS_stubagentRk4Vm8Zq'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
cat > "$d/agent.stdin"
printf "agent %s\n" "$1" >> "$d/journal"
if [ -f "$d/message.$1" ]; then cat "$d/message.$1"; fi
exit 0
TALOS_stubagentRk4Vm8Zq
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusHc6Wn2Bt'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
printf 'status-file collect\n' >> "$d/journal"
printf '%s' "$(cat "$d/collect.json" 2>/dev/null || echo '{}')"
TALOS_stubstatusHc6Wn2Bt
RUN="$GS/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
LEASE="$SANDBOX/.git/talos-lease.ledger"
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
rn() { OUT="$(bash "$RUN" run "$@" 2>"$ERR")"; RC=$?; }

# fixture <extra top-level config members> <collect stage>
fixture() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$LEASE" "${LEASE:?}.lock.d"
  printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": true}, "verify": {"qa_mode": "ci", "timeout_ms": 600000, "ci_wait_s": 900}, "merge": {"required_checks": ["test (ubuntu-latest)"]}%s}' "$1" \
    > "$SANDBOX/talos.pipeline.json"
  printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:review"}], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9"
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"%s"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' "$2" \
    > "$STUB_DIR/collect.json"
  printf ready > "$STUB_DIR/pr-is-draft.12.out"
  printf 1 > "$STUB_DIR/pr-is-draft.12.rc"
  printf 'PASS: verified\n' > "$STUB_DIR/message.qa"
  printf '{"labels": [{"name": "docs:done"}], "state": "open"}' > "$STUB_DIR/view-pr.12.out"
}
verbs() { journal | grep -E '^vcs (ready-pr|pr-checks-required) |^agent qa$' | sed -E 's/^vcs ([a-z-]+) .*/\1/; s/^agent qa$/qa/' | tr '\n' ' ' | sed 's/ $//'; }

fixture "" ready
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "ready-pr qa" "$(verbs)" "AC1 parallel: ready-pr once, then QA, no pr-checks-required in between"
assert_eq "1" "$(journal | grep -c '^vcs ready-pr 12')" "AC1 parallel: ready-pr is called exactly once"

fixture "" reviewer
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_not_contains "$(journal)" "vcs ready-pr" "AC1 a PR not at the ready stage (a fix round) gets no ready-pr"

fixture ', "ci": {"parallel_with_qa": false}' ready
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "ready-pr pr-checks-required qa" "$(verbs)" "AC2 parallel_with_qa false keeps today's order: the CI wait before QA"

fixture ', "merge": {"required_checks": []}' ready
TALOS_LEASE_TTL_S=1800 TALOS_NOW=11000 rn --max-iterations 1
assert_eq "ready-pr qa" "$(verbs)" "AC2 no required_checks keeps today's flow: qa_mode reads local, no CI wait, QA after ready-pr"

# AC9: a QA FAIL on a draft-window PR converts it back to a draft before the fix developer runs.
fixture "" ready
printf 'criterion 2 failed\n' > "$SANDBOX/sum"
OUT="$(bash "$RUN" done qa --issue 9 --pr 12 --verdict FAIL --summary-file "$SANDBOX/sum" --draft 2>"$ERR")"; RC=$?
assert_eq "1" "$(journal | grep -c '^vcs draft-pr 12')" "AC9 a QA FAIL still runs draft-pr before the fix developer is dispatched"

# ── AC4: the rendered QA prompt, the verdict template, the agent profile ─────
render_qa() {
  local o f
  o="$(cd "$SANDBOX" && bash "$TALOS_ROOT/scripts/talos.sh" prompt qa --issue 9 --pr 12 --worktree "$SANDBOX/proj")"
  f="${o#prompt_file=}"
  if [ -f "$f" ]; then cat "$f"; rm -f "${f:?}"; else printf '%s\n' "$o"; fi
}
TREE="$SANDBOX/tree"
mkdir -p "$TREE"
cp -R "$TALOS_ROOT/scripts" "$TREE/scripts"
cp -R "$TALOS_ROOT/templates" "$TREE/templates"
printf '#!/usr/bin/env bash\n[ "${1:-}" = pr-is-draft ] || exit 0\nprintf ready\nexit 1\n' > "$TREE/scripts/pipeline-vcs.sh"
render_tree() { local o f; o="$(cd "$SANDBOX" && bash "$TREE/scripts/talos.sh" prompt qa --issue 9 --pr 12 --worktree "$SANDBOX/proj")"; f="${o#prompt_file=}"; if [ -f "$f" ]; then cat "$f"; rm -f "${f:?}"; else printf '%s\n' "$o"; fi; }
printf '{"vcs":{"provider":"github"},"pr":{"draft":true},"verify":{"qa_mode":"ci","ci_wait_s":600},"merge":{"required_checks":["ci-complete"]}}' > "$SANDBOX/talos.pipeline.json"
par="$(render_tree)"
printf '{"vcs":{"provider":"github"},"pr":{"draft":true},"ci":{"parallel_with_qa":false},"verify":{"qa_mode":"ci","ci_wait_s":600},"merge":{"required_checks":["ci-complete"]}}' > "$SANDBOX/talos.pipeline.json"
seq="$(render_tree)"
assert_contains "$par" "CI per-job results" "AC4 the parallel prompt names the CI per-job results table"
assert_not_contains "$seq" "CI per-job results" "AC4 the sequential prompt is unchanged: no per-job table"
assert_not_contains "$par" "full verify" "AC4 the parallel prompt carries no full-suite instruction"
assert_contains "$par" "Never run the full suite" "AC4 the parallel prompt forbids the full suite"
wait_at="$(printf '%s\n' "$par" | grep -n 'pr-checks-required' | head -n 1 | cut -d: -f1)"
local_at="$(printf '%s\n' "$par" | grep -n 'qa-run' | head -n 1 | cut -d: -f1)"
post_at="$(printf '%s\n' "$par" | grep -n 'post-approval' | head -n 1 | cut -d: -f1)"
if [ -n "$wait_at" ] && [ -n "$local_at" ] && [ -n "$post_at" ] && [ "$local_at" -lt "$wait_at" ] && [ "$wait_at" -lt "$post_at" ]; then
  pass "AC4 the CI wait comes after the local checks and before post-approval"
else
  fail "AC4 the CI wait comes after the local checks and before post-approval (qa-run=$local_at wait=$wait_at post-approval=$post_at)"
fi
assert_contains "$(cat "$TALOS_ROOT/templates/comments/qa-verdict.md")" "CI per-job results" "AC4 the QA verdict template names the CI per-job results table"
assert_contains "$(cat "$TALOS_ROOT/agents/qa.md")" "CI per-job results" "AC4 agents/qa.md names the CI per-job results table"

# ── AC5 to AC7: post-approval and check-approval-sha against stubbed CI ──────
# A gh shim on top of the stock stub: the check-run read answers from $CI_STATE (one
# `<name> <pass|fail|pending>` per line) and a rerun of failed jobs logs itself and
# moves the state to $RERUN_TURNS (a state file's whole content) when that is set.
mkdir -p "$SANDBOX/bin"
export STUBS_DIR CI_STATE="$SANDBOX/ci.state" RERUN_LOG="$SANDBOX/rerun.log"
cat > "$SANDBOX/bin/gh" <<'TALOS_ghshimYd3Jp7Sx'
#!/usr/bin/env bash
case "$*" in
  "api -i"*"/check-runs"*)
    body="" n=0
    while read -r name st; do
      [ -n "$name" ] || continue
      case "$st" in
        pass) s=completed c='"success"' ;;
        pending) s=in_progress c=null ;;
        *) s=completed c='"failure"' ;;
      esac
      body="${body:+$body,}{\"name\":\"$name\",\"status\":\"$s\",\"conclusion\":$c}"; n=$((n + 1))
    done < "$CI_STATE"
    printf 'HTTP/2.0 200 OK\nX-Stub: 1\r\n\r\n{"total_count":%s,"check_runs":[%s]}\n' "$n" "$body" ;;
  "api -i"*"rerun-failed-jobs"*)
    cat > /dev/null 2>&1 < /dev/null
    echo rerun >> "$RERUN_LOG"
    [ -z "${RERUN_TURNS:-}" ] || printf '%b\n' "$RERUN_TURNS" > "$CI_STATE"
    printf 'HTTP/2.0 201 Created\nX-Stub: 1\r\n\r\n{}\n' ;;
  *) exec "$STUBS_DIR/gh" "$@" ;;
esac
TALOS_ghshimYd3Jp7Sx
chmod +x "$SANDBOX/bin/gh"
export PATH="$SANDBOX/bin:$PATH"
unset PIPELINE_CONFIG
cd "$SANDBOX/proj" || exit 1
git config user.email "test@talos.invalid"; git config user.name "talos-test"
SHA="aabb1122ccdd3344eeff556677889900aabb1122"
export STUB_PR_HEAD_SHA="$SHA" STUB_PR_BASE_REF_NAME=main STUB_CURRENT_USER=bot
CSTORE="$SANDBOX/cs.json"
export STUB_COMMENT_STORE="$CSTORE"
cfg_par() {  # <known_flakes JSON list> <parallel true|false>
  printf '{"vcs":{"provider":"github"},"pr":{"draft":true},"ci":{"parallel_with_qa":%s,"known_flakes":%s},"merge":{"required_checks":["unit","e2e"]},"verify":{"ci_wait_s":60}}' "$2" "$1" > talos.pipeline.json
}
# pa_run <ci state lines> [seed comments JSON]: post-approval qa; sets OUT, RC, and the logs.
pa_run() {
  printf '%b' "$1" > "$CI_STATE"
  printf '%s' "${2:-[]}" > "$CSTORE"
  : > "$GH_LOG"; : > "$RERUN_LOG"
  OUT="$(bash "$VCS" post-approval 9 qa 2>&1)"; RC=$?
}
wrote() { grep -c '/comments payload=\|/labels payload=' "$GH_LOG"; }
export STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]'

cfg_par '[]' true
pa_run 'unit pass\ne2e pass\n'
assert_eq "0" "$RC" "AC5 green required checks: post-approval qa posts and labels (exit 0)"
assert_contains "$(cat "$GH_LOG")" "talos:approval sha=$SHA role=qa" "AC5 green: the approval marker is posted"
assert_contains "$(cat "$GH_LOG")" '"qa:pass"' "AC5 green: qa:pass is applied"
pa_run 'unit pass\ne2e fail\n'
assert_eq "1" "$RC" "AC5 a failed required check: exit 1"
assert_contains "$OUT" "post-approval: qa refused: required CI failed: e2e" "AC5 failed: the refusal line names the check"
assert_eq "0" "$(wrote)" "AC5 failed: no marker and no label"
pa_run 'unit pass\ne2e pending\n'
assert_eq "1" "$RC" "AC5 a pending required check: exit 1"
assert_contains "$OUT" "post-approval: qa refused: required CI pending: e2e" "AC5 pending: the refusal line names the check"
assert_eq "0" "$(wrote)" "AC5 pending: no marker and no label"
pa_run 'unit pass\n'
assert_eq "1" "$RC" "AC5 a missing required check: exit 1"
assert_contains "$OUT" "post-approval: qa refused: required CI" "AC5 missing: a refusal line"
assert_eq "0" "$(wrote)" "AC5 missing: no marker and no label"
cfg_par '[]' false
pa_run 'unit pass\ne2e fail\n'
assert_eq "0" "$RC" "AC5 parallel_with_qa false: post-approval qa ignores CI, as before"
cfg_par '[]' true

# AC6: check-approval-sha --require-ci
cas_run() {
  printf '%b' "$1" > "$CI_STATE"
  printf '[{"id":1,"created_at":"2026-10-01T00:00:00Z","body":"<!-- talos:approval sha=%s role=qa -->","user":{"login":"bot"}}]' "$SHA" > "$CSTORE"
  OUT="$(bash "$VCS" check-approval-sha 9 --require-ci 2>&1)"; RC=$?
}
cas_run 'unit pass\ne2e fail\n'
assert_eq "1" "$RC" "AC6 a failed required check: exit 1"
assert_contains "$OUT" "check-approval-sha: ci: failed: e2e" "AC6 failed: the ci: line names the check"
assert_not_contains "$OUT" "stale role=" "AC6 failed: no stale role= line"
cas_run 'unit pass\ne2e pending\n'
assert_eq "1" "$RC" "AC6 a pending required check: exit 1"
assert_contains "$OUT" "check-approval-sha: ci: pending: e2e" "AC6 pending: the ci: line names the check"
assert_not_contains "$OUT" "stale role=" "AC6 pending: no stale role= line"
cas_run 'unit pass\n'
assert_eq "1" "$RC" "AC6 a missing required check: exit 1"
assert_contains "$OUT" "check-approval-sha: ci:" "AC6 missing: a ci: line"
assert_not_contains "$OUT" "stale role=" "AC6 missing: no stale role= line"
cas_run 'unit pass\ne2e pass\n'
assert_eq "0" "$RC" "AC6 green: exit 0"
printf 'unit pass\ne2e pending\n' > "$CI_STATE"
OUT="$(bash "$VCS" check-approval-sha 9 2>&1)"; RC=$?
assert_eq "0" "$RC" "AC8 check-approval-sha without --require-ci: pending CI never strips qa:pass (exit 0)"

# AC7: the one automatic rerun of a configured known flake
cfg_par '["e2e"]' true
RERUN_TURNS='unit pass\ne2e pass' pa_run 'unit pass\ne2e fail\n'
assert_eq "0" "$RC" "AC7 a red known flake that turns green after one rerun is accepted"
assert_eq "1" "$(wc -l < "$RERUN_LOG" | tr -d ' ')" "AC7 exactly one rerun-ci"
assert_contains "$(cat "$GH_LOG")" "talos:ci-rerun $SHA" "AC7 the rerun marker is posted for the head"
assert_contains "$(cat "$GH_LOG")" "talos:approval sha=$SHA role=qa" "AC7 the approval is posted after the green rerun"
RERUN_TURNS='unit pass\ne2e fail' pa_run 'unit pass\ne2e fail\n'
assert_eq "1" "$RC" "AC7 a second red after the rerun is refused"
assert_eq "1" "$(wc -l < "$RERUN_LOG" | tr -d ' ')" "AC7 a second red: still exactly one rerun"
assert_eq "0" "$(grep -c 'role=qa' "$GH_LOG")" "AC7 a second red: no approval marker"
RERUN_TURNS='unit pass\ne2e pass' pa_run 'unit fail\ne2e pass\n'
assert_eq "1" "$RC" "AC7 a failed name outside the list is refused"
assert_eq "0" "$(wc -l < "$RERUN_LOG" | tr -d ' ')" "AC7 a name outside the list is never rerun"
RERUN_TURNS='unit pass\ne2e fail' pa_run 'unit fail\ne2e fail\n'
assert_eq "0" "$(wc -l < "$RERUN_LOG" | tr -d ' ')" "AC7 one flake plus one other failure: no rerun"
MARK="[{\"id\":2,\"created_at\":\"2026-10-01T00:00:00Z\",\"body\":\"CI re-run 1 of 2 for this head.\\n<!-- talos:ci-rerun $SHA -->\",\"user\":{\"login\":\"bot\"}}]"
RERUN_TURNS='unit pass\ne2e pass' pa_run 'unit pass\ne2e fail\n' "$MARK"
assert_eq "1" "$RC" "AC7 an existing talos:ci-rerun marker for the head: refused"
assert_eq "0" "$(wc -l < "$RERUN_LOG" | tr -d ' ')" "AC7 an existing marker: no further rerun"
unset STUB_COMMENT_STORE

# ── AC10: gate merge, ci-failed under parallel mode ──────────────────────────
GG="$SANDBOX/gg"
GSTUB="$SANDBOX/gstub"
export GSTUB
mkdir -p "$GG" "$GSTUB"
cp "$TALOS_ROOT"/scripts/* "$GG/"
GBODY='#!/usr/bin/env bash
d="${GSTUB:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="${1:-}"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
if [ "$n" = "draft-check" ]; then
  case "${1:-}" in
    ci-parallel) cat "$d/ci-parallel.out"; exit 0 ;;
    ready-gate) echo off; exit 0 ;;
    *) echo true; exit 0 ;;
  esac
fi
if [ "$n" = "hooks" ]; then cat > "$d/hooks.stdin"; fi
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-mergebase.sh pipeline-status.sh pipeline-draft-check.sh; do
  printf '%s' "$GBODY" > "$GG/$s"
done
setg() { printf '%s\n' "$2" > "$GSTUB/$1.rc"; printf '%s' "${3:-}" > "$GSTUB/$1.out"; printf '%s' "${4:-}" > "$GSTUB/$1.err"; }
gate_run() {  # <ci-parallel true|false>
  rm -rf "${GSTUB:?}"; mkdir -p "$GSTUB"
  printf '%s' "$1" > "$GSTUB/ci-parallel.out"
  setg view-pr 0 '{"labels":[{"name":"qa:pass"},{"name":"review:approved"},{"name":"security:approved"},{"name":"docs:done"},{"name":"pipeline:review"}]}'
  setg view-issue 0 '{"labels":[{"name":"pipeline:review"}]}'
  setg pr-head 0 "0123456789abcdef0123456789abcdef01234567"
  setg pr-ci-runs 0 2
  setg pr-is-draft 1 ready
  setg pr-checks-required 1 "" "pr-checks-required: failed: unit"
  setg read-comments 0 '{"comments":[{"body":"<!-- talos:ci-rerun 0123456789abcdef0123456789abcdef01234567 -->"},{"body":"<!-- talos:ci-rerun 0123456789abcdef0123456789abcdef01234567 -->"}]}'
  printf '{"vcs":{"provider":"github"},"pr":{"draft":true}}' > "$SANDBOX/talos.pipeline.json"
  OUT="$(cd "$SANDBOX" && PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json" bash "$GG/talos.sh" gate merge 9 42 2>"$ERR")"; RC=$?
}
gate_run true
assert_contains "$OUT" "reason=ci-failed" "AC10 setup: the gate answers ci-failed"
assert_contains "$OUT" "verdict=redispatch" "AC10 setup: the gate redispatches"
verbs_g="$(grep -E '^vcs (draft-pr|pr-checks-required) ' "$GSTUB/journal" | sed -E 's/^vcs ([a-z-]+) .*/\1/' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "pr-checks-required draft-pr" "$verbs_g" "AC10 parallel: draft-pr runs after the red CI read, before the redispatch"
gate_run false
assert_contains "$OUT" "verdict=redispatch" "AC10 not parallel: the redispatch is unchanged"
assert_not_contains "$(cat "$GSTUB/journal")" "vcs draft-pr" "AC10 not parallel: no draft-pr from the gate"

finish
