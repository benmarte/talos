#!/usr/bin/env bash
# test-finding-outcome-event.sh -- the `finding_outcome` event: how each blocking
# review finding of reviewer, security and adversarial ended (#798).
#   AC1 a malformed argument exits 2 and appends nothing
#   AC2 only Important lines of the previous message are findings
#   AC3 fixed / unclassified from the now-file's cited paths
#   AC4 a developer FINDING marker sets wrong / intentional / not-worth-it
#   AC5 the event line: fields, order, 200-char cuts, at most 20 per call
#   AC6 events.enabled false and an unwritable events.path write nothing, exit 0
#   AC7 the verb makes no provider call
#   AC8 no cost view counts the event; list --event shows it
#   AC9 talos.sh run records the events across a review fix round
# AC10 and AC11 are prose (agent docs, docs/reference.md, headers).
set -u
. "$(dirname "$0")/helpers.sh"
# The sandbox, the stubs and the `talos.sh run` fixtures of AC9; no part runs.
TALOS_RUN_PART=0 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"
LOG="$SANDBOX/.git/talos/events.jsonl"
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
HCFG='{"vcs": {"provider": "github", "repo": "acme/widget"}}'
printf '%s\n' "$HCFG" > "$PIPELINE_CONFIG"
unset TALOS_ROLE TALOS_RUN_STARTED

PREV="$SANDBOX/prev.txt"; NOW="$SANDBOX/now.txt"; REPLY="$SANDBOX/reply.txt"
lines() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
# field N KEY: key KEY of the Nth line of the log, as a JSON value (strings bare).
field() {
  python3 -I -c '
import json, sys
try:
    rows = open(sys.argv[1]).read().splitlines()
    v = json.loads(rows[int(sys.argv[2]) - 1]).get(sys.argv[3], "<absent>")
except (ValueError, IndexError, OSError):
    v = "<no event>"
print(json.dumps(v) if not isinstance(v, str) else v)' "$LOG" "$1" "$2"
}
# outcomes: every outcome of the log, in order, comma-joined.
outcomes() {
  python3 -I -c '
import json, sys
try:
    rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except OSError:
    rows = []
print(",".join(r.get("outcome", "?") for r in rows if r.get("event") == "finding_outcome"))' "$LOG"
}
# fo ROLE [extra args...]: the verb for issue 9, PR 12, with the three files.
fo() { local r="$1"; shift; bash "$HOOKS" finding_outcome "$r" 9 --pr 12 --prev-file "$PREV" --now-file "$NOW" "$@" 2>"$SANDBOX/err"; }
fold() { printf '%s\n' "$@"; }

# ── AC1 ─────────────────────────────────────────────────────────────────────
fold 'CHANGES: 1 finding' '- [Important] scripts/a.sh:3 — a thing' > "$PREV"
fold 'APPROVED: fine' > "$NOW"
rm -f "$LOG"
bad() {  # <label> <args...>: exit 2 with the usage, nothing appended
  local label="$1"; shift
  OUT="$(bash "$HOOKS" finding_outcome "$@" 2>&1)"; RC=$?
  assert_eq "2" "$RC" "AC1 $label exits 2"
  assert_contains "$OUT" "pipeline-hooks.sh finding_outcome" "AC1 $label prints the usage"
  assert_eq "0" "$(lines)" "AC1 $label appends nothing"
}
bad "an unknown role" qa 9 --pr 12 --prev-file "$PREV" --now-file "$NOW"
bad "a missing role"
bad "a missing --pr" reviewer 9 --prev-file "$PREV" --now-file "$NOW"
bad "a non-digit issue" reviewer 9x --pr 12 --prev-file "$PREV" --now-file "$NOW"
bad "a missing issue" reviewer --pr 12 --prev-file "$PREV" --now-file "$NOW"
bad "a non-digit pr" reviewer 9 --pr x --prev-file "$PREV" --now-file "$NOW"
bad "a missing --prev-file" reviewer 9 --pr 12 --now-file "$NOW"
bad "a missing --now-file" reviewer 9 --pr 12 --prev-file "$PREV"
bad "--pr with no value" reviewer 9 --prev-file "$PREV" --now-file "$NOW" --pr
bad "an unknown option" reviewer 9 --pr 12 --prev-file "$PREV" --now-file "$NOW" --bogus x
for R in reviewer security adversarial; do
  rm -f "$LOG"
  fo "$R"; RC=$?
  assert_eq "0" "$RC" "AC1 $R is a known role: exit 0"
  assert_eq "1" "$(lines)" "AC1 $R appends its event"
  assert_eq "$R" "$(field 1 stage)" "AC1 $R is the event's stage"
