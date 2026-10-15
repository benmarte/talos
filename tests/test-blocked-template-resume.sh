#!/usr/bin/env bash
# test-blocked-template-resume.sh -- a PR left blocked by a review finding is
# taken to the developer fix round by a later `talos.sh run --issue <N>`, for
# the comment bodies the profiles really post (#711).
#
# The cross-run resume (#639) finds the finding comment with one findings-line
# pattern (_TALOS_FINDING_RE in scripts/talos.sh). Every comment body here is
# rendered from the real templates/comments/*.md with string.Template, as
# _TALOS_RENDER_PY does, so a template change that breaks the reader fails.
# Scaffolding (stubbed vcs/agent/collect) is copied from test-talos-run.sh.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
TALOS="$TALOS_ROOT/scripts/talos.sh"
ERR="$SANDBOX/stderr"

# ── fixture: a copied scripts dir with stubbed providers ──────────────────────
# <key> is the verb of pipeline-vcs.sh, else the script's name;
# $STUB_DIR/<key>.{out,err,rc} is what it answers (rc 0 by default).
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
mkdir -p "$SANDBOX/templates"
mkdir -p "$SANDBOX/templates/prompts"
cp -R "$TALOS_ROOT/templates/prompts/." "$SANDBOX/templates/prompts/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="$1"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
if [ -f "$d/hook.$key" ]; then . "$d/hook.$key"; fi
if [ "$key" = "list-prs" ]; then printf '%s' "${LIST_PRS:-[]}"; exit 0; fi
if [ "$key" = "list-needs-owner" ]; then printf '%s' "${LIST_OWNERS:-[]}"; exit 0; fi
if [ "$key" = "list-issues" ]; then printf '%s' "${LIST_ISSUES:-[]}"; exit 0; fi
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then { printf "[%s]\n" "$*"; cat "$a"; } >> "$d/bodies"; fi
  prev="$a"
