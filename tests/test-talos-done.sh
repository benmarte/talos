#!/usr/bin/env bash
# test-talos-done.sh -- `scripts/talos.sh done` (#469, slice 5 of epic #422).
#
# `done` replaces the "After <role> returns" blocks and the conversation stream
# protocol (role relay, post_stage, spend block) of skills/pipeline/SKILL.md, so this
# file pins that it does what that prose said, in its order:
#   (a) the journal-ordered golden of every role and verdict (board, relay, post_stage,
#       spend, lifecycle event) and the `next=` answer
#   (b) the pre-steps: a RESTAMP_FAIL strips the stale label, a draft QA FAIL runs
#       draft-pr then drops qa:pass, a failure there writes nothing; a draft review
#       batch never calls `gate fix-round`
#   (c) the usage flags, the model rule, the spend block (no PR: --line only)
#   (d) the done-ledger: grammar, at-most-once, a held lock, a failed pre-step
#   (e) free text travels only as a file or stdin, byte for byte
#   (f) every non-fatal failure is a warn; the output contract and the sanitiser
#   (g) the one writer: post_stage and the spend block are written only by the helpers
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
TALOS="$TALOS_ROOT/scripts/talos.sh"
ERR="$SANDBOX/stderr"

# ── fixtures ─────────────────────────────────────────────────────────────────
# A copy of the scripts directory in which every script `done` calls, except the
# config reader and the lock, is one journaling stub (see test-talos-postmerge.sh):
# <key> is what the stub looks up in $STUB_DIR/<key>.{out,err,rc} (rc 0 by default);
# for pipeline-vcs.sh `<verb>.<first arg>` then `<verb>`, for any other script
# `<name>.<first arg>.<line|md>`, `<name>.<first arg>`, then `<name>`.
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
case " $* " in *" --markdown "*) sfx=md ;; *" --line "*) sfx=line ;; *) sfx="" ;; esac
if [ "$n" = "vcs" ]; then cands="${1:-}.${2:-} ${1:-}"
else cands="$n.${1:-}.$sfx $n.${1:-} $n"; fi
key=""
for c in $cands; do
  if [ -e "$d/$c.out" ] || [ -e "$d/$c.err" ] || [ -e "$d/$c.rc" ]; then key="$c"; break; fi
done
printf "%s %s\n" "$n" "$*" >> "$d/journal"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ] && [ "$a" = "-" ]; then cat > "$d/stdin"; fi
  if [ "$prev" = "--summary-file" ]; then { printf "[%s]\n" "$*"; cat "$a"; } >> "$d/hooks.bodies"; fi
  prev="$a"
done
if [ "$n" = "notify" ] && [ "${3:-}" = "-" ]; then { printf "[notify %s]\n" "$*"; cat; } >> "$d/notify.bodies"; fi
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
DN="$GS/talos.sh"

cfg_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }
# set_stub <key> <rc> [out] [err]
set_stub() {
  printf '%s\n' "$2" > "$STUB_DIR/$1.rc"
  printf '%s' "${3:-}" > "$STUB_DIR/$1.out"
  printf '%s' "${4:-}" > "$STUB_DIR/$1.err"
}
LEDGER="$SANDBOX/.git/talos-done.ledger"
reset_stubs() {
  rm -rf "${STUB_DIR:?}" "${LEDGER:?}" "${LEDGER:?}.lock.d"; mkdir -p "$STUB_DIR"
  cfg_json '{"vcs": {"provider": "github"}, "comments": {"enabled": false}}'
  set_stub events.cost.line 0 "spend: 12 tokens"
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
called() { journal | grep -c "^$1 \|^vcs $1 "; }
# jr: the journal with the scratch summary path normalised.
jr() { journal | sed 's| --summary-file [^ ]*| --summary-file F|'; }
SUM="$SANDBOX/summary.txt"
printf 'PASS: 3 criteria verified\n' > "$SUM"
# dn <args...>: run `done` on the stubbed scripts directory.
dn() { OUT="$(bash "$DN" done "$@" 2>"$ERR")"; RC=$?; }

# ── the output contract, as a checker ────────────────────────────────────────
reasons_of() { sed -n "s/^# $1-reasons: //p" "$TALOS" | head -n 1; }
DONE_REASONS="$(reasons_of done)"
# check_out FILE: the first line is done=ok|duplicate or a lone stop line; the others
# are KEY=value, `next=...` last, or `warn reason=<enum> [key=value]...`.
check_out() {
  python3 -I -c '
import re, sys
reasons = set(sys.argv[2].split())
data = open(sys.argv[1], "rb").read()
if re.search(rb"[\x00-\x09\x0b-\x1f\x7f]|\xc2[\x80-\x9f]", data):
    sys.exit(1)
lines = data.decode("utf-8").split("\n")
if lines and lines[-1] == "":
    lines.pop()
if not lines:
    sys.exit(1)
if lines[0].startswith("stop "):
    m = re.match(r"stop reason=([a-z-]+)\Z", lines[0])
    sys.exit(0 if len(lines) == 1 and m and m.group(1) in reasons else 1)
if lines[0] == "done=duplicate":
    sys.exit(0 if len(lines) == 1 else 1)
if lines[0] != "done=ok" or not lines[-1].startswith("next="):
    sys.exit(1)
kv = re.compile(r"[a-z][a-z0-9_.]*=")
sw = re.compile(r"warn reason=([a-z-]+)( [a-z]+=[A-Za-z0-9_.-]+)*\Z")
for ln in lines[1:]:
    if kv.match(ln):
        continue
    m = sw.match(ln)
    if m and m.group(1) in reasons:
        continue
    sys.exit(1)
' "$1" "$DONE_REASONS"
}
assert_out() { printf '%s\n' "$OUT" > "$SANDBOX/out.dn"; check_out "$SANDBOX/out.dn"; assert_eq "0" "$?" "$1: output satisfies the line contract"; }
line_of() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n 1; }

