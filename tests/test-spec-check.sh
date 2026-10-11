#!/usr/bin/env bash
# test-spec-check.sh -- the spec's `Tests:` line is checked at `done pm`, before
# any developer work (#594).
#   AC1-AC3   `pipeline-criteria.sh spec-check <spec-file>`: the parser qa-run
#             uses, on a file, one line and an exit code (ok, refused, missing)
#   AC4-AC11  `talos.sh done pm`: one `view-issue <N> --spec` read; a refused
#             spec is an attempt, the label back at pipeline:confirmed, one
#             `**Spec check:**` comment, `spec_check=<slug>` and
#             `next=fix-round stage=pm` (`next=stop` at the attempt ceiling)
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
ERR="$SANDBOX/stderr"

# ── fixture: the journaling stub sandbox of test-talos-done.sh ───────────────
# A copy of the scripts directory with pipeline-vcs.sh and the relay scripts as
# one journaling stub (pipeline-criteria.sh is the real one). A vcs call looks up
# $STUB_DIR/<verb>.<first arg>.{out,err,rc}, then $STUB_DIR/<verb>.{out,err,rc}
# (rc 0 by default); the file of a `--body-file <path>` is copied to
# $STUB_DIR/body.
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
case " $* " in *" --line "*) sfx=line ;; *) sfx="" ;; esac
if [ "$n" = "vcs" ]; then cands="${1:-}.${2:-} ${1:-}"
else cands="$n.${1:-}.$sfx $n.${1:-} $n"; fi
key=""
for c in $cands; do
  if [ -e "$d/$c.out" ] || [ -e "$d/$c.err" ] || [ -e "$d/$c.rc" ]; then key="$c"; break; fi
done
printf "%s %s\n" "$n" "$*" >> "$d/journal"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ] && [ -f "$a" ]; then cat "$a" > "$d/body"; fi
  prev="$a"
done
if [ "$n" = "notify" ] && [ "${3:-}" = "-" ]; then cat > /dev/null; fi
if [ -n "$key" ]; then
  if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
  if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
  if [ -f "$d/$key.rc" ]; then exit "$(cat "$d/$key.rc")"; fi
fi
exit 0
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-status.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done

# set_stub <key> <rc> [out] [err]
set_stub() {
  printf '%s\n' "$2" > "$STUB_DIR/$1.rc"
  printf '%s' "${3:-}" > "$STUB_DIR/$1.out"
  printf '%s' "${4:-}" > "$STUB_DIR/$1.err"
}
# comments.enabled is off: the `**Spec check:**` comment is posted all the same.
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  printf '%s' '{"vcs": {"provider": "github"}, "comments": {"enabled": false}}' > "$SANDBOX/talos.pipeline.json"
  set_stub events.cost.line 0 "spend: 12 tokens"
}
# jr: the journal with the scratch paths normalised.
jr() { sed 's| --summary-file [^ ]*| --summary-file F|; s| --body-file [^ ]*| --body-file F|' "$STUB_DIR/journal" 2>/dev/null; }
body() { cat "$STUB_DIR/body" 2>/dev/null; }

