#!/usr/bin/env bash
# test-spec-check.sh -- the spec's `Tests:` line is checked when the PM posts
# it, not at QA (#594). `talos.sh done pm` runs `pipeline-criteria.sh
# spec-check <issue>`, the parser qa-run uses, on the spec just recorded: a line
# qa-run would refuse (or `(test)` criteria with no usable `Tests:` line) hands
# the issue back to the PM before any developer work starts.
#   AC1  an annotated `Tests:` line is caught at `done pm`: next=fix-round
#        stage=pm, the issue back at pipeline:confirmed, the reason on the issue
#   AC2  a clean spec passes: next=continue, nothing written
#   AC3  `(test)` criteria and no usable `Tests:` line: caught the same way
#   AC4  `spec-check` answers with the parser's own reason, one line
#   AC5  nothing to check is not a refusal (no PM spec comment, a BLOCKED PM,
#        a spec that cannot be read)
#   AC6  `talos.sh run`: the refused spec is a counted PM round (`gate fix-round
#        <N> pm`), the PM runs again, the developer does not; at the ceiling
#        the run stops blocked
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
ERR="$SANDBOX/stderr"

# ── fixture: a copied scripts dir with stubbed providers (as test-talos-run.sh) ─
# <key> is the verb of pipeline-vcs.sh, else the script's name;
# $STUB_DIR/<key>[.<first arg>]{,.out,.err,.rc} is what it answers (rc 0 by
# default). view-issue.9 answers both the route read and `view-issue 9 --spec`.
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
if [ "$n" = "vcs" ]; then key="$1"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
if [ "$key" = "list-prs" ] || [ "$key" = "list-needs-owner" ] || [ "$key" = "list-issues" ]; then printf "[]"; exit 0; fi
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then { printf "[%s]\n" "$1 $2"; cat "$a"; } >> "$d/bodies"; fi
  prev="$a"
done
if [ "$n" = "hooks" ] || { [ "$n" = "notify" ] && [ "${3:-}" = "-" ]; }; then cat > /dev/null; fi
a1="${2:-}"
if [ -f "$d/$key.$a1.err" ]; then cat "$d/$key.$a1.err" >&2; elif [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
if [ -f "$d/$key.$a1" ]; then cat "$d/$key.$a1"; elif [ -f "$d/$key" ]; then cat "$d/$key"; fi
rc=0
if [ -f "$d/$key.$a1.rc" ]; then rc="$(cat "$d/$key.$a1.rc")"; elif [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-events.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done

# The agent stub: journals the dispatch, prints a final message, and runs the
# Nth dispatch's hook (hook.<role>.<N>): the stage's real work on the fixture.
cat > "$GS/pipeline-agent.sh" <<'TALOS_stubagentQ4nYb7Kd'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
role="$1"
cat > /dev/null
printf "agent %s\n" "$role" >> "$d/journal"
printf 'spec posted, branch fix/issue-9-greet\n'
cnt="$(grep -c "^agent $role\$" "$d/journal")"
if [ -f "$d/hook.$role.$cnt" ]; then . "$d/hook.$role.$cnt"; fi
exit 0
TALOS_stubagentQ4nYb7Kd

# The collect stub: issue 9 is queued, no PR.
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatusM2vHc8Rt'
#!/usr/bin/env bash
printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [9], "held": [], "owners": [], "capped": []}'
TALOS_stubstatusM2vHc8Rt

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '%s' '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"pm": true, "developer": true}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
  > "$PIPELINE_CONFIG"

# spec LINE...: a PM spec with AC1 (test) and AC2 (prose) in $SPEC; each
# argument is one line after the criteria (none: no `Tests:` line at all).
SPEC="$SANDBOX/spec.md"
spec() {
  {
    printf '**PM spec:** greeting\n\n**Goal:** greet.\n\n**Acceptance criteria**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n'
    printf -- '- [ ] AC2 the README names it (prose: doc wording)\n\n'
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
    printf '**Files likely to change:** `feature.txt`\n'
  } > "$SPEC"
}
# issue_with LABEL [SPEC_FILE]: issue 9 as view-issue answers it, with one
# label and, with SPEC_FILE, the PM spec as its one comment.
issue_with() {
  python3 -I -c 'import json, sys
c = [{"body": open(sys.argv[2]).read()}] if len(sys.argv) > 2 else []
print(json.dumps({"number": 9, "title": "t", "state": "open", "body": "- [ ] an item of the issue body",
                  "labels": [{"name": sys.argv[1]}], "comments": c}))' "$@" > "$STUB_DIR/view-issue.9"
}
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$SANDBOX/.git/talos-lease.ledger" "$SANDBOX/.git/talos-lease.ledger.lock.d"
  printf 1 > "$STUB_DIR/has-spec.rc"
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
bodies() { cat "$STUB_DIR/bodies" 2>/dev/null; }
SUM="$SANDBOX/summary.txt"
printf 'greet — 2 acceptance criteria, branch fix/issue-9-greet\n' > "$SUM"
# dn <args...>: `done pm` for issue 9 on the stubbed scripts directory.
dn() { OUT="$(bash "$GS/talos.sh" done pm --issue 9 --summary-file "$SUM" "$@" 2>"$ERR" < /dev/null)"; RC=$?; }
line_of() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n 1; }
sc() { OUT="$(bash "$GS/pipeline-criteria.sh" spec-check "$@" 2>"$ERR")"; RC=$?; }