# ── (a) the golden order of each role and verdict ────────────────────────────
reset_stubs
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM" --tokens 1200 --tool-uses 7 --duration-s 61 --model claude-sonnet-4-6 --sha abc1234
assert_eq "0" "$RC" "qa PASS: exits 0"
assert_eq "done=ok
spend=spend: 12 tokens
next=continue" "$OUT" "qa PASS: done=ok, the spend line, next=continue"
assert_out "qa PASS"
assert_eq "notify qa #42 - 42
hooks post_stage qa qa 42 --pr 57 --sha abc1234 --verdict PASS --summary-file F --tokens 1200 --tool-uses 7 --duration-s 61 --model claude-sonnet-4-6
events cost --issue 42 --pr 57 --line" "$(jr)" "qa PASS: the relay, then post_stage with the usage flags, then the spend block, nothing else"
assert_eq "[notify qa #42 - 42]
PASS: 3 criteria verified" "$(cat "$STUB_DIR/notify.bodies")" "qa PASS: the summary is the relay's stdin"

reset_stubs
printf 'FAIL: criterion 2\n' > "$SUM"
dn qa --issue 42 --pr 57 --verdict FAIL --summary-file "$SUM"
assert_eq "notify qa #42 - 42
hooks post_stage qa qa 42 --pr 57 --verdict FAIL --summary-file F
events cost --issue 42 --pr 57 --line
notify blocked #42 QA failed in PR #57 42
hooks post_stage blocked orchestrator 42 --pr 57 --summary QA failed in PR #57" "$(jr)" "qa FAIL: relay, event, spend, then the blocked lifecycle event (no spend after it)"
assert_eq "fix-round stage=qa" "$(line_of next)" "qa FAIL: next is the fix round"
assert_eq "0" "$(called draft-pr)" "qa FAIL, not draft: no draft-pr"
assert_eq "0" "$(called label-pr)" "qa FAIL, not draft: no label strip"
assert_eq "1" "$(journal | grep -c 'events cost')" "the spend block runs once per call, not after the lifecycle event"

# A draft QA FAIL: draft-pr, then qa:pass is dropped, both before anything is announced.
reset_stubs
dn qa --issue 42 --pr 57 --verdict FAIL --summary-file "$SUM" --draft
assert_eq "vcs draft-pr 57
vcs label-pr 57 --remove qa:pass
notify qa #42 - 42
hooks post_stage qa qa 42 --pr 57 --verdict FAIL --summary-file F
events cost --issue 42 --pr 57 --line
notify blocked #42 QA failed in PR #57 42
hooks post_stage blocked orchestrator 42 --pr 57 --summary QA failed in PR #57" "$(jr)" "draft QA FAIL: draft-pr, label-pr --remove qa:pass, then the usual order"
assert_eq "fix-round stage=qa" "$(line_of next)" "draft QA FAIL: next is the fix round"
assert_eq "0" "$(called record-attempt)" "done never records an attempt (gate fix-round does)"