done

# ── AC2 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
fold 'CHANGES: 3 findings' \
  '- [Important] scripts/a.sh:3 — the real one' \
  '- [Nit] scripts/b.sh:4 — a nit' \
  '- [Pre-existing] scripts/c.sh:5 — old' \
  '1. scripts/d.sh:6 a numbered line' > "$PREV"
fo reviewer
assert_eq "1" "$(lines)" "AC2 one Important, one Nit and one Pre-existing line give exactly one event"
assert_eq "scripts/a.sh:3" "$(field 1 finding)" "AC2 the event is the Important line"
rm -f "$LOG"
fold 'APPROVED: nothing' '- [Nit] scripts/b.sh:4 — a nit' > "$PREV"
fo reviewer; RC=$?
assert_eq "0" "$RC" "AC2 a previous message with no Important line: exit 0"
assert_eq "0" "$(lines)" "AC2 a previous message with no Important line gives no event"

# ── AC3 ─────────────────────────────────────────────────────────────────────
fold 'CHANGES: 3 findings' \
  '- [Important] scripts/a.sh:12 — fixed one' \
  '- [Important] scripts/b.sh:7 — still there' \
  '- [Important] scripts/c.sh:3 — also fixed' > "$PREV"
fold 'CHANGES: 1 finding' \
  '- [Nit] scripts/a.sh:1 — a nit on the fixed path is no finding' \
  '- [Important] scripts/b.sh:20 — moved by the fix' > "$NOW"
rm -f "$LOG"; fo reviewer
assert_eq "fixed,unclassified,fixed" "$(outcomes)" "AC3 a path the now-file no longer cites is fixed, one it cites at another line is unclassified"
fold 'APPROVED: all good' > "$NOW"
rm -f "$LOG"; fo reviewer
assert_eq "fixed,fixed,fixed" "$(outcomes)" "AC3 an APPROVED now-file makes every unmarked finding fixed"
fold 'CLEAR: nothing exploitable' > "$NOW"
rm -f "$LOG"; fo security
assert_eq "fixed,fixed,fixed" "$(outcomes)" "AC3 a CLEAR now-file makes every unmarked finding fixed"

# ── AC4 ─────────────────────────────────────────────────────────────────────
fold 'CHANGES: 3 findings' \
  '- [Important] scripts/a.sh:12 — one' \
  '- [Important] scripts/b.sh:7 — two' \
  '- [Important] scripts/c.sh:3 — three' > "$PREV"
fold 'CHANGES: 1 finding' '- [Important] scripts/b.sh:7 — repeated' > "$NOW"
fold 'fixed the rest' \
  'FINDING scripts/a.sh:12 wrong: it is a test fixture' \
  'FINDING scripts/b.sh:7 not-worth-it: costs more than it saves' \
  'FINDING scripts/b.sh:7 intentional: a second marker for the same finding' > "$REPLY"
rm -f "$LOG"; fo reviewer --reply-file "$REPLY"
assert_eq "wrong,not-worth-it,fixed" "$(outcomes)" "AC4 a marker sets the outcome, repeated by the stage or not; the first marker wins"
assert_eq "it is a test fixture" "$(field 1 note)" "AC4 the marker's reason is the note"
assert_eq "costs more than it saves" "$(field 2 note)" "AC4 the first marker's reason is the note, not the second's"
assert_eq "null" "$(field 3 note)" "AC4 a finding with no marker has a null note"
fold 'x' \
  'FINDING scripts/a.sh:99 wrong: no previous finding has this line' \
  'FINDING scripts/b.sh:7 fixed: not an outcome a developer may claim' \
  'FINDING scripts/c.sh:3 bogus: an unknown word' \
  'see FINDING scripts/c.sh:3 wrong: not at line start' \
  '  FINDING scripts/a.sh:12 wrong: indented' > "$REPLY"
rm -f "$LOG"; fo reviewer --reply-file "$REPLY"
assert_eq "fixed,unclassified,fixed" "$(outcomes)" "AC4 a marker with an unknown path:line, an unknown outcome word or off the line start changes nothing"
fold 'x' 'FINDING scripts/c.sh:3 intentional: kept' > "$REPLY"
rm -f "$LOG"; fo reviewer --reply-file "$SANDBOX/no-such-reply"
assert_eq "fixed,unclassified,fixed" "$(outcomes)" "AC4 a missing reply file is no marker"
rm -f "$LOG"; fo reviewer
assert_eq "fixed,unclassified,fixed" "$(outcomes)" "AC4 no --reply-file is no marker"
rm -f "$LOG"; fo reviewer --reply-file "$REPLY"
assert_eq "fixed,unclassified,intentional" "$(outcomes)" "AC4 intentional is recorded"

