#!/usr/bin/env bash
# test-merge-queue-929.sh -- merge queue 2/5 (#929): under `merge.queue: talos`
# `gate merge` records a PR that passes every gate in a trusted `talos:queue`
# marker comment (FIFO by the time it became eligible) and waits with
# reason=queued; `talos.sh queue list` reads the queue back. Unset, `off` and
# `github` keep today's gate. Tests are named by the spec's criterion id.
#   AC1-AC10  gate merge / queue list against a journaling pipeline-vcs.sh stub
#             (the test-talos-gate.sh pattern; a per-PR answer is
#             <key>.<pr>.{out,rc})
#   AC11      the real pipeline-hooks.sh and pipeline-events.sh
#   AC12      the real pipeline-vcs.sh on the gh, glab and az stubs
# No network, no LLM call. Fixture times are fixed literals.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
TALOS="$TALOS_ROOT/scripts/talos.sh"
ERR="$SANDBOX/stderr"

# ── fixtures ─────────────────────────────────────────────────────────────────
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="${1:-}"; arg="${2:-}"; else key="$n"; arg=""; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then { printf "[%s]\n" "$*"; cat "$a"; printf "\n"; } >> "$d/bodies"; fi
  prev="$a"
done
if [ "$n" = "hooks" ]; then cat > "$d/hooks.stdin"; fi
f="$d/$key"
if [ -n "$arg" ] && { [ -f "$d/$key.$arg.out" ] || [ -f "$d/$key.$arg.rc" ]; }; then f="$d/$key.$arg"; fi
if [ -f "$f.err" ]; then cat "$f.err" >&2; fi
if [ -f "$f.out" ]; then cat "$f.out"; fi
rc=0
if [ -f "$f.rc" ]; then rc="$(cat "$f.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-mergebase.sh pipeline-draft-check.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
GATE="$GS/talos.sh"

HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
OTHER_SHA="fedcba9876543210fedcba9876543210fedcba98"
MARK='<!-- talos:queue -->'
DATA_RX='^queue: base=main head=[0-9a-f]{40} eligible=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# cfg_queue <merge.queue or -> [merge.auto] [extra json members]
cfg_queue() {
  local _q="" _a=""
  [ "$1" = "-" ] || _q="\"queue\": \"$1\""
  [ -z "${2:-}" ] || _a="\"auto\": $2"
  printf '{"base_branch": "main", "merge": {%s%s%s}%s}\n' "$_q" "${_q:+${_a:+, }}" "$_a" "${3:+, $3}" > "$SANDBOX/talos.pipeline.json"
}
set_stub() {  # <key> <rc> [out] [err]
  printf '%s\n' "$2" > "$STUB_DIR/$1.rc"
  printf '%s' "${3:-}" > "$STUB_DIR/$1.out"
  printf '%s' "${4:-}" > "$STUB_DIR/$1.err"
}
labels_json() {
  local out="" n
  for n in "$@"; do out="${out:+$out,}{\"name\":\"$n\"}"; done
  printf '{"labels":[%s]}' "$out"
}
# comments_json 'login|body' ... (\n in a body is a newline)
comments_json() {
  python3 -I -c '
import json, sys
out = []
for a in sys.argv[1:]:
    login, body = a.split("|", 1)
    out.append({"author": {"login": login}, "body": body.replace("\\n", "\n")})
print(json.dumps({"comments": out}))' "$@"
}
# qbody <base> <head> <eligible>: a well-formed queue marker body.
qbody() { printf '**Merge queue:**\\n\\nqueue: base=%s head=%s eligible=%s\\n\\n%s' "$1" "$2" "$3" "$MARK"; }
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  set_stub view-pr 0 "$(labels_json qa:pass review:approved security:approved docs:done pipeline:review)"
  set_stub view-issue 0 "$(labels_json pipeline:review)"
  set_stub pr-head 0 "$HEAD_SHA"
  set_stub current-user 0 "owner"
  set_stub read-comments 0 '{"comments":[]}'
  set_stub draft-check 0 "false"
  set_stub pr-ci-runs 0 "2"
  set_stub upsert-pr-comment 0 "upserted pr=9 comment=created"
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
called() { journal | grep -c "^$1 \|^vcs $1 "; }
enqueued() { journal | grep -c "^hooks post_stage queue_enqueue "; }
bodies() { cat "$STUB_DIR/bodies" 2>/dev/null; }
# The journal with scratch paths folded, so two runs compare.
journal_norm() { journal | sed 's#--body-file [^ ]*#--body-file F#g'; }
gm() { rm -f "$STUB_DIR/journal" "$STUB_DIR/bodies"; OUT="$(bash "$GATE" gate merge 9 42 </dev/null 2>"$ERR")"; RC=$?; }
ql() { OUT="$(bash "$GATE" queue list </dev/null 2>"$ERR")"; RC=$?; }

