#!/usr/bin/env bash
# test-import-usage-911.sh -- `pipeline-events.sh import-usage`, the plugin's
# SubagentStop hook and the readers of the `usage` event (#911). Each assertion
# is named by the spec's criterion id. AC14 and AC15 are prose (docs, changelog).
#   AC1  import over five fixture subagents: events, counts, token measure
#   AC2  cwd attribution (a linked worktree); a brief naming two repos is no-repo
#   AC3  a second run writes nothing and reports seen=
#   AC4  --dry-run prints the same counts and writes nothing
#   AC5  not-subagent, --since, --repo, usage errors
#   AC6  hooks/hooks.json registers one SubagentStop command hook
#   AC7  the hook: Talos roles import, anything else is ignored, TALOS_USAGE_HOOK=0
#   AC8  the hook's fallback to the newest subagent transcript of the session
#   AC9  no double count with a talos.sh run stage_complete
#   AC10 the map, cost and status line sum usage events; none is a stage or activity
#   AC11 a Stuck issue stays Stuck after a usage event
#   AC12 no token-bearing event: the tile reads "not recorded", tokens_7d is null
#   AC13 the usage event keeps post_stage's key order and value rules
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

EV="$TALOS_ROOT/scripts/pipeline-events.sh"
HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
HOOK="$TALOS_ROOT/scripts/talos-usage-hook.sh"
MAPPY="$TALOS_ROOT/scripts/talos-map.py"
STATUS="$TALOS_ROOT/scripts/talos-status.sh"
unset PIPELINE_CONFIG TALOS_ROLE TALOS_RUN_STARTED TALOS_RUN_PID TALOS_USAGE_HOOK GIT_DIR GIT_WORK_TREE
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid

FX="$SANDBOX/fx"
TH="$FX/home"
mkdir -p "$FX" "$TH/maps"
export TALOS_HOME="$TH"

mkrepo() {  # <dir>: a repository with one commit
  mkdir -p "$1" && git -C "$1" init -q -b main && git -C "$1" commit -q --allow-empty -m init
}
A="$FX/repoA"; B="$FX/repoB"; D="$FX/repoD"; E="$FX/repoE"; F="$FX/repoF"; G="$FX/repoG"; C="$FX/repoC"
for r in "$A" "$B" "$C" "$D" "$E" "$F" "$G"; do mkrepo "$r"; done
git -C "$A" worktree add -q -b wt "$FX/repoA-wt"
for r in A B C D E F G; do eval "$r=\"\$(cd \"\$$r\" && pwd -P)\""; done
WT="$(cd "$FX/repoA-wt" && pwd -P)"
LOGA="$A/.git/talos/events.jsonl"; LOGB="$B/.git/talos/events.jsonl"; LOGC="$C/.git/talos/events.jsonl"
LOGD="$D/.git/talos/events.jsonl"; LOGE="$E/.git/talos/events.jsonl"; LOGF="$F/.git/talos/events.jsonl"
LOGG="$G/.git/talos/events.jsonl"
for r in "$A" "$B" "$C" "$D" "$E" "$F" "$G"; do mkdir -p "$r/.git/talos"; done

python3 -I -c '
import json, sys
th, a, b, d, e, f, g = sys.argv[1:8]
reg = {s: {"root": r, "file": s.replace("/", "-") + ".html", "updated": "2026-01-01T00:00:00Z", "line": "x"}
       for s, r in (("owner/repoA", a), ("owner/repoB", b), ("owner/repoD", d), ("owner/repoE", e), ("owner/repoF", f), ("owner/repoG", g))}
json.dump(reg, open(th + "/maps/index.json", "w"))' "$TH" "$A" "$B" "$D" "$E" "$F" "$G"

NOW="$(python3 -I -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
printf '{"event":"pr_opened","role":"developer","issue":13,"pr":40,"repo":"owner/repoA","ts":"%s"}\n' "$NOW" > "$LOGA"
printf '{"event":"stage_complete","role":"developer","issue":12,"pr":null,"verdict":"PR_OPENED","tokens":1000,"ts":"%s"}\n' "$NOW" > "$LOGD"

