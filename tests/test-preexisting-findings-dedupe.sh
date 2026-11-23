#!/usr/bin/env bash
# test-preexisting-findings-dedupe.sh -- the Pre-existing follow-up filer files no
# noise and no duplicates (#1045). By id:
#   AC1 a lone `PRE-EXISTING: none` (also `None.`, `n/a`, `-`, empty) files no issue
#   AC2 the same findings reviewed again by the same role: no second issue, no comment
#   AC3 a second review with one new finding: one comment holding only the new bullet
#   AC4 a failed lookup files nothing and warns once, naming the PR and the role
#   AC5 a first review with two real findings files one issue holding both, as before
# Every test runs on stubs under make_sandbox: no GitHub read, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
ERR="$SANDBOX/stderr"

# <key> is the verb of pipeline-vcs.sh; $STUB_DIR/<key>.<first-arg> (or <key>) is
# the answer and <key>.<first-arg>.rc its exit status. create-issue and
# comment-issue keep the title / body file they were given (<verb>.<kind>.<n>).
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR" "$SANDBOX/templates"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2> /dev/null
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="$1"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
if [ "$key" = "create-issue" ]; then
  c="$(ls "$d" | grep -c "^create-issue.title\.")"
  printf "%s" "$2" > "$d/create-issue.title.$((c + 1))"
  cat "$3" > "$d/create-issue.body.$((c + 1))"
fi
if [ "$key" = "comment-issue" ]; then
  c="$(ls "$d" | grep -c "^comment-issue.body\.")"
  printf "%s" "$2" > "$d/comment-issue.issue.$((c + 1))"
  cat "$4" > "$d/comment-issue.body.$((c + 1))"
fi
if [ "$n" = "notify" ] && [ "${3:-}" = "-" ]; then cat > /dev/null; fi
a1="${2:-}"
if [ -f "$d/$key.$a1" ]; then cat "$d/$key.$a1"
elif [ -f "$d/$key" ]; then cat "$d/$key"; fi
rc=0
if [ -f "$d/$key.$a1.rc" ]; then rc="$(cat "$d/$key.$a1.rc")"; elif [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-status.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
DN="$GS/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"

reset() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  printf '{"vcs": {"provider": "github"}, "comments": {"enabled": false}}' > "$SANDBOX/talos.pipeline.json"
}
# dn ROLE VERDICT SUMMARYFILE: run `done` for issue 42 / PR 57.
dn() { DOUT="$(bash "$DN" done "$1" --issue 42 --pr 57 --verdict "$2" --summary-file "$3" 2> "$ERR")"; DRC=$?; }
count() { ls "$STUB_DIR" 2> /dev/null | grep -c "^$1\." || true; }
SUM="$SANDBOX/summary.txt"
review() {  # the findings, one `PRE-EXISTING:` line each
  printf 'CHANGES: 1\n\nprose\n' > "$SUM"
  local f
  for f in "$@"; do printf 'PRE-EXISTING: %s\n' "$f" >> "$SUM"; done
}
# seed ISSUE ROLE BODY-FILE: the open issue a first review filed, as list-issues shows it.
seed() {
  python3 -I -c '
import json, sys
n, role, body = int(sys.argv[1]), sys.argv[2], open(sys.argv[3]).read()
json.dump([{"number": 7, "title": "unrelated", "labels": [], "body": "x"},
           {"number": n, "title": "Pre-existing findings from %s review of PR #57" % role, "labels": [], "body": body}], sys.stdout)
' "$1" "$2" "$3" > "$STUB_DIR/list-issues"
  printf '{"comments": []}' > "$STUB_DIR/read-comments.$1"
}

# ── AC1: `none` is not a finding ──────────────────────────────────────────────
for none in 'none' 'None.' 'NONE' 'n/a' 'N/A.' '-' '  none  ' ''; do
  reset
  review "$none"
  dn reviewer CHANGES "$SUM"
  assert_eq "0" "$DRC" "AC1 [$none]: done exits 0"
  assert_eq "0" "$(count create-issue.title)" "AC1 [$none]: no issue is filed"
  assert_eq "0" "$(count comment-issue.body)" "AC1 [$none]: no comment is posted"
done
reset
review none 'lib/a.sh:1 — real one'
dn reviewer CHANGES "$SUM"
assert_eq "1" "$(count create-issue.title)" "AC1 a real line next to a none line still files one issue"
assert_not_contains "$(cat "$STUB_DIR/create-issue.body.1")" "- none" "AC1 the none line is not a bullet"