reset_stubs
dn reviewer --issue 42 --pr 57 --verdict APPROVED --summary-file "$SUM"
assert_eq "notify reviewer #42 - 42
hooks post_stage reviewer reviewer 42 --pr 57 --verdict APPROVED --summary-file F
events cost --issue 42 --pr 57 --line" "$(jr)" "reviewer APPROVED"
assert_eq "continue" "$(line_of next)" "reviewer APPROVED: continue"
reset_stubs
dn reviewer --issue 42 --pr 57 --verdict CHANGES --summary-file "$SUM"
assert_eq "notify reviewer #42 - 42
hooks post_stage reviewer reviewer 42 --pr 57 --verdict CHANGES --summary-file F
events cost --issue 42 --pr 57 --line
notify blocked #42 reviewer: changes required 42
hooks post_stage blocked orchestrator 42 --pr 57 --summary reviewer: changes required" "$(jr)" "reviewer CHANGES"
assert_eq "fix-round stage=reviewer" "$(line_of next)" "reviewer CHANGES: next is the fix round"

reset_stubs
dn security --issue 42 --pr 57 --verdict CLEAR --summary-file "$SUM"
assert_eq "continue" "$(line_of next)" "security CLEAR: continue"
reset_stubs
dn security --issue 42 --pr 57 --verdict FINDINGS --summary-file "$SUM"
assert_contains "$(jr)" "notify blocked #42 security: findings in PR #57 42" "security FINDINGS: the blocked notice names the PR"
assert_eq "fix-round stage=security" "$(line_of next)" "security FINDINGS: next is the fix round"
reset_stubs
dn adversarial --issue 42 --pr 57 --verdict FINDINGS --summary-file "$SUM"
assert_contains "$(jr)" "notify blocked #42 adversarial: findings in PR #57 42" "adversarial FINDINGS: the blocked notice"
assert_eq "fix-round stage=adversarial" "$(line_of next)" "adversarial FINDINGS: next is the fix round"
reset_stubs
dn adversarial --issue 42 --pr 57 --verdict CLEAR --summary-file "$SUM"
assert_eq "continue" "$(line_of next)" "adversarial CLEAR: continue"

# A draft review batch: each blocking role still gets its relay and blocked notice,
# but `done` calls no `gate fix-round` and says `batch`: one fix round covers them all.
for role in reviewer security adversarial; do
  reset_stubs
  case "$role" in reviewer) v=CHANGES ;; *) v=FINDINGS ;; esac
  dn "$role" --issue 42 --pr 57 --verdict "$v" --summary-file "$SUM" --draft
  assert_eq "batch" "$(line_of next)" "draft $role $v: next=batch (no per-role fix round)"
  assert_contains "$(jr)" "notify blocked #42" "draft $role $v: the blocked notice is still sent"
  assert_eq "0" "$(called draft-pr)" "draft $role $v: no draft-pr (only a QA failure converts back)"
  assert_eq "0" "$(called record-attempt)" "draft $role $v: no record-attempt"
  assert_eq "0" "$(called label-pr)" "draft $role $v: no label change"
done
assert_eq "0" "$(grep -c 'gate\b.*fix-round\|_talos_gate_fix_round' <<< "$(sed -n '/^_talos_done() {/,/^}/p' "$TALOS")")" "done never calls gate fix-round"

# RESTAMP_PASS / RESTAMP_FAIL: the verdict reaches post_stage as it is; a fail strips
# the role's own label BEFORE anything is announced.
reset_stubs
dn security --issue 42 --pr 57 --verdict RESTAMP_PASS --summary-file "$SUM"
assert_eq "notify security #42 - 42
hooks post_stage security security 42 --pr 57 --verdict RESTAMP_PASS --summary-file F
events cost --issue 42 --pr 57 --line" "$(jr)" "RESTAMP_PASS: normal relay, the verdict reaches post_stage"
assert_eq "continue" "$(line_of next)" "RESTAMP_PASS: continue"
for pair in qa:qa:pass reviewer:review:approved security:security:approved adversarial:adversarial:approved; do
  role="${pair%%:*}"; label="${pair#*:}"
  reset_stubs
  dn "$role" --issue 42 --pr 57 --verdict RESTAMP_FAIL --summary-file "$SUM"
  assert_eq "vcs label-pr 57 --remove $label" "$(jr | head -n 1)" "$role RESTAMP_FAIL: the stale label $label is stripped first"
  assert_contains "$(jr)" "hooks post_stage $role $role 42 --pr 57 --verdict RESTAMP_FAIL" "$role RESTAMP_FAIL: the verdict reaches post_stage"
  assert_eq "fix-round stage=$role" "$(line_of next)" "$role RESTAMP_FAIL: a full stage follows, like CHANGES/FINDINGS"
done
reset_stubs
dn reviewer --issue 42 --pr 57 --verdict RESTAMP_FAIL --summary-file "$SUM" --draft
assert_eq "batch" "$(line_of next)" "draft reviewer RESTAMP_FAIL: next=batch"
assert_eq "0" "$(called draft-pr)" "draft reviewer RESTAMP_FAIL: no draft-pr"