# gen: <dir> <id> <agentType|-> <description> <brief> <cwd> [no-cache-read]
# One subagent: agent-<id>.jsonl and agent-<id>.meta.json. Message m1 streams
# twice (same id, the second line final), m2 once: input 30, output 80, cache
# write 100, cache read 1500, tokens 210, two tool_use blocks, 125 s.
cat > "$FX/gen.py" <<'TALOS_GENPY_x7Kq2mZ'
import json, os, sys
d, aid, atype, desc, brief, cwd = sys.argv[1:7]
nocache = len(sys.argv) > 7 and sys.argv[7] == "no-cache-read"
sub = os.path.join(d, "subagents")
os.makedirs(sub, exist_ok=True)
def line(role, content, ts, msg=None):
    m = {"role": role, "content": content}
    m.update(msg or {})
    return {"type": role, "timestamp": ts, "cwd": cwd, "message": m}
def usage(i, o, cw, cr):
    u = {"input_tokens": i, "output_tokens": o, "cache_creation_input_tokens": cw}
    if not nocache:
        u["cache_read_input_tokens"] = cr
    return {"usage": u}
tool = lambda n: {"type": "tool_use", "id": "t" + n, "name": "Bash", "input": {}}
rows = [
    line("user", brief, "2026-11-10T10:00:00Z"),
    line("assistant", [tool("1")], "2026-11-10T10:00:10Z", dict(usage(10, 5, 100, 1000), id="m1", model="claude-sonnet-5-5")),
    line("assistant", [tool("1")], "2026-11-10T10:00:11Z", dict(usage(10, 50, 100, 1000), id="m1", model="claude-sonnet-5-5")),
    line("user", [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}], "2026-11-10T10:00:30Z"),
    line("assistant", [tool("2")], "2026-11-10T10:02:05Z", dict(usage(20, 30, 0, 500), id="m2", model="claude-sonnet-5-5")),
]
with open(os.path.join(sub, "agent-%s.jsonl" % aid), "w") as f:
    f.write("".join(json.dumps(r) + "\n" for r in rows))
if atype != "-":
    json.dump({"agentType": atype, "description": desc}, open(os.path.join(sub, "agent-%s.meta.json" % aid), "w"))
TALOS_GENPY_x7Kq2mZ
gen() { python3 -I "$FX/gen.py" "$@"; }

S1="$FX/s1"
gen "$S1" a1 talos:developer "implement" "You are the Developer. Implement the spec in owner/repoA for (#12) now." "$FX/elsewhere"
gen "$S1" b1 general-purpose "#40 fix round 1" "Fix the review findings in owner/repoA." "$FX/elsewhere"
gen "$S1" c1 talos:qa "verify" "Verify the PR for owner/repoB, issue #5, and report." "$FX/elsewhere"
gen "$S1" d1 general-purpose "misc" "Do something that names no repository." "$FX/elsewhere"
gen "$S1" e1 talos:docs "docs" "Update the docs for owner/repoA." "$FX/elsewhere"

count() {  # <log> <python condition over e> -> how many events match
  python3 -I -c '
import json, sys
n = 0
try:
    for l in open(sys.argv[1]):
        try:
            e = json.loads(l)
        except ValueError:
            continue
        if isinstance(e, dict) and eval(sys.argv[2]):
            n += 1
except OSError:
    pass
print(n)' "$1" "$2"
}
usage_n() { count "$1" 'e.get("event") == "usage"'; }
sum() { cat "$@" 2>/dev/null | cksum; }
imp() {  # <args...>: stdout in $OUT, status in $RC
  OUT="$(cd "${CWD:-$FX}" && bash "$EV" import-usage "$@" 2> "$FX/err")"; RC=$?
}