GATE_REASONS="$(sed -n 's/^# gate-reasons: //p' "$TALOS" | head -n 1)"
# check_gate_output FILE: tests/test-talos-gate.sh's contract checker.
check_gate_output() {
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
stop_extra = {"usage", "unknown-verb", "scripts-missing", "python-missing", "scratch-unavailable",
              "config-unreadable", "draft-resolve-failed", "view-failed", "labels-unreadable",
              "approval-sha-failed", "draft-unverified", "ci-unverified", "head-unresolved",
              "comments-unreadable", "handoff-label-failed", "trust-unverified", "draft-pr-failed"}
warn_ok = {"ci-runs-unrecorded", "budget-check-failed", "unblock-failed",
           "comment-failed", "label-failed", "value-truncated", "area-check-failed", "board-failed"}
kv = re.compile(r"([A-Za-z][A-Za-z0-9_.]*)=")
sw = re.compile(r"(stop|warn) reason=([a-z:-]+)( key=[A-Za-z0-9_.-]+| issue=[0-9]+)?\Z")
if lines[0].startswith("stop "):
    ok = len(lines) == 1
else:
    ok = lines[0] in ("verdict=" + v for v in ("merge", "handoff", "redispatch", "wait", "block", "ask-owner"))
if not ok:
    sys.exit(1)
for i, ln in enumerate(lines):
    m = kv.match(ln)
    if m:
        if m.group(1) == "verdict" and i != 0:
            sys.exit(1)
        if m.group(1) == "reason" and ln[7:] not in reasons:
            sys.exit(1)
        continue
    m = sw.match(ln)
    if m:
        r = m.group(2)
        if m.group(1) == "stop" and (r in stop_extra or r.startswith("unsupported-verb:")):
            continue
        if m.group(1) == "warn" and r in warn_ok:
            continue
    sys.exit(1)
' "$1" "$GATE_REASONS"
}
assert_gate() { printf '%s\n' "$OUT" > "$SANDBOX/out.gate"; check_gate_output "$SANDBOX/out.gate"; assert_eq "0" "$?" "$1: output satisfies the gate line contract"; }

# The failing gates of AC1 and AC5, each a set_stub line on top of reset_stubs.
gate_case() {
  reset_stubs
  case "$1" in
    happy) : ;;
    blocked-label) set_stub view-pr 0 "$(labels_json qa:pass review:approved security:approved docs:done pipeline:blocked)" ;;
    approvals-missing) set_stub view-pr 0 "$(labels_json qa:pass docs:done)"; set_stub check-approval-sha 0 "" ;;
    stale-approvals) set_stub check-approval-sha 1 "stale role=qa label=qa:pass" "qa: approved at aaa, head is bbb" ;;
    forbidden-files) set_stub check-pr-files 1 ".github/workflows/x.yml" "forbidden" ;;
    ci-pending) set_stub pr-checks-required 2 "" "pending" ;;
    ci-failed)
      set_stub pr-checks-required 1 "" "pr-checks-required: failed: build"
      set_stub read-comments 0 "$(comments_json "owner|<!-- talos:ci-rerun $HEAD_SHA -->" "owner|<!-- talos:ci-rerun $HEAD_SHA -->")" ;;
  esac
}
CASES="happy blocked-label approvals-missing stale-approvals forbidden-files ci-pending ci-failed"

# ── AC1 (same): unset, off and github keep today's gate ──────────────────────
for c in $CASES; do
  gate_case "$c"; cfg_queue -; gm
  base_out="$OUT"; base_rc="$RC"; base_j="$(journal_norm)"
  for q in off; do
    gate_case "$c"; cfg_queue "$q"; gm
    assert_eq "$base_rc|$base_out" "$RC|$OUT" "AC1 merge.queue=$q, $c: gate merge prints what it prints with the key unset"
    assert_eq "$base_j" "$(journal_norm)" "AC1 merge.queue=$q, $c: the same pipeline-vcs call journal"
    assert_eq "0|0" "$(called upsert-pr-comment)|$(enqueued)" "AC1 merge.queue=$q, $c: no upsert, no queue_enqueue"
  done