# ── AC5 ─────────────────────────────────────────────────────────────────────
LONG="$(python3 -I -c 'import sys; sys.stdout.write("w" * 300)')"
fold 'CHANGES: 2 findings' \
  "- [Important] scripts/a.sh:1 — $LONG" \
  '- [Important] scripts/b.sh:2 — short text' > "$PREV"
fold 'CHANGES: 1' '- [Important] scripts/b.sh:9 — still' > "$NOW"
fold 'ok' "FINDING scripts/a.sh:1 wrong: $LONG" > "$REPLY"
rm -f "$LOG"; fo adversarial --reply-file "$REPLY"
assert_eq "2" "$(lines)" "AC5 one line per finding"
assert_eq "finding_outcome" "$(field 1 event)" "AC5 event"
assert_eq "orchestrator" "$(field 1 role)" "AC5 role is orchestrator"
assert_eq "adversarial" "$(field 1 stage)" "AC5 stage is the reviewing role"
assert_eq "9" "$(field 1 issue)" "AC5 issue"
assert_eq "12" "$(field 1 pr)" "AC5 pr"
assert_eq "scripts/a.sh:1" "$(field 1 finding)" "AC5 finding is path:line"
assert_eq "scripts/b.sh:2" "$(field 2 finding)" "AC5 the lines follow the stage's order"
assert_eq "200" "$(python3 -I -c 'import json, sys; print(len(json.loads(open(sys.argv[1]).readline())["text"]))' "$LOG")" "AC5 text is cut to 200 chars"
assert_eq "200" "$(python3 -I -c 'import json, sys; print(len(json.loads(open(sys.argv[1]).readline())["note"]))' "$LOG")" "AC5 note is cut to 200 chars"
assert_eq "short text" "$(field 2 text)" "AC5 text is the finding text after the dash"
assert_eq "wrong" "$(field 1 outcome)" "AC5 outcome"
assert_eq "null" "$(field 2 note)" "AC5 note is null without a marker"
case "$(field 1 ts)" in 20[0-9][0-9]-*T*Z) pass "AC5 ts is a UTC ISO-8601 stamp" ;; *) fail "AC5 ts is a UTC ISO-8601 stamp" "$(cat "$LOG")" ;; esac
python3 -I -c '
for i in range(1, 26):
    print("- [Important] scripts/f%02d.sh:%d — finding %d" % (i, i, i))' > "$SANDBOX/many.txt"
{ echo 'CHANGES: 25 findings'; cat "$SANDBOX/many.txt"; } > "$PREV"
fold 'APPROVED: ok' > "$NOW"
rm -f "$LOG"; fo reviewer
assert_eq "20" "$(lines)" "AC5 at most 20 events per call"
assert_eq "scripts/f20.sh:20" "$(field 20 finding)" "AC5 the first 20 findings are the ones kept"

# ── AC6 ─────────────────────────────────────────────────────────────────────
fold 'CHANGES: 1' '- [Important] scripts/a.sh:3 — x' > "$PREV"
fold 'APPROVED: ok' > "$NOW"
rm -f "$LOG"
printf '{"events": {"enabled": false}}' > "$PIPELINE_CONFIG"
fo reviewer; RC=$?
assert_eq "0" "$RC" "AC6 events.enabled false: exit 0"
assert_file_absent "$LOG" "AC6 events.enabled false: nothing written"
: > "$SANDBOX/afile"
printf '{"events": {"path": "%s/afile/x/events.jsonl"}}' "$SANDBOX" > "$PIPELINE_CONFIG"
fo reviewer; RC=$?
assert_eq "0" "$RC" "AC6 an unwritable events.path: exit 0"
printf '%s\n' "$HCFG" > "$PIPELINE_CONFIG"

# ── AC7 ─────────────────────────────────────────────────────────────────────
NOPROV="$SANDBOX/noprov"; CALLS="$SANDBOX/provider-calls"; mkdir -p "$NOPROV"; : > "$CALLS"
for P in gh glab az curl; do
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "%s"\nexit 1\n' "$P" "$CALLS" > "$NOPROV/$P"
  chmod +x "$NOPROV/$P"
done
rm -f "$LOG"
PATH="$NOPROV:$PATH" fo reviewer --reply-file "$REPLY"; RC=$?
assert_eq "0" "$RC" "AC7 the verb runs with provider stubs on PATH"
assert_eq "1" "$(lines)" "AC7 the verb still appended its event"
assert_eq "" "$(cat "$CALLS")" "AC7 no gh, glab, az or curl call"