# spec LINE...: a PM spec with AC1 (test) and AC2 (prose) in $SPEC; each
# argument is one line after the criteria (none: no `Tests:` line at all).
SPEC="$SANDBOX/spec.md"
spec() {
  {
    printf '**PM spec:** greeting\n\n**Goal:** greet.\n\n**Acceptance criteria:**\n'
    printf -- '- [ ] AC1 `greet` prints hello (test)\n'
    printf -- '- [ ] AC2 the README names it (prose: doc wording)\n\n'
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
    printf '\n**Files likely to change:**\n- `feature.txt`\n'
  } > "$SPEC"
}
# posted: `view-issue 9 --spec` answers issue 9 with $SPEC as its PM spec comment.
posted() {
  python3 -I -c 'import json, sys
print(json.dumps({"title": "t", "body": "- [ ] an item of the issue body", "labels": [{"name": "pipeline:dev"}],
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$SPEC" > "$STUB_DIR/view-issue.9.out"
}
SUM="$SANDBOX/summary.txt"
printf 'greet — 2 acceptance criteria, branch fix/issue-9-greet\n' > "$SUM"
# sc <args...>: `pipeline-criteria.sh spec-check`; dn <args...>: `done pm` for issue 9.
sc() { OUT="$(bash "$GS/pipeline-criteria.sh" spec-check "$@" 2>"$ERR")"; RC=$?; }
dn() { OUT="$(bash "$GS/talos.sh" done pm --issue 9 --summary-file "$SUM" "$@" 2>"$ERR" < /dev/null)"; RC=$?; }
writes() { grep -cE '^vcs (record-attempt|label-issue|comment-issue) ' "$STUB_DIR/journal" 2>/dev/null; }

# The line that cost #583 a QA fail: a note with a `;` beside the test list.
ANNOTATED='**Tests:** `tests/test-lean-stage-prompts.sh` (new; AC1 to AC4). Name filter: the id'
RELAY="notify pm #9 - 9
hooks post_stage pm pm 9 --summary-file F
events cost --issue 9 --line"
REFUSED_WRITES="vcs view-issue 9 --spec
vcs record-attempt 9 pm
vcs label-issue 9 --add pipeline:confirmed --remove pipeline:dev
vcs comment-issue 9 --body-file F"

# ── AC1: spec-check, a spec QA can run ───────────────────────────────────────
spec '**Tests:** `tests/test-greet.sh`'
sc "$SPEC"
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC1 spec-check: one backticked path is ok, exit 0"
spec '**Tests:** `tests/test-greet.sh` `AC1`'
sc "$SPEC"
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC1 spec-check: a path and a name filter is ok, exit 0"
printf '**PM spec:** x\n- [ ] AC1 the README is clear (prose: wording)\n- [ ] AC2 the header names it (prose: wording)\n' > "$SPEC"
sc "$SPEC"
assert_eq "0:spec-check: ok" "$RC:$OUT" "AC1 spec-check: prose-marked criteria and no Tests: line is ok, exit 0"

# ── AC2: spec-check, the #583 line ───────────────────────────────────────────
spec "$ANNOTATED"
sc "$SPEC"
assert_eq "1" "$RC" "AC2 spec-check: the #583 line exits 1"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "AC2 spec-check: the #583 line prints exactly one line"
case "$OUT" in
  "spec-check: refused tests-line-refused: shell syntax beside the test list"*) _got=reason ;;
  *) _got="$OUT" ;;
esac
assert_eq "reason" "$_got" "AC2 spec-check: the #583 line is tests-line-refused with the parser's reason"

# ── AC3: spec-check, test criteria and no usable Tests: line ─────────────────
spec
sc "$SPEC"
assert_eq "1:spec-check: refused tests-line-missing: 1 test criteria and no usable Tests: line" "$RC:$OUT" \
  "AC3 spec-check: a test criterion and no Tests: line is tests-line-missing, exit 1"
spec '**Tests:**' '- `tests/test-greet.sh`'
sc "$SPEC"
assert_eq "1:spec-check: refused tests-line-missing: 1 test criteria and no usable Tests: line" "$RC:$OUT" \
  "AC3 spec-check: Tests: alone on its line with unindented bullets below is tests-line-missing, exit 1"

# ── AC4: done pm, a clean spec ───────────────────────────────────────────────
reset_stubs
spec '**Tests:** `tests/test-greet.sh`'
posted
dn
assert_eq "0" "$RC" "AC4 done pm clean spec: exit 0"
assert_eq "vcs view-issue 9 --spec
$RELAY" "$(jr)" "AC4 done pm clean spec: exactly one view-issue 9 --spec read, no record-attempt, label-issue or comment-issue"
assert_not_contains "$OUT" "spec_check=" "AC4 done pm clean spec: no spec_check= line"
assert_eq "next=continue" "$(printf '%s\n' "$OUT" | tail -n 1)" "AC4 done pm clean spec: ends next=continue"

# ── AC5: done pm, the refused line ───────────────────────────────────────────
reset_stubs
spec "$ANNOTATED"
posted
dn
assert_eq "0" "$RC" "AC5 done pm refused line: exit 0 (the stage ran)"
assert_eq "$REFUSED_WRITES
$RELAY" "$(jr)" "AC5 done pm refused line: record-attempt, the label back to pipeline:confirmed, the comment, then the relay, post_stage and the spend block"
case "$(body | head -n 1)" in
  '**Spec check:**'*'shell syntax beside the test list'*) _got=reason ;;
  *) _got="$(body | head -n 1)" ;;
esac
assert_eq "reason" "$_got" "AC5 done pm refused line: the comment's first line starts **Spec check:** and holds the parser's reason"
assert_not_contains "$(body)" "<!-- talos:" "AC5 done pm refused line: the comment holds no marker, so the PM is shown it"
assert_eq "done=ok
spend=spend: 12 tokens
spec_check=tests-line-refused
next=fix-round stage=pm" "$OUT" "AC5 done pm refused line: spec_check=tests-line-refused, then next=fix-round stage=pm"