done
gate_case happy; cfg_queue off; gm
assert_eq "verdict=merge" "$OUT" "AC1 merge.queue=off, every gate green: verdict=merge as today"

# ── AC2: all gates pass, no marker -> one upsert at the head, reason=queued ───
reset_stubs; cfg_queue talos true; gm
assert_eq "0" "$RC" "AC2 gate merge exits 0"
assert_eq "verdict=wait
reason=queued" "$OUT" "AC2 an eligible PR waits with reason=queued"
assert_gate "AC2 queued"
assert_eq "1" "$(called upsert-pr-comment)" "AC2 exactly one upsert-pr-comment call"
assert_contains "$(journal)" "vcs upsert-pr-comment 9 --marker queue --body-file -" "AC2 the upsert names the queue marker and reads the body on stdin"
assert_eq "0" "$(called merge-pr)" "AC2 merge-pr is never called"
_qb="$(bodies | sed -n '/^\[upsert-pr-comment/,$p' | sed 1d)"
assert_eq "**Merge queue:**" "$(printf '%s\n' "$_qb" | sed -n 1p)" "AC2 the body starts with the **Merge queue:** heading"
assert_eq "" "$(printf '%s\n' "$_qb" | sed -n 2p)" "AC2 a blank line follows the heading"
assert_eq "1" "$(printf '%s\n' "$_qb" | grep -c '^queue:')" "AC2 the body carries exactly one data line"
printf '%s\n' "$_qb" | sed -n 3p | grep -Eq "$DATA_RX" \
  && pass "AC2 the data line is queue: base=main head=<40 hex> eligible=<UTC>" \
  || fail "AC2 the data line is queue: base=main head=<40 hex> eligible=<UTC>" "$(printf '%s\n' "$_qb" | sed -n 3p)"
assert_contains "$_qb" "head=$HEAD_SHA " "AC2 the data line names the current head"

# ── AC3: a trusted marker at the same head and base -> nothing written ───────
reset_stubs; cfg_queue talos true
set_stub read-comments 0 "$(comments_json "owner|$(qbody main "$HEAD_SHA" 2026-11-01T00:00:00Z)")"
gm
assert_eq "verdict=wait
reason=queued" "$OUT" "AC3 an already-queued PR still waits with reason=queued"
assert_eq "0" "$(called upsert-pr-comment)" "AC3 no upsert call for the same head and base"
assert_eq "0" "$(enqueued)" "AC3 no queue_enqueue event"
assert_gate "AC3 queued"

# ── AC4: a marker at an older head (or another base) is rewritten ────────────
for old in "main $OTHER_SHA" "develop $HEAD_SHA"; do
  read -r ob oh <<< "$old"
  L="AC4 marker base=$ob head=${oh:0:7}"
  reset_stubs; cfg_queue talos true
  set_stub upsert-pr-comment 0 "upserted pr=9 comment=updated"
  set_stub read-comments 0 "$(comments_json "owner|$(qbody "$ob" "$oh" 2026-11-01T00:00:00Z)")"
  gm
  assert_eq "verdict=wait
reason=queued" "$OUT" "$L: still reason=queued"
  assert_eq "1" "$(called upsert-pr-comment)" "$L: one upsert"
  assert_contains "$(bodies)" "queue: base=main head=$HEAD_SHA eligible=" "$L: rewritten at the current head and base"
  assert_not_contains "$(bodies)" "eligible=2026-11-01T00:00:00Z" "$L: with a new eligible time"
  assert_eq "1" "$(enqueued)" "$L: an update is a queue_enqueue event"
done

# ── AC5: a failing gate keeps today's verdict under merge.queue: talos ───────
gate_case happy; cfg_queue talos true; gm
assert_eq "1" "$(called upsert-pr-comment)" "AC5 control: the same PR with every gate green is enqueued"
for c in blocked-label approvals-missing stale-approvals forbidden-files ci-pending ci-failed; do
  gate_case "$c"; cfg_queue -; gm
  today="$RC|$OUT"
  gate_case "$c"; cfg_queue talos true; gm
  assert_eq "$today" "$RC|$OUT" "AC5 $c: today's verdict and reason under merge.queue: talos"
  assert_eq "0|0" "$(called upsert-pr-comment)|$(enqueued)" "AC5 $c: no upsert, no queue_enqueue"
  assert_not_contains "$OUT" "reason=queued" "AC5 $c: not queued"
