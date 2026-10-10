#!/usr/bin/env bash
# test-draft-stage-order.sh -- draft-PR stage order (#332, PR 2 of 2; the default since #435).
#
# The draft-specific instructions live in skills/pipeline/refs/draft-order.md
# (#547: the core playbook stays small; `talos.sh env` prints ref=draft-order when
# PR_DRAFT is true), so the default flow in SKILL.md carries only a pointer.
#
# Covers:
#   (a) the core points at the ref and keeps the draft verbs out of the default
#       flow; the ref holds the seven-step order and the two replay lines
#   (b) stage order with pr.draft: developer opens a DRAFT PR, docs before any
#       approval marker, reviewer + security + adversarial in parallel, ONE fix
#       round, ready-pr, QA, merge; QA/CI failure = draft-pr -> fix -> ready-pr
#   (c) the QA draft guard: dispatch only when pr-is-draft exits 1 AND prints
#       exactly "ready"; exit 0 (draft) and exit 2 (unverified) never dispatch
#   (d) run-count model: a stub gh tracks draft state and emulates the
#       tests.yml trigger rule; the documented verb sequence yields exactly 1
#       run on the happy path and exactly 1 added run per QA-failure round
#   (e) positive controls: removing the ready-pr step, or the QA draft guard,
#       from a copy of the ref turns the named checks red
#   (f) liveness (#340): "QA passed, CI failed at Step 4, fix round" replayed
#       against the real ref text reaches ready-pr; without the qa:pass strip a
#       stale approval makes step 5's precondition impossible
#
#   (g) the default path (#435): one resolver, `pr.draft` unset is true on github,
#       gitlab and azure and false on github-api and file; explicit false wins
#
# DRAFT_REF_FILE=<path> points every ref check at another copy of the ref (used
# to show the positive controls red against a mutated copy).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

CORE="$TALOS_ROOT/skills/pipeline/SKILL.md"
SKILL="${DRAFT_REF_FILE:-$TALOS_ROOT/skills/pipeline/refs/draft-order.md}"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export TALOS_RETRY_SLEEP_SCALE=0

# ── helpers (all take the ref file as $1) ────────────────────────────────────
# draft_text: the ref is all draft text.
draft_text() { cat "$1"; }

# norm: collapse whitespace so a pattern can span a wrapped line.
norm() { tr '\n' ' ' | tr -s ' '; }
# in_order TEXT ERE... : success when every pattern matches, each after the end
# of the previous match.
in_order() {
  printf '%s' "$1" | python3 -c '
import re, sys
text = " ".join(sys.stdin.read().split())
pos = 0
for pat in sys.argv[1:]:
    m = re.compile(pat).search(text, pos)
    if not m:
        sys.exit(1)
    pos = m.end()
' "${@:2}"
}

# ── (a) the core points at the ref; the ref holds the order ──────────────────
CORE_FLAT="$(norm < "$CORE")"
check_core_points_at_ref() {  # $1 = SKILL.md
  local c; c="$(norm < "$1")"
  in_order "$c" '`PR_DRAFT` \(`pr.draft`, default `true`\) is `true` or `false`, from `pipeline-draft-check.sh resolve`, the one resolver' \
    'show its one stderr warning line, if any, once' 'Talos never edits CI config' \
    '`PR_DRAFT = true` reorders Steps 3c-3e \(`ref=draft-order`\)'
}
check_core_points_at_ref "$CORE"; assert_eq "0" "$?" "Step 0: PR_DRAFT comes from the one resolver, which owns the provider fallback and the CI warning, and names ref=draft-order (#435, #547)"
assert_not_contains "$CORE_FLAT" 'pipeline-config.sh pr.draft' "Step 0: no call site reads pr.draft on its own (#435)"
assert_contains "$CORE_FLAT" 'with `PR_DRAFT` this stage runs BEFORE QA on the draft, `ref=draft-order`' "Step 3e: the core says review runs before QA in draft mode and names the ref"
assert_contains "$CORE_FLAT" 'a `draft` wait continues the draft order, never QA' "Step 2: a draft wait continues the draft order and never resumes at QA"
case "$CORE_FLAT" in *'ready-pr failed'*|*'create-pr --draft'*|*'STATE="$(bash scripts/pipeline-vcs.sh pr-is-draft'*) r=1 ;; *) r=0 ;; esac
assert_eq "0" "$r" "the core holds none of the draft procedure (ready-pr failure, create-pr --draft, the pr-is-draft guard): it lives in the ref"

# Structural check (#471): the ref carries the full seven-step Draft stage
# order, in order, plus the two verbatim replay lines (the provider-call table).
DRAFT_ORDER_TEXT="$(draft_text "$SKILL" | norm)"
in_order "$DRAFT_ORDER_TEXT" \
  '1\. \*\*Developer: open the DRAFT PR' \
  '2\. \*\*Docs: CHANGELOG now' \
  '3\. \*\*Review: reviewer, security and adversarial' \
  '4\. \*\*Developer: ONE fix round for every finding' \
  '5\. \*\*`ready-pr`: the ONE CI run' \
  '6\. \*\*QA: on a ready PR only' \
  '7\. \*\*Merge'
assert_eq "0" "$?" "the ref holds the seven Draft stage order anchors, in order"
case "$DRAFT_ORDER_TEXT" in
  *'happy path: create-pr --draft -> ready-pr -> QA, merge'*) r=0 ;;
  *) r=1 ;;
