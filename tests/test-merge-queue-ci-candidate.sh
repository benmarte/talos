#!/usr/bin/env bash
# test-merge-queue-ci-candidate.sh -- merge.queue_ci (#1081): under `merge.queue: talos`
# with `merge.queue_ci: candidate` a reviewed PR joins the queue as a draft with no CI
# run of its own, and the candidate's CI is the one gate for every member. Tests are
# named by the spec's criterion id.
#   AC1  gate merge enqueues a draft with no CI run; queue_enqueue carries ci=candidate
#   AC2  routing keeps the PR a draft; queue run: ready-pr, merge-pr, cancel-pr-runs
#   AC3  the QA prompt and post-approval qa
#   AC4  the effective value (pipeline-draft-check.sh queue-ci, talos.sh env)
#   AC5  base-protection answers checks-bypass (gh and curl legs)
#   AC6  the key unset or `pr` keeps today's queue
# The fixture is tests/test-merge-queue-retry-950.sh's: tests/talos-run-sections.sh
# sourced with TALOS_RUN_PART=930 TALOS_RUN_EMBED=1, a local bare `origin`, journaling
# stubs. No network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=930 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TALOS_RETRY_SLEEP_SCALE=0
MARK='<!-- talos:queue -->'
HEAD12="aabbccddeeff00112233445566778899aabbccdd"

# ── fixtures (as tests/test-merge-queue-retry-950.sh) ────────────────────────
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
UPD="$SANDBOX/origin-updates.log"
export Q_ORIGIN="$ORIGIN" Q_SEED="$SEED"
git remote set-url origin "$ORIGIN"