done

# ── AC6 (same): merge.auto false hands off before the queue step ─────────────
reset_stubs; cfg_queue off false; gm
# The one call the queue does not make: merge.queue off also reads pr-behind (#1060).
handoff_j="$(journal_norm | grep -v '^vcs pr-behind ')"
reset_stubs; cfg_queue talos false; gm
assert_eq "verdict=handoff" "$OUT" "AC6 merge.queue: talos with merge.auto: false still hands off"
assert_eq "$handoff_j" "$(journal_norm)" "AC6 the same calls as the hand-off without the queue"
assert_eq "0|0|0" "$(called upsert-pr-comment)|$(called read-comments)|$(enqueued)" "AC6 no queue read or write"

# ── AC7: queue list is FIFO by eligible, then PR number, across processes ─────
# list_fixture: PRs 11-17 on main and 18 on develop. 12 is oldest, 11 and 13 tie,
# 14 has no marker, 15's marker is at an older head, 16's names another base.
list_fixture() {
  reset_stubs; cfg_queue talos true
  set_stub list-prs 0 '[{"number":11,"baseRefName":"main"},{"number":12,"baseRefName":"main"},{"number":13,"baseRefName":"main"},{"number":14,"baseRefName":"main"},{"number":15,"baseRefName":"main"},{"number":16,"baseRefName":"main"},{"number":18,"baseRefName":"develop"}]'
  local p
  for p in 11 12 13 14 15 16 18; do set_stub "pr-head.$p" 0 "$(printf '%040d' "$p")"; done
  set_stub read-comments.11 0 "$(comments_json "owner|$(qbody main "$(printf '%040d' 11)" 2026-11-03T00:00:00Z)")"
  set_stub read-comments.12 0 "$(comments_json "owner|$(qbody main "$(printf '%040d' 12)" 2026-11-01T00:00:00Z)")"
  set_stub read-comments.13 0 "$(comments_json "owner|$(qbody main "$(printf '%040d' 13)" 2026-11-03T00:00:00Z)")"
  set_stub read-comments.14 0 '{"comments":[]}'
  set_stub read-comments.15 0 "$(comments_json "owner|$(qbody main "$OTHER_SHA" 2026-10-01T00:00:00Z)")"
  set_stub read-comments.16 0 "$(comments_json "owner|$(qbody develop "$(printf '%040d' 16)" 2026-10-01T00:00:00Z)")"
  set_stub read-comments.18 0 "$(comments_json "owner|$(qbody develop "$(printf '%040d' 18)" 2026-10-01T00:00:00Z)")"
}
list_fixture
ql
assert_eq "0" "$RC" "AC7 queue list exits 0"
assert_eq "queued pr=12 head=$(printf '%040d' 12) eligible=2026-11-01T00:00:00Z
queued pr=11 head=$(printf '%040d' 11) eligible=2026-11-03T00:00:00Z
queued pr=13 head=$(printf '%040d' 13) eligible=2026-11-03T00:00:00Z" "$OUT" "AC7 FIFO by eligible time, a tie by PR number; no-marker, stale-head and other-base PRs left out"
first="$OUT"
ql
assert_eq "$first" "$OUT" "AC7 a fresh second process prints identical output"
assert_not_contains "$(journal)" "read-comments 18" "AC7 a PR on another base is not read"
assert_eq "0" "$(called upsert-pr-comment)" "AC7 queue list writes nothing"