# ── AC8 ─────────────────────────────────────────────────────────────────────
rm -f "$LOG"
printf '{"event":"developer","role":"developer","issue":9,"pr":12,"verdict":"PR_OPENED","tokens":1000,"tool_uses":3,"duration_s":9,"ts":"2026-10-01T00:00:00Z"}\n' > "$LOG"
cost_forms() {
  bash "$EVENTS" cost 2>&1
  bash "$EVENTS" cost --json 2>&1
  bash "$EVENTS" cost --issue 9 --line 2>&1
  bash "$EVENTS" cost --issue 9 --markdown 2>&1
}
BEFORE="$(cost_forms)"
fold 'CHANGES: 2' '- [Important] scripts/a.sh:3 — x' '- [Important] scripts/b.sh:4 — y' > "$PREV"
fo security
assert_eq "3" "$(lines)" "AC8 two finding_outcome events were appended"
assert_eq "$BEFORE" "$(cost_forms)" "AC8 no cost form (table, --json, --line, --markdown) changes after finding_outcome events"
assert_eq "2" "$(bash "$EVENTS" list --event finding_outcome 2>&1 | grep -c 'finding_outcome')" "AC8 list --event finding_outcome shows them"

# ── AC9 ─────────────────────────────────────────────────────────────────────
# The run fixture of tests/talos-run-sections.sh section (l), with the real
# finding_outcome verb behind the journalling hooks stub.
cp "$TALOS_ROOT/scripts/pipeline-hooks.sh" "$GS/real-hooks.sh"
cat > "$GS/pipeline-hooks.sh" <<'TALOS_stubhooksK4nQ8vZt2w'
#!/usr/bin/env bash
printf 'hooks %s\n' "$*" >> "${STUB_DIR:?}/journal"
if [ "${1:-}" = finding_outcome ]; then exec bash "$(dirname "$0")/real-hooks.sh" "$@"; fi
cat > "${STUB_DIR:?}/hooks.stdin"
exit 0
TALOS_stubhooksK4nQ8vZt2w
fo_fixture() {  # $1 = the developer's final message line after the PR URL; $2 = the reviewer's second message
  reset_stubs
  LEASE_RESET
  printf '{"vcs": {"provider": "github", "repo": "acme/widget"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true}, "pr": {"draft": false}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
    > "$SANDBOX/talos.pipeline.json"
  draft_collect reviewer
  printf '{"labels": [], "state": "open"}' > "$STUB_DIR/view-pr.12"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  printf 'https://github.com/acme/widget/pull/12\n%s\n' "$1" > "$STUB_DIR/message.developer"
  cat > "$STUB_DIR/hook.developer.1" <<'HOOK'
printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"
HOOK
  printf 'CHANGES: 2 findings\n- [Important] scripts/a.sh:3 — the first\n- [Important] scripts/b.sh:9 — the second\n' > "$STUB_DIR/message.reviewer.1"
  printf '%s\n' "$2" > "$STUB_DIR/message.reviewer.2"
  rm -f "$LOG"
}

fo_fixture 'FINDING scripts/a.sh:3 intentional: kept on purpose' 'APPROVED: the new head is fine'
TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 2
assert_eq "0" "$RC" "AC9 the run exits 0"
assert_eq "1" "$(grep -c '^agent developer$' "$STUB_DIR/journal")" "AC9 the fixture ran one developer fix round"
assert_eq "2" "$(lines)" "AC9 CHANGES, a fix round with a marker, then APPROVED: two events"
assert_eq "intentional,fixed" "$(outcomes)" "AC9 the marked finding has the marker's outcome, the other fixed"
assert_eq "kept on purpose" "$(field 1 note)" "AC9 the marker's reason is the note"
assert_eq "reviewer" "$(field 1 stage)" "AC9 the stage is the reviewer"
assert_eq "9" "$(field 1 issue)" "AC9 the issue is the run's"
assert_eq "12" "$(field 1 pr)" "AC9 the pr is the run's"

fo_fixture 'fixed both' 'APPROVED: the new head is fine'
TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 1
assert_eq "0" "$(lines)" "AC9 a first-round CHANGES alone appends no event"

for V in RESTAMP_PASS RESTAMP_FAIL; do
  fo_fixture 'fixed both' "$V: restamp"
  TALOS_LEASE_TTL_S=1800 TALOS_NOW=14000 rn --max-iterations 2
  assert_eq "0" "$(lines)" "AC9 a reviewer $V verdict after the first round appends no event"
done

finish
