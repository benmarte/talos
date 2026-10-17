#!/usr/bin/env bash
# test-red-check-drop-773.sh -- red-check drops a pre-existing, id-colliding Tests
# file instead of stopping (#773). Each assertion label starts with its AC id.
#   AC1-AC6   `red-check` on fixture git branches (real scripts, stub view-issue)
#   AC7-AC8   `revise-spec` on the stub spec
#   AC9-AC10  `qa-run` and the **Regression:** line
#   AC11      `talos.sh run` on stubs
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

REPO="$SANDBOX/repo"
RAN="$SANDBOX/ran.log"
export QA_SPEC_FILE="$SANDBOX/qa-spec.md"
CRIT_REAL="$TALOS_ROOT/scripts/pipeline-criteria.sh"

# ── fixture: a repo whose branch holds a red commit then a feature commit ─────
# tf PATH ID:state...  -- a test file printing one label per id (ok|fail), and
# appending its own path to $RAN each time it runs.
tf() {
  local p="$1" a id st
  shift
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "%s" >> "%s"\n' "$p" "$RAN"
    for a in "$@"; do
      id="${a%%:*}"; st="${a#*:}"
      if [ "$st" = ok ]; then printf 'printf "  ok  %s label\\n"\n' "$id"
      elif [ "$st" = fail ]; then printf 'printf "FAIL  %s label\\n"\n' "$id"; fi
    done
  } > "$p"
}
# tfeat PATH ID -- red until feature.txt exists, so one file is red then green.
tfeat() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "%s" >> "%s"\n' "$1" "$RAN"
    printf 'if [ -f feature.txt ]; then echo "  ok  %s label"; else echo "FAIL  %s label"; fi\n' "$2" "$2"
  } > "$1"
}
new_repo() {  # $1 = optional function that adds files before the base commit
  rm -rf "${REPO:?}" "$RAN"; mkdir -p "$REPO/scripts" "$REPO/tests"
  cd "$REPO" || exit 1
  git init -q -b main
  git remote add origin git@github.com:acme/widget.git
  git config user.email t@t.invalid
  git config user.name t
  cp "$TALOS_ROOT"/scripts/* scripts/
  cat > tests/run-tests.sh <<'TALOS_Vh3tQ8mWc2Ke'
#!/usr/bin/env bash
rc=0
while [ $# -gt 0 ]; do
  case "$1" in --for) bash "$2" || rc=1; shift 2 ;; *) shift ;; esac
done
exit "$rc"
TALOS_Vh3tQ8mWc2Ke
  cat > scripts/pipeline-vcs.sh <<'TALOS_Nb5yR1dXf7Lp'
#!/usr/bin/env bash
case "$1" in
  view-issue)
    python3 -I -c 'import json, sys
print(json.dumps({"title": "t", "body": "issue body", "labels": [],
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$QA_SPEC_FILE" ;;
  pr-mergeable) echo MERGEABLE ;;
  checkout-pr) : ;;
  *) echo "stub pipeline-vcs: unexpected verb: $*" >&2; exit 99 ;;
esac
TALOS_Nb5yR1dXf7Lp
  printf 'base\n' > README.md
  [ -z "${1:-}" ] || "$1"
  git add -A
  git commit -q -m base
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b feat/issue-7-greet
}
red_commit() { git add -A; git commit -q -m "test(#7): red first"; }
feature_commit() { printf 'done\n' > feature.txt; git add -A; git commit -q -m "feat(#7): greet"; }
spec() {  # $@ = the checklist lines and any Tests: line
  printf '**PM spec:** greeting\n\n**Acceptance criteria**\n' > "$QA_SPEC_FILE"
  printf '%s\n' "$@" >> "$QA_SPEC_FILE"
}
rc_run() { OUT="$(bash scripts/pipeline-criteria.sh red-check "$@" 2>/dev/null)"; RC=$?; }
T1='- [ ] AC1 greet prints hello (test)'
T2='- [ ] AC2 greet takes a name (test)'
T3='- [ ] AC3 greet keeps its flag (test)'
TL='**Tests:** `tests/test-old.sh` `tests/test-new.sh`'
OLD='tests/test-old.sh'
NEW='tests/test-new.sh'
# An earlier issue's file: it already labels AC1 and AC3 on the base branch.
base_old() { tf "$OLD" AC1:ok AC3:ok; }

# ── AC1 a base-branch Tests file and a new one both label AC1 ─────────────────
new_repo base_old
tf "$NEW" AC1:fail AC2:fail; red_commit; feature_commit
spec "$T1" "$T2" '' "$TL"
rc_run 7
assert_eq "drop-file $OLD reason=id-collision-with-$NEW
red-check: REVISE 1" "$OUT" "AC1 the pre-existing file is dropped: drop-file and red-check: REVISE 1, no id-collision"
assert_eq "1" "$RC" "AC1 a droppable collision exits 1"

# ── AC2 the dropped file does not run; a kind-mismatch is still printed ───────
new_repo base_old
tf "$NEW" AC1:fail AC2:ok; red_commit; feature_commit
spec "$T1" "$T2" '' "$TL"
rc_run 7
assert_contains "$OUT" "drop-file $OLD reason=id-collision-with-$NEW" "AC2 the drop-file line is printed beside a kind-mismatch"
assert_contains "$OUT" "kind-mismatch AC2 want=same" "AC2 a kind-mismatch on the kept file is still printed"
assert_contains "$OUT" "red-check: REVISE 2" "AC2 the verdict counts the kind-mismatch and the drop-file lines"
assert_eq "$NEW" "$(sort -u "$RAN" 2>/dev/null)" "AC2 only the kept file runs in the red run; the dropped file does not"

# ── AC3 a (test) criterion labelled only in the dropped file ──────────────────
new_repo base_old
tf "$NEW" AC1:fail AC2:fail; red_commit; feature_commit
spec "$T1" "$T2" "$T3" '' "$TL"
rc_run 7
assert_contains "$OUT" "to-prose AC3 file=$OLD" "AC3 a (test) labelled at the red commit only in the dropped file prints to-prose"
assert_not_contains "$OUT" "to-prose AC1" "AC3 an id the kept file also labels is no to-prose"
assert_contains "$OUT" "red-check: REVISE 2" "AC3 the verdict counts the drop-file and to-prose lines"

# ── AC4 both Tests files exist on the base: still a collision ─────────────────
both_base() { tf tests/test-a.sh AC1:ok; tf tests/test-b.sh AC1:ok; }
new_repo both_base
tf tests/test-a.sh AC1:fail AC2:ok; tf tests/test-b.sh AC1:fail; red_commit; feature_commit
spec "$T1" '' '**Tests:** `tests/test-a.sh` `tests/test-b.sh`'
rc_run 7
assert_contains "$OUT" "id-collision AC1 file=tests/test-a.sh" "AC4 two base-branch files labelling the id print id-collision for the first"
assert_contains "$OUT" "id-collision AC1 file=tests/test-b.sh" "AC4 two base-branch files labelling the id print id-collision for the second"
assert_contains "$OUT" "red-check: COLLISION 2" "AC4 the verdict is COLLISION"
assert_not_contains "$OUT" "drop-file" "AC4 no file is dropped"
assert_eq "4" "$RC" "AC4 the human-needed case exits 4"

# ── AC5 both Tests files are new on the branch: still a collision ─────────────
new_repo
tf tests/test-a.sh AC1:fail; tf tests/test-b.sh AC1:fail; red_commit; feature_commit
spec "$T1" '' '**Tests:** `tests/test-a.sh` `tests/test-b.sh`'
rc_run 7
assert_contains "$OUT" "id-collision AC1 file=tests/test-a.sh" "AC5 two new files labelling the id print id-collision for the first"
assert_contains "$OUT" "id-collision AC1 file=tests/test-b.sh" "AC5 two new files labelling the id print id-collision for the second"
assert_contains "$OUT" "red-check: COLLISION 2" "AC5 the verdict is COLLISION"
assert_eq "4" "$RC" "AC5 the human-needed case exits 4"

# ── AC6 a droppable collision beside a non-droppable one ──────────────────────
# AC1: test-old.sh (base) and test-new.sh (new). AC2: test-x.sh alone, on the base.
mixed_base() { tf "$OLD" AC1:ok; tf tests/test-x.sh AC2:ok; }
new_repo mixed_base
tf "$NEW" AC1:fail; tf tests/test-x.sh AC2:fail; red_commit; feature_commit
spec "$T1" "$T2" '' '**Tests:** `tests/test-old.sh` `tests/test-x.sh` `tests/test-new.sh`'
rc_run 7
assert_contains "$OUT" "id-collision AC2 file=tests/test-x.sh" "AC6 the non-droppable collision is printed"
assert_contains "$OUT" "red-check: COLLISION 1" "AC6 the verdict is COLLISION"
assert_not_contains "$OUT" "drop-file" "AC6 no drop-file line is printed beside a collision a human must settle"
assert_eq "4" "$RC" "AC6 a droppable collision beside a non-droppable one exits 4"

# ── AC7 revise-spec: drop-file and to-prose ───────────────────────────────────
REV_IN="drop-file $OLD reason=id-collision-with-$NEW
to-prose AC3 file=$OLD"
new_repo
spec "$T1" "$T3" '' "$TL" '' 'trailer'
OUT="$(printf '%s\n' "$REV_IN" | bash scripts/pipeline-criteria.sh revise-spec 7 2>&1)"; RC=$?
assert_eq "0" "$RC" "AC7 revise-spec of a drop-file and a to-prose line exits 0"
assert_eq "$(printf '%s\n' greeting '' '**Acceptance criteria**' "$T1" '- [ ] AC3 greet keeps its flag (prose: tests/test-old.sh must pass at head)' '' '**Tests:** `tests/test-new.sh`' '**Regression:** `tests/test-old.sh`' '' 'trailer')" \
  "$(printf '%s\n' "$OUT" | sed -n '3,999p')" "AC7 the file moves from the Tests: line to a **Regression:** line and the marker becomes (prose: <file> must pass at head)"
assert_contains "$(printf '%s\n' "$OUT" | sed -n 1p)" "$OLD" "AC7 the lead note names the dropped file"
assert_contains "$(printf '%s\n' "$OUT" | sed -n 1p)" "shares an id with a file the branch adds" "AC7 the lead note says why"
assert_eq "**PM spec:** revised" "$(printf '%s\n' "$OUT" | sed -n 1p | cut -c1-20)" "AC7 the lead note follows **PM spec:**"

# the file in a bullet list: its bullet goes, the Regression line follows the list
spec "$T1" "$T3" '' '**Tests:**' "- \`$OLD\`" "- \`$NEW\`" '' 'trailer'
OUT="$(printf '%s\n' "$REV_IN" | bash scripts/pipeline-criteria.sh revise-spec 7 2>&1)"; RC=$?
assert_eq "$(printf '%s\n' greeting '' '**Acceptance criteria**' "$T1" '- [ ] AC3 greet keeps its flag (prose: tests/test-old.sh must pass at head)' '' '**Tests:**' "- \`$NEW\`" '**Regression:** `tests/test-old.sh`' '' 'trailer')" \
  "$(printf '%s\n' "$OUT" | sed -n '3,999p')" "AC7 a dropped bullet is removed and the Regression line follows the list"

# ── AC8 revise-spec of kind-mismatch lines only is #747's output ──────────────
new_repo
spec "$T1" "$T3" '' "$TL"
OUT="$(printf 'kind-mismatch AC1 want=same\n' | bash scripts/pipeline-criteria.sh revise-spec 7 2>&1)"; RC=$?
assert_eq "$(printf '%s\n' '**PM spec:** revised by the driver after red-check: AC1 is (same) (green at the red commit)' '' greeting '' '**Acceptance criteria**' '- [ ] AC1 greet prints hello (same: green at the red commit, found by red-check)' "$T3" '' "$TL")" \
  "$OUT" "AC8 a kind-mismatch-only revise-spec prints the same spec as before"
assert_eq "0" "$RC" "AC8 a kind-mismatch-only revise-spec exits 0"

# ── AC9-AC10 qa-run and the **Regression:** line ──────────────────────────────
# tests/test-new.sh is red until feature.txt exists; tests/test-old.sh is the regression file.
RL='**Regression:** `tests/test-old.sh`'
reg_base() { tf "$OLD" AC3:ok; }
new_repo reg_base
tfeat "$NEW" AC1; red_commit
tf "$OLD" AC3:fail; printf 'exit 3\n' >> "$OLD"
feature_commit
spec "$T1" '' '**Tests:** `tests/test-new.sh`' "$RL"
OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?
assert_contains "$OUT" "qa-run: verdict FAIL regression run exited 1" "AC9 a failing **Regression:** file ends verdict FAIL with regression run exited <N>"
assert_contains "$OUT" "FAIL  AC3 label" "AC9 the FAIL lines of the regression output are shown"
assert_eq "1" "$RC" "AC9 a failing regression file exits 1"
assert_eq "1" "$(grep -c "^$OLD\$" "$RAN")" "AC9 the regression file runs once, whole, at the head"

new_repo reg_base
tfeat "$NEW" AC1; red_commit
tf "$OLD" AC2:ok AC3:ok
feature_commit
spec "$T1" "$T2" '' '**Tests:** `tests/test-new.sh`' "$RL"
OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?
assert_eq "1" "$(grep -c "^$OLD\$" "$RAN")" "AC10 the passing regression file runs once, whole, at the head"
assert_not_contains "$OUT" "regression run exited" "AC10 a passing **Regression:** file does not fail the gate"
assert_not_contains "$OUT" "AC2 red@" "AC10 a passing regression file whose output labels AC2 adds no red-to-green line for AC2"
assert_not_contains "$OUT" "AC2 green@head" "AC10 a passing regression file adds no green@head line for AC2"
assert_contains "$OUT" "AC2 FAIL" "AC10 AC2 is still a FAIL: only the Tests: files count toward a criterion"
assert_eq "1" "$RC" "AC10 the criterion with no evidence fails the gate"

new_repo reg_base
tfeat "$NEW" AC1; red_commit
tf "$OLD" AC1:ok AC3:ok
feature_commit
spec "$T1" '' '**Tests:** `tests/test-new.sh`' "$RL"
OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?
assert_contains "$OUT" "qa-run: verdict PASS" "AC10 a passing regression file leaves the verdict PASS"
assert_eq "0" "$RC" "AC10 a passing regression file exits 0"

# ── AC11 the driver on stubs ──────────────────────────────────────────────────
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
# red-check is the stub's to answer; every other verb is the real script.
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
# Issue 9's PM spec: AC1 and AC2 are tests; the older file is on the Tests: line.
SPEC_BODY='**PM spec:** greeting

**Acceptance criteria:**
- [ ] AC1 `greet` prints hello (test)
- [ ] AC2 `greet` keeps its flag (test)

**Tests:** `tests/test-old.sh` `tests/test-new.sh`
'
# first_round: a first-round developer (no PR yet) opens PR 12; the next pass
# finds it at the reviewer stage.
first_round() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$LEASE" "${LEASE:?}.lock.d"
  printf '%s' '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"reviewer": true}, "pr": {"draft": false}, "comments": {"enabled": false}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' \
    > "$SANDBOX/talos.pipeline.json"
  set_stub events.cost.line 0 "spend: 12 tokens"
  printf '%s' "$SPEC_BODY" > "$SANDBOX/spec.md"
  python3 -I -c 'import json, sys
print(json.dumps({"number": 9, "title": "t", "body": "- [ ] an item", "labels": [{"name": "pipeline:dev"}], "state": "open",
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$SANDBOX/spec.md" > "$STUB_DIR/view-issue.9"
  printf '{"prs":[],"pr_total":0,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.json"
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"reviewer"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.dev"
  # The developer's done moves the issue off pipeline:dev; the PR is then at reviewer.
  python3 -I -c 'import json, sys
print(json.dumps({"number": 9, "title": "t", "body": "- [ ] an item", "labels": [], "state": "open",
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$SANDBOX/spec.md" > "$STUB_DIR/view-issue.9.after"
  printf 'cp "$d/collect.dev" "$d/collect.json"; cp "$d/view-issue.9.after" "$d/view-issue.9"\n' > "$STUB_DIR/hook.developer.1"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  printf 'https://github.com/acme/widget/pull/12\nopened\n' > "$STUB_DIR/message.developer.1"
  printf 'APPROVED: fine\n' > "$STUB_DIR/message.reviewer.1"
}
drv() { OUT="$(TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 bash "$RUN" run --issue 9 --max-iterations "${1:-2}" 2>"$ERR")"; RC=$?; }

# AC11 REVISE: the revised spec is posted, spec-usable is asked again, the run goes on.
first_round
printf 'drop-file %s reason=id-collision-with-%s\nto-prose AC2 file=%s\nred-check: REVISE 2\n' "$OLD" "$NEW" "$OLD" > "$STUB_DIR/red-check.out"
printf 1 > "$STUB_DIR/red-check.rc"
drv
BODY="$(cat "$STUB_DIR/body" 2>/dev/null)"
assert_eq "**PM spec:** revised by the driver after red-check:" "$(printf '%s\n' "$BODY" | sed -n 1p | cut -c1-52)" "AC11 a red-check REVISE posts the revised spec"
assert_contains "$BODY" '**Regression:** `tests/test-old.sh`' "AC11 the posted spec carries the **Regression:** line"
assert_contains "$BODY" "AC2 \`greet\` keeps its flag (prose: $OLD must pass at head)" "AC11 the posted spec carries the to-prose marker"
assert_contains "$(journal)" "criteria revise-spec 9" "AC11 revise-spec runs on a REVISE verdict"
assert_contains "$(journal)" "criteria spec-usable 9" "AC11 spec-usable is asked again after the post"
assert_eq "1" "$(journal | grep -c '^agent reviewer$')" "AC11 the run still dispatches reviewer"
assert_eq "0" "$(printf '%s\n' "$OUT" | grep -c '^stop ')" "AC11 a REVISE verdict does not stop the run"

# AC11 COLLISION: still a stop before reviewer.
first_round
printf 'id-collision AC1 file=tests/test-a.sh\nid-collision AC1 file=tests/test-b.sh\nred-check: COLLISION 2\n' > "$STUB_DIR/red-check.out"
printf 4 > "$STUB_DIR/red-check.rc"
drv
assert_eq "stop reason=spec-unusable detail=id-collision issue=9 pr=12" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC11 an exit 4 COLLISION still ends the run as spec-unusable detail=id-collision"
assert_eq "0" "$(journal | grep -c '^agent reviewer$')" "AC11 reviewer is not dispatched after a COLLISION"

finish
