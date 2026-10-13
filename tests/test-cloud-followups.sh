#!/usr/bin/env bash
# test-cloud-followups.sh -- cloud-session follow-ups (#653): a refused first
# attempt whose fallback worked prints no 403 note, and a branch merge-pr could
# not delete is named once by the run.
#   AC1 ready-pr / draft-pr: GraphQL refused, ccr REST route served: no 403 note
#   AC2 merge-pr: a refused head-branch DELETE prints only the one "could not be deleted" line
#   AC3 the run emits warn reason=branch-left issue=N branch=BRANCH per left branch
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export STUB_REPO=acme/widget TALOS_RETRY_SLEEP_SCALE=0
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > talos.pipeline.json

# ── AC1: ready-pr / draft-pr with GraphQL refused ────────────────────────────
for _v in ready-pr:ready_for_review draft-pr:convert_to_draft; do
  printf '%s\n' '{"number":9,"node_id":"PR_kw9"}' '{}' > "$SANDBOX/gh.queue"
  OUT="$(STUB_GH_NO_GRAPHQL=1 GH_QUEUE="$SANDBOX/gh.queue" bash "$VCS" "${_v%%:*}" 9 2>&1)"; RC=$?
  assert_eq "0" "$RC" "AC1 ${_v%%:*} exits 0 when the REST route serves it" "$OUT"
  assert_not_contains "$OUT" "HTTP 403 on ${_v%%:*}" "AC1 ${_v%%:*} prints no 403 note after a working fallback"
  printf '%s\n' '{"number":9,"node_id":"PR_kw9"}' '422:{"message":"no"}' > "$SANDBOX/gh.queue"
  OUT="$(STUB_GH_NO_GRAPHQL=1 GH_QUEUE="$SANDBOX/gh.queue" bash "$VCS" "${_v%%:*}" 9 2>&1)"; RC=$?
  assert_eq "nonzero" "$([ "$RC" -ne 0 ] && echo nonzero)" "AC1 ${_v%%:*} exits non-zero when the REST route fails too" "$OUT"
  assert_contains "$OUT" "HTTP 422 on ${_v%%:*}" "AC1 ${_v%%:*} prints the refusal of a failed REST route"
done

# ── AC2: merge-pr with the branch DELETE refused ─────────────────────────────
PRJ='{"head":{"ref":"feat/issue-7-x","repo":{"full_name":"acme/widget"}},"base":{"repo":{"full_name":"acme/widget"}}}'
printf '%s\n' "$PRJ" '{"merged":true}' '403:{"message":"refused"}' > "$SANDBOX/gh.queue"
OUT="$(GH_QUEUE="$SANDBOX/gh.queue" bash "$VCS" merge-pr 9 2>&1)"; RC=$?
assert_eq "0" "$RC" "AC2 merge-pr exits 0 when only the branch delete is refused" "$OUT"
assert_not_contains "$OUT" "HTTP 403 on merge-pr" "AC2 no 403 note for the refused branch delete"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c "merge-pr: PR #9 merged, but its branch 'feat/issue-7-x' could not be deleted")" \
  "AC2 exactly one could-not-be-deleted line" "$OUT"
printf '%s\n' "$PRJ" '405:{"message":"not mergeable"}' > "$SANDBOX/gh.queue"
OUT="$(GH_QUEUE="$SANDBOX/gh.queue" bash "$VCS" merge-pr 9 2>&1)"; RC=$?
assert_eq "1" "$RC" "AC2 a failed merge PUT still exits 1" "$OUT"
assert_contains "$OUT" "HTTP 405 on merge-pr" "AC2 a failed merge PUT keeps its own HTTP note"

# ── AC3: the run names the branch merge-pr left behind ───────────────────────
# A copy of the scripts with journaling stubs, as test-talos-run.sh builds one.
GS="$SANDBOX/gs"; STUB_DIR="$SANDBOX/stub"; export STUB_DIR
mkdir -p "$GS" "$STUB_DIR" "$SANDBOX/templates"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cp -R "$TALOS_ROOT/templates/." "$SANDBOX/templates/"
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="$1"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
if [ -f "$d/hook.$key" ]; then . "$d/hook.$key"; fi
if [ "$key" = "list-prs" ]; then printf "[]"; exit 0; fi
if [ "$key" = "list-needs-owner" ] || [ "$key" = "list-issues" ]; then printf "[]"; exit 0; fi
a1="${2:-}"
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
if [ -f "$d/$key.$a1" ]; then cat "$d/$key.$a1"; elif [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.$a1.rc" ]; then rc="$(cat "$d/$key.$a1.rc")"; elif [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-events.sh pipeline-worktree.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusQ8zLw4Vn'
#!/usr/bin/env bash
cat "${STUB_DIR:?}/collect.json"
TALOS_stubstatusQ8zLw4Vn
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' > "$PIPELINE_CONFIG"
printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"merge"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.json"
printf '{"labels": [{"name": "qa:pass"}, {"name": "docs:done"}, {"name": "review:approved"}, {"name": "security:approved"}], "state": "open"}' > "$STUB_DIR/view-pr.12"
printf '{"number": 9, "title": "t", "labels": [], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9"
printf ready > "$STUB_DIR/pr-is-draft.12"; printf 1 > "$STUB_DIR/pr-is-draft.12.rc"
printf 'talos:checkout state=returned\n' > "$STUB_DIR/worktree.out"
printf "pipeline-vcs: merge-pr: PR #12 merged, but its branch 'fix/issue-9-x' could not be deleted\n" > "$STUB_DIR/merge-pr.err"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
OUT="$(TALOS_LEASE_TTL_S=1800 TALOS_NOW=17000 bash "$GS/talos.sh" run --issue 9 --max-iterations 3 2>"$SANDBOX/stderr")"; RC=$?
assert_eq "0" "$RC" "AC3 the run exits 0 after a merge that left its branch" "$OUT"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c '^warn reason=branch-left issue=9 branch=fix/issue-9-x$')" \
  "AC3 one warn reason=branch-left issue=9 branch=fix/issue-9-x line" "$OUT"
assert_contains "$OUT" "stop merged pr=12" "AC3 the run still ends merged"

finish