BACK="vcs label-issue 9 --add pipeline:confirmed --remove pipeline:dev"
# The line that cost #583 a QA fail: a note with a `;` beside the test list.
ANNOTATED='**Tests:** `tests/test-greet.sh` (new; AC1 to AC2). Name filter: `AC1`'
CLEAN='**Tests:** `tests/test-greet.sh` `AC1`'

# ── AC1: an annotated Tests: line is caught at `done pm` ─────────────────────
reset_stubs
spec "$ANNOTATED"
issue_with pipeline:dev "$SPEC"
dn
assert_eq "0" "$RC" "AC1 annotated Tests: line: done pm still exits 0 (the stage ran)"
assert_eq "done=ok" "$(printf '%s\n' "$OUT" | head -n 1)" "AC1 annotated Tests: line: done=ok first"
assert_eq "fix-round stage=pm" "$(line_of next)" "AC1 annotated Tests: line: next is the PM's fix round, not the developer"
assert_contains "$(journal)" "vcs view-issue 9 --spec" "AC1 annotated Tests: line: the spec just recorded is the one read"
assert_contains "$(journal)" "$BACK" "AC1 annotated Tests: line: the issue goes back to pipeline:confirmed, where next routes the PM"
assert_contains "$(journal)" "vcs comment-issue 9 --body-file" "AC1 annotated Tests: line: the reason is posted on the issue, where the PM reads it"
assert_contains "$(bodies)" "shell syntax beside the test list" "AC1 annotated Tests: line: the comment carries the parser's reason"
case "$(bodies | sed -n 2p)" in
  '**Agent:**'* | '**PM spec:**'* | '') _lead=stage ;;
  *) _lead=plain ;;
esac
assert_eq "plain" "$_lead" "AC1 annotated Tests: line: the comment is no stage comment, so view-issue --since-stage shows it after the spec"
assert_not_contains "$(bodies)" "<!-- talos:" "AC1 annotated Tests: line: the comment carries no marker (a marker comment is hidden from the PM)"
assert_contains "$(journal)" "hooks post_stage pm pm 9" "AC1 annotated Tests: line: the PM stage is still recorded"
# The bare form (no backticks) with the same note is refused too.
reset_stubs
spec '**Tests:** tests/test-greet.sh (new; AC1 to AC2)'
issue_with pipeline:dev "$SPEC"
dn
assert_eq "fix-round stage=pm" "$(line_of next)" "AC1 annotated bare Tests: line: next is the PM's fix round"