# ── AC5: a first review with real findings files one issue, as today ──────────
reset
review 'lib/a.sh:10 — old bug one' 'lib/b.sh:20 — old bug two'
dn reviewer CHANGES "$SUM"
assert_eq "1" "$(count create-issue.title)" "AC5 one issue is filed"
assert_eq "Pre-existing findings from reviewer review of PR #57" "$(cat "$STUB_DIR/create-issue.title.1" 2> /dev/null)" "AC5 the title names the role and the PR"
body="$(cat "$STUB_DIR/create-issue.body.1" 2> /dev/null)"
assert_contains "$body" "- lib/a.sh:10 — old bug one" "AC5 the first finding is a bullet"
assert_contains "$body" "- lib/b.sh:20 — old bug two" "AC5 the second finding is a bullet"
assert_eq "0" "$(count comment-issue.body)" "AC5 no comment on a first review"
cp "$STUB_DIR/create-issue.body.1" "$SANDBOX/first.body"

# ── AC2: the same findings again: nothing ─────────────────────────────────────
reset
seed 90 reviewer "$SANDBOX/first.body"
review 'lib/a.sh:10 — old bug one' 'LIB/b.sh:20  —  Old   bug two'
dn reviewer CHANGES "$SUM"
assert_eq "0" "$DRC" "AC2: done exits 0"
assert_eq "0" "$(count create-issue.title)" "AC2: no second issue is filed"
assert_eq "0" "$(count comment-issue.body)" "AC2: no comment is added (whitespace and case do not count)"
# findings already in an earlier comment count as known too
reset
printf -- '- lib/a.sh:10 — old bug one\n' > "$SANDBOX/one.body"
seed 90 reviewer "$SANDBOX/one.body"
printf '{"comments": [{"id": 1, "author": "x", "body": "- lib/b.sh:20 — old bug two"}]}' > "$STUB_DIR/read-comments.90"
review 'lib/a.sh:10 — old bug one' 'lib/b.sh:20 — old bug two'
dn reviewer CHANGES "$SUM"
assert_eq "0" "$(count create-issue.title)" "AC2: a finding known from a comment files no issue"
assert_eq "0" "$(count comment-issue.body)" "AC2: a finding known from a comment adds no comment"

# ── AC3: one new finding: one comment with only that bullet ───────────────────
reset
seed 90 reviewer "$SANDBOX/first.body"
review 'lib/a.sh:10 — old bug one' 'lib/c.sh:30 — brand new'
dn reviewer CHANGES "$SUM"
assert_eq "0" "$DRC" "AC3: done exits 0"
assert_eq "0" "$(count create-issue.title)" "AC3: no second issue is filed"
assert_eq "1" "$(count comment-issue.body)" "AC3: exactly one comment"
assert_eq "90" "$(cat "$STUB_DIR/comment-issue.issue.1" 2> /dev/null)" "AC3: the comment goes to the existing issue"
cbody="$(cat "$STUB_DIR/comment-issue.body.1" 2> /dev/null)"
assert_contains "$cbody" "- lib/c.sh:30 — brand new" "AC3: the new bullet is in the comment"
assert_not_contains "$cbody" "old bug one" "AC3: a known bullet is not repeated"
# another role's issue is not this role's
reset
seed 90 security "$SANDBOX/first.body"
review 'lib/a.sh:10 — old bug one'
dn reviewer CHANGES "$SUM"
assert_eq "1" "$(count create-issue.title)" "AC3: an issue of another role does not absorb this role's findings"

# ── AC4: a failed lookup files nothing and warns once ─────────────────────────
reset
review 'lib/a.sh:10 — old bug one'
printf 1 > "$STUB_DIR/list-issues.rc"
dn reviewer CHANGES "$SUM"
warns="$(printf '%s\n' "$DOUT" | grep 'warn reason=followup-lookup-failed')"
assert_eq "0" "$DRC" "AC4: done still exits 0"
assert_eq "0" "$(count create-issue.title)" "AC4: nothing is filed when the issue lookup fails"
assert_eq "0" "$(count comment-issue.body)" "AC4: nothing is commented when the issue lookup fails"
assert_eq "1" "$(printf '%s\n' "$warns" | grep -c .)" "AC4: one warn line"
assert_contains "$warns" "pr=57" "AC4: the warn names the PR"
assert_contains "$warns" "role=reviewer" "AC4: the warn names the role"
# a failed read of the existing issue's comments is the same
reset
seed 90 reviewer "$SANDBOX/first.body"
printf 1 > "$STUB_DIR/read-comments.90.rc"
review 'lib/c.sh:30 — brand new'
dn reviewer CHANGES "$SUM"
assert_eq "0" "$(count create-issue.title)" "AC4: nothing is filed when the comment read fails"
assert_eq "0" "$(count comment-issue.body)" "AC4: nothing is commented when the comment read fails"
assert_eq "1" "$(printf '%s\n' "$DOUT" | grep -c 'warn reason=followup-lookup-failed')" "AC4: one warn line for a failed comment read"

finish