# validator
reset_stubs
printf 'CONFIRMED: reproducible\n' > "$SUM"
dn validator --issue 42 --verdict CONFIRMED --summary-file "$SUM"
assert_eq "status 42 In progress
notify validator #42 - 42
hooks post_stage validator validator 42 --verdict CONFIRMED --summary-file F
events cost --issue 42 --line" "$(jr)" "validator CONFIRMED: board In progress, relay, post_stage, the spend --line only (no PR yet)"
assert_eq "done=ok
spend=spend: 12 tokens
next=continue" "$OUT" "validator CONFIRMED: output"
for v in ALREADY_FIXED DUPLICATE NEEDS_MORE_INFO SECURITY_THREAT; do
  reset_stubs
  dn validator --issue 42 --verdict "$v" --summary-file "$SUM"
  assert_eq "status 42 Blocked
notify validator #42 - 42
hooks post_stage validator validator 42 --verdict $v --summary-file F
events cost --issue 42 --line
notify blocked #42 Validator: $v 42
hooks post_stage blocked orchestrator 42 --summary Validator: $v" "$(jr)" "validator $v: board Blocked, relay, event, spend, blocked lifecycle"
  assert_eq "stop" "$(line_of next)" "validator $v: next=stop (move to the next issue)"
done

# pm: a document, not a verdict
reset_stubs
printf 'goal — 3 acceptance criteria, branch fix/issue-42-x\n' > "$SUM"
dn pm --issue 42 --summary-file "$SUM"
assert_eq "notify pm #42 - 42
hooks post_stage pm pm 42 --summary-file F
events cost --issue 42 --line" "$(jr)" "pm: relay and event, no verdict, no board"
assert_eq "continue" "$(line_of next)" "pm: continue"
# docs, with a PR
reset_stubs
printf 'docs posted\n' > "$SUM"
dn docs --issue 42 --pr 57 --summary-file "$SUM"
assert_eq "notify docs #42 - 42
hooks post_stage docs docs 42 --pr 57 --summary-file F
events cost --issue 42 --pr 57 --line" "$(jr)" "docs: relay and event"

# developer
reset_stubs
printf 'PR #57 opened — null deref fixed\n' > "$SUM"
dn developer --issue 42 --pr 57 --verdict PR_OPENED --summary-file "$SUM"
assert_eq "status 42 In review
notify developer #42 - 42
hooks post_stage developer developer 42 --pr 57 --verdict PR_OPENED --summary-file F
events cost --issue 42 --pr 57 --line
notify pr-opened #42 PR #57 opened 42
hooks post_stage pr-opened orchestrator 42 --pr 57 --summary PR #57 opened" "$(jr)" "developer PR_OPENED: board In review, relay, event, spend, the pr-opened lifecycle event"
assert_eq "continue" "$(line_of next)" "developer PR_OPENED: continue (the playbook runs the mergeability gate)"
reset_stubs
dn developer --issue 42 --verdict BLOCKED --summary-file "$SUM"
assert_eq "status 42 Blocked
notify developer #42 - 42
hooks post_stage developer developer 42 --verdict BLOCKED --summary-file F
events cost --issue 42 --line
notify blocked #42 developer blocked 42
hooks post_stage blocked orchestrator 42 --summary developer blocked" "$(jr)" "developer BLOCKED (no PR): board Blocked, relay, event, spend --line, blocked lifecycle"
assert_eq "stop" "$(line_of next)" "developer BLOCKED: next=stop"
assert_out "developer BLOCKED" ""

# ── (b) a failed pre-step writes nothing ─────────────────────────────────────
reset_stubs
set_stub label-pr 1 "" "boom"
dn reviewer --issue 42 --pr 57 --verdict RESTAMP_FAIL --summary-file "$SUM"
assert_eq "stop reason=label-failed" "$OUT" "a failed label strip is stop reason=label-failed"
assert_eq "1" "$RC" "a failed label strip exits 1"
assert_eq "vcs label-pr 57 --remove review:approved" "$(jr)" "a failed label strip: nothing is relayed, evented or spent"
reset_stubs
set_stub draft-pr 1
dn qa --issue 42 --pr 57 --verdict FAIL --summary-file "$SUM" --draft
assert_eq "stop reason=draft-pr-failed" "$OUT" "a failed draft-pr is stop reason=draft-pr-failed"
assert_eq "vcs draft-pr 57" "$(jr)" "a failed draft-pr: no label strip, no announcement"