# ── AC8: a corrupt trusted marker fails closed ───────────────────────────────
corrupt_bodies=(
  "**Merge queue:**\n\nno data here\n\n$MARK"
  "**Merge queue:**\n\nqueue: base=main head=$HEAD_SHA eligible=2026-11-01T00:00:00Z\nqueue: base=main head=$HEAD_SHA eligible=2026-11-02T00:00:00Z\n\n$MARK"
  "**Merge queue:**\n\nqueue: base=main head=0123456789ABCDEF0123456789abcdef0123456z eligible=2026-11-01T00:00:00Z\n\n$MARK"
  "**Merge queue:**\n\nqueue: base=main head=$HEAD_SHA eligible=2026-13-45T99:00:00Z\n\n$MARK"
)
corrupt_names=("no data line" "two data lines" "non-hex head" "bad eligible")
i=0
while [ "$i" -lt "${#corrupt_bodies[@]}" ]; do
  cb="${corrupt_bodies[$i]}"; cn="${corrupt_names[$i]}"
  reset_stubs; cfg_queue talos true
  set_stub read-comments 0 "$(comments_json "owner|$cb")"
  gm
  assert_eq "verdict=wait
reason=queue-state-unverified" "$OUT" "AC8 gate merge, $cn: verdict=wait reason=queue-state-unverified"
  assert_eq "0|0" "$(called upsert-pr-comment)|$(enqueued)" "AC8 gate merge, $cn: no upsert, no event"
  assert_gate "AC8 $cn"
  list_fixture
  set_stub read-comments.13 0 "$(comments_json "owner|$cb")"
  ql
  assert_eq "stop reason=queue-state-unverified" "$OUT" "AC8 queue list, $cn: one lone stop line, no queued line"
  assert_eq "1" "$RC" "AC8 queue list, $cn: exits 1"
  i=$((i + 1))
done
list_fixture; set_stub read-comments.12 1 "" "boom"; ql
assert_eq "stop reason=queue-state-unverified" "$OUT" "AC8 queue list: a failed read-comments is the same lone stop"
list_fixture; set_stub pr-head.12 1 "" "boom"; ql
assert_eq "stop reason=queue-state-unverified" "$OUT" "AC8 queue list: a failed pr-head is the same lone stop"
list_fixture; set_stub list-prs 1 "" "boom"; ql
assert_eq "stop reason=queue-state-unverified" "$OUT" "AC8 queue list: a failed list-prs is the same lone stop"

# ── AC9: failed reads and writes never merge ─────────────────────────────────
reset_stubs; cfg_queue talos true; set_stub read-comments 1 "" "boom"; gm
assert_eq "stop reason=comments-unreadable" "$OUT" "AC9 a failed read-comments stops comments-unreadable"
assert_eq "1|0|0" "$RC|$(called upsert-pr-comment)|$(enqueued)" "AC9 comments-unreadable exits 1, writes nothing"
reset_stubs; cfg_queue talos true; set_stub read-comments 0 "not json"; gm
assert_eq "stop reason=comments-unreadable" "$OUT" "AC9 an unparsable read-comments stops comments-unreadable"
reset_stubs; cfg_queue talos true; set_stub current-user 2 "" "refused"; gm
assert_eq "stop reason=trust-unverified" "$OUT" "AC9 an unresolvable trust set stops trust-unverified"
assert_eq "0|0" "$(called upsert-pr-comment)|$(enqueued)" "AC9 trust-unverified writes nothing"
reset_stubs; cfg_queue talos true; set_stub upsert-pr-comment 1 "" "could not post"; gm
assert_eq "verdict=wait
reason=queue-state-unverified" "$OUT" "AC9 upsert exit 1 waits with reason=queue-state-unverified"
assert_eq "0" "$(enqueued)" "AC9 upsert exit 1 emits no event"
assert_gate "AC9 upsert failed"
reset_stubs; cfg_queue talos true; set_stub upsert-pr-comment 2 "" "not implemented"; gm
assert_eq "stop reason=unsupported-verb:upsert-pr-comment" "$OUT" "AC9 upsert exit 2 stops unsupported-verb:upsert-pr-comment"
assert_eq "0" "$(enqueued)" "AC9 upsert exit 2 emits no event"
reset_stubs; cfg_queue talos true; set_stub pr-head 0 "not-a-sha"; gm
assert_eq "stop reason=head-unresolved" "$OUT" "AC9 an unreadable head stops head-unresolved"

