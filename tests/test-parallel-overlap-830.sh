#!/usr/bin/env bash
# test-parallel-overlap-830.sh -- the issue walk of pipeline-next.py prefers
# ready issues whose expected files do not overlap the files of the issues in
# flight (#830, part of #826). Expected files come from a "Files touched" list
# in the issue body (else the PM spec), and from `area:*` labels when there is
# no list. A generated file never overlaps; two migrations always do. Overlap
# demotes, never blocks. Runs `pipeline-next.py issue-side` against a stub
# provider: no GitHub read, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

NEXT="$TALOS_ROOT/scripts/pipeline-next.py"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$STUB_DIR"

cat > "$SANDBOX/vcs.sh" <<'TALOS_stubvcs830Qm7'
#!/usr/bin/env bash
# view-issue <n> [--spec]: $STUB_DIR/view-issue.<n>[.spec].json (the spec read
# falls back to the plain answer); every call is logged.
printf '%s\n' "$*" >> "${STUB_DIR:?}/calls.log"
[ "$1" = "view-issue" ] || exit 1
f="$STUB_DIR/view-issue.$2.json"
if [ "${3:-}" = "--spec" ] && [ -f "$STUB_DIR/view-issue.$2.spec.json" ]; then f="$STUB_DIR/view-issue.$2.spec.json"; fi
[ -f "$f" ] || exit 1
cat "$f"
TALOS_stubvcs830Qm7