# ── (c) usage flags, the model rule, the spend block ─────────────────────────
reset_stubs
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM" --model 'a b;$(touch ./pwned)'
assert_contains "$OUT" "warn reason=model-invalid issue=42" "a model with other characters is dropped with a warning"
assert_not_contains "$(journal)" "--model" "a model with other characters never reaches post_stage"
assert_file_absent "$SANDBOX/pwned" "a hostile model value is never run"
reset_stubs
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM"
assert_not_contains "$(journal)" "--model" "no --model, no flag"
assert_not_contains "$(journal)" "--tokens" "no --tokens, no flag (never a guessed 0)"

# The spend comment: with a PR, comments on and spend.comment not false.
reset_stubs
cfg_json '{"vcs": {"provider": "github"}, "comments": {"enabled": true}}'
set_stub events.cost.md 0 "spend-comment-body"
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM"
assert_contains "$(jr)" "events cost --issue 42 --pr 57 --markdown
vcs upsert-pr-comment 57 --marker spend --body-file -" "the spend comment is upserted for a PR stage"
assert_eq "spend-comment-body" "$(cat "$STUB_DIR/stdin")" "the spend body reaches the upsert on stdin"
reset_stubs
cfg_json '{"vcs": {"provider": "github"}, "comments": {"enabled": true}, "spend": {"comment": false}}'
set_stub events.cost.md 0 "spend-comment-body"
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM"
assert_eq "0" "$(called upsert-pr-comment)" "spend.comment false: no upsert"
reset_stubs
cfg_json '{"vcs": {"provider": "github"}, "comments": {"enabled": true}}'
set_stub events.cost.md 0 "spend-comment-body"
dn validator --issue 42 --verdict CONFIRMED --summary-file "$SUM"
assert_eq "0" "$(called upsert-pr-comment)" "no PR yet: the spend --line only, no upsert"
assert_not_contains "$(journal)" "--markdown" "no PR yet: no --markdown call"
reset_stubs
cfg_json '{"vcs": {"provider": "github"}, "comments": {"enabled": true}}'
set_stub events.cost.md 0 "spend-comment-body"
set_stub upsert-pr-comment 1
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM"
assert_contains "$OUT" "warn reason=spend-upsert-failed issue=42" "an upsert that exits 1 is warn reason=spend-upsert-failed"
assert_eq "0" "$RC" "a failed upsert never fails the call"

# ── (d) the done-ledger ──────────────────────────────────────────────────────
reset_stubs
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM" --action-id qa-42.1_a
assert_eq "done=ok" "$(line_of done | sed 's/^/done=/')" "an action id: done=ok the first time"
assert_eq "qa-42.1_a" "$(cat "$LEDGER")" "the id is recorded under the git common dir"
BEFORE="$(journal)"
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM" --action-id qa-42.1_a
assert_eq "done=duplicate" "$OUT" "a repeated action id prints done=duplicate and nothing else"
assert_eq "0" "$RC" "a duplicate exits 0"
assert_eq "$BEFORE" "$(journal)" "a duplicate emits no second relay, event, spend or label"
assert_out "duplicate" ""
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM" --action-id qa-42.2
assert_eq "done=ok" "$(printf '%s' "$OUT" | head -n 1)" "another id is another action"
assert_eq "qa-42.1_a
qa-42.2" "$(cat "$LEDGER")" "both ids are in the ledger, one per line"
# A call with no id records nothing and repeats freely.
before_n="$(wc -l < "$LEDGER" | tr -d ' ')"
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM"
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM"
assert_eq "$before_n" "$(wc -l < "$LEDGER" | tr -d ' ')" "no --action-id: the ledger is untouched"
assert_eq "done=ok" "$(printf '%s' "$OUT" | head -n 1)" "no --action-id: a repeat runs again"
# Grammar: [a-z0-9._-]{1,64}.
for bad in "" "UPPER" "a b" 'a;b' 'a$(x)' "$(printf 'x%.0s' $(seq 1 65))" 'a/b'; do
  reset_stubs
  dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM" --action-id "$bad"
  assert_eq "stop reason=usage" "$OUT" "action id '$(printf '%.20s' "$bad")' is refused"
  assert_eq "2" "$RC" "a bad action id exits 2"
  assert_eq "" "$(journal)" "a bad action id runs nothing"
