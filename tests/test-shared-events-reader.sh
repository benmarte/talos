#!/usr/bin/env bash
# test-shared-events-reader.sh -- one shared events-log reader, scripts/talos_events.py (#1019).
# The JSONL scanners (pipeline-events.sh, pipeline-hooks.sh, pipeline-eval.sh,
# talos-map.py, talos-usage.py, pipeline-spend-format.py) share one tolerant reader and
# one set of number helpers; nothing they print changes. The `(same)` criteria compare
# against tests/fixtures/shared-events-reader/*.out, captured from the scripts as they
# stood before the refactor (regenerate with TALOS_REGEN_FIXTURES=1 only for a change
# of output on purpose).
#   AC1 (same) talos.sh map renders the same page from the fixture log
#   AC2 (same) cost, cost --line, --markdown, --json, list and scoreboard give the same output
#   AC3 (same) talos-usage.py (import-usage) and pipeline-spend-format.py (the session line) are unchanged
#   AC4 (same) a truncated, a non-JSON, a non-object and a blank line: the same in every consumer
#   AC5 install.sh --global ships scripts/talos_events.py; map and cost run from the installed copy
#   AC6 (prose) no consumer keeps its own JSONL scan loop or `def num`; the CHANGELOG notes it
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

GOLD="$TALOS_ROOT/tests/fixtures/shared-events-reader"
TALOS="$TALOS_ROOT/scripts/talos.sh"
unset TALOS_TRANSCRIPT_PATH TALOS_USAGE_HOOK
# A stage session exports the repository and run identity (PIPELINE_REPO overrides vcs.repo,
# so the map would be named for the real repository, not acme/widget): the page must not depend on them.
unset PIPELINE_REPO PIPELINE_RUN_ID TALOS_PR TALOS_QA_CI_RC TALOS_RUN_STARTED TALOS_EFFORT TALOS_STATUS_READ_DEADLINE
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
STATE="$SANDBOX/.git/talos"
LOG="$STATE/events.jsonl"
MAP="$HOME/.talos/maps/acme-widget.html"
mkdir -p "$STATE" "$HOME/.cache/talos/meta" "$SANDBOX/bin"
printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"
for c in curl glab az; do cp "$SANDBOX/bin/gh" "$SANDBOX/bin/$c"; done
NOW_EPOCH=1781524800   # 2026-06-15T12:00:00Z