# ── AC4 (first: the logs are still untouched): --dry-run ───────────────────────
BEFORE="$(sum "$LOGA" "$LOGB")"
imp --session-dir "$S1" --dry-run
assert_eq "imported=3 skipped=2 (no-repo=1 no-issue=1 seen=0 not-subagent=0) tokens=630" "$OUT" "AC4 --dry-run prints the counts a real run prints"
assert_eq "$BEFORE" "$(sum "$LOGA" "$LOGB")" "AC4 --dry-run leaves both logs byte-identical"
assert_eq "0" "$RC" "AC4 --dry-run exits 0"

# ── AC1: the import ──────────────────────────────────────────────────────────
imp --session-dir "$S1"
assert_eq "imported=3 skipped=2 (no-repo=1 no-issue=1 seen=0 not-subagent=0) tokens=630" "$OUT" "AC1 the counts line"
assert_eq "1" "$(count "$LOGA" 'e.get("event") == "usage" and e["issue"] == 12 and e["role"] == "developer" and e["pr"] is None')" "AC1 one usage event for 12, role developer, into A's log"
assert_eq "1" "$(count "$LOGA" 'e.get("event") == "usage" and e["issue"] == 13 and e["role"] == "other" and e["pr"] == 40')" "AC1 one usage event for 13, role other, pr 40, into A's log"
assert_eq "2" "$(usage_n "$LOGA")" "AC1 A's log holds exactly two usage events"
assert_eq "1" "$(count "$LOGB" 'e.get("event") == "usage" and e["issue"] == 5 and e["role"] == "qa"')" "AC1 one usage event into B's log"
assert_eq "1" "$(usage_n "$LOGB")" "AC1 B's log holds exactly one"
assert_eq '[210, 30, 80, 100, 1500, 2, 125, "a1", "claude-sonnet-5-5", "claude", "transcript", "owner/repoA", "2026-11-10T10:02:05Z"]' \
  "$(grep '"a1"' "$LOGA" | head -1 | python3 -I -c '
import json, sys
e = json.load(sys.stdin)
print(json.dumps([e["tokens"], e["input_tokens"], e["output_tokens"], e["cache_write_tokens"], e["cache_read_tokens"], e["tool_uses"],
                  e["duration_s"], e["agent_id"], e["model"], e["runner"], e["source"], e["repo"], e["ts"]]))' 2>&1)" \
  "AC1 tokens is input + output + cache write once per message id; the figures, model, runner, source and ts hold the fixture's values"

# ── AC3: idempotent ──────────────────────────────────────────────────────────
BEFORE="$(sum "$LOGA" "$LOGB")"
imp --session-dir "$S1"
assert_eq "imported=0 skipped=5 (no-repo=1 no-issue=1 seen=3 not-subagent=0) tokens=0" "$OUT" "AC3 the second run imports nothing and reports seen=3"
assert_eq "$BEFORE" "$(sum "$LOGA" "$LOGB")" "AC3 the second run appends nothing"

# ── AC2: cwd attribution; two repositories named ─────────────────────────────
S2="$FX/s2"
gen "$S2" f1 general-purpose "misc" "Tidy up; closes #12." "$WT/sub/dir"
gen "$S2" g1 general-purpose "misc" "Compare owner/repoA with owner/repoB, closes #12." "$FX/elsewhere"
imp --session-dir "$S2"
assert_eq "imported=1 skipped=1 (no-repo=1 no-issue=0 seen=0 not-subagent=0) tokens=210" "$OUT" "AC2 one goes to A by cwd, the brief naming both repositories is no-repo"
assert_eq "1" "$(count "$LOGA" 'e.get("event") == "usage" and e.get("agent_id") == "f1" and e["role"] == "other"')" "AC2 a cwd inside A's linked worktree goes to A's log"
assert_eq "0" "$(count "$LOGB" 'e.get("agent_id") == "g1"')" "AC2 the brief naming both repositories is in no log"