done
reset_stubs
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM" --action-id "$(printf 'x%.0s' $(seq 1 64))"
assert_eq "done=ok" "$(printf '%s' "$OUT" | head -n 1)" "a 64-character action id is accepted"
# Outside a git repository there is no common dir to hold the ledger: an id is a stop.
reset_stubs
mkdir -p "$SANDBOX/nogit-dir"
REAL_SANDBOX="$(cd "$SANDBOX" && pwd -P)"
OUT="$(cd "$SANDBOX/nogit-dir" && GIT_CEILING_DIRECTORIES="$REAL_SANDBOX" bash "$DN" done qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM" --action-id no-repo 2>"$ERR")"; RC=$?
assert_eq "stop reason=ledger-unavailable" "$OUT" "an action id outside a git repository is stop reason=ledger-unavailable"
assert_eq "1" "$RC" "ledger-unavailable exits 1"
assert_eq "" "$(journal)" "ledger-unavailable: nothing is announced"
# A failed pre-step is not recorded: the same id works once the cause is gone.
reset_stubs
set_stub label-pr 1
dn reviewer --issue 42 --pr 57 --verdict RESTAMP_FAIL --summary-file "$SUM" --action-id rs-1
assert_eq "stop reason=label-failed" "$OUT" "ledger: a failed pre-step is a stop"
assert_file_absent "$LEDGER" "ledger: a failed pre-step records nothing"
set_stub label-pr 0
dn reviewer --issue 42 --pr 57 --verdict RESTAMP_FAIL --summary-file "$SUM" --action-id rs-1
assert_eq "done=ok" "$(printf '%s' "$OUT" | head -n 1)" "ledger: the same id runs once the pre-step works"
# A lock held by a live process is `ledger-locked`: nothing is written or announced.
reset_stubs
mkdir "$LEDGER.lock.d"
printf '%s:1\n' "$$" > "$LEDGER.lock.d/pid"
TALOS_DONE_LOCK_S=1 dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM" --action-id held-1
assert_eq "stop reason=ledger-locked" "$OUT" "a lock that cannot be held is stop reason=ledger-locked"
assert_eq "1" "$RC" "ledger-locked exits 1"
assert_eq "" "$(journal)" "ledger-locked: nothing is announced"
assert_file_absent "$LEDGER" "ledger-locked: nothing is recorded"
rm -rf "${LEDGER:?}.lock.d"
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM" --action-id held-1
assert_eq "done=ok" "$(printf '%s' "$OUT" | head -n 1)" "ledger-locked: the call can be repeated once the lock is free"
assert_eq "0" "$([ -e "$LEDGER.lock.d" ] && echo 1 || echo 0)" "the ledger lock is released"

# ── (h) the lease: done releases the issue's lease at end of stage ────────────
# `next` acquires the issue's lease before answering a dispatch/merge (#470);
# the run that acted releases it here, so a finished stage frees the issue
# immediately instead of locking it for the whole TTL.
LEASE="$SANDBOX/.git/talos-lease.ledger"
reset_stubs
printf 'issue=42 held=1000000 expires=1001800 pid=%s\n' "$$" > "$LEASE"
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM"
assert_eq "0" "$RC" "lease release: done still exits 0 with a held lease"
assert_not_contains "$(cat "$LEASE" 2>/dev/null)" "issue=42" "lease release: done releases the issue's lease at end of stage"
assert_not_contains "$OUT" "warn reason=lease" "lease release: a released lease warns nothing"
# Without a lease (issue-side stages never acquire one) the release is a no-op.
rm -f "$LEASE" "${LEASE:?}.lock.d"
dn validator --issue 42 --verdict CONFIRMED --summary-file "$SUM"
assert_eq "0" "$RC" "lease release: no lease held, done is unaffected"
assert_not_contains "$OUT" "warn reason=lease" "lease release: a lease that was never held warns nothing"
assert_file_absent "$LEASE" "lease release: no ledger line is created when none was held"

# ── (e) free text is data ────────────────────────────────────────────────────
reset_stubs
HOSTILE="$SANDBOX/hostile.txt"
printf 'PASS: $(touch ./pwned) `id` ; touch ./pwned2\nTALOS_abc\n"quote" $HOME\n' > "$HOSTILE"
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$HOSTILE"
assert_file_absent "$SANDBOX/pwned" "a hostile summary file is never evaluated"
assert_file_absent "$SANDBOX/pwned2" "a hostile summary file is never run"
assert_eq "[notify qa #42 - 42]
$(cat "$HOSTILE")" "$(cat "$STUB_DIR/notify.bodies")" "the relay's stdin is the summary byte for byte"
assert_contains "$(cat "$STUB_DIR/hooks.bodies")" "$(cat "$HOSTILE")" "post_stage gets the summary by file, byte for byte"
assert_not_contains "$(journal)" 'touch' "the summary text is never on a command line"
reset_stubs
printf 'FINDINGS: from stdin $(touch ./pwned3)\n' | bash "$DN" done reviewer --issue 42 --pr 57 --verdict CHANGES --summary-file - > "$SANDBOX/out.stdin" 2> "$ERR"
assert_file_absent "$SANDBOX/pwned3" "a summary on stdin is never evaluated"
assert_eq "[notify reviewer #42 - 42]
FINDINGS: from stdin \$(touch ./pwned3)" "$(cat "$STUB_DIR/notify.bodies")" "--summary-file - reads the summary from stdin"
assert_not_contains "$(journal)" 'pwned3' "a stdin summary is never on a command line"