# issue <n> <labels,|-> <body> : issue #n's plain view-issue answer.
issue() {
  python3 -I -c "
import json, sys
labels = [] if sys.argv[2] == '-' else [{'name': x} for x in sys.argv[2].split(',')]
print(json.dumps({'number': int(sys.argv[1]), 'title': 'issue ' + sys.argv[1], 'labels': labels, 'body': sys.argv[3], 'comments': []}))" \
    "$1" "$2" "$3" > "$STUB_DIR/view-issue.$1.json"
}
# spec <n> <comment body> : issue #n's --spec answer, one PM spec comment.
spec() {
  python3 -I -c "
import json, sys
print(json.dumps({'title': 't', 'body': '', 'labels': [], 'comments': [{'body': sys.argv[2]}]}))" \
    "$1" "$2" > "$STUB_DIR/view-issue.$1.spec.json"
}
# files <path...> : a body with a Files touched list.
files() {
  local _b=$'Part of #1\n\n## Files touched\n' _p
  for _p in "$@"; do _b="$_b- $_p"$'\n'; done
  printf '%s' "$_b"
}
# state <queued,|-> <inflight,|-> [priority-json]
state() {
  python3 -I -c "
import json, sys
ids = lambda s: [] if s == '-' else [int(x) for x in s.split(',')]
d = {'prs': [], 'pr_total': 0, 'ignored': 0, 'blocked': [], 'queued': ids(sys.argv[1]), 'held': [],
     'inflight': ids(sys.argv[2]), 'owners': [], 'capped': []}
if len(sys.argv) > 3 and sys.argv[3]: d['priority'] = json.loads(sys.argv[3])
print(json.dumps(d))" "$1" "$2" "${3-}" > "$SANDBOX/state.json"
}
# walk <max-parallel|-> <leased,|-> : the issue-side answer into OUT.
walk() {
  local _l="" _m=()
  [ "$2" = "-" ] || _l="$2"
  [ "$1" = "-" ] || _m=(--max-parallel "$1")
  OUT="$(python3 -I "$NEXT" issue-side "$SANDBOX/state.json" --vcs "$SANDBOX/vcs.sh" --issue '' \
    --roles validator --label-filter pipeline:ready --skip-labels '' \
    ${_m[@]+"${_m[@]}"} --pm-skip false --leased "$_l" 2>/dev/null)"
}
reset() { rm -f "$STUB_DIR"/*; }

# ── AC1: the cap arithmetic (existing behaviour, pinned) ──────────────────────
reset
for _n in 1 2 3 4 5; do issue "$_n" "pipeline:ready" ""; done
state "5" "-"
walk 4 "1,2,3"
assert_eq "action=dispatch stage=validator issue=5" "$OUT" "AC1 max-parallel 4 dispatches a ready issue while 3 leases are held"
walk 4 "1,2,3,4"
assert_eq "action=wait reason=cap" "$OUT" "AC1 max-parallel 4 answers wait reason=cap at 4 leases"
walk - "1"
assert_eq "action=wait reason=cap" "$OUT" "AC1 max-parallel unset answers wait reason=cap at one lease"

# ── AC2: a files list that overlaps an in-flight issue is demoted ─────────────
reset
issue 1 "pipeline:dev" "$(files scripts/a.sh)"
issue 2 "pipeline:ready" "$(files scripts/a.sh)"
issue 3 "pipeline:ready" "$(files scripts/b.sh)"
state "2,3" "1"
walk 4 "1"
assert_eq "action=dispatch stage=validator issue=3" "$OUT" "AC2 the ready issue with a disjoint files list is dispatched first"
rm "$STUB_DIR/view-issue.3.json"
state "2" "1"
walk 4 "1"
assert_eq "action=dispatch stage=validator issue=2" "$OUT" "AC2 an overlapping issue is still dispatched when nothing else fits"
# A trailing parenthesised note is not part of the path, and a backticked path counts.
reset
issue 1 "pipeline:dev" "$(files 'scripts/a.sh (walk ~690)')"
issue 2 "pipeline:ready" "$(files '`scripts/a.sh` the walk')"
issue 3 "pipeline:ready" "$(files scripts/b.sh)"
state "2,3" "1"
walk 4 "1"
assert_eq "action=dispatch stage=validator issue=3" "$OUT" "AC2 a bullet note is stripped and a backticked path is read"

# ── AC3: area labels stand in for a missing files list ────────────────────────
reset
issue 1 "pipeline:dev,area:api" "no list here"
issue 2 "pipeline:ready,area:api" "no list here"
issue 3 "pipeline:ready,area:web" "no list here"
state "2,3" "1"
walk 4 "1"
assert_eq "action=dispatch stage=validator issue=3" "$OUT" "AC3 without any files list the area label decides"
issue 1 "pipeline:dev,bug" "no list here"
issue 2 "pipeline:ready,bug" "no list here"
issue 3 "pipeline:ready,bug" "no list here"
walk 4 "1"
assert_eq "action=dispatch stage=validator issue=2" "$OUT" "AC3 only an area: label counts (the queue order stays)"

# ── AC4: the PM spec's list is used when the body has none ────────────────────
reset
issue 1 "pipeline:dev" "$(files scripts/a.sh)"
issue 2 "pipeline:ready" "no list in the body"
issue 3 "pipeline:ready" "$(files scripts/b.sh)"
spec 2 $'**PM spec:** #2\n\n**Files likely to change:**\n- scripts/a.sh (the walk)\n- docs/x.md\n\n**Branch name:** x'
state "2,3" "1"
walk 4 "1"
assert_eq "action=dispatch stage=validator issue=3" "$OUT" "AC4 a files list in the PM spec marks #2 as overlapping"
if grep -q '^view-issue 2 --spec' "$STUB_DIR/calls.log"; then pass "AC4 the spec is read with view-issue --spec"; else fail "AC4 the spec is read with view-issue --spec"; fi

# ── AC5: a generated file is never an overlap ─────────────────────────────────
for _g in internal/db/x/querier.go api/openapi.yaml web/schema.ts authz/generated_x.go; do
  reset
  issue 1 "pipeline:dev" "$(files "$_g")"
  issue 2 "pipeline:ready" "$(files "$_g")"
  issue 3 "pipeline:ready" "$(files scripts/b.sh)"
  state "2,3" "1"
  walk 4 "1"
  assert_eq "action=dispatch stage=validator issue=2" "$OUT" "AC5 a shared $_g does not overlap, the queue order stays"
done

# ── AC6: two migrations overlap whatever their names ──────────────────────────
reset
issue 1 "pipeline:dev" "$(files db/migrations/0042_a.sql)"
issue 2 "pipeline:ready" "$(files db/migrations/0043_b.sql)"
issue 3 "pipeline:ready" "$(files scripts/b.sh)"
state "2,3" "1"
walk 4 "1"
assert_eq "action=dispatch stage=validator issue=3" "$OUT" "AC6 an issue adding a migration waits behind a disjoint one"

# ── AC7: priority stays the first key ─────────────────────────────────────────
reset
issue 1 "pipeline:dev" "$(files scripts/a.sh)"
issue 2 "pipeline:ready,p0" "$(files scripts/a.sh)"
issue 3 "pipeline:ready,p2" "$(files scripts/b.sh)"
state "2,3" "1" '{"2": 0, "3": 2}'
walk 4 "1"
assert_eq "action=dispatch stage=validator issue=2" "$OUT" "AC7 a better priority is dispatched before a non-overlapping worse one"
reset
issue 2 "pipeline:ready" "$(files scripts/a.sh)"
issue 3 "pipeline:ready" "$(files scripts/b.sh)"
state "2,3" "-"
walk 4 "-"
assert_eq "action=dispatch stage=validator issue=2" "$OUT" "AC7 with nothing in flight the queue order is untouched"
if grep -q -- '--spec' "$STUB_DIR/calls.log"; then fail "AC7 no overlap read with nothing in flight"; else pass "AC7 no overlap read with nothing in flight"; fi

finish