# ── AC5: not-subagent, --since, --repo, usage errors ─────────────────────────
S5="$FX/s5"
gen "$S5" h1 talos:pm "pm" "You are the PM for owner/repoA, closes #12." "$FX/elsewhere"
cp "$S5/subagents/agent-h1.jsonl" "$S5/subagents/notes.jsonl"
BEFORE="$(sum "$LOGA" "$LOGB")"
imp --transcript "$S5/subagents/notes.jsonl"
assert_eq "imported=0 skipped=1 (no-repo=0 no-issue=0 seen=0 not-subagent=1) tokens=0" "$OUT" "AC5 a file not named agent-*.jsonl counts not-subagent"
assert_eq "$BEFORE" "$(sum "$LOGA" "$LOGB")" "AC5 not-subagent writes nothing"
imp --transcript "$S5/subagents/agent-h1.jsonl" --since 2099-01-01
assert_contains "$OUT" "imported=0" "AC5 --since skips a transcript whose last message is older"
assert_eq "0" "$(count "$LOGA" 'e.get("agent_id") == "h1"')" "AC5 --since writes nothing"
imp --transcript "$S5/subagents/agent-h1.jsonl" --since 2026-01-01
assert_contains "$OUT" "imported=1" "AC5 --since keeps a newer transcript"
S5C="$FX/s5c"
gen "$S5C" k1 talos:qa "qa" "Verify owner/repoC, issue #9." "$FX/elsewhere"
imp --transcript "$S5C/subagents/agent-k1.jsonl"
assert_contains "$OUT" "no-repo=1" "AC5 a repository that is neither in the registry nor given with --repo is no-repo"
CWD="$C" imp --transcript "$S5C/subagents/agent-k1.jsonl" --repo owner/repoC
assert_contains "$OUT" "imported=1" "AC5 --repo adds a candidate slug (rooted at the current checkout)"
assert_eq "1" "$(count "$LOGC" 'e.get("agent_id") == "k1" and e["issue"] == 9')" "AC5 the --repo event is in that checkout's log"
BEFORE="$(sum "$LOGA" "$LOGB" "$LOGC")"
imp --session-dir "$S1" --bogus; RC1=$RC
imp --session-dir; RC2=$RC
imp --since; RC3=$RC
imp; RC4=$RC
assert_eq "2 2 2 2" "$RC1 $RC2 $RC3 $RC4" "AC5 an unknown option, a missing value and no source exit 2"
assert_eq "$BEFORE" "$(sum "$LOGA" "$LOGB" "$LOGC")" "AC5 a usage error writes nothing"

# ── AC6: hooks/hooks.json ────────────────────────────────────────────────────
assert_eq '["SubagentStop", 1, 1, "command", "${CLAUDE_PLUGIN_ROOT}/scripts/talos-usage-hook.sh", true]' \
  "$(python3 -I -c '
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
ev = h["SubagentStop"]
hk = ev[0]["hooks"]
print(json.dumps([list(h)[0], len(ev), len(hk), hk[0]["type"], hk[0]["command"], isinstance(hk[0].get("timeout"), int)]))' "$TALOS_ROOT/hooks/hooks.json" 2>&1)" \
  "AC6 hooks/hooks.json is valid and registers one SubagentStop command hook with a timeout"

