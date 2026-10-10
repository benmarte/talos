#!/usr/bin/env bash
# test-events-log.sh -- the local events log at <git common dir>/talos/
# scripts/pipeline-hooks.sh's post_stage verb appends every payload as one
# JSON line, and scripts/pipeline-events.sh reads it back. One sandbox, one set
# of fixtures for the three event-log areas (the old test-events-cost.sh and
# test-events-arg-hang.sh were folded in by #556):
#
# Part 1 -- the log itself:
#   (a) post_stage with no hooks.post_stage configured still appends one line
#   (b) post_stage with hooks.post_stage configured appends exactly one line
#       (not two -- the hook run and the local log are independent writers)
#   (c) events.enabled: false -> no file is created
#   (d) the log path resolves to the MAIN repo's git common dir (outside
#       every git tree, #517) from inside a linked worktree (a scratch repo
#       + `git worktree add` under mktemp)
#   (e) reader filters (--issue/--role/--last) and --json
#   (f) a malformed line is skipped, with the count reported on stderr
#   (g) 8 parallel post_stage calls append 8 intact, non-interleaved lines
#
# Part 2 -- per-stage cost accounting (#202, #258, #259):
#   (a) post_stage --tokens/--tool-uses/--duration-s land in the payload and
#       the events log line, unchanged
#   (b) omitting them -> null in both
#   (c) an invalid --tokens value -> null + one stderr note, post_stage still
#       exits 0
#   (d) `pipeline-events.sh cost` sums tokens/tool_uses/duration_s and counts
#       events correctly, grouped by (issue, role), across two issues and
#       four roles
#   (e) --issue filters the cost summary to one issue
#   (f) --json parses and matches the table
#   (g) a null-tokens event is counted in the unrecorded column, not silently
#       folded into a real 0
#   (h) an explicit --tokens 0 event is a real zero, not counted as
#       unrecorded -- a fixture proves null and 0 read differently
#   (i) a RESTAMP_PASS/RESTAMP_FAIL verdict is counted in the restamp
#       column (#258), separate from that group's events/tokens totals
#
# Part 3 -- a value-taking flag given as the last argument exits 2 with a
# usage line instead of looping forever (#450):
#   (a) pipeline-hooks.sh post_stage: all 13 value flags
#   (b) pipeline-events.sh list: --issue --role --event --last; tail: --issue
# Every form runs under a kill-after-5-seconds guard that reports a hang; the
# guard runs all forms in ONE python3 process.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"

# _realpath PATH -- canonicalizes symlinks (macOS: /tmp -> /private/tmp) and
# collapses "//" so path comparisons below aren't tripped up by cosmetic
# differences between two independently-built strings that name the same
# file. The path need not exist.
_realpath() { python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$1"; }

# ── (a) No hooks.post_stage configured -- the local log still gets one line ──
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "claude"}}
EOF
out="$(bash "$HOOKS" post_stage qa qa 42 --verdict PASS 2>"$SANDBOX/err.log")"
rc=$?
assert_eq "0" "$rc" "no hook configured: post_stage still exits 0"
assert_eq "" "$out" "no hook configured: no stdout"
assert_file_exists ".git/talos/events.jsonl" "no hook configured: events log was created"

_line_count="$(grep -c . .git/talos/events.jsonl 2>/dev/null || true)"
assert_eq "1" "$_line_count" "no hook configured: exactly one line was appended"

