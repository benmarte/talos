#!/usr/bin/env bash
# test-revise-body-spec.sh -- `revise-spec` on an issue-body spec, and the driver's
# stop when it cannot apply a red-check finding (#954). Each assertion label
# starts with its AC id.
#   AC1-AC3   `revise-spec` on a stub view-issue (real pipeline-criteria.sh)
#   AC4       `talos.sh run` on stubs: a failed revise-spec is spec-unusable
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

CRIT_REAL="$TALOS_ROOT/scripts/pipeline-criteria.sh"

# ── AC1-AC3 revise-spec: a scripts dir whose view-issue answers from files ────
RS="$SANDBOX/rs"
mkdir -p "$RS"
cp "$TALOS_ROOT"/scripts/* "$RS/"
cat > "$RS/pipeline-vcs.sh" <<'TALOS_Rv4nQ7sXk2Dj'
#!/usr/bin/env bash
case "$1" in
  view-issue)
    python3 -I -c 'import json, os, sys
c = []
if os.path.exists(sys.argv[2]):
    c = [{"body": open(sys.argv[2]).read()}]
print(json.dumps({"title": "t", "body": open(sys.argv[1]).read(), "labels": [], "comments": c}))' "$RS_BODY" "$RS_COMMENT" ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_Rv4nQ7sXk2Dj
export RS_BODY="$SANDBOX/rs-body.md" RS_COMMENT="$SANDBOX/rs-comment.md"
revise() {  # $1 = the findings, fed on stdin; the spec files are set by the caller
  OUT="$(printf '%s\n' "$1" | bash "$RS/pipeline-criteria.sh" revise-spec 7 2>"$SANDBOX/rs.err")"; RC=$?
  ERRTXT="$(cat "$SANDBOX/rs.err")"
}
MARK='(same: green at the red commit, found by red-check)'
LEAD1='**PM spec:** revised by the driver after red-check: AC2 is (same) (green at the red commit)'

# AC1 a body spec with no AC ids: the 2nd unmarked line is flipped by inserting the marker.
rm -f "$RS_COMMENT"
printf '%s\n' 'Intro text' '' '- [ ] first thing works' '- [ ] second thing works' '- [ ] third thing works' '' '**Tests:** tests/test-x.sh' > "$RS_BODY"
revise 'kind-mismatch AC2 want=same'
assert_eq "0" "$RC" "AC1 a positional kind-mismatch on a body spec exits 0"
assert_eq "$(printf '%s\n' "$LEAD1" '' 'Intro text' '' '- [ ] first thing works' "- [ ] $MARK second thing works" '- [ ] third thing works' '' '**Tests:** tests/test-x.sh')" "$OUT" \
  "AC1 only the 2nd checklist line changes, by the inserted (same: ...) marker; every other byte is unchanged"

# AC2 an explicit (test) marker on a positional criterion is flipped as well.
printf '%s\n' '- [ ] first thing works' '- [ ] second thing works (test)' '- [ ] third thing works' > "$RS_BODY"
revise 'kind-mismatch AC2 want=same'
assert_eq "0" "$RC" "AC2 a positional criterion with a (test) marker exits 0"
assert_eq "$(printf '%s\n' "$LEAD1" '' '- [ ] first thing works' "- [ ] second thing works $MARK" '- [ ] third thing works')" "$OUT" \
  "AC2 the explicit (test) marker is replaced by the (same: ...) marker, other lines unchanged"

# AC2 a positional (same) line flips back to (test).
printf '%s\n' '- [ ] first thing works' '- [ ] second thing works (same: refactor)' > "$RS_BODY"
revise 'kind-mismatch AC2 want=test'
assert_contains "$OUT" '- [ ] second thing works (test)' "AC2 a positional (same: ...) marker flips to (test)"

# AC2 a positional criterion past the end of the checklist is not flippable.
printf '%s\n' '- [ ] first thing works' > "$RS_BODY"
revise 'kind-mismatch AC2 want=same'
assert_eq "1" "$RC" "AC2 a positional id beyond the checklist exits 1"
assert_contains "$ERRTXT" "revise-spec: not a flippable criterion line: AC2" "AC2 the refusal names the id"

# AC1 a **PM spec:** comment supersedes the body: the comment is what is revised.
printf '%s\n' '- [ ] body one' '- [ ] body two' > "$RS_BODY"
printf '%s\n' '**PM spec:** posted' '' '- [ ] comment one' '- [ ] comment two' > "$RS_COMMENT"
revise 'kind-mismatch AC2 want=same'
assert_contains "$OUT" "- [ ] $MARK comment two" "AC1 a comment spec takes precedence over the body for revise-spec"
rm -f "$RS_COMMENT"

# AC3 explicit AC ids: the output is what it was before (id match, final marker replaced in place).
printf '%s\n' '**PM spec:** greeting' '' '**Acceptance criteria**' '- [ ] AC1 greet prints hello (test)' '- [ ] AC2 greet keeps its flag (same: refactor)' '- [ ] AC3 greet is documented (test)' '' '**Tests:** `tests/test-greet.sh`' > "$RS_BODY"
revise 'kind-mismatch AC1 want=same
kind-mismatch AC2 want=test'
assert_eq "$(printf '%s\n' '**PM spec:** revised by the driver after red-check: AC1 is (same) (green at the red commit), AC2 is (test) (red at the red commit)' '' greeting '' '**Acceptance criteria**' "- [ ] AC1 greet prints hello $MARK" '- [ ] AC2 greet keeps its flag (test)' '- [ ] AC3 greet is documented (test)' '' '**Tests:** `tests/test-greet.sh`')" "$OUT" \
  "AC3 a PM spec with AC<n> ids is revised exactly as before"
# AC3 with explicit ids, an unmarked line is not flippable (no positional fallback).
printf '%s\n' '- [ ] AC1 first (test)' '- [ ] AC2 second' > "$RS_BODY"
revise 'kind-mismatch AC2 want=same'
assert_eq "1" "$RC" "AC3 an AC-id spec's unmarked line is still not flippable"

# ── AC4 the driver on stubs ───────────────────────────────────────────────────
cd "$SANDBOX" || exit 1
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
ERR="$SANDBOX/stderr"
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR" "$SANDBOX/templates"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cp -R "$TALOS_ROOT/templates/prompts" "$SANDBOX/templates/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="$1"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
if [ -f "$d/hook.$key" ]; then . "$d/hook.$key"; fi
if [ "$key" = "list-prs" ] || [ "$key" = "list-needs-owner" ] || [ "$key" = "list-issues" ]; then printf "[]"; exit 0; fi
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ] && [ -f "$a" ]; then cat "$a" > "$d/body"; fi
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
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-events.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
cat > "$GS/pipeline-agent.sh" <<'TALOS_Kd9wP4sTn6Ua'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
role="$1"
cat > "$d/agent.stdin"
printf "agent %s\n" "$role" >> "$d/journal"
cnt="$(grep -c "^agent $role\$" "$d/journal")"
if [ -f "$d/message.$role.$cnt" ]; then cat "$d/message.$role.$cnt"; fi
if [ -f "$d/hook.$role.$cnt" ]; then . "$d/hook.$role.$cnt"; fi
exit 0
TALOS_Kd9wP4sTn6Ua
cat > "$GS/pipeline-status-file.sh" <<'TALOS_Ye2cM8vJq5Rb'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
printf 'status-file collect\n' >> "$d/journal"
printf '%s' "$(cat "$d/collect.json" 2>/dev/null || echo '{}')"
TALOS_Ye2cM8vJq5Rb
# red-check is the stub's to answer; every other verb (revise-spec, spec-usable) is the real script.
cp "$CRIT_REAL" "$GS/pipeline-criteria-real.sh"
cat > "$GS/pipeline-criteria.sh" <<'TALOS_Gx6hB3nUf1Wz'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
printf "criteria %s\n" "$*" >> "$d/journal"
if [ "$1" = red-check ]; then
  [ ! -f "$d/red-check.out" ] || cat "$d/red-check.out"
  exit "$(cat "$d/red-check.rc" 2>/dev/null || echo 0)"
fi
exec bash "$(dirname "$0")/pipeline-criteria-real.sh" "$@"
TALOS_Gx6hB3nUf1Wz

RUN="$GS/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
LEASE="$SANDBOX/.git/talos-lease.ledger"
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
set_stub() { printf '%s\n' "$2" > "$STUB_DIR/$1.rc"; printf '%s' "${3:-}" > "$STUB_DIR/$1.out"; printf '%s' "${4:-}" > "$STUB_DIR/$1.err"; }
# first_round BODY: a first-round developer (no PR yet) opens PR 12 for issue 9, whose
# spec is the issue BODY (no PM stage); the next pass finds the PR at the reviewer stage.
first_round() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$LEASE" "${LEASE:?}.lock.d"
  printf '%s' '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"reviewer": true}, "pr": {"draft": false}, "comments": {"enabled": false}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
    > "$SANDBOX/talos.pipeline.json"
  set_stub events.cost.line 0 "spend: 12 tokens"
  printf '%s' "$1" > "$SANDBOX/spec.md"
  python3 -I -c 'import json, sys
print(json.dumps({"number": 9, "title": "t", "body": open(sys.argv[1]).read(), "labels": [{"name": "pipeline:dev"}], "state": "open", "comments": []}))' "$SANDBOX/spec.md" > "$STUB_DIR/view-issue.9"
  printf '{"prs":[],"pr_total":0,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.json"
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"reviewer"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.dev"
  # The developer's done moves the issue off pipeline:dev; the PR is then at reviewer.
  python3 -I -c 'import json, sys
print(json.dumps({"number": 9, "title": "t", "body": open(sys.argv[1]).read(), "labels": [], "state": "open", "comments": []}))' "$SANDBOX/spec.md" > "$STUB_DIR/view-issue.9.after"
  printf 'cp "$d/collect.dev" "$d/collect.json"; cp "$d/view-issue.9.after" "$d/view-issue.9"\n' > "$STUB_DIR/hook.developer.1"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  printf 'https://github.com/acme/widget/pull/12\nopened\n' > "$STUB_DIR/message.developer.1"
  printf 'APPROVED: fine\n' > "$STUB_DIR/message.reviewer.1"
}
drv() { OUT="$(TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 bash "$RUN" run --issue 9 --max-iterations "${1:-2}" 2>"$ERR")"; RC=$?; }
BODY_SPEC='- [ ] first
- [ ] second

**Tests:** tests/test-x.sh
'

# AC4 a finding revise-spec cannot apply (AC9 is no criterion of the spec): block and stop.
first_round "$BODY_SPEC"
printf 'kind-mismatch AC9 want=same\nred-check: MISMATCH 1\n' > "$STUB_DIR/red-check.out"
printf 1 > "$STUB_DIR/red-check.rc"
drv
assert_eq "stop reason=spec-unusable detail=revise-failed issue=9 pr=12" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC4 a failed revise-spec ends the run as spec-unusable detail=revise-failed"
assert_eq "0" "$RC" "AC4 the stop exits 0"
assert_eq "0" "$(printf '%s\n' "$OUT" | grep -c 'state-unavailable')" "AC4 a failed revise-spec is not state-unavailable"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "AC4 the issue is blocked"
assert_contains "$(journal)" "vcs label-pr 12 --add pipeline:blocked" "AC4 the PR is blocked"
assert_contains "$(cat "$ERR")" "revise-spec: not a flippable criterion line: AC9" "AC4 the revise-spec line is relayed"
assert_file_absent "$STUB_DIR/body" "AC4 nothing is posted"
assert_eq "0" "$(journal | grep -c '^agent reviewer$')" "AC4 reviewer is not dispatched"

# AC4 control: a spec that cannot be read stays state-unavailable.
first_round "$BODY_SPEC"
printf 'not json' > "$STUB_DIR/view-issue.9"
printf 'kind-mismatch AC1 want=same\nred-check: MISMATCH 1\n' > "$STUB_DIR/red-check.out"
printf 1 > "$STUB_DIR/red-check.rc"
drv
assert_contains "$(printf '%s\n' "$OUT" | grep '^stop ')" "stop reason=state-unavailable" "AC4 control: an unreadable spec is still state-unavailable"

# AC1 the driver posts the revised body spec as a **PM spec:** comment and the run goes on.
first_round "$BODY_SPEC"
printf 'kind-mismatch AC2 want=same\nred-check: MISMATCH 1\n' > "$STUB_DIR/red-check.out"
printf 1 > "$STUB_DIR/red-check.rc"
drv
BODY="$(cat "$STUB_DIR/body" 2>/dev/null)"
assert_eq "**PM spec:** revised by the driver after red-check: AC2 is (same) (green at the red commit)" "$(printf '%s\n' "$BODY" | sed -n 1p)" "AC1 the driver posts a revised body spec as a **PM spec:** comment"
assert_contains "$BODY" "- [ ] (same: green at the red commit, found by red-check) second" "AC1 the posted spec carries the inserted marker"
assert_eq "1" "$(journal | grep -c '^agent reviewer$')" "AC1 the run continues to reviewer"

finish