GQ="$SANDBOX/gq"
mkdir -p "$GQ"
cp "$GS"/* "$GQ/"
for s in pipeline-mergebase.sh pipeline-worktree.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GQ/$s"
done

sg() { git -C "$SEED" "$@"; }
origin_reset() {
  rm -rf "${ORIGIN:?}" "${SEED:?}"
  : > "$UPD"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git init -q "$SEED"
  sg symbolic-ref HEAD refs/heads/main
  sg config user.name talos-test
  sg config user.email test@talos.invalid
  sg config commit.gpgsign false
  printf 'base\n' > "$SEED/base.txt"
  printf '# Changelog\n\n## [Unreleased]\n\n' > "$SEED/CHANGELOG.md"
  sg add -A
  sg commit -q -m base
  sg remote add origin "$ORIGIN"
  sg push -q origin main
}
comments_json() {
  python3 -I -c '
import json, sys
out = []
for a in sys.argv[1:]:
    login, body = a.split("|", 1)
    out.append({"author": {"login": login}, "body": body.replace("\\n", "\n")})
print(json.dumps({"comments": out}))' "$@"
}
qbody() { printf '**Merge queue:**\\n\\nqueue: base=%s head=%s eligible=%s\\n\\n%s' "$1" "$2" "$3" "$MARK"; }
Q_LIST=""
Q_SEQ=0
q_pr() {  # <pr> <issue> <file> <line>: one queued PR on feat/issue-<issue>-q
  local _pr="$1" _n="$2" _br="feat/issue-$2-q" _h
  sg checkout -q -B "$_br" main
  printf '%s\n' "$4" >> "$SEED/$3"
  sg add -A
  sg commit -q -m "pr$_pr: $3"
  sg push -q -f origin "$_br"
  _h="$(sg rev-parse HEAD)"
  sg checkout -q main
  Q_SEQ=$((Q_SEQ + 1))
  printf '%s' "$_h" > "$STUB_DIR/pr-head.$_pr"
  comments_json "owner|$(qbody main "$_h" "$(printf '2026-11-01T00:00:%02dZ' "$Q_SEQ")")" > "$STUB_DIR/read-comments.$_pr"
  printf '{"number": %s, "headRefName": "%s", "baseRefName": "main", "labels": [], "state": "open"}' "$_pr" "$_br" > "$STUB_DIR/view-pr.$_pr"
  Q_LIST="$Q_LIST${Q_LIST:+,}{\"number\":$_pr,\"baseRefName\":\"main\",\"headRefName\":\"$_br\",\"isCrossRepository\":false}"
  export LIST_PRS="[$Q_LIST]"
}
# qc_cfg <queue_ci: candidate|pr|-> [<merge.queue, default talos>] [<extra top-level members>]
qc_cfg() {
  local _qc="" _q="${2:-talos}"
  [ "$1" = "-" ] || _qc=", \"queue_ci\": \"$1\""
  printf '{"vcs": {"provider": "github"}, "base_branch": "main"%s, "merge": {"queue": "%s", "method": "squash"%s}}' \
    "${3:+, $3}" "$_q" "$_qc" > "$SANDBOX/talos.pipeline.json"
}
q_reset() {
  reset_stubs
  LEASE_RESET
  Q_LIST=""; Q_SEQ=0
  export LIST_PRS="[]" LIST_ISSUES="[]"
  printf 'owner' > "$STUB_DIR/current-user"
  printf 'talos:checkout state=kept' > "$STUB_DIR/worktree.out"
  printf 'open' > "$STUB_DIR/base-protection.out"
  qc_cfg candidate
  origin_reset
}
q_three() { q_pr 11 41 a11.txt x11; q_pr 12 42 a12.txt x12; q_pr 13 43 a13.txt x13; }
qr() { OUT="$(bash "$GQ/talos.sh" queue run </dev/null 2>"$ERR")"; RC=$?; }
jc() { journal | grep -c -E "$1"; }
line1() { printf '%s\n' "$OUT" | sed -n 1p; }
has_line() { grep -qx -- "$1" <<< "$OUT"; }
assert_line() { if has_line "$2"; then pass "$1"; else fail "$1" "no line '$2' in: $(printf '%s' "$OUT" | tr '\n' '|')"; fi; }
# order <verbs regex>: the matching provider calls, as `<verb> <pr>` joined by `>`.
order() { journal | grep -oE "^vcs ($1) [0-9]+" | sed 's/^vcs //' | tr '\n' '>' | sed 's/>$//'; }

# gate_fix <draft|ready> <pr-checks-required rc>: PR 12 of issue 42 with every approval,
# for `gate merge`; the config is the caller's.
gate_fix() {
  reset_stubs
  LEASE_RESET
  export LIST_PRS="[]" LIST_ISSUES="[]"
  printf 'owner' > "$STUB_DIR/current-user"
  printf 'open' > "$STUB_DIR/base-protection.out"
  qc_cfg candidate
  printf '{"labels":[{"name":"qa:pass"},{"name":"docs:done"},{"name":"review:approved"},{"name":"security:approved"}],"state":"open"}' > "$STUB_DIR/view-pr.12"
  printf '{"labels":[{"name":"pipeline:review"}],"state":"open"}' > "$STUB_DIR/view-issue.42"
  printf '%s' "$HEAD12" > "$STUB_DIR/pr-head.12"
  printf '{"comments":[]}' > "$STUB_DIR/read-comments.12"
  printf 'upserted pr=12 comment=created' > "$STUB_DIR/upsert-pr-comment.12.out"
  case "$1" in
    draft) printf 'draft' > "$STUB_DIR/pr-is-draft.12.out"; printf '0' > "$STUB_DIR/pr-is-draft.12.rc" ;;
    *) printf 'ready' > "$STUB_DIR/pr-is-draft.12.out"; printf '1' > "$STUB_DIR/pr-is-draft.12.rc" ;;
  esac
  printf '%s' "$2" > "$STUB_DIR/pr-checks-required.12.rc"
  [ "$2" -eq 0 ] || printf 'pr-checks-required: pending or missing: ci\n' > "$STUB_DIR/pr-checks-required.12.err"
  printf '4' > "$STUB_DIR/pr-ci-runs.12.out"
}
gm() { rm -f "$STUB_DIR/journal"; OUT="$(bash "$GQ/talos.sh" gate merge 12 42 </dev/null 2>"$ERR")"; RC=$?; }

# ── AC4: the effective value ─────────────────────────────────────────────────
# qci: pipeline-draft-check.sh queue-ci over the stubbed provider; OUT is stdout, ERRTXT stderr.
qci() { rm -f "$STUB_DIR/journal"; OUT="$(cd "$SANDBOX" && bash "$GQ/pipeline-draft-check.sh" queue-ci 2>"$ERR")"; RC=$?; ERRTXT="$(cat "$ERR")"; }
bp_calls() { jc '^vcs base-protection '; }

q_reset
qci
assert_eq "candidate||1" "$OUT|$ERRTXT|$(bp_calls)" "AC4 candidate with merge.queue talos, draft on, QA on, an open base: candidate, silent, one protection read"
qc_cfg candidate off
qci
assert_eq "pr|1|0" "$OUT|$(printf '%s\n' "$ERRTXT" | grep -c .)|$(bp_calls)" "AC4 merge.queue off reads pr with one stderr line, no protection read"
assert_contains "$ERRTXT" "merge.queue_ci" "AC4 merge.queue off: the line names the key"
qc_cfg candidate talos '"pr": {"draft": false}'
qci
assert_eq "pr|1" "$OUT|$(printf '%s\n' "$ERRTXT" | grep -c .)" "AC4 pr.draft false reads pr with one stderr line"
assert_contains "$ERRTXT" "pr.draft" "AC4 pr.draft false: the line names pr.draft"
qc_cfg candidate talos '"roles": {"qa": false}'
qci
assert_eq "pr|1" "$OUT|$(printf '%s\n' "$ERRTXT" | grep -c .)" "AC4 roles.qa off reads pr with one stderr line"
assert_contains "$ERRTXT" "roles.qa" "AC4 roles.qa off: the line names roles.qa"
qc_cfg candidate
printf 'checks' > "$STUB_DIR/base-protection.out"; printf '1' > "$STUB_DIR/base-protection.rc"
qci
assert_eq "pr|note reason=queue-ci-protected base=main" "$OUT|$ERRTXT" "AC4 base-protection checks reads pr with the note naming the base"
printf '2' > "$STUB_DIR/base-protection.rc"; : > "$STUB_DIR/base-protection.out"
qci
assert_eq "pr|note reason=queue-ci-protected base=main" "$OUT|$ERRTXT" "AC4 an unreadable protection counts as checks"
printf 'checks-bypass' > "$STUB_DIR/base-protection.out"; printf '1' > "$STUB_DIR/base-protection.rc"
qci
assert_eq "candidate|" "$OUT|$ERRTXT" "AC4 base-protection checks-bypass keeps candidate"
for v in - pr; do
  q_reset; qc_cfg "$v"
  qci
  assert_eq "pr||0" "$OUT|$ERRTXT|$(bp_calls)" "AC4 merge.queue_ci '$v': pr, silent, no protection read"
done

# ── AC1: a draft with every approval and no CI run is queued ─────────────────
gate_fix draft 2
gm
assert_eq "verdict=wait" "$(line1)" "AC1 candidate: a draft PR with no CI run answers verdict=wait"
assert_line "AC1 candidate: reason=queued" "reason=queued"
assert_eq "1" "$(jc '^vcs upsert-pr-comment 12 ')" "AC1 candidate: the queue marker is written"
assert_eq "1" "$(jc "^hooks post_stage queue_enqueue orchestrator 42 --pr 12 --sha $HEAD12 --ci candidate")" "AC1 candidate: queue_enqueue carries ci=candidate"
assert_eq "0" "$(jc '^vcs (ready-pr|draft-pr) ')" "AC1 candidate: no stage marks the PR ready"
assert_not_contains "$OUT" "ci-pending" "AC1 candidate: no ci-pending wait"
assert_not_contains "$OUT" "draft-pr" "AC1 candidate: no draft redispatch"
# A red required check that did run on the PR head is handled as today.
gate_fix draft 1
printf 'pr-checks-required: failed: unit\n' > "$STUB_DIR/pr-checks-required.12.err"
gm
assert_line "AC1 candidate: a red PR CI is handled as today (a re-run), not queued" "reason=ci-rerun"
assert_eq "0" "$(jc '^vcs upsert-pr-comment ')" "AC1 candidate: a red PR CI writes no queue marker"

# ── AC6: the key unset or pr keeps today's gate ──────────────────────────────
for v in - pr; do
  gate_fix ready 2
  qc_cfg "$v"
  gm
  assert_line "AC6 merge.queue_ci '$v': a ready PR with pending CI waits for it" "reason=ci-pending"
  assert_eq "0" "$(jc '^vcs upsert-pr-comment ')" "AC6 merge.queue_ci '$v': nothing is queued before its own CI is green"
  gate_fix draft 2
  qc_cfg "$v"
  gm
  assert_line "AC6 merge.queue_ci '$v': a draft is redispatched to the ready flow" "reason=draft-pr"
  gate_fix ready 0
  qc_cfg "$v"
  gm
  assert_line "AC6 merge.queue_ci '$v': a green PR CI is queued" "reason=queued"
  assert_eq "1" "$(jc "^hooks post_stage queue_enqueue orchestrator 42 --pr 12 --sha $HEAD12 --ci pr")" "AC6 merge.queue_ci '$v': queue_enqueue carries ci=pr"
done

# ── AC2: routing keeps the PR a draft; the queue marks it ready only to merge ─
nxt() {  # <queue-ci> <labels, comma-joined>: pipeline-next.py's stage for draft PR 9
  python3 -I -c '
import importlib.util, sys
sys.dont_write_bytecode = True
s = importlib.util.spec_from_file_location("pn", sys.argv[1])
m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)
m.opts = {"pr-draft": "true", "queue-ci": sys.argv[2], "merge-auto": "true"}
m.listed_draft = {9: True}
m.vcs = lambda *a: (0, "", "")
print(m.next_stage(9, set(x for x in sys.argv[3].split(",") if x), set(), {"qa", "docs", "reviewer", "security"}))' \
    "$TALOS_ROOT/scripts/pipeline-next.py" "$1" "$2"
}
NOQA="docs:done,review:approved,security:approved"
assert_eq "qa" "$(nxt candidate "$NOQA")" "AC2 candidate: a draft with every approval but qa goes to QA, on the draft"
assert_eq "merge" "$(nxt candidate "$NOQA,qa:pass")" "AC2 candidate: a draft with every approval current goes to the merge gate, not the ready wait"
assert_eq "ready" "$(nxt pr "$NOQA")" "AC6 key unset or pr: a draft with the other approvals is the ready stage (ready-pr comes before QA)"
assert_eq "ready" "$(nxt '' "$NOQA,qa:pass")" "AC6 an empty option reads as pr: the ready stage"

q_reset; q_three
qr
assert_eq "verdict=merged" "$(line1)" "AC2 candidate: the queue merges the three drafts"
assert_eq "ready-pr 11>merge-pr 11>cancel-pr-runs 11>ready-pr 12>merge-pr 12>cancel-pr-runs 12>ready-pr 13>merge-pr 13>cancel-pr-runs 13" \
  "$(order 'ready-pr|merge-pr|cancel-pr-runs')" "AC2 each member: ready-pr, then merge-pr, then cancel-pr-runs, in queue order"
assert_eq "0" "$(jc '^vcs draft-pr ')" "AC2 no member is put back to a draft"
q_reset; q_pr 11 41 a11.txt x11; q_pr 12 42 a12.txt x12
printf '1' > "$STUB_DIR/cancel-pr-runs.11.rc"
qr
assert_eq "verdict=merged" "$(line1)" "AC2 a failed cancel-pr-runs does not stop the merges"
assert_line "AC2 a failed cancel-pr-runs prints the warning" "warn reason=pr-run-cancel-failed pr=11"
assert_eq "merge-pr 11>merge-pr 12" "$(order 'merge-pr')" "AC2 the next members still merge after a failed cancel"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c '^warn reason=pr-run-cancel-failed')" "AC2 only the failed cancel warns"
q_reset; q_pr 11 41 a11.txt x11; q_pr 12 42 a12.txt x12
printf '1' > "$STUB_DIR/ready-pr.12.rc"
qr
assert_eq "block" "$(printf '%s\n' "$OUT" | sed -n 's/^verdict=//p' | tail -n 1)" "AC2 a failed ready-pr blocks the merges"
assert_eq "merge-pr 11" "$(order 'merge-pr')" "AC2 a failed ready-pr: the member after it is not merged"

# ── AC6: the key unset or pr: the queue calls neither verb ───────────────────
for v in - pr; do
  q_reset; qc_cfg "$v"; q_pr 11 41 a11.txt x11; q_pr 12 42 a12.txt x12
  qr
  assert_eq "verdict=merged" "$(line1)" "AC6 merge.queue_ci '$v': the queue merges as today"
  assert_eq "0" "$(jc '^vcs (ready-pr|cancel-pr-runs) ')" "AC6 merge.queue_ci '$v': queue run calls no ready-pr and no cancel-pr-runs"
  assert_eq "2" "$(jc '^vcs merge-pr ')" "AC6 merge.queue_ci '$v': the two PRs merge"
done

# ── AC3: the QA prompt and post-approval qa ──────────────────────────────────
# A tree whose draft resolver and provider are stubs: candidate on, the PR a draft.
TREE="$SANDBOX/tree"
mkdir -p "$TREE" "$SANDBOX/proj"
cp -R "$TALOS_ROOT/scripts" "$TREE/scripts"
cp -R "$TALOS_ROOT/templates" "$TREE/templates"
printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  queue-ci) echo "${QCI_STUB:-candidate}" ;;\n  ready-gate) echo off ;;\n  ci-parallel) echo false ;;\n  *) echo true ;;\nesac\n' > "$TREE/scripts/pipeline-draft-check.sh"
printf '#!/usr/bin/env bash\n[ "${1:-}" = pr-is-draft ] || exit 0\nprintf draft\nexit 0\n' > "$TREE/scripts/pipeline-vcs.sh"
render_qa() {
  local o f
  o="$(cd "$SANDBOX" && bash "$TREE/scripts/talos.sh" prompt qa --issue 9 --pr 12 --worktree "$SANDBOX/proj" 2>/dev/null)"
  f="${o#prompt_file=}"
  if [ -f "$f" ]; then cat "$f"; rm -f "${f:?}"; else printf '%s\n' "$o"; fi
}
printf '{"vcs":{"provider":"github"},"merge":{"queue":"talos","queue_ci":"candidate","required_checks":["ci-complete"]},"verify":{"qa_mode":"ci","ci_wait_s":600}}' > "$SANDBOX/talos.pipeline.json"
# talos.sh env prints the resolver's answer as QUEUE_CI (isolation validates against ./scripts).
mkdir -p "$SANDBOX/envproj" && ln -s "$TREE/scripts" "$SANDBOX/envproj/scripts"
printf '{"vcs":{"provider":"github"},"execution":{"isolation":"branch"}}' > "$SANDBOX/talos.pipeline.json"
ENVOUT="$(cd "$SANDBOX/envproj" && QCI_STUB=candidate bash "$TREE/scripts/talos.sh" env 2>/dev/null)"
assert_contains "$ENVOUT" "QUEUE_CI=candidate" "AC4 talos.sh env prints the effective value as QUEUE_CI"
ENVOUT="$(cd "$SANDBOX/envproj" && QCI_STUB=pr bash "$TREE/scripts/talos.sh" env 2>/dev/null)"
assert_contains "$ENVOUT" "QUEUE_CI=pr" "AC4 talos.sh env prints QUEUE_CI=pr when the resolver says pr"
printf '{"vcs":{"provider":"github"},"merge":{"queue":"talos","queue_ci":"candidate","required_checks":["ci-complete"]},"verify":{"qa_mode":"ci","ci_wait_s":600}}' > "$SANDBOX/talos.pipeline.json"
cand="$(QCI_STUB=candidate render_qa)"
assert_contains "$cand" "CI: the merge-queue candidate is the gate (merge.queue_ci: candidate)" "AC3 the QA prompt carries the candidate-gate line"
assert_not_contains "$cand" "CI wait budget" "AC3 the QA prompt carries no CI wait budget line"
assert_not_contains "$cand" "pr-checks-required 12" "AC3 the QA prompt asks for no CI wait command"
assert_not_contains "$cand" 'the full `verify:` list once' "AC3 the QA prompt carries no full verify step"
assert_contains "$cand" "qa-run" "AC3 the QA prompt still runs the qa-run criteria"
plain="$(QCI_STUB=pr render_qa)"
assert_not_contains "$plain" "merge-queue candidate is the gate" "AC6 merge.queue_ci pr: the QA prompt has no candidate-gate line"
assert_contains "$plain" "CI wait budget" "AC6 merge.queue_ci pr: the QA prompt keeps its CI wait line"

# post-approval qa against a gh shim whose check-run answers come from $CI_STATE.
mkdir -p "$SANDBOX/bin" "$SANDBOX/proj"
export STUBS_DIR CI_STATE="$SANDBOX/ci.state"
cat > "$SANDBOX/bin/gh" <<'TALOS_ghshimQ8w2Lz5Hn'
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
  *) exec "$STUBS_DIR/gh" "$@" ;;
esac
TALOS_ghshimQ8w2Lz5Hn
chmod +x "$SANDBOX/bin/gh"
export PATH="$SANDBOX/bin:$PATH"
unset PIPELINE_CONFIG
cd "$SANDBOX/proj" || exit 1
git config user.email "test@talos.invalid"; git config user.name "talos-test"
SHA="aabb1122ccdd3344eeff556677889900aabb1122"
export STUB_PR_HEAD_SHA="$SHA" STUB_PR_BASE_REF_NAME=main STUB_CURRENT_USER=bot
CSTORE="$SANDBOX/cs.json"
export STUB_COMMENT_STORE="$CSTORE"
export STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]'
printf '{"vcs":{"provider":"github"},"merge":{"queue":"talos","queue_ci":"candidate","required_checks":["unit","e2e"]},"verify":{"ci_wait_s":60}}' > talos.pipeline.json
pa_run() {  # <ci state lines>: post-approval qa with the stub resolver answering $QCI_STUB
  printf '%b' "$1" > "$CI_STATE"
  printf '[]' > "$CSTORE"
  : > "$GH_LOG"
  OUT="$(bash "$TREE/scripts/pipeline-vcs.sh" post-approval 9 qa 2>&1)"; RC=$?
}
printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  queue-ci) echo "${QCI_STUB:-candidate}" ;;\n  ci-parallel) echo false ;;\n  *) echo true ;;\nesac\n' > "$TREE/scripts/pipeline-draft-check.sh"
cp "$TALOS_ROOT/scripts/pipeline-vcs.sh" "$TREE/scripts/pipeline-vcs.sh"
QCI_STUB=candidate pa_run ''
assert_eq "0" "$RC" "AC3 candidate: post-approval qa succeeds with no CI run on the head"
assert_contains "$(cat "$GH_LOG")" "talos:approval sha=$SHA role=qa" "AC3 candidate: the approval marker is posted"
QCI_STUB=candidate pa_run 'unit pass\ne2e pending\n'
assert_eq "0" "$RC" "AC3 candidate: a pending required check does not refuse"
QCI_STUB=candidate pa_run 'unit pass\ne2e fail\n'
assert_eq "1" "$RC" "AC3 candidate: a required check that ran on the head and is red still refuses"
assert_contains "$OUT" "post-approval: qa refused: required CI failed: e2e" "AC3 candidate: the refusal names the red check"
assert_eq "0" "$(grep -c 'role=qa' "$GH_LOG")" "AC3 candidate: a red check leaves no approval marker"

# ── AC5: base-protection answers checks-bypass, on both transports ───────────
use_stubs
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
bp() {  # <leg> <canned answers, one per line>
  github_leg "$1"
  printf '%s\n' "$2" > "$CURL_QUEUE"
  : > "$CURL_LOG"
  OUT="$(bash "$VCS" base-protection main 2>"$ERR")"; RC=$?
}
PROT='{"name":"main","protected":true}
{"strict":true,"contexts":["ci"],"checks":[{"context":"ci"}]}'
RS='{"name":"main","protected":false}
[{"type":"required_status_checks","ruleset_id":7,"parameters":{"required_status_checks":[{"context":"ci"}]}}]'
for leg in gh curl; do
  bp "$leg" "$PROT
{\"permissions\":{\"admin\":true}}
{\"enabled\":false}
[]"
  assert_eq "checks-bypass|1" "$OUT|$RC" "AC5 $leg: an admin, admins not enforced, no ruleset: checks-bypass"
  bp "$leg" "$PROT
{\"permissions\":{\"admin\":true}}
{\"enabled\":true}
[]"
  assert_eq "checks|1" "$OUT|$RC" "AC5 $leg: admins enforced by the branch protection: checks"
  bp "$leg" "$PROT
{\"permissions\":{\"admin\":false}}"
  assert_eq "checks|1" "$OUT|$RC" "AC5 $leg: the user is not an admin: checks"
  bp "$leg" "$RS
{\"permissions\":{\"admin\":true}}
{\"bypass_actors\":[{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"always\"}]}"
  assert_eq "checks-bypass|1" "$OUT|$RC" "AC5 $leg: a ruleset listing the repository admin role as a bypass actor: checks-bypass"
  bp "$leg" "$RS
{\"permissions\":{\"admin\":true}}
{\"bypass_actors\":[]}"
  assert_eq "checks|1" "$OUT|$RC" "AC5 $leg: a ruleset with no bypass actor: checks"
  bp "$leg" "$RS
{\"permissions\":{\"admin\":false}}"
  assert_eq "checks|1" "$OUT|$RC" "AC5 $leg: a ruleset and a user who is not an admin: checks"
  bp "$leg" "$RS
{\"permissions\":{\"admin\":true}}
{\"bypass_actors\":[{\"actor_id\":9,\"actor_type\":\"Team\",\"bypass_mode\":\"always\"}]}"
  assert_eq "checks|1" "$OUT|$RC" "AC5 $leg: a ruleset whose bypass actor is another team: checks"
  bp "$leg" "$RS
not json"
  assert_eq "checks|1" "$OUT|$RC" "AC5 $leg: an unreadable admin check counts as checks"
  bp "$leg" '{"name":"main","protected":false}
[]'
  assert_eq "open|0" "$OUT|$RC" "AC5 $leg: no protection stays open"
done

# cancel-pr-runs: GitHub only; another provider exits 2 and calls nothing.
printf '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}\n' > talos.pipeline.json
: > "$GH_LOG"
OUT="$(bash "$VCS" cancel-pr-runs 5 2>"$ERR")"; RC=$?
assert_eq "2|" "$RC|$(cat "$GH_LOG")" "AC2 cancel-pr-runs on gitlab exits 2 and cancels nothing"

finish