# make_log <clean|dirty>: the fixture events log. `dirty` is the clean one with a
# truncated line, a non-JSON line, a non-object line and blank lines in between.
make_log() {
  python3 -I -c '
import json, sys
mode, path = sys.argv[1:3]
def ev(event, role, issue, pr, verdict, ts, **kw):
    d = {"event": event, "role": role, "issue": issue, "pr": pr, "verdict": verdict,
         "tokens": None, "tool_uses": None, "duration_s": None, "model": "sonnet", "ts": ts}
    d.update(kw)
    return json.dumps(d)
rows = [
    ev("validator", "validator", 21, None, "CONFIRMED", "2026-06-15T09:00:00Z", tokens=1000, tool_uses=3, duration_s=40),
    ev("pm", "pm", 21, None, "SPEC", "2026-06-15T09:05:00Z", tokens=2000, tool_uses=4, duration_s=60),
    ev("stage_complete", "developer", 21, 31, "PR_OPENED", "2026-06-15T09:30:00Z", tokens=50000, tool_uses=60, duration_s=900,
       cache_read_tokens=400000, cache_write_tokens=20000),
    ev("developer", "developer", 21, 31, "OPENED", "2026-06-15T09:30:05Z"),
    ev("reviewer", "reviewer", 21, 31, "APPROVED", "2026-06-15T09:50:00Z", tokens=12000, tool_uses=9, duration_s=120),
    ev("qa", "qa", 21, 31, "PASS", "2026-06-15T10:10:00Z", tokens="n/a", tool_uses=5, duration_s=200),
    ev("hand_note", "orchestrator", 21, 31, None, "2026-06-15T10:11:00Z", kind="unblocked"),
    ev("merged", "orchestrator", 21, 31, "merged", "2026-06-15T10:20:00Z"),
    ev("run_end", "orchestrator", None, None, None, "2026-06-15T10:21:00Z", stage="qa", reason="done"),
    ev("developer", "developer", 22, None, "BLOCKED", "2026-06-15T11:00:00Z", tokens=-5, tool_uses=2, duration_s=30),
    ev("usage", "other", 22, None, None, "2026-06-15T11:30:00Z", tokens=700, agent_id="zz1", tool_uses=1, duration_s=10),
    ev("stage_start", "developer", 23, None, None, "2026-06-15T11:40:00Z"),
    json.dumps({"event": "developer", "role": "developer", "issue": "24", "ts": "2026-06-15T11:45:00Z", "verdict": "PR_OPENED", "tokens": 4000}),
]
bad = ["{\"event\": \"qa\", \"role\": \"qa\", \"issue\": 21, \"tok", "this is not json", "[1, 2, 3]", "", "   "]
out = []
for i, r in enumerate(rows):
    out.append(r)
    if mode == "dirty" and i % 3 == 1:
        out.append(bad[(i // 3) % len(bad)])
if mode == "dirty":
    out += bad
with open(path, "w") as f:
    f.write("\n".join(out) + "\n")' "$1" "$LOG"
  python3 -I -c '
import json, sys
json.dump({"ts": "2026-06-15T11:50:00Z", "run": {"active": False}, "collect": {}}, open(sys.argv[1] + "/state.json", "w"))' "$STATE"
}

# transcript <file>: a session transcript with a truncated line and a non-JSON line in it.
transcript() {
  python3 -I -c '
import json, sys
def row(i, o, cw, cr, mid, ts):
    return json.dumps({"type": "assistant", "timestamp": ts, "message": {"id": mid, "role": "assistant", "usage": {
        "input_tokens": i, "output_tokens": o, "cache_creation_input_tokens": cw, "cache_read_input_tokens": cr}}})
lines = [row(10, 5, 100, 1000, "m1", "2026-06-15T10:00:00Z"), "{\"type\": \"assist", "not json",
         row(10, 50, 100, 1000, "m1", "2026-06-15T10:00:01Z"), "", row(20, 30, 0, 500, "m2", "2026-06-15T10:02:00Z")]
open(sys.argv[1], "w").write("\n".join(lines) + "\n")' "$1"
}

# usage_fixture: a registry holding one repository, a subagent transcript and a log with bad lines.
usage_fixture() {
  UFX="$SANDBOX/ufx"
  rm -rf "${UFX:?}"
  mkdir -p "$UFX/home/maps" "$UFX/repo" "$UFX/sess/subagents"
  git -C "$UFX/repo" init -q -b main && git -C "$UFX/repo" commit -q --allow-empty -m init
  UROOT="$(cd "$UFX/repo" && pwd -P)"
  mkdir -p "$UROOT/.git/talos"
  python3 -I -c '
import json, sys
home, root, sess = sys.argv[1:4]
json.dump({"owner/repo": {"root": root, "file": "owner-repo.html", "updated": "2026-01-01T00:00:00Z", "line": "x"}}, open(home + "/maps/index.json", "w"))
def row(role, content, ts, extra=None):
    m = {"role": role, "content": content}
    m.update(extra or {})
    return json.dumps({"type": role, "timestamp": ts, "cwd": "/nowhere", "message": m})
u = lambda i, o: {"usage": {"input_tokens": i, "output_tokens": o, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 7}, "id": "m%d" % i}
lines = [row("user", "You are the Developer. Implement the spec in owner/repo for (#12) now.", "2026-06-15T10:00:00Z"),
         "{\"type\": \"assis", row("assistant", [{"type": "tool_use", "id": "t", "name": "Bash", "input": {}}], "2026-06-15T10:00:10Z", u(10, 5)),
         "not json at all", "", row("assistant", [], "2026-06-15T10:01:00Z", u(20, 30))]
open(sess + "/subagents/agent-a1.jsonl", "w").write("\n".join(lines) + "\n")
json.dump({"agentType": "talos:developer", "description": "implement"}, open(sess + "/subagents/agent-a1.meta.json", "w"))
open(root + "/.git/talos/events.jsonl", "w").write(
    "{\"event\": \"pr_opened\", \"role\": \"developer\", \"issue\": 12, \"pr\": 40, \"ts\": \"2026-06-15T09:00:00Z\"}\n"
    "{\"event\": \"usage\", \"role\": \"qa\", \"issue\": 1, \"agent_id\": \"seen-before\", \"trun\n"
    "garbage\n\n[]\n"
    "{\"event\": \"usage\", \"role\": \"qa\", \"issue\": 1, \"agent_id\": \"seen-before\", \"ts\": \"2026-06-15T09:30:00Z\"}\n")' "$UFX/home" "$UROOT" "$UFX/sess"
}

norm() { sed -e "s#$SANDBOX#<SB>#g" -e "s#/private<SB>#<SB>#g"; }

# capture <label> <clean|dirty> <scripts dir>: every consumer's output on the fixture log, into $OUTD/<label>-<name>.out.
capture() {
  local label="$1" mode="$2" sd="$3" args pr
  make_log "$mode"
  cp "$LOG" "$SANDBOX/log.orig"
  transcript "$SANDBOX/session.jsonl"
  rm -f "$MAP"
  TALOS_NOW="$NOW_EPOCH" PATH="$SANDBOX/bin:$PATH" bash "$sd/talos.sh" map > "$SANDBOX/map.stdout" 2>&1
  { cat "$MAP" 2>/dev/null || true; } | norm > "$OUTD/$label-map.out"
  {
    for args in "cost" "cost --json" "cost --issue 21 --line" "cost --issue 21 --pr 31 --line" "cost --issue 21 --markdown" \
                "cost --issue 21 --pr 31 --markdown" "list" "list --json --issue 21" "list --role developer --last 2" "tail" \
                "scoreboard" "scoreboard --json"; do
      printf '$ %s\n' "$args"
      # shellcheck disable=SC2086
      PATH="$SANDBOX/bin:$PATH" bash "$sd/pipeline-events.sh" $args 2>&1
      echo "rc=$?"
    done
  } | norm > "$OUTD/$label-cost.out"
  TALOS_TRANSCRIPT_PATH="$SANDBOX/session.jsonl" bash "$sd/pipeline-events.sh" cost --summary --issue 21 --issue 22 --issue 24 2>&1 | norm > "$OUTD/$label-spend.out"
  : > "$SANDBOX/hook.out"
  for pr in 31 99; do
    bash "$sd/pipeline-hooks.sh" hand_event merged orchestrator 21 --pr "$pr" --once >> "$SANDBOX/hook.out" 2>&1
    echo "rc=$? pr=$pr lines=$(wc -l < "$LOG" | tr -d ' ')" >> "$SANDBOX/hook.out"
  done
  norm < "$SANDBOX/hook.out" > "$OUTD/$label-hooks.out"
  cp "$SANDBOX/log.orig" "$LOG"
  { PATH="$SANDBOX/bin:$PATH" bash "$sd/pipeline-eval.sh" candidates 2>&1; echo "rc=$?"; } | norm > "$OUTD/$label-eval.out"
}

# usage_capture <label> <scripts dir>: import-usage twice over the fixture, the second run reading the log the first wrote.
usage_capture() {
  local run
  usage_fixture
  {
    for run in first second; do
      printf '$ %s\n' "$run"
      (cd "$UFX" && TALOS_HOME="$UFX/home" bash "$2/pipeline-events.sh" import-usage --session-dir "$UFX/sess" 2>&1; echo "rc=$?")
      grep -c . "$UROOT/.git/talos/events.jsonl"
    done
    python3 -I -c '
import json, sys
for l in open(sys.argv[1]):
    try:
        e = json.loads(l)
    except ValueError:
        continue
    if isinstance(e, dict) and e.get("agent_id") == "a1":
        print(json.dumps(e, sort_keys=True))' "$UROOT/.git/talos/events.jsonl"
  } | norm > "$OUTD/$1-usage.out"
}

# compare <names...> -- <ac> <what>: the captured outputs against the golden ones.
compare() {
  local names=() n ok=1
  while [ "$1" != "--" ]; do names+=("$1"); shift; done
  shift
  for n in "${names[@]}"; do
    if [ -n "${TALOS_REGEN_FIXTURES:-}" ]; then cp "$OUTD/$n.out" "$GOLD/$n.out"; continue; fi
    if [ "$(cat "$OUTD/$n.out")" != "$(cat "$GOLD/$n.out" 2>/dev/null)" ]; then
      ok=0
      printf 'differs: %s\n' "$n" >&2
      diff "$GOLD/$n.out" "$OUTD/$n.out" 2>&1 | head -10 >&2
    fi
  done
  assert_eq "1" "$ok" "$1"
}

OUTD="$SANDBOX/out"
mkdir -p "$OUTD" "$GOLD"
capture clean clean "$TALOS_ROOT/scripts"
capture dirty dirty "$TALOS_ROOT/scripts"
usage_capture clean "$TALOS_ROOT/scripts"
usage_capture dirty "$TALOS_ROOT/scripts"

compare clean-map -- "AC1 talos.sh map renders the same page from the fixture log"
compare clean-cost -- "AC2 cost, cost --line, --markdown, --json, list, tail and scoreboard give the same output"
compare clean-usage -- "AC3 import-usage (talos-usage.py) writes the same event and prints the same counts"
compare clean-spend -- "AC3 the session line (pipeline-spend-format.py) is unchanged"
compare dirty-map dirty-cost dirty-spend dirty-usage dirty-hooks dirty-eval -- \
  "AC4 a log with a truncated, a non-JSON, a non-object and a blank line gives the same results in every consumer"
compare clean-hooks clean-eval -- "AC4 hand_event --once and eval candidates on the clean log are unchanged"

# AC5: the installed copy.
G="$SANDBOX/ginstall"
mkdir -p "$G"
(cd "$TALOS_ROOT" && HOME="$G" CLAUDE_CONFIG_DIR="$G/.claude" TALOS_HOME="$G/.talos" bash install.sh --global > "$SANDBOX/install.out" 2>&1)
IH="$G/.talos"
assert_file_exists "$IH/scripts/talos_events.py" "AC5 install.sh --global ships scripts/talos_events.py"
if [ -f "$IH/scripts/talos_events.py" ]; then
  OUTD="$SANDBOX/inst"
  mkdir -p "$OUTD"
  capture clean clean "$IH/scripts"
  assert_eq "$(cat "$GOLD/clean-map.out")" "$(cat "$OUTD/clean-map.out")" "AC5 talos.sh map run from the installed copy renders the same page"
  assert_eq "$(cat "$GOLD/clean-cost.out")" "$(cat "$OUTD/clean-cost.out")" "AC5 pipeline-events.sh cost from the installed copy gives the same output"
else
  assert_eq "installed" "missing" "AC5 talos.sh map run from the installed copy renders the same page"
  assert_eq "installed" "missing" "AC5 pipeline-events.sh cost from the installed copy gives the same output"
fi

# AC6: no consumer keeps its own scan loop or def num; the module and the CHANGELOG line exist.
for f in pipeline-events.sh pipeline-hooks.sh pipeline-eval.sh talos-map.py talos-usage.py pipeline-spend-format.py; do
  assert_eq "0" "$(grep -c 'def num(' "$TALOS_ROOT/scripts/$f")" "AC6 $f has no def num"
  assert_eq "0" "$(grep -c 'json\.loads(line)' "$TALOS_ROOT/scripts/$f")" "AC6 $f has no json.loads(line) scan loop of its own"
done
assert_file_exists "$TALOS_ROOT/scripts/talos_events.py" "AC6 the shared module exists"
assert_contains "$(sed -n '/^## \[Unreleased\]/,/^## \[[0-9]/p' "$TALOS_ROOT/CHANGELOG.md")" "talos_events.py" "AC6 the CHANGELOG notes the shared reader"
finish
