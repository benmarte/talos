#!/usr/bin/env bash
# test-red-check-747.sh -- `pipeline-criteria.sh red-check` and its driver hook (#747).
# A criterion's kind is checked against its state at the red commit before the
# review stages run. Each assertion label starts with its AC id.
#   AC1-AC7   the verb on fixture git branches (real scripts, stub view-issue)
#   AC8-AC11  `talos.sh run` on stubs: when red-check runs, the revised spec, the stop
#   AC12      qa-run still reports a (test) green at red as vacuous
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
# appending to $RAN each time it runs.
tf() {
  local p="$1" a id st
  shift
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo ran >> "%s"\n' "$RAN"
    for a in "$@"; do
      id="${a%%:*}"; st="${a#*:}"
      if [ "$st" = ok ]; then printf 'printf "  ok  %s label\\n"\n' "$id"
      elif [ "$st" = fail ]; then printf 'printf "FAIL  %s label\\n"\n' "$id"; fi
    done
  } > "$p"
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
while [ $# -gt 0 ]; do
  case "$1" in --for) bash "$2"; shift 2 ;; *) shift ;; esac
done
TALOS_Vh3tQ8mWc2Ke
  cat > scripts/pipeline-vcs.sh <<'TALOS_Nb5yR1dXf7Lp'
#!/usr/bin/env bash
case "$1" in
  view-issue)
    python3 -I -c 'import json, sys
print(json.dumps({"title": "t", "body": "issue body", "labels": [],
                  "comments": [{"body": open(sys.argv[1]).read()}]}))' "$QA_SPEC_FILE" ;;
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
S2='- [ ] AC2 greet keeps its flag (same: refactor)'
TL='**Tests:** `tests/test-greet.sh`'

# ── AC1 clean: (test) red at red, (same) green at red ─────────────────────────
new_repo
tf tests/test-greet.sh AC1:fail AC2:ok; red_commit; feature_commit
spec "$T1" "$S2" '' "$TL"
rc_run 7
assert_eq "red-check: ok" "$OUT" "AC1 a (test) red and a (same) green at the red commit print red-check: ok"
assert_eq "0" "$RC" "AC1 a clean branch exits 0"

# ── AC2 a (test) criterion green at red ───────────────────────────────────────
new_repo
tf tests/test-greet.sh AC1:ok AC2:ok; red_commit; feature_commit
spec "$T1" "$S2" '' "$TL"
rc_run 7
assert_eq "kind-mismatch AC1 want=same
red-check: MISMATCH 1" "$OUT" "AC2 a (test) green at the red commit prints kind-mismatch want=same and MISMATCH 1"
assert_eq "1" "$RC" "AC2 a kind-mismatch exits 1"

# ── AC3 a (same) criterion red at red ─────────────────────────────────────────
new_repo
tf tests/test-greet.sh AC1:fail AC2:fail; red_commit; feature_commit
spec "$T1" "$S2" '' "$TL"
rc_run 7
assert_eq "kind-mismatch AC2 want=test
red-check: MISMATCH 1" "$OUT" "AC3 a (same) red at the red commit prints kind-mismatch want=test"
assert_eq "1" "$RC" "AC3 a kind-mismatch exits 1"

# ── AC4 a Tests: file that already labels the id at the merge-base ────────────
shared_base() { tf tests/test-greet.sh AC1:ok; }
new_repo shared_base
tf tests/test-greet.sh AC1:fail; red_commit; feature_commit
spec "$T1" '' "$TL"
rc_run 7
assert_eq "id-collision AC1 file=tests/test-greet.sh
red-check: COLLISION 1" "$OUT" "AC4 a Tests: file labelling the id at the merge-base prints id-collision and COLLISION 1"
assert_eq "4" "$RC" "AC4 an id-collision exits 4"

# ── AC5 the same id in two Tests: files; collision wins over a mismatch ───────
new_repo
tf tests/test-a.sh AC1:fail AC2:ok; tf tests/test-b.sh AC1:fail; red_commit; feature_commit
spec "$T1" '- [ ] AC2 greet keeps its flag (test)' '' '**Tests:** `tests/test-a.sh` `tests/test-b.sh`'
rc_run 7
assert_contains "$OUT" "id-collision AC1 file=tests/test-a.sh" "AC5 the id in two Tests: files prints id-collision for the first file"
assert_contains "$OUT" "id-collision AC1 file=tests/test-b.sh" "AC5 the id in two Tests: files prints id-collision for the second file"
assert_contains "$OUT" "kind-mismatch AC2 want=same" "AC5 a kind-mismatch beside a collision is still printed"
assert_contains "$OUT" "red-check: COLLISION 2" "AC5 the verdict counts the collisions"
assert_eq "4" "$RC" "AC5 a collision beside a kind-mismatch exits 4"

