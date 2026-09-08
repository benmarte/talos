#!/usr/bin/env bash
# test-events-log.sh -- the local .talos/events.jsonl audit log (#183):
# scripts/pipeline-hooks.sh's post_stage verb appends every payload as one
# JSON line, and scripts/pipeline-events.sh reads it back. Covers:
#   (a) post_stage with no hooks.post_stage configured still appends one line
#   (b) post_stage with hooks.post_stage configured appends exactly one line
#       (not two -- the hook run and the local log are independent writers)
#   (c) events.enabled: false -> no file is created
#   (d) the log path resolves to the MAIN repo root from inside a linked
#       worktree (a scratch repo + `git worktree add` under mktemp)
#   (e) reader filters (--issue/--role/--last) and --json
#   (f) a malformed line is skipped, with the count reported on stderr
#   (g) 8 parallel post_stage calls append 8 intact, non-interleaved lines
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
assert_file_exists ".talos/events.jsonl" "no hook configured: events log was created"

_line_count="$(grep -c . .talos/events.jsonl 2>/dev/null || true)"
assert_eq "1" "$_line_count" "no hook configured: exactly one line was appended"

_check="$(python3 -c "
import json
d = json.loads(open('.talos/events.jsonl').read().strip())
print('OK' if d.get('event') == 'qa' and d.get('role') == 'qa' and d.get('issue') == 42 and d.get('verdict') == 'PASS' else 'BAD:' + json.dumps(d))
")"
assert_eq "OK" "$_check" "no hook configured: the appended line is the exact post_stage payload"

# ── (b) hooks.post_stage configured -- the log gets exactly one line (not two,
# one per writer) ──────────────────────────────────────────────────────────
rm -f .talos/events.jsonl
HOOK_CAPTURE="$SANDBOX/hook-stdin.json"
cat > talos.pipeline.json <<EOF
{"hooks": {"post_stage": "cat > $HOOK_CAPTURE", "timeout_s": 5}}
EOF
bash "$HOOKS" post_stage qa qa 42 --verdict PASS >/dev/null 2>"$SANDBOX/err.log"
rc=$?
assert_eq "0" "$rc" "hook configured: post_stage still exits 0"
assert_file_exists "$HOOK_CAPTURE" "hook configured: hooks.post_stage command still ran"
_line_count="$(grep -c . .talos/events.jsonl 2>/dev/null || true)"
assert_eq "1" "$_line_count" "hook configured: events log still gets exactly one line"

# ── (c) events.enabled: false -- no file at all ───────────────────────────────
rm -f .talos/events.jsonl
cat > talos.pipeline.json <<'EOF'
{"events": {"enabled": false}}
EOF
bash "$HOOKS" post_stage qa qa 42 --verdict PASS >/dev/null 2>"$SANDBOX/err.log"
rc=$?
assert_eq "0" "$rc" "events disabled: post_stage still exits 0"
assert_file_absent ".talos/events.jsonl" "events disabled: no events log is created"
rm -rf .talos

# ── (d) Path resolves to the MAIN repo root from inside a linked worktree ────
# Independent scratch repo (not the sandbox repo above), so the worktree
# machinery under test is exercised in isolation.
WT_MAIN="$(mktemp -d "${TMPDIR:-/tmp}/talos-events-main.XXXXXX")"
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
LINKED="$WT_MAIN.linked"
( cd "$LINKED" && bash "$HOOKS" post_stage qa qa 99 --verdict PASS 2>"$SANDBOX/wt-err.log" )
rc=$?
assert_eq "0" "$rc" "linked worktree: post_stage exits 0"
assert_file_exists "$WT_MAIN/.talos/events.jsonl" "linked worktree: event landed in the MAIN repo's .talos/, not the worktree's"
assert_file_absent "$LINKED/.talos/events.jsonl" "linked worktree: no worktree-local copy was created"

_resolved_path="$(cd "$LINKED" && bash "$EVENTS" path)"
assert_eq "$(_realpath "$WT_MAIN/.talos/events.jsonl")" "$(_realpath "$_resolved_path")" \
  "linked worktree: pipeline-events.sh path agrees with pipeline-hooks.sh's resolution"

rm -rf "$WT_MAIN" "$LINKED"

# ── (e) Reader filters + --json ────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "claude"}}
EOF
rm -f .talos/events.jsonl
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
assert_eq "$(_realpath "$SANDBOX/.talos/events.jsonl")" "$(_realpath "$_path")" "reader: path prints the resolved log path"

# ── (f) A malformed line is skipped, with the count reported on stderr ───────
printf 'not json at all\n' >> .talos/events.jsonl
err="$(bash "$EVENTS" list --last 100 2>&1 >/dev/null)"
assert_contains "$err" "skipped 1 malformed" "reader: malformed line is reported once on stderr"
out="$(bash "$EVENTS" list --last 100 2>/dev/null)"
assert_not_contains "$out" "not json at all" "reader: malformed line never reaches stdout"

# ── (g) 8 parallel post_stage calls -> 8 intact, non-interleaved lines ───────
rm -f .talos/events.jsonl
cat > talos.pipeline.json <<'EOF'
{"agents": {"runner": "claude"}}
EOF
_pids=""
for i in 1 2 3 4 5 6 7 8; do
  bash "$HOOKS" post_stage qa qa "$i" --verdict PASS --summary "parallel-$i" >/dev/null 2>&1 &
  _pids="$_pids $!"
done
for p in $_pids; do wait "$p"; done

_line_count="$(grep -c . .talos/events.jsonl 2>/dev/null || true)"
assert_eq "8" "$_line_count" "parallel: 8 concurrent post_stage calls produce 8 lines"

_check="$(python3 -c "
import json
bad = 0
with open('.talos/events.jsonl') as f:
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

finish