# ── AC2: a clean spec passes ─────────────────────────────────────────────────
reset_stubs
spec "$CLEAN"
issue_with pipeline:dev "$SPEC"
dn
assert_eq "0" "$RC" "AC2 clean spec: exit 0"
assert_eq "continue" "$(line_of next)" "AC2 clean spec: next=continue (the developer is next)"
assert_contains "$(journal)" "vcs view-issue 9 --spec" "AC2 clean spec: the spec was checked"
assert_not_contains "$(journal)" "label-issue" "AC2 clean spec: no label is touched"
assert_not_contains "$(journal)" "comment-issue" "AC2 clean spec: nothing is posted"
assert_not_contains "$OUT" "warn" "AC2 clean spec: no warning"
# The note on its own line, as agents/pm.md asks, is clean too.
reset_stubs
spec '**Tests:** `tests/test-greet.sh`' 'Note: the file is new; it covers AC1 to AC2.'
issue_with pipeline:dev "$SPEC"
dn
assert_eq "continue" "$(line_of next)" "AC2 clean spec: a note on its own line below the Tests: line passes"
# A prose-only spec has nothing to run and needs no Tests: line.
reset_stubs
printf '**PM spec:** x\n- [ ] AC1 the README is clear (prose: wording)\n' > "$SPEC"
issue_with pipeline:dev "$SPEC"
dn
assert_eq "continue" "$(line_of next)" "AC2 clean spec: prose only, no Tests: line needed"

# ── AC3: (test) criteria and no usable Tests: line ───────────────────────────
reset_stubs
spec
issue_with pipeline:dev "$SPEC"
dn
assert_eq "fix-round stage=pm" "$(line_of next)" "AC3 no Tests: line: next is the PM's fix round"
assert_contains "$(journal)" "$BACK" "AC3 no Tests: line: the issue goes back to pipeline:confirmed"
assert_contains "$(bodies)" "no Tests: line" "AC3 no Tests: line: the comment says what is missing"
reset_stubs
spec '**Tests:**'
issue_with pipeline:dev "$SPEC"
dn
assert_eq "fix-round stage=pm" "$(line_of next)" "AC3 an empty Tests: line: next is the PM's fix round"

# ── AC4: spec-check, the parser's answer in one line ─────────────────────────
reset_stubs
spec "$ANNOTATED"
issue_with pipeline:dev "$SPEC"
sc 9
assert_eq "1" "$RC" "AC4 spec-check: a refused Tests: line exits 1"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "AC4 spec-check: a refusal is exactly one line"
assert_contains "$OUT" "spec-check: refused" "AC4 spec-check: the line says refused"
assert_contains "$OUT" "shell syntax beside the test list" "AC4 spec-check: with the parser's reason, the one qa-run prints"
assert_eq "vcs view-issue 9 --spec" "$(journal)" "AC4 spec-check: one read, nothing written, nothing run"
reset_stubs
spec '**Tests:** `npm test`'
issue_with pipeline:dev "$SPEC"
sc 9
assert_contains "$OUT" "a runner command, not a test path" "AC4 spec-check: a runner command is refused with the parser's reason"
reset_stubs
spec "$CLEAN"
issue_with pipeline:dev "$SPEC"
sc 9
assert_eq "0" "$RC" "AC4 spec-check: a clean spec exits 0"
assert_eq "spec-check: ok" "$OUT" "AC4 spec-check: a clean spec is ok"
reset_stubs
spec
issue_with pipeline:dev "$SPEC"
sc 9
assert_eq "1" "$RC" "AC4 spec-check: (test) criteria with no Tests: line exits 1"
assert_contains "$OUT" "1 (test) criteria but no Tests: line" "AC4 spec-check: it counts the (test) criteria left unprovable"
sc '9;id'
assert_eq "2" "$RC" "AC4 spec-check: an issue id with shell syntax is usage (exit 2)"