# ── AC6 no finding, or skipped without a run ──────────────────────────────────
new_repo
tf tests/test-greet.sh; red_commit; feature_commit
spec "$T1" '' "$TL"
rc_run 7
assert_eq "red-check: ok" "$OUT" "AC6 a missing state at the red commit is no finding"
assert_eq "0" "$RC" "AC6 a missing state exits 0"

new_repo
tf tests/test-greet.sh AC1:ok; printf 'x\n' > impl.txt; red_commit; feature_commit
spec "$T1" '' "$TL"
rc_run 7
assert_contains "$OUT" "red-check: skipped" "AC6 a red commit that is not tests-only is skipped"
assert_eq "0" "$RC" "AC6 a skipped run exits 0"
assert_file_absent "$RAN" "AC6 a skipped run (red commit not tests-only) runs no test"

new_repo
tf tests/test-greet.sh AC1:ok; red_commit; feature_commit
spec "$T1" '' "$TL"
rc_run 7 main
assert_contains "$OUT" "red-check: skipped" "AC6 a ref with no commit after the merge-base has no red commit: skipped"
assert_eq "0" "$RC" "AC6 no red commit exits 0"
assert_file_absent "$RAN" "AC6 no red commit runs no test"

new_repo
tf tests/test-greet.sh AC1:ok; red_commit; feature_commit
spec '- [ ] AC1 the README names it (prose: wording)'
rc_run 7
assert_contains "$OUT" "red-check: skipped" "AC6 a prose-only spec with no Tests: line is skipped"
assert_eq "0" "$RC" "AC6 a prose-only spec exits 0"
assert_file_absent "$RAN" "AC6 a prose-only spec runs no test"

# ── AC7 usable, usage, and the caller's checkout left alone ───────────────────
new_repo
tf tests/test-greet.sh AC1:ok; red_commit; feature_commit
spec "$T1"
rc_run 7
assert_eq "red-check: BLOCKED spec: 1 test criteria and no Tests: line" "$OUT" "AC7 an unusable spec prints red-check: BLOCKED spec: <why>"
assert_eq "4" "$RC" "AC7 an unusable spec exits 4"
rc_run abc
assert_eq "2" "$RC" "AC7 a non-numeric issue is usage, exit 2"
rc_run
assert_eq "2" "$RC" "AC7 no issue is usage, exit 2"

new_repo
tf tests/test-greet.sh AC1:ok; red_commit; feature_commit
git checkout -q main
spec "$T1" '' "$TL"
state() { printf '%s|%s|%s|%s\n' "$(git rev-parse HEAD)" "$(git symbolic-ref -q HEAD)" "$(git status --porcelain --untracked-files=no)" "$(git worktree list | wc -l | tr -d ' ')"; }
before="$(state)"
rc_run 7 feat/issue-7-greet
after="$(state)"
assert_eq "kind-mismatch AC1 want=same
red-check: MISMATCH 1" "$OUT" "AC7 <ref> selects the branch whose red commit is checked, from another checkout"
assert_eq "$before" "$after" "AC7 the caller's HEAD, branch, tracked files and worktree list are the same after the run"

# ── AC8-AC11 the driver on stubs ──────────────────────────────────────────────
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
# Issue 9's PM spec: AC1 test, AC2 same, AC3 prose.
SPEC_BODY='**PM spec:** greeting

**Acceptance criteria:**
- [ ] AC1 `greet` prints hello (test)
- [ ] AC2 `greet` keeps its flag (same: refactor)
- [ ] AC3 `greet` is documented (test)
- [ ] AC4 the README names it (prose: doc wording)

**Tests:** `tests/test-greet.sh`
'
# first_round [ISSUE-LABELS]: a first-round developer (no PR yet) opens PR 12;
# the next pass finds it at the reviewer stage.
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
# line_of PATTERN: the 1-based journal line of the first match, else 0.
line_of() { journal | grep -n -m 1 -e "$1" | cut -d: -f1 | grep . || echo 0; }

first_round
drv
assert_eq "1" "$(journal | grep -c '^criteria red-check 9 ')" "AC8 red-check runs once after the first-round developer opens the PR"
RCL="$(line_of '^criteria red-check 9 ')"; DEVL="$(line_of '^agent developer$')"; REVL="$(line_of '^agent reviewer$')"
assert_eq "yes" "$([ "$DEVL" -gt 0 ] && [ "$RCL" -gt "$DEVL" ] && [ "$REVL" -gt "$RCL" ] && echo yes || echo "no dev=$DEVL rc=$RCL rev=$REVL")" "AC8 the journal order is developer, red-check, reviewer"
assert_contains "$(journal)" "criteria red-check 9 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "AC8 red-check is given the PR head"
assert_file_absent "$STUB_DIR/body" "AC8 a clean result posts no comment"