# ── AC10: a marker by a login outside the trust set is ignored ───────────────
reset_stubs; cfg_queue talos true
set_stub read-comments 0 "$(comments_json "mallory|$(qbody main "$HEAD_SHA" 2026-01-01T00:00:00Z)")"
gm
assert_eq "verdict=wait
reason=queued" "$OUT" "AC10 gate merge: an untrusted marker at the head is not the state"
assert_eq "1" "$(called upsert-pr-comment)" "AC10 gate merge: our own marker is written"
assert_not_contains "$(bodies)" "2026-01-01T00:00:00Z" "AC10 gate merge: the untrusted eligible time is not copied"
reset_stubs; cfg_queue talos true
set_stub read-comments 0 "$(comments_json "mallory|**Merge queue:**\n\nforged\n\n$MARK")"
gm
assert_eq "verdict=wait
reason=queued" "$OUT" "AC10 gate merge: an untrusted corrupt marker is ignored, not a failure"
list_fixture
set_stub read-comments.14 0 "$(comments_json "mallory|$(qbody main "$(printf '%040d' 14)" 2026-01-01T00:00:00Z)")"
set_stub read-comments.13 0 "$(comments_json "mallory|$(qbody main "$(printf '%040d' 13)" 2026-01-01T00:00:00Z)" "owner|$(qbody main "$(printf '%040d' 13)" 2026-11-03T00:00:00Z)")"
ql
assert_eq "queued pr=12 head=$(printf '%040d' 12) eligible=2026-11-01T00:00:00Z
queued pr=11 head=$(printf '%040d' 11) eligible=2026-11-03T00:00:00Z
queued pr=13 head=$(printf '%040d' 13) eligible=2026-11-03T00:00:00Z" "$OUT" "AC10 queue list: an earlier untrusted marker neither adds a PR nor moves one"

