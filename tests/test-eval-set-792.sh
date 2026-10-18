#!/usr/bin/env bash
# test-eval-set-792.sh -- scripts/pipeline-eval.sh replays the reviewer, security
# or QA stage against stored cases and scores it (#792). Tests are named by the
# spec's criterion id (AC1 ...).
#   AC1  add: the case file, for a --bug and a --clean case
#   AC2  add: exit 2 and nothing written on a bad call
#   AC3  add: the spec snapshot is the newest **PM spec:** comment, else the issue body
#   AC4  list
#   AC5  run: the stage prompt, and no provider call
#   AC6  the matching rule and --tolerance
#   AC7  false alarms on clean cases only; only `- [Important] ...` lines count
#   AC8  the table, the score line and the saved run
#   AC9  --role, an unknown role, a failing stage run
#   AC10 --max-cases
#   AC11 compare
#   AC12 candidates
#   AC13 nothing else runs it
#   AC15 the new script passes the bash 3 lint
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
unset TALOS_ROLE TALOS_RUN_STARTED
git config user.email "test@talos.invalid"
git config user.name "talos-test"

# The script runs from a scripts dir of links to the real ones, except the two
# siblings it calls (the provider and the stage runner), which are stubs.
SD="$SANDBOX/scripts"; mkdir -p "$SD"
for f in "$TALOS_ROOT"/scripts/*; do ln -s "$f" "$SD/$(basename "$f")"; done
rm -f "$SD/pipeline-vcs.sh" "$SD/pipeline-agent.sh"
FIX="$SANDBOX/fix"; mkdir -p "$FIX/out"
export EVAL_FIX="$FIX" EVAL_VCS_LOG="$SANDBOX/vcs.log" EVAL_AGENT_LOG="$SANDBOX/agent.log" EVAL_PROMPTS="$SANDBOX/prompts"
mkdir -p "$EVAL_PROMPTS"
cat > "$SD/pipeline-vcs.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$EVAL_VCS_LOG"
case "$1" in
  diff-pr) cat "$EVAL_FIX/diff.$2" ;;
  view-issue) cat "$EVAL_FIX/issue.$2" ;;
  read-comments) cat "$EVAL_FIX/comments.$2" ;;
  list-default-commits) cat "$EVAL_FIX/commits" ;;
  list-regresses) cat "$EVAL_FIX/regresses" ;;
  *) exit 1 ;;
esac
STUB
cat > "$SD/pipeline-agent.sh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--resolve" ]; then echo "runner=claude runner_cmd= model=stub-model-1 effort=high"; exit 0; fi
prompt="$(cat)"
id="$(printf '%s\n' "$prompt" | sed -n 's/^Case: //p' | head -1)"
echo "$1 $2 $id" >> "$EVAL_AGENT_LOG"
printf '%s\n' "$prompt" > "$EVAL_PROMPTS/$id"
[ -f "$EVAL_FIX/out/$id.fail" ] && exit 1
cat "$EVAL_FIX/out/$id" 2>/dev/null
exit 0
STUB
EVAL="$SD/pipeline-eval.sh"
STATE="$SANDBOX/.git/talos/eval"
CASES="$STATE/cases"; RUNS="$STATE/runs"

ev() { OUT="$(bash "$EVAL" "$@" 2>"$SANDBOX/err")"; RC=$?; ERR="$(cat "$SANDBOX/err")"; }
jget() { python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2])))' "$1" "$2"; }
vcs_calls() { if [ -f "$EVAL_VCS_LOG" ]; then wc -l < "$EVAL_VCS_LOG" | tr -d ' '; else echo 0; fi; }
nfiles() { ls "$1" 2>/dev/null | wc -l | tr -d ' '; }

# fixtures: PR 11 changes a.py and b.py, PR 12 only c.py; issue 5 has PM spec
# comments (the newer wins), issue 6 has none.
printf 'diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1 +1 @@\n-x\n+y\ndiff --git a/b.py b/b.py\n--- a/b.py\n+++ b/b.py\n@@ -1 +1 @@\n-x\n+y\n' > "$FIX/diff.11"
printf 'diff --git a/c.py b/c.py\n--- a/c.py\n+++ b/c.py\n@@ -1 +1 @@\n-x\n+y\n' > "$FIX/diff.12"
cp "$FIX/diff.11" "$FIX/diff.13"; cp "$FIX/diff.12" "$FIX/diff.14"; cp "$FIX/diff.11" "$FIX/diff.15"
printf '{"title": "t", "body": "ISSUE BODY 5", "labels": [], "comments": []}\n' > "$FIX/issue.5"
printf '{"title": "t", "body": "ISSUE BODY 6", "labels": [], "comments": []}\n' > "$FIX/issue.6"
cat > "$FIX/comments.5" <<'JSON'
{"comments": [
 {"body": "**PM spec:** OLD SPEC", "createdAt": "2026-10-01T00:00:00Z"},
 {"body": "chatter", "createdAt": "2026-10-03T00:00:00Z"},
 {"body": "**PM spec:** NEW SPEC", "createdAt": "2026-10-02T00:00:00Z"}
]}
JSON
printf '{"comments": [{"body": "chatter", "createdAt": "2026-10-03T00:00:00Z"}]}\n' > "$FIX/comments.6"

# ── AC1 ──────────────────────────────────────────────────────────────────────
ev add --pr 11 --issue 5 --role reviewer --bug a.py:10 --confirmed-by ben
assert_eq "0" "$RC" "AC1 add --bug exits 0"
C="$CASES/reviewer-pr11.json"
assert_file_exists "$C" "AC1 case file reviewer-pr11.json"
assert_eq '["reviewer-pr11", 11, 5, "reviewer", "bug", {"file": "a.py", "line": 10}, "ben"]' \
  "$(jget "$C" '[d["id"], d["pr"], d["issue"], d["role"], d["kind"], d["bug"], d["confirmed_by"]]')" "AC1 bug case fields"
assert_eq "true" "$(jget "$C" '"+++ b/a.py" in d["diff"] and "+++ b/b.py" in d["diff"]')" "AC1 diff snapshot"
assert_eq "true" "$(jget "$C" 'bool(d["added"]) and "NEW SPEC" in d["spec"]')" "AC1 spec snapshot and added"
ev add --pr 12 --issue 6 --role security --clean --confirmed-by ben
assert_eq "0" "$RC" "AC1 add --clean exits 0"
assert_eq '["clean", null]' "$(jget "$CASES/security-pr12.json" '[d["kind"], d["bug"]]')" "AC1 clean case has bug null"

# ── AC3 ──────────────────────────────────────────────────────────────────────
assert_eq '"**PM spec:** NEW SPEC"' "$(jget "$C" 'd["spec"]')" "AC3 newest PM spec comment"
assert_eq '"ISSUE BODY 6"' "$(jget "$CASES/security-pr12.json" 'd["spec"]')" "AC3 no PM spec comment: the issue body"

# ── AC2 ──────────────────────────────────────────────────────────────────────
before="$(nfiles "$CASES")"
bad() {  # label, args...
  local label="$1"; shift
  ev add "$@"
  assert_eq "2:$before" "$RC:$(nfiles "$CASES")" "AC2 $label: exit 2, nothing written"
}
bad "path not in the diff" --pr 13 --issue 5 --role reviewer --bug zzz.py:3 --confirmed-by ben
bad "missing --confirmed-by" --pr 13 --issue 5 --role reviewer --bug a.py:3
bad "neither --bug nor --clean" --pr 13 --issue 5 --role reviewer --confirmed-by ben
bad "both --bug and --clean" --pr 13 --issue 5 --role reviewer --bug a.py:3 --clean --confirmed-by ben
bad "unknown role" --pr 13 --issue 5 --role developer --bug a.py:3 --confirmed-by ben
bad "existing case id" --pr 11 --issue 5 --role reviewer --bug b.py:3 --confirmed-by ben
bad "option with no value" --pr 13 --issue 5 --role reviewer --bug a.py:3 --confirmed-by
assert_eq '{"file": "a.py", "line": 10}' "$(jget "$C" 'd["bug"]')" "AC2 the existing case is untouched"

# ── AC4 ──────────────────────────────────────────────────────────────────────
ev list
assert_eq "0" "$RC" "AC4 list exits 0"
assert_contains "$OUT" "reviewer-pr11	reviewer	bug	a.py:10	ben" "AC4 bug row"
assert_contains "$OUT" "security-pr12	security	clean	-	ben" "AC4 clean row"
assert_eq "3" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "AC4 header and one row per case"
mv "$CASES" "$STATE/cases.keep"
ev list
assert_eq "0:1" "$RC:$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "AC4 no cases: the header only, exit 0"
mv "$STATE/cases.keep" "$CASES"

# ── AC5 / AC6 / AC7 ──────────────────────────────────────────────────────────
rm -rf "$RUNS"
: > "$EVAL_VCS_LOG"
printf -- '- [Important] a.py:12 — off by two\n' > "$FIX/out/reviewer-pr11"
printf -- '- [Important] c.py:1 — noise\nnot a finding\n- [Suggestion] c.py:2 — nit\n  - [Important] c.py:3 — indented\n' > "$FIX/out/security-pr12"
ev run --role reviewer
assert_eq "0" "$RC" "AC5 run exits 0"
P="$EVAL_PROMPTS/reviewer-pr11"
assert_eq "reviewer - reviewer-pr11" "$(head -1 "$EVAL_AGENT_LOG")" "AC5 the stage runner gets <role> - on stdin"
assert_contains "$(cat "$P")" "NEW SPEC" "AC5 prompt holds the spec"
assert_contains "$(cat "$P")" "+++ b/b.py" "AC5 prompt holds the diff"
assert_contains "$(cat "$P")" "- [Important] <path>:<line> — <text>" "AC5 prompt states the output shape"
assert_contains "$(cat "$P")" "Do not post" "AC5 prompt says to post nothing"
assert_contains "$(cat "$P")" "run any tests" "AC5 prompt says to run no tests"
assert_eq "0" "$(vcs_calls)" "AC5 run calls the provider for nothing"
assert_eq "" "$(cat "$GH_LOG")" "AC5 run calls gh for nothing"
assert_contains "$OUT" "reviewer-pr11	bug	found" "AC6 within the tolerance (2 lines) is found"

run_result() {  # case-id -> result column of the last run's table
  printf '%s\n' "$OUT" | awk -F'\t' -v c="$1" '$1 == c { print $3 }'
}
tol() {  # label, expected, finding line, tolerance args...
  local label="$1" want="$2" line="$3"; shift 3
  printf -- '%s\n' "$line" > "$FIX/out/reviewer-pr11"
  ev run --role reviewer "$@"
  assert_eq "$want" "$(run_result reviewer-pr11)" "AC6 $label"
}
tol "boundary line (5 away) is found" found "- [Important] a.py:15 — x"
tol "beyond the tolerance is missed" missed "- [Important] a.py:16 — x"
tol "another file is missed" missed "- [Important] b.py:10 — x"
tol "no finding is missed" missed ""
tol "--tolerance 1 moves the boundary in" missed "- [Important] a.py:12 — x" --tolerance 1
tol "--tolerance 8 moves the boundary out" found "- [Important] a.py:18 — x" --tolerance 8

printf -- '- [Important] a.py:10 — real\n- [Important] b.py:1 — extra\n- [Important] c.py:1 — extra\n' > "$FIX/out/reviewer-pr11"
ev run --role reviewer
assert_eq "found" "$(run_result reviewer-pr11)" "AC7 extra findings on a bug case do not change found"
assert_contains "$OUT" "score reviewer: 1/1 100% false_alarms=0" "AC7 extra findings on a bug case are not false alarms"
ev run --role security
assert_eq "false-alarm x1" "$(run_result security-pr12)" "AC7 clean case: Important lines are false alarms, others ignored"
assert_contains "$OUT" "score security: 0/0 n/a false_alarms=1" "AC7/AC8 no bug cases: n/a, false alarms reported"
printf 'all good\n' > "$FIX/out/security-pr12"
ev run --role security
assert_eq "clean" "$(run_result security-pr12)" "AC7 clean case with no finding is clean"

# ── AC8 / AC9 ────────────────────────────────────────────────────────────────
ev add --pr 14 --issue 6 --role reviewer --clean --confirmed-by ben
ev add --pr 15 --issue 5 --role reviewer --bug b.py:7 --confirmed-by ben
printf -- '- [Important] a.py:10 — real\n' > "$FIX/out/reviewer-pr11"
printf -- '- [Important] c.py:1 — noise\n- [Important] c.py:2 — noise\n' > "$FIX/out/reviewer-pr14"
printf 'nothing\n' > "$FIX/out/reviewer-pr15"
rm -rf "$RUNS"
ev run
assert_eq "0" "$RC" "AC8 run (all roles) exits 0"
assert_contains "$OUT" "reviewer-pr14	clean	false-alarm x2" "AC8 table row with false-alarm count"
assert_contains "$OUT" "reviewer-pr15	bug	missed" "AC8 table row missed"
assert_contains "$OUT" "score reviewer: 1/2 50% false_alarms=2" "AC8 reviewer score line"
assert_contains "$OUT" "score security: 0/0 n/a false_alarms=0" "AC8 security score line"
assert_not_contains "$OUT" "score qa" "AC8 a role with no case has no score line"
R="$(ls "$RUNS"/*-reviewer.json 2>/dev/null | head -1)"
assert_file_exists "$R" "AC8 saved run <timestamp>-reviewer.json"
assert_eq '["reviewer", "stub-model-1", 1, 2, 2, 50]' "$(jget "$R" '[d["role"], d["model"], d["found"], d["bugs"], d["false_alarms"], d["score"]]')" "AC8 run file figures"
assert_eq '[["reviewer-pr11", "found"], ["reviewer-pr14", "false-alarm"], ["reviewer-pr15", "missed"]]' \
  "$(jget "$R" '[[c["case"], c["result"]] for c in d["cases"]]')" "AC8 per-case results"
assert_eq "1" "$(ls "$RUNS" | grep -c security)" "AC8 one run file per role run"
assert_eq "true" "$(jget "$(ls "$RUNS"/*-security.json | head -1)" 'd["score"] is None')" "AC8 n/a is saved as null"

: > "$EVAL_AGENT_LOG"
ev run --role security
assert_eq "1" "$(wc -l < "$EVAL_AGENT_LOG" | tr -d ' ')" "AC9 --role replays only that role's cases"
ev run --role bogus
assert_eq "2" "$RC" "AC9 unknown role exits 2"
touch "$FIX/out/reviewer-pr11.fail" "$FIX/out/reviewer-pr14.fail"
ev run --role reviewer
assert_eq "missed" "$(run_result reviewer-pr11)" "AC9 a failing stage run on a bug case is missed"
assert_eq "error" "$(run_result reviewer-pr14)" "AC9 a failing stage run on a clean case is not clean"
rm -f "$FIX/out/"*.fail

# ── AC10 ─────────────────────────────────────────────────────────────────────
for n in 21 22 23 24 25 26 27 28 29 30 31; do
  cp "$FIX/diff.11" "$FIX/diff.$n"
  ev add --pr "$n" --issue 5 --role qa --bug a.py:1 --confirmed-by ben
done
: > "$EVAL_AGENT_LOG"
ev run --role qa
assert_eq "2:0" "$RC:$(wc -l < "$EVAL_AGENT_LOG" | tr -d ' ')" "AC10 11 cases exceed the default cap of 10: exit 2, no stage run"
ev run --role qa --max-cases 11
assert_eq "0:11" "$RC:$(wc -l < "$EVAL_AGENT_LOG" | tr -d ' ')" "AC10 --max-cases raises the cap"
ev run --max-cases 3
assert_eq "2" "$RC" "AC10 --max-cases lowers it, all roles counted together"

# ── AC11 ─────────────────────────────────────────────────────────────────────
rm -rf "$RUNS"; mkdir -p "$RUNS"
mkrun() {  # timestamp found bugs false_alarms score
  printf '{"role": "reviewer", "model": "m", "cases": [], "found": %s, "bugs": %s, "false_alarms": %s, "score": %s}\n' "$2" "$3" "$4" "$5" > "$RUNS/$1-reviewer.json"
}
ev compare --role reviewer
assert_eq "2" "$RC" "AC11 no saved run: exit 2"
mkrun 20261001T000000000000Z 2 4 1 50
ev compare --role reviewer
assert_eq "2" "$RC" "AC11 one saved run: exit 2"
mkrun 20261002T000000000000Z 3 4 1 75
ev compare --role reviewer
assert_eq "0" "$RC" "AC11 a higher score: exit 0"
assert_contains "$OUT" "2/4" "AC11 earlier run figures"
assert_contains "$OUT" "3/4" "AC11 later run figures"
assert_contains "$OUT" "delta" "AC11 delta line"
assert_contains "$OUT" "+25" "AC11 score delta"
mkrun 20261003T000000000000Z 3 4 2 75
ev compare --role reviewer
assert_eq "1" "$RC" "AC11 more false alarms: exit 1"
mkrun 20261004T000000000000Z 1 4 0 25
ev compare --role reviewer
assert_eq "1" "$RC" "AC11 lower score: exit 1 (newest two)"
ev compare --role reviewer 20261001T000000000000Z-reviewer.json 20261002T000000000000Z-reviewer.json
assert_eq "0" "$RC" "AC11 two named runs"

# ── AC12 ─────────────────────────────────────────────────────────────────────
for pr in 11 12 40 41 42; do
  printf '{"event": "merged", "role": "orchestrator", "issue": 5, "pr": %s, "repo": "acme/widget", "ts": "2026-10-10T00:00:00Z"}\n' "$pr"
done > "$SANDBOX/.git/talos/events.jsonl"
cat > "$FIX/commits" <<'JSON'
[{"sha": "a", "subject": "Revert \"feat: x (#40)\" (#43)", "date": "2026-10-11"},
 {"sha": "b", "subject": "Revert \"feat: y (#11)\" (#44)", "date": "2026-10-11"},
 {"sha": "c", "subject": "feat: z (#99)", "date": "2026-10-11"}]
JSON
cat > "$FIX/regresses" <<'JSON'
[{"number": 50, "kind": "pr", "date": "2026-10-12", "regresses": 41},
 {"number": 51, "kind": "pr", "date": "2026-10-12", "regresses": 98},
 {"number": 52, "kind": "pr", "date": "2026-10-12", "regresses": 40}]
JSON
ev candidates
assert_eq "0" "$RC" "AC12 candidates exits 0"
assert_eq "40	revert
41	fix-forward" "$OUT" "AC12 reverted and fixed-forward merged PRs, PRs in a case skipped, others ignored"
mv "$FIX/regresses" "$FIX/regresses.keep"
ev candidates
assert_eq "1" "$RC" "AC12 a failed provider read exits 1"
assert_contains "$ERR" "list-regresses" "AC12 the failed read is named on stderr"
mv "$FIX/regresses.keep" "$FIX/regresses"

# ── AC13 ─────────────────────────────────────────────────────────────────────
refs="$(grep -rl 'pipeline-eval' "$TALOS_ROOT/scripts/talos.sh" "$TALOS_ROOT/scripts/pipeline-hooks.sh" "$TALOS_ROOT/skills" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$refs" "AC13 talos.sh, pipeline-hooks.sh and skills/ never reference pipeline-eval.sh"
before="$(wc -c < "$SANDBOX/.git/talos/events.jsonl" | tr -d ' ')"
ev run --role security
assert_eq "$before" "$(wc -c < "$SANDBOX/.git/talos/events.jsonl" | tr -d ' ')" "AC13 run appends no line to the events log"

# ── AC15 ─────────────────────────────────────────────────────────────────────
lint="$(bash "$TALOS_ROOT/scripts/bash3-lint.sh" "$TALOS_ROOT/scripts/pipeline-eval.sh" 2>&1)"; lrc=$?
assert_eq "0:" "$lrc:$lint" "AC15 pipeline-eval.sh passes the bash 3 lint"

[ "$_FAIL" -eq 0 ] || { printf '%d failed\n' "$_FAIL" >&2; exit 1; }
printf 'test-eval-set-792: %d passed\n' "$_PASS"