# ── AC7: the hook ────────────────────────────────────────────────────────────
S7="$FX/s7"
gen "$S7" q1 talos:qa "qa" "You are the QA agent for owner/repoA, closes #12." "$FX/elsewhere"
gen "$S7" q2 qa "qa" "You are the QA agent for owner/repoA, closes #12." "$FX/elsewhere"
gen "$S7" q3 general-purpose "x" "Please look at owner/repoA, closes #12." "$FX/elsewhere"
hook() {  # <stdin text>: stdout in $OUT, status in $RC, seconds in $SECS
  local t0; t0="$(wall_s)"
  OUT="$(cd "$FX" && printf '%s' "$1" | bash "$HOOK" 2> "$FX/err")"; RC=$?
  SECS="$(since_s "$t0")"
}
payload() {  # <agent_type> <agent_id> <path>
  python3 -I -c '
import json, sys
print(json.dumps({"session_id": "s", "hook_event_name": "SubagentStop", "agent_type": sys.argv[1], "agent_id": sys.argv[2],
                  "agent_transcript_path": sys.argv[3], "cwd": "/x"}))' "$@"
}
N0="$(usage_n "$LOGA")"
hook "$(payload talos:qa q1 "$S7/subagents/agent-q1.jsonl")"
assert_eq "0 " "$RC $OUT" "AC7 the hook for talos:qa exits 0 with empty stdout"
assert_eq "$((N0 + 1))" "$(usage_n "$LOGA")" "AC7 talos:qa appends one usage event"
assert_eq "1" "$(count "$LOGA" 'e.get("agent_id") == "q1" and e["role"] == "qa"')" "AC7 the event is the subagent's, role qa"
assert_eq "yes" "$(python3 -I -c 'import sys; print("yes" if float(sys.argv[1]) < 2 else "no")' "$SECS")" "AC7 the hook returns within 2 s"
hook "$(payload qa q2 "$S7/subagents/agent-q2.jsonl")"
assert_eq "$((N0 + 2))" "$(usage_n "$LOGA")" "AC7 a bare qa appends one usage event"
N1="$(usage_n "$LOGA")"
hook "$(payload general-purpose q3 "$S7/subagents/agent-q3.jsonl")"; R1="$RC$OUT"
hook "$(payload '' q3 "$S7/subagents/agent-q3.jsonl")"; R2="$RC$OUT"
hook 'this is {not json'; R3="$RC$OUT"
assert_eq "0 0 0" "$R1 $R2 $R3" "AC7 general-purpose, an empty agent_type and malformed JSON exit 0 with empty stdout"
assert_eq "$N1" "$(usage_n "$LOGA")" "AC7 those append nothing"
gen "$S7" q4 talos:qa "qa" "You are the QA agent for owner/repoA, closes #12." "$FX/elsewhere"
TALOS_USAGE_HOOK=0 hook "$(payload talos:qa q4 "$S7/subagents/agent-q4.jsonl")"
assert_eq "0 " "$RC $OUT" "AC7 TALOS_USAGE_HOOK=0 exits 0 with empty stdout"
assert_eq "$N1" "$(usage_n "$LOGA")" "AC7 TALOS_USAGE_HOOK=0 appends nothing"

# ── AC8: the fallback to the newest subagent transcript ──────────────────────
S8="$FX/s8"
gen "$S8" old1 talos:qa "qa" "You are the QA agent for owner/repoA, closes #12." "$FX/elsewhere"
gen "$S8" new1 talos:qa "qa" "You are the QA agent for owner/repoA, closes #12." "$FX/elsewhere"
touch -t 202611010000 "$S8/subagents/agent-old1.jsonl"
touch -t 202611020000 "$S8/subagents/agent-new1.jsonl"
: > "$S8.jsonl"
hook "$(python3 -I -c '
import json, sys
print(json.dumps({"agent_type": "talos:qa", "agent_id": "zzz", "transcript_path": sys.argv[1]}))' "$S8.jsonl")"
assert_eq "0 " "$RC $OUT" "AC8 the fallback hook exits 0 with empty stdout"
assert_eq "1 0" "$(count "$LOGA" 'e.get("agent_id") == "new1"') $(count "$LOGA" 'e.get("agent_id") == "old1"')" "AC8 with no agent_transcript_path the newest subagent transcript of the session is imported"