_check="$(python3 -c "
import json
d = json.loads(open('.git/talos/events.jsonl').read().strip())
print('OK' if d.get('event') == 'qa' and d.get('role') == 'qa' and d.get('issue') == 42 and d.get('verdict') == 'PASS' else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "no hook configured: the appended line is the exact post_stage payload"

# ── (b) hooks.post_stage configured -- the log gets exactly one line (not two,
# one per writer) ──────────────────────────────────────────────────────────
rm -f .git/talos/events.jsonl
HOOK_CAPTURE="$SANDBOX/hook-stdin.json"
cat > talos.pipeline.json <<EOF
{"hooks": {"post_stage": "cat > $HOOK_CAPTURE", "timeout_s": 5}}
EOF
bash "$HOOKS" post_stage qa qa 42 --verdict PASS >/dev/null 2>"$SANDBOX/err.log"
rc=$?
assert_eq "0" "$rc" "hook configured: post_stage still exits 0"
assert_file_exists "$HOOK_CAPTURE" "hook configured: hooks.post_stage command still ran"
_line_count="$(grep -c . .git/talos/events.jsonl 2>/dev/null || true)"
assert_eq "1" "$_line_count" "hook configured: events log still gets exactly one line"

# ── (c) events.enabled: false -- no file at all ───────────────────────────────
rm -f .git/talos/events.jsonl
cat > talos.pipeline.json <<'EOF'
{"events": {"enabled": false}}
EOF
bash "$HOOKS" post_stage qa qa 42 --verdict PASS >/dev/null 2>"$SANDBOX/err.log"
rc=$?
assert_eq "0" "$rc" "events disabled: post_stage still exits 0"
assert_file_absent ".git/talos/events.jsonl" "events disabled: no events log is created"
rm -rf .git/talos

# ── (d) Path resolves to the MAIN repo root from inside a linked worktree ────
# Independent scratch repo (not the sandbox repo above), so the worktree
# machinery under test is exercised in isolation.
WT_MAIN="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-events-main.XXXXXX")" || exit 1
(
  cd "$WT_MAIN"
  git init -q
  git config user.name "talos-test"
  git config user.email "test@talos.invalid"
  : > README.md
  git add README.md
  git commit -q -m "init"
  cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "claude"}}
EOF
  git worktree add -q -b events-linked "$WT_MAIN.linked" >/dev/null 2>&1
)
LINKED="${WT_MAIN:?}.linked"
( cd "$LINKED" && bash "$HOOKS" post_stage qa qa 99 --verdict PASS 2>"$SANDBOX/wt-err.log" )
rc=$?
assert_eq "0" "$rc" "linked worktree: post_stage exits 0"
assert_file_exists "$WT_MAIN/.git/talos/events.jsonl" "linked worktree: event landed in the MAIN repo's git common dir (outside every tree, #517), not the worktree's"
assert_file_absent "$LINKED/.talos/events.jsonl" "linked worktree: no worktree-local copy, and the old in-tree .talos/ location is never written"

_resolved_path="$(cd "$LINKED" && bash "$EVENTS" path)"
assert_eq "$(_realpath "$WT_MAIN/.git/talos/events.jsonl")" "$(_realpath "$_resolved_path")" \
  "linked worktree: pipeline-events.sh path agrees with pipeline-hooks.sh's resolution"

rm -rf "$WT_MAIN" "$LINKED"

# ── (e) Reader filters + --json ────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "claude"}}
EOF
rm -f .git/talos/events.jsonl
bash "$HOOKS" post_stage qa qa 42 --verdict PASS --summary "issue 42 qa" >/dev/null 2>&1
bash "$HOOKS" post_stage reviewer reviewer 42 --verdict PASS --summary "issue 42 review" >/dev/null 2>&1
bash "$HOOKS" post_stage qa qa 43 --verdict FAIL --summary "issue 43 qa" >/dev/null 2>&1

out="$(bash "$EVENTS" list --issue 42 2>"$SANDBOX/err.log")"
_n="$(printf '%s\n' "$out" | grep -c . || true)"
assert_eq "2" "$_n" "reader: --issue 42 matches exactly the two issue-42 events"
assert_not_contains "$out" "issue 43 qa" "reader: --issue 42 excludes issue 43"

out="$(bash "$EVENTS" list --issue 42 --role qa 2>"$SANDBOX/err.log")"
_n="$(printf '%s\n' "$out" | grep -c . || true)"
assert_eq "1" "$_n" "reader: --issue 42 --role qa narrows to one event"
assert_contains "$out" "issue 42 qa" "reader: the one matched event is the qa one"

out="$(bash "$EVENTS" list --last 1 2>"$SANDBOX/err.log")"
_n="$(printf '%s\n' "$out" | grep -c . || true)"
assert_eq "1" "$_n" "reader: --last 1 keeps only the most recent event"
assert_contains "$out" "issue 43 qa" "reader: --last 1 keeps the last-appended event"