# AC9 a kind-mismatch: the spec is revised by the driver and the run continues.
first_round
printf 'kind-mismatch AC1 want=same\nkind-mismatch AC2 want=test\nred-check: MISMATCH 2\n' > "$STUB_DIR/red-check.out"
printf 1 > "$STUB_DIR/red-check.rc"
drv
BODY="$(cat "$STUB_DIR/body" 2>/dev/null)"
assert_eq "**PM spec:** revised by the driver after red-check: AC1 is (same) (green at the red commit), AC2 is (test) (red at the red commit)" "$(printf '%s\n' "$BODY" | sed -n 1p)" "AC9 the revised spec's first line says the driver revised it and names the ids"
EXPECT="$(printf '%s' "$SPEC_BODY" | sed -e '1s/^\*\*PM spec:\*\* /\*\*PM spec:\*\* revised by the driver after red-check: AC1 is (same) (green at the red commit), AC2 is (test) (red at the red commit)\
\
/' -e 's/^\(- \[ \] AC1 .*\)(test)$/\1(same: green at the red commit, found by red-check)/' -e 's/^\(- \[ \] AC2 .*\)(same: refactor)$/\1(test)/')"
assert_eq "$EXPECT" "$BODY" "AC9 only the listed ids' final markers change; every other line is byte-identical"
assert_contains "$(journal)" "criteria spec-usable 9" "AC9 spec-usable is asked again after the post"
assert_eq "1" "$(journal | grep -c '^agent reviewer$')" "AC9 the run continues to reviewer"

# AC10 an id-collision blocks and stops before reviewer.
first_round
printf 'id-collision AC1 file=tests/test-greet.sh\nred-check: COLLISION 1\n' > "$STUB_DIR/red-check.out"
printf 4 > "$STUB_DIR/red-check.rc"
drv
assert_eq "stop reason=spec-unusable detail=id-collision issue=9 pr=12" "$(printf '%s\n' "$OUT" | grep '^stop ')" "AC10 an id-collision ends the run as spec-unusable detail=id-collision"
assert_eq "0" "$RC" "AC10 the stop exits 0"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "AC10 the issue is blocked"
assert_contains "$(journal)" "vcs label-pr 12 --add pipeline:blocked" "AC10 the PR is blocked"
assert_eq "0" "$(journal | grep -c '^agent reviewer$')" "AC10 reviewer is not dispatched"

# AC11 a developer fix round (a QA FAIL on an open PR) does not call red-check.
first_round
printf '%s' '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"qa": true}, "pr": {"draft": false}, "comments": {"enabled": false}, "verify": {"timeout_ms": 600000, "ci_wait_s": 900}}' > "$SANDBOX/talos.pipeline.json"
cp "$STUB_DIR/view-issue.9.after" "$STUB_DIR/view-issue.9"
printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"qa"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.json"
printf 'FAIL: AC1 broke\n' > "$STUB_DIR/message.qa.1"
printf 'https://github.com/acme/widget/pull/12\nfixed\n' > "$STUB_DIR/message.developer.1"
printf 'printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$d/pr-head.12"\n' > "$STUB_DIR/hook.developer.1"
OUT="$(TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 bash "$RUN" run --max-iterations 2 2>"$ERR")"; RC=$?
assert_eq "1" "$(journal | grep -c '^agent developer$')" "AC11 control: the fix-round developer ran"
assert_eq "0" "$(journal | grep -c '^criteria red-check')" "AC11 a developer fix round does not call red-check"

# ── AC12 qa-run is unchanged ──────────────────────────────────────────────────
new_repo
tf tests/test-greet.sh AC1:ok; red_commit; feature_commit
RED8="$(git rev-parse HEAD~1 | cut -c1-8)"
spec "$T1" '' "$TL"
cat > scripts/pipeline-vcs.sh <<'TALOS_Lw4jN7aXb8dT'
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
TALOS_Lw4jN7aXb8dT
git add -A; git commit -q -m "stub vcs"
OUT="$(bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"; RC=$?
assert_contains "$OUT" "AC1 FAIL vacuous (green at red@$RED8)" "AC12 qa-run prints AC<n> FAIL vacuous (green at red@<sha8>) for a (test) green at red"
assert_contains "$OUT" "qa-run: verdict FAIL 1 test criteria FAIL" "AC12 qa-run keeps its verdict line"
assert_eq "1" "$RC" "AC12 qa-run keeps exit 1"

finish