# ── AC9: no double count ─────────────────────────────────────────────────────
H9="$FX/h9"
gen "$S7" r1 talos:developer "dev" "You are the Developer for owner/repoD, closes #12." "$FX/elsewhere"
imp --transcript "$S7/subagents/agent-r1.jsonl"
assert_contains "$OUT" "imported=1" "AC9 importing a subagent for 12 adds one usage event"
assert_eq "1" "$(usage_n "$LOGD")" "AC9 one usage event in the log"
map_of() {  # <events> <slug> <home>: render the map the way talos.sh does
  python3 -I "$MAPPY" --events "$1" --state "$FX/no-state.json" --home "$3" --provider github --repo "$2" \
    --scripts "$TALOS_ROOT/scripts" --titles "$FX/titles" < /dev/null > /dev/null 2> "$FX/maperr"
}
reg() {  # <home> <slug> <python over e>
  python3 -I -c '
import json, sys
e = json.load(open(sys.argv[1] + "/maps/index.json")).get(sys.argv[2])
print(json.dumps(eval(sys.argv[3]), ensure_ascii=False))' "$1" "$2" "$3" 2>&1
}
mkdir -p "$FX/titles"
map_of "$LOGD" owner/repoD "$H9"
assert_eq "1210" "$(reg "$H9" owner/repoD 'e["tiles"]["tokens_7d"]')" "AC9 the map's tokens for #12 are the stage_complete and the usage event summed"
imp --transcript "$S7/subagents/agent-r1.jsonl"
hook "$(payload talos:developer r1 "$S7/subagents/agent-r1.jsonl")"
assert_eq "1" "$(usage_n "$LOGD")" "AC9 re-importing, and the hook firing for the same agent_id, add nothing"
map_of "$LOGD" owner/repoD "$H9"
assert_eq "1210" "$(reg "$H9" owner/repoD 'e["tiles"]["tokens_7d"]')" "AC9 the total does not change"
assert_contains "$(cat "$H9/maps/owner-repoD.html")" ">1k<" "AC9 the page shows #12's tokens"

# ── AC10: only usage events ──────────────────────────────────────────────────
ue() {  # <issue> <role> <tokens> <cache read> <agent id>
  printf '{"event":"usage","role":"%s","issue":%s,"pr":null,"repo":"owner/repoE","model":null,"runner":"claude","duration_s":9,"tokens":%s,"tool_uses":1,"input_tokens":1,"output_tokens":1,"cache_write_tokens":1,"cache_read_tokens":%s,"agent_id":"%s","source":"transcript","ts":"%s"}\n' \
    "$2" "$1" "$3" "$4" "$5" "$NOW"
}
{ ue 20 developer 300 5000 x20; ue 21 qa 200 2000 x21; } > "$LOGE"
H10="$FX/h10"
map_of "$LOGE" owner/repoE "$H10"
PAGE10="$(cat "$H10/maps/owner-repoE.html")"
assert_eq "500" "$(reg "$H10" owner/repoE 'e["tiles"]["tokens_7d"]')" "AC10 tiles.tokens_7d is the sum of the usage events"
assert_contains "$PAGE10" "<b>500</b><span>tokens" "AC10 the tokens tile shows the sum"
assert_contains "$PAGE10" "Top spend" "AC10 Top spend lists the issues"
assert_contains "$PAGE10" ">300<" "AC10 an issue's tokens are its usage events' sum"
assert_not_contains "$PAGE10" "Activity" "AC10 no usage event is an Activity row"
assert_eq "0" "$(printf '%s' "$PAGE10" | grep -o 'class="s [drfx]"' | wc -l | tr -d ' ')" "AC10 no usage event marks a stage-bar segment"
COST="$(cd "$E" && bash "$EV" cost --json)"
assert_eq "[500, 7000]" "$(printf '%s' "$COST" | python3 -I -c 'import json, sys; t = json.load(sys.stdin)["total"]; print(json.dumps([t["tokens"], t["cache_read_tokens"]]))' 2>&1)" "AC10 pipeline-events.sh cost counts the tokens and the cache reads"
STAT="$(cd "$E" && printf '' | bash "$STATUS" --line 2> /dev/null)"
assert_contains "$STAT" "cache read 2k" "AC10 the status line counts the issue's cache reads"
assert_contains "$STAT" "200" "AC10 the status line counts the issue's tokens"