out="$(bash "$EVENTS" list --issue 42 --role qa --json 2>"$SANDBOX/err.log")"
_check="$(printf '%s' "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read().strip())
print('OK' if d.get('issue') == 42 and d.get('role') == 'qa' and d.get('summary') == 'issue 42 qa' else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "reader: --json prints the full payload as one JSON object"

out="$(bash "$EVENTS" tail --issue 43 2>"$SANDBOX/err.log")"
assert_contains "$out" "issue 43 qa" "reader: tail --issue scopes correctly"

_path="$(bash "$EVENTS" path)"
assert_eq "$(_realpath "$SANDBOX/.git/talos/events.jsonl")" "$(_realpath "$_path")" "reader: path prints the resolved log path"

# ── (f) A malformed line is skipped, with the count reported on stderr ───────
printf 'not json at all\n' >> .git/talos/events.jsonl
err="$(bash "$EVENTS" list --last 100 2>&1 >/dev/null)"
assert_contains "$err" "skipped 1 malformed" "reader: malformed line is reported once on stderr"
out="$(bash "$EVENTS" list --last 100 2>/dev/null)"
assert_not_contains "$out" "not json at all" "reader: malformed line never reaches stdout"

# ── (g) 8 parallel post_stage calls -> 8 intact, non-interleaved lines ───────
rm -f .git/talos/events.jsonl
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "claude"}}
EOF
_pids=""
for i in 1 2 3 4 5 6 7 8; do
  bash "$HOOKS" post_stage qa qa "$i" --verdict PASS --summary "parallel-$i" >/dev/null 2>&1 &
  _pids="$_pids $!"
done
for p in $_pids; do wait "$p"; done

_line_count="$(grep -c . .git/talos/events.jsonl 2>/dev/null || true)"
assert_eq "8" "$_line_count" "parallel: 8 concurrent post_stage calls produce 8 lines"

_check="$(python3 -c "
import json
bad = 0
with open('.git/talos/events.jsonl') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            json.loads(line)
        except ValueError:
            bad += 1
print(bad)
")"
assert_eq "0" "$_check" "parallel: every line is valid, whole JSON (no interleaving)"

# ═════════════════════════════════════════════════════════════════════════════
# Part 2 -- per-stage cost accounting
# ═════════════════════════════════════════════════════════════════════════════
rm -f .git/talos/events.jsonl
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "claude"}}
EOF

# ── (a) --tokens/--tool-uses/--duration-s land in payload + log line ───────
out="$(bash "$HOOKS" post_stage qa qa 42 --verdict PASS --tokens 1234 --tool-uses 7 --duration-s 12 2>"$SANDBOX/err.log")"
rc=$?
assert_eq "0" "$rc" "valid tokens/tool-uses: post_stage exits 0"
assert_eq "" "$out" "valid tokens/tool-uses: no stdout"