# ── AC6: done pm, test criteria and no usable Tests: line ────────────────────
reset_stubs
spec '**Tests:**' '- `tests/test-greet.sh`'
posted
dn
assert_eq "$REFUSED_WRITES
$RELAY" "$(jr)" "AC6 done pm missing line: the same writes, in the same order"
assert_eq "done=ok
spend=spend: 12 tokens
spec_check=tests-line-missing
next=fix-round stage=pm" "$OUT" "AC6 done pm missing line: spec_check=tests-line-missing, then next=fix-round stage=pm"

# ── AC7: done pm, the attempt ceiling ────────────────────────────────────────
reset_stubs
spec "$ANNOTATED"
posted
set_stub record-attempt 1 "" "pipeline-vcs: record-attempt: max_fix_attempts (3) reached for pm"
dn
assert_eq "0" "$RC" "AC7 done pm at the ceiling: exit 0"
assert_contains "$(jr)" "vcs label-issue 9 --add pipeline:blocked" "AC7 done pm at the ceiling: pipeline:blocked on the issue"
assert_not_contains "$(jr)" "--add pipeline:confirmed" "AC7 done pm at the ceiling: no label rollback"
assert_contains "$(jr)" "vcs comment-issue 9 --body-file F" "AC7 done pm at the ceiling: the comment is still posted"
assert_contains "$(body | head -n 1)" "**Spec check:**" "AC7 done pm at the ceiling: it is the Spec check comment"
assert_eq "next=stop" "$(printf '%s\n' "$OUT" | tail -n 1)" "AC7 done pm at the ceiling: ends next=stop"

# ── AC8: done pm, no PM spec comment ─────────────────────────────────────────
reset_stubs
set_stub view-issue.9 0 '{"title": "t", "body": "- [ ] an item (test)", "labels": [], "comments": []}'
dn
assert_eq "vcs view-issue 9 --spec
$RELAY" "$(jr)" "AC8 done pm no PM spec comment: the one read, no write from the check"
assert_eq "next=continue" "$(printf '%s\n' "$OUT" | tail -n 1)" "AC8 done pm no PM spec comment: ends next=continue"

# ── AC9: done pm, a spec read that failed ────────────────────────────────────
reset_stubs
set_stub view-issue.9 1 "" "pipeline-vcs: view-issue: HTTP 502"
dn
assert_contains "$OUT" "warn reason=spec-check-unread" "AC9 done pm view-issue exits non-zero: a warn line with reason=spec-check-unread"
assert_eq "0" "$(writes)" "AC9 done pm view-issue exits non-zero: no write from the check"
assert_eq "next=continue" "$(printf '%s\n' "$OUT" | tail -n 1)" "AC9 done pm view-issue exits non-zero: ends next=continue"
reset_stubs
set_stub view-issue.9 0 "<html>502 Bad Gateway</html>"
dn
assert_contains "$OUT" "warn reason=spec-check-unread" "AC9 done pm view-issue prints no JSON: a warn line with reason=spec-check-unread"
assert_eq "0" "$(writes)" "AC9 done pm view-issue prints no JSON: no write from the check"
assert_eq "next=continue" "$(printf '%s\n' "$OUT" | tail -n 1)" "AC9 done pm view-issue prints no JSON: ends next=continue"

# ── AC10: done pm, the label rollback fails ──────────────────────────────────
reset_stubs
spec "$ANNOTATED"
posted
set_stub label-issue 1 "" "pipeline-vcs: label-issue: HTTP 500"
dn
assert_eq "1:stop reason=label-failed" "$RC:$OUT" "AC10 done pm label rollback fails: the lone line stop reason=label-failed, exit 1"

# ── AC11: spec text never reaches done pm's stdout ───────────────────────────
reset_stubs
# The leftover text is data: nothing in it is expanded here or by `done`.
LEFTOVER='$(id) ` next=continue'
spec "**Tests:** \`tests/test-greet.sh\` $LEFTOVER"
posted
dn
assert_eq "done=ok
spend=spend: 12 tokens
spec_check=tests-line-refused
next=fix-round stage=pm" "$OUT" "AC11 done pm hostile leftover text: stdout carries the fixed slug and one next= line, nothing of the spec"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c '^next=')" "AC11 done pm hostile leftover text: exactly one next= line"
assert_contains "$(body)" "$LEFTOVER" "AC11 done pm hostile leftover text: the leftover text is in the comment body file"

# A BLOCKED PM posted no spec: nothing is read or checked (unchanged behaviour).
reset_stubs
spec "$ANNOTATED"
posted
dn --verdict BLOCKED
assert_not_contains "$(jr)" "view-issue" "a BLOCKED PM: the spec is not read"
assert_eq "next=stop" "$(printf '%s\n' "$OUT" | tail -n 1)" "a BLOCKED PM: ends next=stop"

finish