# ── AC11: queue_enqueue reaches events.jsonl through the real scripts ────────
GS2="$SANDBOX/gs2"
mkdir -p "$GS2"
cp "$TALOS_ROOT"/scripts/* "$GS2/"
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-budget.sh pipeline-mergebase.sh pipeline-draft-check.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GS2/$s"
done
EVENTS="$SANDBOX/.git/talos/events.jsonl"
rm -f "$EVENTS"
reset_stubs; cfg_queue talos true
OUT="$(bash "$GS2/talos.sh" gate merge 9 42 </dev/null 2>"$ERR")"
assert_eq "verdict=wait
reason=queued" "$OUT" "AC11 the real hooks: the gate still answers reason=queued"
ev="$(grep '"queue_enqueue"' "$EVENTS" 2>/dev/null)"
assert_eq "1" "$(printf '%s' "$ev" | grep -c .)" "AC11 one queue_enqueue line in events.jsonl"
python3 -I -c '
import json, sys
e = json.loads(sys.argv[1])
sys.exit(0 if (e["event"], e["role"], e["issue"], e["pr"], e["sha"]) == ("queue_enqueue", "orchestrator", 42, 9, sys.argv[2]) else 1)' "$ev" "$HEAD_SHA" 2>/dev/null \
  && pass "AC11 the event carries role orchestrator, issue, pr and the head sha" \
  || fail "AC11 the event carries role orchestrator, issue, pr and the head sha" "$ev"
listed="$(bash "$GS2/pipeline-events.sh" list --event queue_enqueue --json 2>/dev/null)"
assert_contains "$listed" "queue_enqueue" "AC11 pipeline-events.sh list --event queue_enqueue --json shows it"
assert_contains "$listed" "$HEAD_SHA" "AC11 the listed event names the head"
set_stub read-comments 0 "$(comments_json "owner|$(qbody main "$HEAD_SHA" 2026-11-01T00:00:00Z)")"
bash "$GS2/talos.sh" gate merge 9 42 </dev/null >/dev/null 2>&1
assert_eq "1" "$(grep -c '"queue_enqueue"' "$EVENTS")" "AC11 a second run at the same head adds no event"

# ── AC12: upsert-pr-comment --marker queue on github, gitlab and azure ───────
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
FIX="$SANDBOX/fix"
mkdir -p "$FIX"
printf '**Merge queue:**\n\nqueue: base=main head=%s eligible=2026-11-01T00:00:00Z\n' "$OTHER_SHA" > "$FIX/q1"
printf '**Merge queue:**\n\nqueue: base=main head=%s eligible=2026-11-02T00:00:00Z\n' "$HEAD_SHA" > "$FIX/q2"
up() { OUT="$(bash "$VCS" upsert-pr-comment 9 --marker queue --body-file - < "$1" 2>"$ERR")"; RC=$?; }

# github: the gh stub's stateful comment store.
export GITHUB_TOKEN="test-token-929"
export STUB_COMMENT_STORE="$SANDBOX/store.json"
export GH_STDIN_LOG="$SANDBOX/gh.stdin.log"
export GH_REST_LOG="$CURL_LOG"
export CURL_ARGV_LOG="$SANDBOX/curl.argv.log"
export STUB_CURRENT_USER="owner"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > talos.pipeline.json
printf '[]' > "$STUB_COMMENT_STORE"
up "$FIX/q1"
assert_eq "0" "$RC" "AC12 github: --marker queue is accepted (exit 0)"
assert_contains "$OUT" "comment=created" "AC12 github: the first upsert creates the marker comment"
up "$FIX/q2"
assert_contains "$OUT" "comment=updated" "AC12 github: the second upsert updates it in place"
gh_store="$(python3 -I -c '
import json, sys
s = json.load(open(sys.argv[1]))
print(len(s)); print(s[0]["body"])' "$STUB_COMMENT_STORE")"
assert_eq "1" "$(printf '%s\n' "$gh_store" | sed -n 1p)" "AC12 github: one comment after two upserts"
assert_contains "$gh_store" "head=$HEAD_SHA" "AC12 github: the comment holds the new data line"
assert_eq "$MARK" "$(printf '%s\n' "$gh_store" | tail -n 1)" "AC12 github: the queue marker is the last line"

# gitlab: the glab stub writes notes back to its state dir.
git remote set-url origin git@gitlab.com:acme/widget.git
printf '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}, "markers": {"trusted_authors": ["bot"]}}\n' > talos.pipeline.json
export STUB_CURRENT_USER="bot" STUB_GITLAB_POST_AUTHOR="bot"
STUB_GITLAB_STATE_DIR="$(safe_mktemp_dir "$SANDBOX/gl.XXXXXX")" || exit 1
export STUB_GITLAB_STATE_DIR
: > "$GH_LOG"
up "$FIX/q1"
assert_eq "0" "$RC" "AC12 gitlab: --marker queue is accepted (exit 0)"
assert_contains "$OUT" "comment=created" "AC12 gitlab: the first upsert creates the marker note"
up "$FIX/q2"
assert_contains "$OUT" "comment=updated" "AC12 gitlab: the second upsert updates it in place"
assert_eq "1|1" "$(grep -c '^GLAB api --method POST projects/acme%2Fwidget/merge_requests/9/notes' "$GH_LOG")|$(grep -c '^GLAB api --method PUT projects/acme%2Fwidget/merge_requests/9/notes/' "$GH_LOG")" "AC12 gitlab: one POST, then one PUT"

# azure: the az stub serves the threads it is given.
git remote set-url origin git@github.com:acme/widget.git
printf '{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}, "markers": {"trusted_authors": ["bot@acme.com"]}}\n' > talos.pipeline.json
export STUB_CURRENT_USER="bot@acme.com" STUB_AZURE_POST_AUTHOR="bot@acme.com"
: > "$GH_LOG"
STUB_AZURE_PR_THREADS='{"value":[]}' up "$FIX/q1"
assert_eq "0" "$RC" "AC12 azure: --marker queue is accepted (exit 0)"
assert_contains "$OUT" "comment=created" "AC12 azure: the first upsert creates the marker thread"
az_thr="$(python3 -I -c '
import json, sys
c = open(sys.argv[1]).read().rstrip("\n") + "\n\n" + sys.argv[2]
print(json.dumps({"value": [{"id": 5, "comments": [{"id": 2, "content": c, "commentType": "text",
    "author": {"displayName": "Bot", "uniqueName": "bot@acme.com"}, "publishedDate": "2026-11-01T00:00:00Z"}]}]}))' "$FIX/q1" "$MARK")"
: > "$GH_LOG"
STUB_AZURE_PR_THREADS="$az_thr" up "$FIX/q2"
assert_contains "$OUT" "comment=updated" "AC12 azure: the second upsert updates it in place"
assert_eq "1|0" "$(grep -c '^AZ ARGS: \[rest\] \[--method\] \[patch\].*pullRequests/9/threads/5/comments/2' "$GH_LOG")|$(grep -c '^AZ ARGS: \[rest\] \[--method\] \[post\].*pullRequests/9/threads' "$GH_LOG")" "AC12 azure: one PATCH of the marker comment, no new thread"

finish