_check="$(python3 -c "
import json
d = json.loads(open('.git/talos/events.jsonl').read().strip())
print('OK' if d.get('tokens') == 1234 and d.get('tool_uses') == 7 and d.get('duration_s') == 12 else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "valid tokens/tool-uses: the log line carries tokens/tool_uses/duration_s"

# ── (b) Omitted -> null in both ─────────────────────────────────────────────
rm -f .git/talos/events.jsonl
bash "$HOOKS" post_stage qa qa 42 --verdict PASS >/dev/null 2>"$SANDBOX/err.log"
_check="$(python3 -c "
import json
d = json.loads(open('.git/talos/events.jsonl').read().strip())
print('OK' if d.get('tokens') is None and d.get('tool_uses') is None else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "omitted tokens/tool-uses: null in the log line"

# ── (c) Invalid --tokens -> null + one stderr note, still exits 0 ──────────
rm -f .git/talos/events.jsonl
out="$(bash "$HOOKS" post_stage qa qa 42 --verdict PASS --tokens abc 2>"$SANDBOX/err.log")"
rc=$?
assert_eq "0" "$rc" "invalid --tokens: post_stage still exits 0"
assert_contains "$(cat "$SANDBOX/err.log")" "not a non-negative integer" \
  "invalid --tokens: one stderr note explains the fallback"
_check="$(python3 -c "
import json
d = json.loads(open('.git/talos/events.jsonl').read().strip())
print('OK' if d.get('tokens') is None else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "invalid --tokens: null in the log line, not the bad string"

# ── Fixture log for the cost summary: two issues, four roles, one explicit
# zero-tokens event (validator on issue 42) distinct from the null-tokens
# event (developer on issue 43) ─────────────────────────────────────────────
rm -f .git/talos/events.jsonl
bash "$HOOKS" post_stage qa qa 42 --verdict PASS --tokens 100 --tool-uses 5 --duration-s 10 >/dev/null 2>&1
bash "$HOOKS" post_stage qa qa 42 --verdict PASS --tokens 50 --tool-uses 2 --duration-s 5 >/dev/null 2>&1
bash "$HOOKS" post_stage reviewer reviewer 42 --verdict PASS --tokens 200 --tool-uses 1 --duration-s 20 >/dev/null 2>&1
bash "$HOOKS" post_stage validator validator 42 --verdict CONFIRMED --tokens 0 --tool-uses 0 --duration-s 3 >/dev/null 2>&1
bash "$HOOKS" post_stage developer developer 43 --verdict PASS --duration-s 30 >/dev/null 2>&1

# ── (d) cost sums correctly across two issues and four roles ───────────────
out="$(bash "$EVENTS" cost 2>"$SANDBOX/err.log")"
assert_contains "$out" "$(printf '42\tqa\t2\t150\t7\t15\t0\t0')" "cost: issue 42 / qa row sums two events"
assert_contains "$out" "$(printf '42\treviewer\t1\t200\t1\t20\t0\t0')" "cost: issue 42 / reviewer row"
assert_contains "$out" "$(printf '42\tvalidator\t1\t0\t0\t3\t0\t0')" \
  "cost: issue 42 / validator row (explicit --tokens 0 is a real zero, not unrecorded)"
assert_contains "$out" "$(printf '43\tdeveloper\t1\t0\t0\t30\t1\t0')" \
  "cost: issue 43 / developer row (null tokens summed as 0, flagged unrecorded)"
assert_contains "$out" "$(printf 'TOTAL\t\t5\t350\t8\t68\t1\t0')" "cost: TOTAL row sums every group"

# ── Header uses the `unrecorded` and `restamp` column names ────────────────
assert_contains "$out" "$(printf 'issue\trole\tevents\ttokens\ttool_uses\tduration_s\tunrecorded\trestamp')" \
  "cost: table header names the unrecorded and restamp columns"

# ── (e) --issue filters ─────────────────────────────────────────────────────
out="$(bash "$EVENTS" cost --issue 42 2>"$SANDBOX/err.log")"
assert_not_contains "$out" "developer" "cost --issue 42: excludes issue 43's developer row"
assert_contains "$out" "$(printf 'TOTAL\t\t4\t350\t8\t38\t0\t0')" "cost --issue 42: TOTAL row scoped to issue 42 only"

# ── (f) --json parses and matches the table ─────────────────────────────────
out="$(bash "$EVENTS" cost --json 2>"$SANDBOX/err.log")"
_check="$(printf '%s' "$out" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read().strip())
rows = {(r['issue'], r['role']): r for r in d['rows']}
r42qa = rows.get((42, 'qa'))
r42validator = rows.get((42, 'validator'))
ok = (
    r42qa is not None
    and r42qa['events'] == 2 and r42qa['tokens'] == 150
    and r42qa['tool_uses'] == 7 and r42qa['duration_s'] == 15
    and r42qa['restamp'] == 0
    and r42validator is not None
    and r42validator['tokens'] == 0 and r42validator['unrecorded'] == 0
    and r42validator['restamp'] == 0
    and d['total']['events'] == 5 and d['total']['tokens'] == 350
    and d['total']['unrecorded'] == 1 and d['total']['restamp'] == 0
)
print('OK' if ok else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "cost --json: parses and matches the table's rows and total, using the unrecorded and restamp keys"

# ── (g) unrecorded is counted, not silently folded into a real 0 ───────────
out="$(bash "$EVENTS" cost 2>"$SANDBOX/err.log")"
_unrecorded_line="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "43" && $2 == "developer" { print }')"
_unrecorded_count="$(printf '%s' "$_unrecorded_line" | awk -F'\t' '{ print $(NF-1) }')"
assert_eq "1" "$_unrecorded_count" "cost: the null-tokens event is flagged in the unrecorded column"

# ── (h) an explicit zero is not flagged as unrecorded ───────────────────────
_zero_line="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "42" && $2 == "validator" { print }')"
_zero_unrecorded_count="$(printf '%s' "$_zero_line" | awk -F'\t' '{ print $(NF-1) }')"
assert_eq "0" "$_zero_unrecorded_count" "cost: an explicit --tokens 0 event is not flagged as unrecorded"

# ── (i) RESTAMP_PASS/RESTAMP_FAIL verdicts are counted in the restamp
#        column (#258), separate from full-stage events/tokens ────────────
rm -f .git/talos/events.jsonl
bash "$HOOKS" post_stage qa qa 44 --verdict PASS --tokens 100 --tool-uses 5 --duration-s 10 >/dev/null 2>&1
bash "$HOOKS" post_stage qa qa 44 --verdict RESTAMP_PASS --tokens 20 --tool-uses 1 --duration-s 2 >/dev/null 2>&1
bash "$HOOKS" post_stage security security 44 --verdict RESTAMP_FAIL --tokens 15 --tool-uses 1 --duration-s 1 >/dev/null 2>&1
out="$(bash "$EVENTS" cost --issue 44 2>"$SANDBOX/err.log")"
assert_contains "$out" "$(printf '44\tqa\t2\t120\t6\t12\t0\t1')" \
  "cost: RESTAMP_PASS is counted in the restamp column, alongside the group's other (full-stage) event"
assert_contains "$out" "$(printf '44\tsecurity\t1\t15\t1\t1\t0\t1')" \
  "cost: RESTAMP_FAIL is also counted in the restamp column"
assert_contains "$out" "$(printf 'TOTAL\t\t3\t135\t7\t13\t0\t2')" \
  "cost: TOTAL restamp column sums across both roles"
out_json="$(bash "$EVENTS" cost --issue 44 --json 2>"$SANDBOX/err.log")"
_restamp_check="$(printf '%s' "$out_json" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read().strip())
rows = {r['role']: r for r in d['rows']}
ok = rows['qa']['restamp'] == 1 and rows['security']['restamp'] == 1 and d['total']['restamp'] == 2
print('OK' if ok else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_restamp_check" "cost --json: restamp column present and correct"

# ═════════════════════════════════════════════════════════════════════════════
# Part 3 -- a value-taking flag as the last argument: exit 2, no hang
# ═════════════════════════════════════════════════════════════════════════════
# Every case runs `bash SCRIPT ARGS` in its own session with stdin closed. One
# python3 runs them all: RC is the exit code, or HANG after 5 s (the whole process
# group is then killed and reaped), ERR is stderr on one line. Fields of a case are
# joined with the ASCII unit separator so no path or argument is word-split.
HANG_CASES=(); HANG_LABELS=()
hc() {  # LABEL SCRIPT ARGS...
  HANG_LABELS+=("$1"); shift
  local IFS=$'\037'
  HANG_CASES+=("$*")
}
for flag in --pr --sha --verdict --summary --summary-file --details-file --attempt \
            --duration-s --tokens --tool-uses --ci-runs --model --runner; do
  hc "post_stage $flag" "$HOOKS" post_stage qa qa 1 "$flag"
done
for form in "list --issue" "list --role" "list --event" "list --last" "tail --issue" "list --json --issue"; do
  # shellcheck disable=SC2086
  hc "events $form" "$EVENTS" $form
done
HANG_RES="$SANDBOX/hang.res"
python3 -I - "${HANG_CASES[@]}" > "$HANG_RES" <<'PY'
import os, signal, subprocess, sys
for case in sys.argv[1:]:
    p = subprocess.Popen(["bash"] + case.split("\x1f"), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.PIPE, start_new_session=True)
    try:
        _, err = p.communicate(timeout=5)
        rc = str(p.returncode)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        _, err = p.communicate()
        rc = "HANG"
    print(rc + " " + err.decode(errors="replace").strip().replace("\n", " / "))
PY
_hi=0
while IFS= read -r res; do
  RC="${res%% *}"; ERR="${res#* }"; label="${HANG_LABELS[$_hi]}"; _hi=$((_hi + 1))
  assert_eq "2" "$RC" "$label as the last argument: exit 2, no hang"
  case "$label" in
    post_stage*)
      assert_contains "$ERR" "${label#post_stage } needs a value" "$label: names the flag"
      assert_contains "$ERR" "Usage: pipeline-hooks.sh" "$label: prints the usage" ;;
    *)
      assert_contains "$ERR" "needs a value" "$label: says a value is missing"
      assert_contains "$ERR" "Usage: pipeline-events.sh" "$label: prints the usage" ;;
  esac
done < "$HANG_RES"
assert_eq "${#HANG_CASES[@]}" "$_hi" "every last-argument case produced a result"

finish