# ── AC11: a Stuck issue stays Stuck ──────────────────────────────────────────
SD11="$FX/sd11"; mkdir -p "$SD11"
T1="$(python3 -I -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=40)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
python3 -I -c '
import json, sys
json.dump({"ts": sys.argv[2], "run": {}, "collect": {"prs": [], "queued": [], "inflight": [], "held": [], "blocked": [["issue", 30]], "capped": [], "owners": []},
           "collect_ts": sys.argv[2]}, open(sys.argv[1] + "/state.json", "w"))' "$SD11" "$T1"
ue 30 developer 100 0 x30 > "$LOGF"
H11="$FX/h11"
python3 -I "$MAPPY" --events "$LOGF" --state "$SD11/state.json" --home "$H11" --provider github --repo owner/repoF \
  --scripts "$TALOS_ROOT/scripts" --titles "$FX/titles" < /dev/null > /dev/null 2>&1
assert_eq "1" "$(reg "$H11" owner/repoF 'e["tiles"]["needs"]')" "AC11 an issue Stuck in the collect stays Stuck after a later usage event"

# ── AC12: an unknown figure is never 0 ───────────────────────────────────────
printf '{"event":"developer","role":"developer","issue":40,"pr":null,"verdict":"PR_OPENED","tokens":null,"ts":"%s"}\n' "$NOW" > "$LOGG"
H12="$FX/h12"
map_of "$LOGG" owner/repoG "$H12"
assert_eq "null" "$(reg "$H12" owner/repoG 'e["tiles"]["tokens_7d"]')" "AC12 with no token-bearing event tiles.tokens_7d is null"
TILE="$(python3 -I -c '
import re, sys
m = re.search(r"<div class=\"kpi\"><b>[^<]*</b><span>[^<]*tokens[^<]*</span></div>", open(sys.argv[1]).read())
print(m.group(0) if m else "<none>")' "$H12/maps/owner-repoG.html")"
assert_contains "$TILE" "<b>—</b>" "AC12 the tokens tile reads —"
assert_contains "$TILE" "not recorded" "AC12 the tokens tile says not recorded"
printf '{"event":"developer","role":"developer","issue":41,"pr":null,"verdict":"PR_OPENED","tokens":700,"ts":"%s"}\n' "$NOW" >> "$LOGG"
map_of "$LOGG" owner/repoG "$H12"
assert_eq "700" "$(reg "$H12" owner/repoG 'e["tiles"]["tokens_7d"]')" "AC12 with one token-bearing event the tile stays the sum"

# ── AC13: post_stage's key order and value rules ─────────────────────────────
PS="$FX/ps.jsonl"
( cd "$D" && bash "$HOOKS" post_stage developer developer 12 --pr 3 --model m --runner claude --duration-s 5 --tokens 9 --tool-uses 2 \
    --input-tokens 1 --output-tokens 2 --cache-write-tokens 3 --cache-read-tokens 4 ) > /dev/null 2>&1
tail -1 "$LOGD" > "$PS"
S13="$FX/s13"
gen "$S13" n1 talos:developer "dev" "You are the Developer for owner/repoE, closes #12." "$FX/elsewhere" no-cache-read
imp --transcript "$S13/subagents/agent-n1.jsonl"
assert_eq "ok" "$(python3 -I -c '
import json, sys
ps = json.loads(open(sys.argv[1]).readline())
us = [json.loads(l) for l in open(sys.argv[2]) if "\"n1\"" in l][0]
shared = [k for k in ps if k in us]
if [k for k in us if k in ps] != shared:
    print("order", shared, [k for k in us if k in ps]); sys.exit()
ints = ["issue", "duration_s", "tokens", "tool_uses", "input_tokens", "output_tokens", "cache_write_tokens"]
bad = [k for k in ints if not (isinstance(us[k], int) and not isinstance(us[k], bool))]
if bad or us["cache_read_tokens"] is not None or us["pr"] is not None:
    print("values", bad, us.get("cache_read_tokens"), us["pr"]); sys.exit()
print("ok")' "$PS" "$LOGE" 2>&1)" "AC13 the shared keys keep post_stage's order; integers are numbers and a missing figure is null"

finish