esac
assert_eq "0" "$r" "the happy-path replay line is verbatim"
case "$DRAFT_ORDER_TEXT" in
  *'failure round: draft-pr -> label-pr --remove qa:pass -> developer fix + re-stamps -> ready-pr -> QA, merge'*) r=0 ;;
  *) r=1 ;;
esac
assert_eq "0" "$r" "the failure-round replay line is verbatim"

# ── Prose pins ───────────────────────────────────────────────────────────────
DT="$(draft_text "$SKILL" | norm)"

in_order "$DT" 'Under `VERIFY_QA_MODE` `ci` the PR was just marked ready' 'run the CI gate' '`B` = `min\(VERIFY_CI_WAIT_S, VERIFY_TIMEOUT_MS/1000 - 30\)`' 'the Bash call.s timeout `VERIFY_TIMEOUT_MS`' '2, still pending at `B`, spawns QA'
assert_eq "0" "$?" "QA after ready-pr, under qa_mode ci: the gate is one pr-checks-required --wait call capped under the Bash timeout (#435)"

# The line moved from the playbook into the verb (#468): --draft renders it, the default prompt has none.
assert_contains "$(talos_prompt_text developer --issue 5 --draft)" 'Open the PR as a DRAFT: bash scripts/pipeline-vcs.sh create-pr <branch> "$PR_TITLE" "$BODY_FILE" --draft' "developer prompt: --draft opens the PR with create-pr ... --draft"
assert_not_contains "$(talos_prompt_text developer --issue 5)" 'create-pr' "developer prompt: no create-pr line without --draft"
assert_contains "$DT" 'Every `talos.sh prompt` and every `talos.sh done` takes `--draft`' "the ref sends --draft on every prompt and every done call"


# ── (b) stage order ──────────────────────────────────────────────────────────
check_stage_order() {  # $1 = ref file
  local dt; dt="$(draft_text "$1" | norm)"
  in_order "$dt" \
    '1\. \*\*Developer: open the DRAFT PR' \
    '2\. \*\*Docs: CHANGELOG now' \
    '3\. \*\*Review: reviewer, security and adversarial' \
    '4\. \*\*Developer: ONE fix round for every finding' \
    '5\. \*\*`ready-pr`: the ONE CI run' \
    '6\. \*\*QA: on a ready PR only' \
    '7\. \*\*Merge'
}

check_ready_pr_step() {  # $1 = ref file
  local dt; dt="$(draft_text "$1" | norm)"
  in_order "$dt" \
    '5\. \*\*`ready-pr`: the ONE CI run' \
    'bash scripts/pipeline-vcs\.sh ready-pr <PR_NUMBER>' \
    'The `ready_for_review` event is the only CI trigger in the whole flow' \
    '6\. \*\*QA: on a ready PR only'
}

check_stage_order "$SKILL"; assert_eq "0" "$?" "stage order: developer (draft) -> docs -> review -> fix round -> ready-pr -> QA -> merge"
check_ready_pr_step "$SKILL"; assert_eq "0" "$?" "ready-pr step: the Draft stage order calls ready-pr after review and before QA"

in_order "$DT" '2\. \*\*Docs: CHANGELOG now' 'lands before any approval marker exists and never makes one stale' 'A push to a draft runs no CI' '3\. \*\*Review'
assert_eq "0" "$?" "stage order: the docs commit lands before any approval marker (no docs-induced stale approval, no CI run)"
in_order "$DT" '3\. \*\*Review: reviewer, security and adversarial' 'one parallel batch' 'on the draft' 'never re-dispatch the developer on one role.s verdict'
assert_eq "0" "$?" "stage order: reviewer + security + adversarial review the draft in one parallel batch, no per-role developer dispatch"
in_order "$DT" '3\. \*\*Review: reviewer, security and adversarial' 'one parallel batch' '4\. \*\*Developer: ONE fix round for every finding' 'collect the findings of ALL roles into one fix-round dispatch'
assert_eq "0" "$?" "stage order: adversarial joins the same parallel batch; one fix round covers every role"
in_order "$DT" '4\. \*\*Developer: ONE fix round for every finding' 'collect the findings of ALL roles into one fix-round dispatch' 'call `gate fix-round` once' 'the re-stamps review only the delta' 're-run docs \(step 2\) first, inside this draft window' '5\. \*\*`ready-pr`'
assert_eq "0" "$?" "stage order: one fix round, one gate fix-round, re-stamps on the delta, docs re-runs in the draft window before ready-pr"
in_order "$DT" '\*\*QA failure or CI failure\*\*' 'convert the PR back FIRST with `bash scripts/pipeline-vcs.sh draft-pr <PR_NUMBER>`' 'one developer fix round' 'the re-stamps on the delta' '`ready-pr` again' 'exactly one CI run however many commits'
assert_eq "0" "$?" "stage order: QA/CI failure is draft-pr -> developer fix -> re-stamps -> ready-pr, one run per round"
# The stage-return call (#469) carries the draft choreography: a failed QA is converted
# back first, and a draft review batch is one fix round (`done` never calls `gate
# fix-round`; tests/test-talos-done.sh runs it).
in_order "$DT" 'Every `talos.sh prompt` and every `talos.sh done` takes `--draft`' 'a QA `FAIL` is converted back first \(`draft-pr`, drop `qa:pass`\)' 'CHANGES/FINDINGS answers `next=batch`' 'no attempt is recorded and the developer is not re-dispatched by it'
assert_eq "0" "$?" "stage return: done --draft converts a failed QA back first and batches review findings without recording an attempt"
in_order "$DT" 'Review runs before QA' 'the "only after `qa:pass`" rule of Step 3e does not apply'
assert_eq "0" "$?" "stage order: Step 3e review stages run before QA in draft mode"
# Step 3d Pass path (#340): the note says 3e is not re-entered after QA passes.
in_order "$DT" 'QA passing ends the QA stage' 'Step 3e is NOT entered again' 'already ran on the draft' 'Go to Step 4'
assert_eq "0" "$?" "Step 3d Pass: the ref says Step 3e is not re-entered once QA passes (#340)"
pass_path="$(awk '/^### 3d\. /{p=1} /^### 3e\. /{p=0} p' "$CORE" | awk '/^- \*\*Pass:\*\*/{p=1} /^- \*\*Fail/{p=0} p')"
case "$(printf '%s' "$pass_path" | norm)" in *'review already ran: go to Step 4'*) r=0 ;; *) r=1 ;; esac
assert_eq "0" "$r" "Step 3d Pass: the core's Pass path sends a draft-flow PR to Step 4, not back into 3e (#340)"
in_order "$DT" '7\. \*\*Merge\.\*\* Step 4, unchanged' 'approval SHAs and `ci-complete` on the final head are still required' 'bypasses no gate'
assert_eq "0" "$?" "merge gate: approval SHAs and ci-complete on the final head still required, no draft bypass"
in_order "$DT" '`gate merge` asks `pr-is-draft` itself and never lets a draft through' 'No gate is waived for a draft-flow PR'
assert_eq "0" "$?" "merge gate: no gate is waived for a draft-flow PR and the pr-is-draft guard is left to gate merge"