# ── AC5: nothing to check is not a refusal ───────────────────────────────────
# No PM spec comment (an epic proposal, a provider without one): the issue body
# is not what the PM recorded, so it is never checked in its place.
reset_stubs
issue_with pipeline:blocked
sc 9
assert_eq "0" "$RC" "AC5 no PM spec comment: spec-check exits 0"
assert_contains "$OUT" "spec-check: skipped" "AC5 no PM spec comment: spec-check says skipped"
dn
assert_eq "continue" "$(line_of next)" "AC5 no PM spec comment: next=continue"
assert_not_contains "$(journal)" "label-issue" "AC5 no PM spec comment: no label is touched"
# A PM that ended BLOCKED posted no spec to check.
reset_stubs
spec "$ANNOTATED"
issue_with pipeline:dev "$SPEC"
dn --verdict BLOCKED
assert_eq "stop" "$(line_of next)" "AC5 a BLOCKED PM: next=stop as before"
assert_not_contains "$(journal)" "view-issue 9 --spec" "AC5 a BLOCKED PM: the spec is not checked"
assert_not_contains "$(journal)" "pipeline:confirmed" "AC5 a BLOCKED PM: the issue is not handed back"
# A spec that cannot be read is a warning: QA's own check still stands behind it.
reset_stubs
printf 1 > "$STUB_DIR/view-issue.rc"
sc 9
assert_eq "3" "$RC" "AC5 unreadable spec: spec-check exits 3"
dn
assert_eq "0" "$RC" "AC5 unreadable spec: done pm exits 0"
assert_contains "$OUT" "warn reason=spec-check-failed issue=9" "AC5 unreadable spec: a warning names it"
assert_eq "continue" "$(line_of next)" "AC5 unreadable spec: next=continue"
assert_not_contains "$(journal)" "label-issue" "AC5 unreadable spec: no label is touched"
assert_contains "$(sed -n 's/^# done-reasons: //p' "$TALOS_ROOT/scripts/talos.sh")" "spec-check-failed" \
  "AC5 unreadable spec: the warning is on done's reason list"

# ── AC6: talos.sh run, the refused spec is a counted PM round ────────────────
rn() { OUT="$(TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 bash "$GS/talos.sh" run "$@" 2>"$ERR")"; RC=$?; }
order() { grep -oE "agent [a-z]+|vcs record-attempt 9 [a-z]+|$BACK|vcs comment-issue 9" "$STUB_DIR/journal" | tr '\n' '>' | sed 's/>$//'; }
# The second PM run posts a clean spec and advances the label, as the PM does.
pm_fixture() {
  reset_stubs
  spec "$ANNOTATED"
  issue_with pipeline:confirmed "$SPEC"
  spec "$CLEAN"
  issue_with pipeline:dev "$SPEC"
  mv "$STUB_DIR/view-issue.9" "$STUB_DIR/view-issue.clean"
  spec "$ANNOTATED"
  issue_with pipeline:confirmed "$SPEC"
  cat > "$STUB_DIR/hook.pm.2" <<'HOOK'
cp "$d/view-issue.clean" "$d/view-issue.9"
HOOK
}
pm_fixture
rn --issue 9 --max-iterations 2
assert_eq "0" "$RC" "AC6 run: the run exits 0"
assert_eq "agent pm>$BACK>vcs comment-issue 9>vcs record-attempt 9 pm>agent pm" "$(order)" \
  "AC6 run: refused spec -> back to confirmed, the reason posted -> gate fix-round (record-attempt) -> the PM again, no developer"
# The ceiling: the gate blocks, the run stops, the PM is not dispatched again.
pm_fixture
printf 'pipeline-vcs: record-attempt: max_fix_attempts (3) reached for pm\n' > "$STUB_DIR/record-attempt.err"
printf 1 > "$STUB_DIR/record-attempt.rc"
rn --issue 9 --max-iterations 5
assert_eq "0" "$RC" "AC6 run at the ceiling: the stop exits 0"
assert_contains "$OUT" "stop verdict=block reason=max-fix-attempts" "AC6 run at the ceiling: the gate's block ends the run"
assert_eq "1" "$(grep -c '^agent pm$' "$STUB_DIR/journal")" "AC6 run at the ceiling: the PM ran once, never to --max-iterations"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "AC6 run at the ceiling: the issue is blocked for a human"
assert_not_contains "$(journal)" "agent developer" "AC6 run at the ceiling: no developer work starts"

finish