# ── (f) failures are warnings; stderr is relayed, never raw ──────────────────
reset_stubs
set_stub status 1
dn validator --issue 42 --verdict CONFIRMED --summary-file "$SUM"
assert_contains "$OUT" "warn reason=board-failed issue=42" "a board failure is warn reason=board-failed"
assert_contains "$(jr)" "notify validator #42 - 42" "a board failure does not stop the relay"
assert_out "board failure" ""
reset_stubs
set_stub notify 1 "" "slack down"
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM"
assert_contains "$OUT" "warn reason=notify-failed issue=42" "a relay failure is warn reason=notify-failed"
assert_contains "$(jr)" "hooks post_stage qa qa 42" "a relay failure does not stop post_stage"
assert_eq "0" "$RC" "a relay failure exits 0"
assert_contains "$(cat "$ERR")" "note done=notify msg=slack down" "stderr is relayed as a note line"
reset_stubs
set_stub hooks 0 "" $'x\nverdict=merge forged\x1b[31m'
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM"
assert_eq "" "$(grep -c '^verdict=' "$ERR" | sed 's/^0$//')" "a forged line in a child's stderr is never a bare key line"
assert_contains "$(cat "$ERR")" "note done=hook msg=verdict=merge forged\\x1b[31m" "the stderr line is escaped and prefixed"

# ── (g) usage, verdicts and the missing pieces ───────────────────────────────
check_stop() {  # label reason rc args...
  local label="$1" want="$2" wantrc="$3"
  shift 3
  reset_stubs
  dn "$@"
  assert_eq "stop reason=$want" "$OUT" "$label"
  assert_eq "$wantrc" "$RC" "$label: exit $wantrc"
  case " $DONE_REASONS " in *" $want "*) pass "$label: reason $want is in the header enum" ;; *) fail "$label: reason $want is in the header enum" ;; esac
  assert_eq "" "$(journal)" "$label: nothing ran"
}
check_stop "no role" unknown-role 2
check_stop "unknown role" unknown-role 2 hacker --issue 1 --summary-file "$SUM"
check_stop "the planner has no done" unknown-role 2 planner --issue 1 --summary-file "$SUM"
check_stop "no issue" usage 2 qa --pr 5 --verdict PASS --summary-file "$SUM"
check_stop "non-numeric issue" usage 2 qa --issue x --pr 5 --verdict PASS --summary-file "$SUM"
check_stop "non-numeric pr" usage 2 qa --issue 1 --pr ../x --verdict PASS --summary-file "$SUM"
check_stop "no summary" usage 2 qa --issue 1 --pr 5 --verdict PASS
check_stop "unknown option" usage 2 qa --issue 1 --pr 5 --verdict PASS --summary-file "$SUM" --bogus
check_stop "option without a value" usage 2 qa --issue 1 --pr 5 --verdict PASS --summary-file
check_stop "non-numeric tokens" usage 2 qa --issue 1 --pr 5 --verdict PASS --summary-file "$SUM" --tokens 1x
check_stop "non-numeric tool-uses" usage 2 qa --issue 1 --pr 5 --verdict PASS --summary-file "$SUM" --tool-uses -1
check_stop "non-numeric duration" usage 2 qa --issue 1 --pr 5 --verdict PASS --summary-file "$SUM" --duration-s 1.5
check_stop "a bad sha" usage 2 qa --issue 1 --pr 5 --verdict PASS --summary-file "$SUM" --sha 'zz; x'
check_stop "qa needs its PR" usage 2 qa --issue 1 --verdict PASS --summary-file "$SUM"
check_stop "reviewer needs its PR" usage 2 reviewer --issue 1 --verdict APPROVED --summary-file "$SUM"
check_stop "pr-opened needs its PR" usage 2 developer --issue 1 --verdict PR_OPENED --summary-file "$SUM"
check_stop "no verdict for qa" verdict-invalid 2 qa --issue 1 --pr 5 --summary-file "$SUM"
check_stop "a verdict of another role" verdict-invalid 2 qa --issue 1 --pr 5 --verdict APPROVED --summary-file "$SUM"
check_stop "a lowercase verdict" verdict-invalid 2 qa --issue 1 --pr 5 --verdict pass --summary-file "$SUM"
check_stop "a hostile verdict" verdict-invalid 2 qa --issue 1 --pr 5 --verdict 'PASS;touch x' --summary-file "$SUM"
check_stop "pm takes no verdict" verdict-invalid 2 pm --issue 1 --verdict PASS --summary-file "$SUM"
check_stop "docs takes no verdict" verdict-invalid 2 docs --issue 1 --pr 5 --verdict PASS --summary-file "$SUM"
check_stop "an unreadable summary file" file-unreadable 1 qa --issue 1 --pr 5 --verdict PASS --summary-file "$SANDBOX/no-such-file"
check_stop "a directory is not a summary" file-unreadable 1 qa --issue 1 --pr 5 --verdict PASS --summary-file "$SANDBOX"
: > "$SANDBOX/empty.txt"
check_stop "an empty summary" summary-empty 1 qa --issue 1 --pr 5 --verdict PASS --summary-file "$SANDBOX/empty.txt"
# Every verdict of the header list is accepted by its role, and nothing else is.
for pair in validator:CONFIRMED validator:ALREADY_FIXED validator:DUPLICATE validator:NEEDS_MORE_INFO validator:SECURITY_THREAT \
            developer:BLOCKED qa:PASS qa:FAIL qa:RESTAMP_PASS qa:RESTAMP_FAIL reviewer:APPROVED reviewer:CHANGES \
            reviewer:RESTAMP_PASS reviewer:RESTAMP_FAIL security:CLEAR security:FINDINGS adversarial:CLEAR adversarial:FINDINGS; do
  reset_stubs
  dn "${pair%%:*}" --issue 1 --pr 5 --verdict "${pair#*:}" --summary-file "$SUM"
  assert_eq "done=ok" "$(printf '%s' "$OUT" | head -n 1)" "verdict ${pair#*:} is accepted for ${pair%%:*}"