done
if [ "$n" = "hooks" ]; then cat > "$d/hooks.stdin"; fi
if [ "$n" = "notify" ] && [ "${3:-}" = "-" ]; then cat > "$d/notify.stdin"; fi
a1="${2:-}"
if [ -f "$d/$key.$a1.err" ]; then cat "$d/$key.$a1.err" >&2; elif [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
if [ -f "$d/$key.$a1.out" ]; then cat "$d/$key.$a1.out"
elif [ -f "$d/$key.$a1" ]; then cat "$d/$key.$a1"
elif [ -f "$d/$key.out" ]; then cat "$d/$key.out"
elif [ -f "$d/$key" ]; then cat "$d/$key"; fi
rc=0
if [ -f "$d/$key.$a1.rc" ]; then rc="$(cat "$d/$key.$a1.rc")"; elif [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done

# The agent stub: journals the dispatch and the prompt it received on stdin; the
# Nth dispatch of a role may run a hook (hook.<role>.<N>).
cat > "$GS/pipeline-agent.sh" <<'TALOS_stubagentN4pKd7Wz'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
role="$1"
cat > "$d/agent.stdin"
printf "agent %s\n" "$role" >> "$d/journal"
if [ -f "$d/message.$role" ]; then cat "$d/message.$role"; fi
cnt="$(grep -c "^agent $role\$" "$d/journal")"
if [ -f "$d/message.$role.$cnt" ]; then cat "$d/message.$role.$cnt"; fi
if [ -f "$d/hook.$role.$cnt" ]; then . "$d/hook.$role.$cnt"; fi
exit 0
TALOS_stubagentN4pKd7Wz

cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusQ8vLt2Hc'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
printf 'status-file collect\n' >> "$d/journal"
printf '%s' "$(cat "$d/collect.json" 2>/dev/null || echo '{}')"
exit 0
TALOS_stubstatusQ8vLt2Hc

RUN="$GS/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
LEASE="$SANDBOX/.git/talos-lease.ledger"
LEASE_RESET() { rm -f "$LEASE" "${LEASE:?}.lock.d"; }
rn() { OUT="$(bash "$RUN" run "$@" 2>"$ERR")"; RC=$?; }
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
rev_order() { grep -oE 'agent [a-z]+|vcs record-attempt 9 [a-z]+ --pr 12|label-pr 12 --remove pipeline:blocked' "$STUB_DIR/journal" | tr '\n' '>' | sed 's/>$//'; }
rev_count() { journal | grep -c "$1"; }

# fixture: a PR (12, issue 9) at collect stage `blocked`, no PR-side state but
# its comments; a fix round that pushes a new head and records its prompt.
# $1 = the owner question's status (answered, unanswered), or none.
blocked_fixture() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  LEASE_RESET
  printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": false}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
    > "$SANDBOX/talos.pipeline.json"
  if [ "$1" = none ]; then
    printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"blocked"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.json"
  else
    printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":true,"stage":"blocked"}],"pr_total":1,"ignored":0,"blocked":[["PR",12]],"queued":[],"held":[],"owners":[{"n":12,"status":"%s","question":"Which design?"}],"capped":[]}' "$1" > "$STUB_DIR/collect.json"
  fi
  printf '{"number": 9, "title": "t", "labels": [], "body": "body", "state": "open"}' > "$STUB_DIR/view-issue.9"
  printf '{"labels": [], "state": "open"}' > "$STUB_DIR/view-pr.12"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  printf 'https://github.com/acme/widget/pull/12\nfixed the findings\n' > "$STUB_DIR/message.developer"
  cat > "$STUB_DIR/hook.developer.1" <<'HOOK'
cp "$d/agent.stdin" "$d/developer.prompt"
printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"
HOOK
}

# render <template> <role> <verdict> <summary> <details>: a comment body from the
# real template, filled the way _TALOS_RENDER_PY fills it.
render() {
  HEADER="**Agent:** $2 (talos)" ISSUE=9 PR=12 VERDICT="$3" SUMMARY="$4" DETAILS="$5" \
    BLOCKED_BY="scripts/x.sh:12 (interpreted)" ATTENTION_REPORT="scripts/x.sh:12 asserts nothing" \
    python3 -I -c 'import os, string, sys
print(string.Template(open(sys.argv[1]).read()).substitute(os.environ).strip())' "$TALOS_ROOT/templates/comments/$1.md"
}
# comments_json <body>...: the PR's read-comments answer, one comment per body.
comments_json() {
  python3 -I -c 'import json, sys
print(json.dumps({"comments": [{"author": {"login": "bot"}, "body": b} for b in sys.argv[1:]]}))' "$@" > "$STUB_DIR/read-comments.12"
}
FINDING="1. scripts/x.sh:12 asserts nothing (the-blocked-finding)"
QUESTION="Design decision needed: reviewer blocked PR #12 repeatedly on scripts/x.sh. Which design?

<!-- talos:needs-owner -->"
go() { TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --issue 9 --max-iterations 1; }

# ── AC1: the real blocked.md reviewer comment resumes to the fix round ────────
blocked_fixture none
comments_json "$(render blocked reviewer "" "2 findings: scripts/x.sh:12 asserts nothing" "$FINDING")"
go
assert_eq "0" "$RC" "AC1 run --issue on a PR blocked by a blocked.md reviewer comment exits 0"
assert_eq "vcs record-attempt 9 reviewer --pr 12>label-pr 12 --remove pipeline:blocked>agent developer" "$(rev_order)" \
  "AC1 the gate fix-round for reviewer, the unblock, then the developer fix round"
assert_not_contains "$OUT" "action=wait reason=blocked" "AC1 the run does not end on the blocked wait"
assert_contains "$(cat "$STUB_DIR/developer.prompt" 2>/dev/null)" "Fix round: PR #12 is already open" "AC1 the developer got the fix-round shape of the prompt"

# ── AC2: the owner's reply reaches the fix round with the findings ────────────
blocked_fixture answered
comments_json "$(render blocked reviewer "" "2 findings: scripts/x.sh:12 asserts nothing" "$FINDING")" "$QUESTION" "Use the second design."
go
assert_eq "0" "$RC" "AC2 run --issue on an answered owner question exits 0"
assert_eq "vcs record-attempt 9 reviewer --pr 12>label-pr 12 --remove pipeline:blocked>agent developer" "$(rev_order)" \
  "AC2 the answered question goes to the fix round for the reviewer"
AC2_PROMPT="$(cat "$STUB_DIR/developer.prompt" 2>/dev/null)"
assert_contains "$AC2_PROMPT" "(the-blocked-finding)" "AC2 the fix round holds the blocked.md findings text"
assert_contains "$AC2_PROMPT" "The owner answered the design question:
Use the second design." "AC2 the fix round holds the owner's reply"

# ── AC3: a non-finding reviewer verdict and a foreign role's Blocked do not resume
blocked_fixture none
comments_json "$(render review-signoff reviewer APPROVED "looks fine" "no findings")"
go
assert_eq "0" "$(rev_count '^agent developer$')" "AC3 a reviewer APPROVED comment is not taken to the fix round"
assert_contains "$OUT" "action=wait reason=blocked" "AC3 that PR still ends on the blocked wait"
blocked_fixture none
comments_json "$(render blocked developer "" "1 finding: the build needs a secret" "$FINDING")"
go
assert_eq "0" "$(rev_count '^agent developer$')" "AC3 a Blocked line in a developer comment is not taken to the fix round"
assert_contains "$OUT" "action=wait reason=blocked" "AC3 the developer-blocked PR still ends on the blocked wait"

# ── AC4: the signoff templates still resume ───────────────────────────────────
blocked_fixture none
comments_json "$(render security-signoff security FINDINGS "1 finding" "$FINDING")"
go
assert_eq "vcs record-attempt 9 security --pr 12>label-pr 12 --remove pipeline:blocked>agent developer" "$(rev_order)" \
  "AC4 a security-signoff FINDINGS comment resumes to the fix round for security"
blocked_fixture none
comments_json "$(render review-signoff reviewer CHANGES "1 finding" "$FINDING")"
go
assert_eq "vcs record-attempt 9 reviewer --pr 12>label-pr 12 --remove pipeline:blocked>agent developer" "$(rev_order)" \
  "AC4 a review-signoff CHANGES comment resumes to the fix round for reviewer"

finish
