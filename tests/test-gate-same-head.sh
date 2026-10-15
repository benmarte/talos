#!/usr/bin/env bash
# test-gate-same-head.sh -- the same-area check of `gate fix-round` counts a
# re-review of one unchanged PR head as one round (#710).
#
# A findings comment carries `<!-- talos:reviewed sha=<40-hex> -->`; adjacent
# findings comments whose heads are both known and equal collapse into one
# round. A comment with no marker has an unknown head and is its own round (fail
# open). Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
ERR="$SANDBOX/stderr"

# ── fixtures (as tests/test-talos-gate.sh) ───────────────────────────────────
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="${1:-}"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
if [ "$n" = "hooks" ]; then cat > "$d/hooks.stdin"; fi
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-mergebase.sh pipeline-draft-check.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
GATE="$GS/talos.sh"

SHA_A="0123456789abcdef0123456789abcdef01234567"
SHA_B="fedcba9876543210fedcba9876543210fedcba98"
SHA_C="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
cfg_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }
set_stub() {
  printf '%s\n' "$2" > "$STUB_DIR/$1.rc"
  printf '%s' "${3:-}" > "$STUB_DIR/$1.out"
  printf '%s' "${4:-}" > "$STUB_DIR/$1.err"
}
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$SANDBOX/talos.pipeline.json"
  set_stub read-comments 0 '{"comments":[]}'
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
called() { journal | grep -c "^$1 \|^vcs $1 "; }
line_of() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
comments_json() {  # <login> <body>...: a read-comments object
  python3 -I -c 'import json, sys
a = sys.argv[1:]
print(json.dumps({"comments": [{"author": {"login": a[i]}, "body": a[i + 1]} for i in range(0, len(a), 2)]}))' "$@"
}
fr() { OUT="$(bash "$GATE" gate fix-round "$@" 2>"$ERR")"; RC=$?; }
area() {  # <stage> <comments-json>: one gate run on PR 9
  set_stub read-comments 0 "$2"; set_stub record-attempt 0 "stage=$1 count=1 total=1"
  : > "$STUB_DIR/journal"
  fr 42 "$1" --pr 9
}
mark() { printf '<!-- talos:reviewed sha=%s -->' "$1"; }

REV_1=$'**Agent:** reviewer (talos)\n\n**Blocked** — a pin\n\n1. scripts/x.sh:12 asserts nothing.'
REV_2=$'**Agent:** reviewer (talos)\n\n**Blocked** — the pin again\n\n1. scripts/x.sh:30 still passes on the old code.'
REV_A1="$REV_1"$'\n\n'"$(mark "$SHA_A")"
REV_A2="$REV_2"$'\n\n'"$(mark "$SHA_A")"
REV_B2="$REV_2"$'\n\n'"$(mark "$SHA_B")"
REV_C2="$REV_2"$'\n\n'"$(mark "$SHA_C")"
REV_APPROVAL="$REV_2"$'\n\n<!-- talos:approval sha='"$SHA_A"$' role=reviewer -->\n'"$(mark "$SHA_A")"
TODAY_OUT="verdict=redispatch
count=1
total=1
stage=reviewer"
ASKED=$'Design decision needed: reviewer blocked PR #9 on scripts/x.sh in 2 rounds running. Which design should the next fix round implement?\n\nReply on this PR with the decision; the next fix-round gate continues from it.\n\n<!-- talos:needs-owner -->'

# AC1: two findings comments on one file at one head are one round.
reset_stubs
area reviewer "$(comments_json bot "$REV_A1" bot "$REV_A2")"
assert_eq "$TODAY_OUT" "$OUT" "AC1 two reviewer findings on one file at one head: redispatch"
assert_eq "1" "$(called record-attempt)" "AC1 the attempt is recorded"
assert_eq "0" "$(called mark-needs-owner)" "AC1 no question is parked"

# AC2: different heads are two rounds.
reset_stubs
area reviewer "$(comments_json bot "$REV_A1" bot "$REV_B2")"
assert_eq "verdict=ask-owner
reason=design-decision
stage=reviewer
rounds=2
area=scripts/x.sh" "$OUT" "AC2 two reviewer findings on one file at different heads: ask-owner"

# AC3: owner question guards (green on base).
reset_stubs
area reviewer "$(comments_json bot "$REV_A1" bot "$REV_B2" bot "$ASKED" owner "Use fixed paths only.")"
assert_eq "$TODAY_OUT" "$OUT" "AC3 an answered owner question: redispatch"
area reviewer "$(comments_json bot "$REV_A1" bot "$REV_B2" bot "$ASKED")"
assert_eq "verdict=ask-owner
reason=design-decision
stage=reviewer" "$OUT" "AC3 an unanswered owner question: ask-owner with no rounds= or area="

# AC4: no marker, unknown heads: fail open (green on base).
reset_stubs
area reviewer "$(comments_json bot "$REV_1" bot "$REV_2")"
assert_eq "verdict=ask-owner" "$(printf '%s\n' "$OUT" | head -n 1)" "AC4 two same-file findings with no marker: ask-owner"
assert_eq "scripts/x.sh" "$(line_of "$OUT" area)" "AC4 unmarked findings: the area is the shared file"
area reviewer "$(comments_json bot "$REV_A1" bot "$REV_2")"
assert_eq "verdict=ask-owner" "$(printf '%s\n' "$OUT" | head -n 1)" "AC4 one marked and one unmarked comment: unknown head, ask-owner"

# AC5: the carve-out admits only the reviewed marker.
reset_stubs
area reviewer "$(comments_json bot "$REV_A1" bot "$REV_APPROVAL")"
assert_eq "$TODAY_OUT" "$OUT" "AC5 a comment with an approval marker is not a findings comment, even carrying the reviewed marker"
area reviewer "$(comments_json bot "$REV_A1")"
assert_eq "$TODAY_OUT" "$OUT" "AC5 one marker-carrying findings comment is one round: redispatch"
area reviewer "$(comments_json bot "$REV_A1" bot "$REV_B2")"
assert_eq "verdict=ask-owner" "$(printf '%s\n' "$OUT" | head -n 1)" "AC5 marker-carrying findings comments are counted as findings"

# AC6: limits.same_area_rounds=3 over heads A, A, B / A, B, C.
reset_stubs; cfg_json '{"limits": {"same_area_rounds": 3}}'
area reviewer "$(comments_json bot "$REV_A1" bot "$REV_A2" bot "$REV_B2")"
assert_eq "$TODAY_OUT" "$OUT" "AC6 heads A, A, B collapse to two rounds: redispatch"
area reviewer "$(comments_json bot "$REV_A1" bot "$REV_B2" bot "$REV_C2")"
assert_eq "verdict=ask-owner" "$(printf '%s\n' "$OUT" | head -n 1)" "AC6 heads A, B, C are three rounds: ask-owner"
assert_eq "3" "$(line_of "$OUT" rounds)" "AC6 heads A, B, C: rounds=3"

finish