# The guard itself runs inside `talos.sh gate merge` (#466): the real verb, every
# other gate stubbed green, PR_DRAFT = true. Only a ready PR (pr-is-draft exit 1,
# stdout exactly ready) reaches the merge verdict; exit 2 (unverified) never merges.
GATE_DIR="$SANDBOX/gate-scripts"
mkdir -p "$GATE_DIR"
cp "$TALOS_ROOT"/scripts/* "$GATE_DIR/"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "$1" in' \
  '  view-pr|view-issue) printf "{\"labels\":[{\"name\":\"qa:pass\"},{\"name\":\"review:approved\"},{\"name\":\"security:approved\"},{\"name\":\"docs:done\"}]}\n" ;;' \
  '  pr-is-draft) printf "%s" "${STUB_DRAFT_OUT:-}"; exit "${STUB_DRAFT_RC:-0}" ;;' \
  '  pr-ci-runs) echo 1 ;;' \
  'esac' 'exit 0' > "$GATE_DIR/pipeline-vcs.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo true' > "$GATE_DIR/pipeline-draft-check.sh"
gate_verdict() {  # $1 = pr-is-draft exit code, $2 = its stdout
  STUB_DRAFT_RC="$1" STUB_DRAFT_OUT="$2" bash "$GATE_DIR/talos.sh" gate merge 9 42 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}
assert_eq "verdict=merge ci_runs=1" "$(gate_verdict 1 ready)" "merge gate: PR_DRAFT = true, pr-is-draft exit 1 and ready: gate merge reaches the merge verdict"
assert_eq "verdict=redispatch reason=draft-pr" "$(gate_verdict 0 draft)" "merge gate: a draft (pr-is-draft exit 0) never merges, it goes back to the Draft stage order"
assert_eq "stop reason=draft-unverified" "$(gate_verdict 2 '')" "merge gate: pr-is-draft exit 2 is unverified: do NOT merge"
assert_eq "stop reason=draft-unverified" "$(gate_verdict 1 draft)" "merge gate: exit 1 without the word ready never merges"
in_order "$DT" 'Capture the CI-run count BEFORE `merge-pr`' 'pass `--ci-runs "\$CI_RUNS"` to `post-merge`' 'Never call `pr-ci-runs` after the merge' 'omit the flag, never guess'
assert_eq "0" "$?" "metric: the CI-run count is captured before merge-pr, reaches post_stage via --ci-runs, and is omitted when unverified"

# ── (c) the QA draft guard ───────────────────────────────────────────────────
check_qa_draft_guard() {  # $1 = ref file
  local dt; dt="$(draft_text "$1" | norm)"
  # The core's QA step names the guard before QA is spawned.
  case "$(awk '/^### 3d\. /{p=1} /^### 3e\. /{p=0} p' "$CORE" | norm)" in *'the `pr-is-draft` guard'*) ;; *) return 1 ;; esac
  in_order "$dt" \
    '## QA draft guard' \
    'Before EVERY QA dispatch' \
    'and before any CI wait' \
    'STATE="\$\(bash scripts/pipeline-vcs\.sh pr-is-draft <PR_NUMBER>\)"; RC=\$\?' \
    'Dispatch QA \(and start the CI wait\) ONLY when `RC` is 1 AND `STATE` is exactly `ready`' \
    '`RC` 0 \(`draft`\)' 'Continue the order at the first missing step' \
    '`RC` 2 \(unverified' 'stop this issue for this pass and report `pr-is-draft not verified' \
    'Never read it as `ready` or `draft`'
}

check_qa_draft_guard "$SKILL"; assert_eq "0" "$?" "QA draft guard: QA and the CI wait dispatch only on pr-is-draft exit 1 AND stdout exactly ready; exit 0 and exit 2 start nothing"


# ── Provider stub: a PR with draft state and the tests.yml trigger rule ──────
# Emulates .github/workflows/tests.yml: a run is created on opened /
# synchronize / reopened / ready_for_review, and its jobs are skipped (run
# conclusion `skipped`) while the PR is a draft (`draft != true`). Anything
# else (converted_to_draft, labeled, ...) creates no run.
BIN="$SANDBOX/modelbin"
mkdir -p "$BIN"
export MODEL_STATE="$SANDBOX/model-state"
mkdir -p "$MODEL_STATE"
export PATH="$BIN:$PATH"

cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && exit 0
exec python3 -I "$(dirname "$0")/model-gh.py" "$@"
EOF
cat > "$BIN/model-gh.py" <<'EOF'
# The model GitHub: one PR (#42) with a draft state, labels, a head SHA and a
# QA approval marker, behind the REST calls pipeline-vcs.sh makes
# (`gh api -i -X <METHOD> [--input <file>] <path>`), plus `__event <type>`.
import json, os, re, sys
from urllib.parse import unquote

S = os.environ["MODEL_STATE"]
PRN = 42


def rd(name):
    f = os.path.join(S, name)
    return open(f).read().strip() if os.path.exists(f) else ""


def wr(name, value):
    open(os.path.join(S, name), "w").write(value)


def emit(event):
    if event in ("opened", "synchronize", "reopened", "ready_for_review"):
        conclusion = "skipped" if rd("draft") == "true" else "success"
        open(os.path.join(S, "runs"), "a").write("%s %s\n" % (conclusion, PRN))


def reply(status, body, raw=False):
    sys.stdout.write("HTTP/2.0 %d Model\nX-Stub: 1\r\n\r\n%s\n" % (status, body if raw else json.dumps(body)))
    if status >= 400:
        sys.stderr.write("gh: model error (HTTP %d)\n" % status)
        sys.exit(1)
    sys.exit(0)


argv = sys.argv[1:]
if argv[:1] == ["__event"]:
    emit(argv[1])
    sys.exit(0)
if argv[:2] != ["api", "-i"]:
    if argv[:1] == ["api"]:
        print("acme/widget")   # repo auto-detection
    sys.exit(0)

method, infile, path = "GET", None, ""
i = 2
while i < len(argv):
    if argv[i] == "-X":
        method = argv[i + 1]; i += 2
    elif argv[i] == "-H":
        i += 2
    elif argv[i] == "--input":
        infile = argv[i + 1]; i += 2
    else:
        path = argv[i]; i += 1
payload = json.load(open(infile)) if infile else {}
route = re.sub(r"^repos/[^/]+/[^/]+/?", "", path.split("?")[0])

if method == "POST" and path == "graphql":
    q = payload.get("query", "")
    if "convertPullRequestToDraft" in q:
        wr("draft", "true"); emit("converted_to_draft")
    elif "markPullRequestReadyForReview" in q:
        wr("draft", "false"); emit("ready_for_review")
    reply(200, {"data": {"result": {}}})
if method == "POST" and route == "pulls":
    wr("draft", "true" if payload.get("draft") else "false")
    emit("opened")
    reply(201, {"number": PRN, "html_url": "https://github.com/acme/widget/pull/%d" % PRN})
if route == "pulls/%d" % PRN and method == "GET":
    if os.environ.get("MODEL_FETCH_FAIL"):
        reply(502, {"message": "Bad Gateway"})
    if os.environ.get("MODEL_GARBAGE"):
        reply(200, "nope", raw=True)
    repo = {"full_name": "acme/widget"}
    reply(200, {"number": PRN, "state": "open", "merged_at": None, "draft": rd("draft") == "true",
                "node_id": "PR_model", "mergeable": True,
                "labels": [{"name": l} for l in rd("labels").splitlines() if l],
                "head": {"ref": "feat/issue-332-x", "sha": rd("head"), "repo": repo},
                "base": {"ref": "main", "repo": repo}})
if route == "pulls/%d/merge" % PRN and method == "PUT":
    # Like GitHub: the merge removes the head branch, after which every run for
    # that head comes back with an empty pull_requests[].
    lines = [l.split()[0] + " -" for l in open(os.path.join(S, "runs")).read().splitlines() if l.strip()]
    wr("runs", "\n".join(lines) + ("\n" if lines else ""))
    reply(200, {"merged": True})
if route == "issues/%d/comments" % PRN and method == "GET":
    comments = []
    if rd("qa_sha"):
        comments.append({"id": 1, "user": {"login": "model-bot"}, "created_at": "2026-01-01T00:00:00Z",
                         "body": "QA passed\n\n<!-- talos:approval sha=%s role=qa -->" % rd("qa_sha")})
    reply(200, comments)
if route == "issues/%d/labels" % PRN and method == "POST":
    open(os.path.join(S, "labels"), "a").write("".join(l + "\n" for l in payload.get("labels", [])))
    reply(200, [])
m = re.fullmatch(r"issues/%d/labels/(.+)" % PRN, route)
if m and method == "DELETE":
    name = unquote(m.group(1))
    wr("labels", "".join(l + "\n" for l in rd("labels").splitlines() if l and l != name))
    reply(200, [])
if route == "user":
    reply(200, {"login": "model-bot"})
if route == "actions/runs":
    runs = [l.split() for l in rd("runs").splitlines() if l.strip()]
    reply(200, {"total_count": len(runs), "workflow_runs": [
        {"conclusion": c, "pull_requests": ([] if n == "-" else [{"number": int(n)}])} for c, n in runs]})
reply(200, {})
EOF
chmod +x "$BIN/gh"

printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "base_branch": "main"}\n' > talos.pipeline.json
BODY="$SANDBOX/body.md"; printf 'the body\n' > "$BODY"

# model_reset: a fresh repo state. One run from ANOTHER PR (#99) that reused
# the same branch name is already on record: it must never be counted.
model_reset() {
  printf 'success 99\n' > "$MODEL_STATE/runs"
  echo false > "$MODEL_STATE/draft"
  : > "$MODEL_STATE/labels"
  rm -f "$MODEL_STATE/qa_sha" "$MODEL_STATE/head"
}
push() {  # $1 = number of commits pushed (each is a `synchronize`)
  local i=0; while [ "$i" -lt "$1" ]; do "$BIN/gh" __event synchronize; i=$((i + 1)); done
}
ci_runs() { bash "$VCS" pr-ci-runs 42 2>/dev/null; }

# verb_sequence FILE LABEL -> the provider calls of that documented sequence,
# one per line (`create-pr --draft`, `ready-pr`, `draft-pr`), in order.
verb_sequence() {
  draft_text "$1" > "$SANDBOX/dtext.txt"
  python3 - "$SANDBOX/dtext.txt" "$2" <<'PY'
import sys
path, label = sys.argv[1], sys.argv[2] + ":"
for line in open(path):
    if line.startswith(label):
        for tok in line[len(label):].split("->"):
            words = tok.strip().split()
            if words and words[0] in ("create-pr", "ready-pr", "draft-pr", "label-pr", "pr-ci-runs", "merge-pr", "post_stage"):
                print(" ".join(words))
        break
PY
}

# replay_verbs FILE LABEL N : run the documented sequence against the stub.
# Work (pushes) happens while the PR is a draft: after the PR is opened as a
# draft (developer 3 commits, docs 1, one fix round 2) and after `draft-pr`
# (the QA-failure fix round, N commits). `ready-pr` is followed by QA, which
# pushes nothing. Prints the executed-run count seen just before each ready-pr.
replay_verbs() {
  local verb
  while IFS= read -r verb; do
    case "$verb" in
      "create-pr --draft") bash "$VCS" create-pr feat/issue-332-x "T" "$BODY" --draft </dev/null >/dev/null 2>&1; push 6 ;;
      "draft-pr") bash "$VCS" draft-pr 42 </dev/null >/dev/null 2>&1; push "$3" ;;
      "label-pr --remove qa:pass") bash "$VCS" label-pr 42 --remove qa:pass </dev/null >/dev/null 2>&1 ;;
      "ready-pr") echo "before-ready=$(ci_runs)"; bash "$VCS" ready-pr 42 </dev/null >/dev/null 2>&1 ;;
    esac
  done < <(verb_sequence "$1" "$2")
}

model_happy_runs() {  # $1 = SKILL.md -> executed runs after the happy path
  model_reset
  replay_verbs "$1" "happy path" 0 >/dev/null
  ci_runs
}

model_failure_round_added() {  # $1 = SKILL.md $2 = N pushes -> runs added by one round
  local before
  model_reset
  replay_verbs "$1" "happy path" 0 >/dev/null
  before="$(ci_runs)"
  replay_verbs "$1" "failure round" "$2" >/dev/null
  echo "$(( $(ci_runs) - before ))"
}

# ── (d) run-count model ──────────────────────────────────────────────────────
# The model's trigger rule is the repo's own workflow rule.
WF="$TALOS_ROOT/.github/workflows/tests.yml"
assert_contains "$(cat "$WF")" "types: [opened, synchronize, reopened, ready_for_review]" "model rule: tests.yml runs on opened/synchronize/reopened/ready_for_review"
assert_contains "$(cat "$WF")" "github.event.pull_request.draft != true" "model rule: tests.yml jobs are skipped while the PR is a draft"

# The model measures what it says: a plain (non-draft) flow spends a run on the
# open and on every push.
model_reset
bash "$VCS" create-pr feat/issue-332-x "T" "$BODY" >/dev/null 2>&1; push 6
assert_eq "7" "$(ci_runs)" "run-count model: control, a non-draft PR spends 1 + 6 runs and ignores the other PR's run"

assert_eq "create-pr --draft ready-pr" "$(verb_sequence "$SKILL" "happy path" | tr '\n' ' ' | sed 's/ $//')" "run-count model: documented happy path is create-pr --draft -> ready-pr"
assert_eq "draft-pr label-pr --remove qa:pass ready-pr" "$(verb_sequence "$SKILL" "failure round" | tr '\n' ' ' | sed 's/ $//')" "run-count model: documented failure round is draft-pr -> label-pr --remove qa:pass -> ready-pr (#340)"

model_reset
pre="$(replay_verbs "$SKILL" "happy path" 0)"
assert_eq "before-ready=0" "$pre" "run-count model: no CI run executed during the developer, docs and review stages (6 pushes to a draft)"
assert_eq "1" "$(ci_runs)" "run-count model: happy path is exactly ONE executed CI run, on ready-pr"
assert_eq "1" "$(model_happy_runs "$SKILL")" "run-count model: happy path is exactly ONE executed CI run (fresh replay)"

for n in 3 5 8; do
  assert_eq "1" "$(model_failure_round_added "$SKILL" "$n")" "run-count model: a QA-failure fix round with $n pushes adds exactly ONE run"
done

# Control: the same N pushes without draft-pr spend one run each.
model_reset
bash "$VCS" create-pr feat/issue-332-x "T" "$BODY" --draft >/dev/null 2>&1; push 6
bash "$VCS" ready-pr 42 >/dev/null 2>&1
before="$(ci_runs)"; push 3
assert_eq "3" "$(( $(ci_runs) - before ))" "run-count model: control, pushing a fix round to a READY PR spends 3 runs"

# ── (f) liveness: QA passed, CI failed at Step 4, fix round (#340) ───────────
# QA passes on C1, then Step 4's pr-checks-required fails past its re-run budget.
# The failure round converts the PR to a draft and a developer fix moves the head
# to C2 (a tests/ path, so no approval waiver applies). Step 5 requires
# `check-approval-sha --stale-list` to exit 0 before `ready-pr`. A present-but-
# stale qa:pass makes that impossible: QA is forbidden on a draft, so nothing can
# re-stamp it. The documented failure round must get past that precondition.
git_commit() { git -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
mkdir -p tests
echo one > tests/a; git add tests/a; git_commit commit -m c1
C1="$(git rev-parse HEAD)"
echo two > tests/a; git_commit commit -am c2
C2="$(git rev-parse HEAD)"

# replay_qa_passed_ci_failed FILE -> "ready-pr" when the documented round reaches
# ready-pr, else "blocked: <stale lines>". Replays the real documented sequence:
# the verbs come from FILE's "failure round:" line, the fix lands before step 5.
replay_qa_passed_ci_failed() {
  local verb out
  model_reset
  printf 'qa:pass\n' > "$MODEL_STATE/labels"
  echo "$C1" > "$MODEL_STATE/qa_sha"; echo "$C1" > "$MODEL_STATE/head"
  while IFS= read -r verb; do
    case "$verb" in
      "draft-pr") bash "$VCS" draft-pr 42 </dev/null >/dev/null 2>&1 ;;
      "label-pr --remove qa:pass") bash "$VCS" label-pr 42 --remove qa:pass </dev/null >/dev/null 2>&1 ;;
      "ready-pr")
        echo "$C2" > "$MODEL_STATE/head"   # the developer fix round has landed
        if out="$(bash "$VCS" check-approval-sha 42 --stale-list 2>&1 </dev/null)"; then
          bash "$VCS" ready-pr 42 </dev/null >/dev/null 2>&1; echo "ready-pr"
        else
          printf 'blocked: %s\n' "$(printf '%s' "$out" | grep '^stale' | tr '\n' ' ')"
        fi ;;
    esac
  done < <(verb_sequence "$1" "failure round")
}

# Control: the stale approval really does fail step 5's precondition.
model_reset
printf 'qa:pass\n' > "$MODEL_STATE/labels"; echo "$C1" > "$MODEL_STATE/qa_sha"; echo "$C2" > "$MODEL_STATE/head"
out="$(bash "$VCS" check-approval-sha 42 --stale-list 2>&1)"; rc=$?
assert_eq "1" "$rc" "liveness model: control, a stale qa:pass on a moved head fails check-approval-sha (exit 1)"
assert_contains "$out" "stale role=qa label=qa:pass" "liveness model: control, the stale line names qa:pass"

assert_eq "ready-pr" "$(replay_qa_passed_ci_failed "$SKILL")" "liveness: QA passed, CI failed at Step 4, fix round: the documented sequence reaches ready-pr"
assert_eq "false" "$(cat "$MODEL_STATE/draft")" "liveness: the PR is ready after the round"
assert_eq "0" "$(grep -c 'qa:pass' "$MODEL_STATE/labels")" "liveness: qa:pass is gone, so QA (step 6, qa:pass absent) runs in full on the ready PR"
in_order "$DT" 'QA runs in full on the ready PR' '`qa:pass` absent'
assert_eq "0" "$?" "liveness: the failure round text says QA runs in full on the ready PR"
# A QA FAIL leaves no qa:pass; stripping it must be a harmless no-op.
model_reset; echo "$C1" > "$MODEL_STATE/head"
bash "$VCS" label-pr 42 --remove qa:pass >/dev/null 2>&1; assert_eq "0" "$?" "liveness: stripping an absent qa:pass is a no-op (exit 0)"
# The strip removes only qa:pass: the other approvals stay for the delta re-stamps.
model_reset; printf 'qa:pass\nreview:approved\n' > "$MODEL_STATE/labels"
bash "$VCS" label-pr 42 --remove qa:pass >/dev/null 2>&1
assert_eq "review:approved" "$(cat "$MODEL_STATE/labels")" "liveness: only qa:pass is removed, review:approved stays"

# ── Step 2 resume routing (#470: `talos.sh next` owns the draft check) ───────
check_step2_resume() {  # $1 = SKILL.md
  local s
  s="$(awk '/^## Step 2 — /{p=1} /^## Step 3 — /{p=0} p' "$1" | norm)"
  in_order "$s" \
    'action=dispatch stage=<role> pr=<M> issue=<N>' \
    'action=merge pr=<M> issue=<N>' \
    'a `draft` wait continues the draft order, never QA'
}
check_step2_resume "$CORE"; assert_eq "0" "$?" "Step 2: \`talos.sh next\` answers dispatch/merge/wait, a draft-window PR continues the Draft stage order and never resumes at QA"

# ── (d2) ci_runs is captured BEFORE merge-pr ─────────────────────────────────
# merge-pr deletes the head branch; GitHub then returns every run for that head
# with an empty pull_requests[], so pr-ci-runs can no longer attribute them and
# fails closed (exit 2). The documented Step 4 order must capture the count
# first and carry it to the `merged` post_stage call.
check_ci_runs_before_merge() {  # $1 = ref file
  # The documented sequence reads pr-ci-runs before merge-pr, `gate merge` really
  # reads it before it answers `merge` (pr-ci-runs is called, then the verdict),
  # and Step 4 never calls pr-ci-runs itself after merge-pr.
  local seq verb ci verdict
  seq="$(verb_sequence "$1" "merge sequence" | tr '\n' ' ')"
  case "$seq" in "pr-ci-runs merge-pr "*) ;; *) return 1 ;; esac
  verb="$(sed -n '/^_talos_gate_merge() {/,/^}/p' "$TALOS_ROOT/scripts/talos.sh")"
  ci="$(printf '%s\n' "$verb" | grep -n -m1 -F '_vcs pr-ci-runs' | cut -d: -f1)"
  verdict="$(printf '%s\n' "$verb" | grep -n -F '_talos_verdict merge' | tail -n 1 | cut -d: -f1)"
  [ -n "$ci" ] && [ -n "$verdict" ] && [ "$ci" -lt "$verdict" ] || return 1
  awk '
    /^## Step 4 — /{p=1; next} /^## Step 5 — /{p=0}
    p && /pipeline-vcs\.sh pr-ci-runs/ { late = 1 }
    END { exit late }' "$CORE"
}

# replay_merge FILE : run the documented merge sequence; prints the ci_runs
# value that reaches the `merged` post_stage call ("" when none was captured).
replay_merge() {
  local tok ci="" recorded=""
  while IFS= read -r tok; do
    case "$tok" in
      "pr-ci-runs") ci="$(ci_runs)" ;;
      "merge-pr") bash "$VCS" merge-pr 42 </dev/null >/dev/null 2>&1 ;;
      "post_stage merged --ci-runs") recorded="$ci" ;;
    esac
  done < <(verb_sequence "$1" "merge sequence")
  printf '%s' "$recorded"
}

check_ci_runs_before_merge "$SKILL"; assert_eq "0" "$?" "ci_runs order: gate merge captures pr-ci-runs BEFORE its merge verdict, the sequence has it before merge-pr, and Step 4 never calls it after"
assert_eq "pr-ci-runs merge-pr post_stage merged --ci-runs" "$(verb_sequence "$SKILL" "merge sequence" | tr '\n' ' ' | sed 's/ $//')" "ci_runs order: documented merge sequence is pr-ci-runs -> merge-pr -> post_stage merged --ci-runs"
in_order "$DT" 'Capture the CI-run count BEFORE `merge-pr`' 'empty `pull_requests\[\]`' 'exits 2' 'while the PR is open' 'omit the flag, never guess' 'run summary' 'never blocks or delays an otherwise green merge'
assert_eq "0" "$?" "ci_runs order: exit 2 records no ci_runs, is noted in the run summary, and neither blocks the merge nor waives any gate (#340)"
assert_not_contains "$DT" 'merge anyway' "ci_runs order: no sentence reads as merging without the required checks (#340)"

model_reset
replay_verbs "$SKILL" "happy path" 0 >/dev/null
assert_eq "1" "$(replay_merge "$SKILL")" "ci_runs order: the count captured before merge-pr (1 run) reaches the merged event"
# Realistic stub: after the merge the branch is gone and nothing attributes.
out="$(ci_runs)"; rc=0; bash "$VCS" pr-ci-runs 42 >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "ci_runs order: after merge-pr, pr-ci-runs is unverified (exit 2) because runs lose their pull_requests[]"
assert_eq "" "$out" "ci_runs order: after merge-pr, pr-ci-runs prints no count"

# ── (c) the guard against the real pr-is-draft verb ──────────────────────────
# qa_may_dispatch is the documented rule: dispatch only when pr-is-draft exits 1
# AND its stdout is exactly "ready".
qa_may_dispatch() {
  local state rc
  state="$(bash "$VCS" pr-is-draft 42 2>/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] && [ "$state" = "ready" ]
}
model_reset; echo true > "$MODEL_STATE/draft"
qa_may_dispatch; assert_eq "1" "$?" "QA draft guard: QA does NOT dispatch while the PR is a draft (pr-is-draft exit 0)"
echo false > "$MODEL_STATE/draft"
qa_may_dispatch; assert_eq "0" "$?" "QA draft guard: QA dispatches on a ready PR (pr-is-draft exit 1, stdout ready)"
MODEL_FETCH_FAIL=1 qa_may_dispatch; assert_eq "1" "$?" "QA draft guard: QA does NOT dispatch when the draft state cannot be fetched (exit 2)"
MODEL_GARBAGE=1 qa_may_dispatch; assert_eq "1" "$?" "QA draft guard: QA does NOT dispatch on an unparseable response (exit 2)"
out="$(MODEL_FETCH_FAIL=1 bash "$VCS" pr-is-draft 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "QA draft guard: an unverified draft state is exit 2, neither draft nor ready"
assert_eq "" "$out" "QA draft guard: an unverified draft state prints nothing on stdout"

# ── (e) positive controls ────────────────────────────────────────────────────
# Mutate a copy of the ref and show the named checks turn red.
MUT="$SANDBOX/ref.mutated.md"

# Control 1: remove the ready-pr step (every line that names ready-pr).
grep -v 'ready-pr' "$SKILL" > "$MUT"
check_ready_pr_step "$MUT"; assert_eq "1" "$?" "positive control: without the ready-pr step, 'ready-pr step' check goes red"
check_stage_order "$MUT"; assert_eq "1" "$?" "positive control: without the ready-pr step, 'stage order' check goes red"
[ "$(model_happy_runs "$MUT")" != "1" ]; assert_eq "0" "$?" "positive control: without the ready-pr step, 'run-count happy path' goes red (the PR never leaves draft, CI never runs)"

# Control 2: remove the QA draft guard (every line that names pr-is-draft).
grep -v 'pr-is-draft' "$SKILL" > "$MUT"
check_qa_draft_guard "$MUT"; assert_eq "1" "$?" "positive control: without the QA draft guard, 'QA draft guard' check goes red"

# Control 5 (#340): without the qa:pass strip the replay dead-ends before ready-pr.
sed 's/ -> label-pr --remove qa:pass//' "$SKILL" > "$MUT"
case "$(replay_qa_passed_ci_failed "$MUT")" in "blocked: stale role=qa label=qa:pass"*) r=0 ;; *) r=1 ;; esac
assert_eq "0" "$r" "positive control: without the qa:pass strip the failure round is blocked at step 5 (stale role=qa label=qa:pass)"

# Control 3: the core check does detect a core that no longer points at the ref.
grep -v 'draft-order' "$CORE" > "$MUT"
check_core_points_at_ref "$MUT"; assert_eq "1" "$?" "positive control: a core without ref=draft-order turns 'core points at the ref' red"

# Control 4: capture pr-ci-runs AFTER merge-pr (the defect QA found at 7562576).
awk '/^merge sequence:/ { print "merge sequence:  merge-pr -> pr-ci-runs -> post_stage merged --ci-runs"; next } { print }' "$SKILL" > "$MUT"
check_ci_runs_before_merge "$MUT"; assert_eq "1" "$?" "positive control: pr-ci-runs after merge-pr turns the 'ci_runs order' check red"
model_reset; replay_verbs "$MUT" "happy path" 0 >/dev/null
assert_eq "" "$(replay_merge "$MUT")" "positive control: pr-ci-runs after merge-pr records no ci_runs (runs lost their pull_requests[]), so the replay goes red"


# ── (g) the default path: one resolver (#435) ────────────────────────────────
# `pr.draft` unset is the draft flow on github, gitlab and azure and the ready
# flow on github-api and file; an explicit false always wins. The resolver is
# the one place that knows (Step 0 and pipeline-status-file.sh both call it).
DC="$TALOS_ROOT/scripts/pipeline-draft-check.sh"
RES="$SANDBOX/resolve"; mkdir -p "$RES"
resolve_with() {  # $1 = JSON config; prints "<value>|<stderr>" from an empty repo dir
  printf '%s\n' "$1" > "$RES/cfg.json"
  ( cd "$RES" && PIPELINE_CONFIG="$RES/cfg.json" bash "$DC" resolve 2>"$RES/err" | tr -d '\n'; printf '|%s' "$(cat "$RES/err")" )
}
for prov in github gitlab azure; do
  cfg_unset='{"vcs":{"provider":"'$prov'"}}'
  cfg_true='{"vcs":{"provider":"'$prov'"},"pr":{"draft":true}}'
  cfg_false='{"vcs":{"provider":"'$prov'"},"pr":{"draft":false}}'
  assert_eq "true|" "$(resolve_with "$cfg_unset")" "default: pr.draft unset on $prov resolves to true, silently"
  assert_eq "true|" "$(resolve_with "$cfg_true")" "default: explicit true on $prov resolves to true"
  assert_eq "false|" "$(resolve_with "$cfg_false")" "default: explicit false on $prov wins, silently"
done
assert_eq "true|" "$(resolve_with '{}')" "default: no provider key is github, true"
assert_eq "false|pipeline: pr.draft ignored: provider github-api cannot open draft PRs" "$(resolve_with '{"vcs":{"provider":"github-api"}}')" "default: unset on github-api resolves to false with the one-line warning"
assert_eq "false|pipeline: pr.draft ignored: provider github-api cannot open draft PRs" "$(resolve_with '{"vcs":{"provider":"github-api"},"pr":{"draft":true}}')" "default: explicit true on github-api resolves to false with the one-line warning"
assert_eq "false|" "$(resolve_with '{"vcs":{"provider":"github-api"},"pr":{"draft":false}}')" "default: explicit false on github-api is false, silently"
assert_eq "false|" "$(resolve_with '{"vcs":{"provider":"file"}}')" "default: unset on file resolves to false, silently (no PRs exist there)"
assert_eq "false|pipeline: pr.draft ignored: provider file cannot open draft PRs" "$(resolve_with '{"vcs":{"provider":"file"},"pr":{"draft":true}}')" "default: explicit true on file resolves to false with the one-line warning"
assert_eq "false|" "$(resolve_with '{"vcs":{"provider":"file"},"pr":{"draft":false}}')" "default: explicit false on file is false, silently"
assert_eq "true|" "$(resolve_with '{"pr":{"draft":"TRUE"}}')" "default: the key is case-insensitive"
assert_eq "true|" "$(resolve_with '{"pr":{"draft":"banana"}}')" "default: a junk value reads as unset (the default)"

# Step 0 and the status file share it: neither hard-codes the default any more.
assert_contains "$(cat "$TALOS_ROOT/scripts/pipeline-status-file.sh")" 'pipeline-draft-check.sh" resolve' "status file: asks the same resolver as Step 0"
assert_not_contains "$(cat "$TALOS_ROOT/scripts/pipeline-status-file.sh")" 'cfg pr.draft' "status file: no hard-coded pr.draft default"

finish