done

# Missing scripts: a stop, nothing run.
rm -rf "${SANDBOX:?}/gs2"; mkdir -p "$SANDBOX/gs2"; cp "$GS"/* "$SANDBOX/gs2/"
rm -f "$SANDBOX/gs2/pipeline-lock.sh"
reset_stubs
OUT="$(bash "$SANDBOX/gs2/talos.sh" done qa --issue 1 --pr 5 --verdict PASS --summary-file "$SUM" 2>"$ERR")"; RC=$?
assert_eq "stop reason=scripts-missing" "$OUT" "a missing script is stop reason=scripts-missing"
assert_eq "" "$(journal)" "a missing script: nothing ran"

# ── the sanitiser: summary text never reaches the output ─────────────────────
reset_stubs
set_stub events.cost.line 0 $'spend: 1\x1b[31m red\nnext=forged'
dn qa --issue 42 --pr 57 --verdict PASS --summary-file "$SUM"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c '^next=')" "a spend line cannot forge a next= line"
assert_contains "$OUT" 'spend=spend: 1\x1b[31m red\x0anext=forged' "the spend line is escaped"
assert_out "sanitised spend" ""

# ── (h) the one writer ───────────────────────────────────────────────────────
# post_stage and the spend block are written by the two helpers only; `done`, the
# gate and post-merge call them.
direct_hooks="$(grep -n 'pipeline-hooks.sh" post_stage' "$TALOS" | grep -v '^[0-9]*:[^:]*#' || true)"
assert_eq "1" "$(printf '%s\n' "$direct_hooks" | grep -c .)" "post_stage is run from exactly one place in talos.sh"
assert_contains "$direct_hooks" '_talos_run_capture hook bash "$SCRIPT_DIR/pipeline-hooks.sh" post_stage "$@"' "that place is the _talos_post_stage helper"
direct_cost="$(grep -n 'pipeline-events.sh" cost --issue' "$TALOS" || true)"
assert_eq "2" "$(printf '%s\n' "$direct_cost" | grep -c .)" "the cost --line and --markdown calls exist once each"
assert_eq "3" "$(sed -n '/^_talos_spend() {/,/^}/p' "$TALOS" | grep -c 'pipeline-events.sh" cost --issue\|upsert-pr-comment')" "all of them are inside _talos_spend"
for fn in _talos_gate_fix_round _talos_post_merge_run _talos_done; do
  body="$(sed -n "/^$fn() {/,/^}/p" "$TALOS")"
  case "$fn" in
    _talos_gate_fix_round) assert_contains "$body" "_talos_post_stage budget-blocked" "$fn writes through _talos_post_stage" ;;
    _talos_post_merge_run) assert_contains "$body" '_talos_post_stage merged' "$fn writes through _talos_post_stage"
                           assert_contains "$body" '_talos_spend "$_n" "$_pr"' "$fn spends through _talos_spend" ;;
    _talos_done) assert_contains "$body" '_talos_post_stage "$_role" "$_role"' "$fn writes through _talos_post_stage"
                 assert_contains "$body" '_talos_spend "$_n" "$_pr"' "$fn spends through _talos_spend" ;;
  esac
done

finish
