#!/usr/bin/env bash
# test-code-driven-default.sh -- /talos:pipeline starts the code driver (#602).
#
# The playbook's default flow is Step 0, one `talos.sh run`, then one documented
# action per driver end line. The LLM-per-stage loop is read only when
# `talos.sh env` prints ORCHESTRATOR=llm. One test per criterion of the spec:
#   AC1  the execution.orchestrator table row and the default ORCHESTRATOR=code
#   AC2  llm in any letter case; any other value is code plus one stderr line
#   AC3  the file provider and the planner force llm, with one stderr line
#   AC4  code prints no ref= line; llm prints ref=llm-loop first, then main's
#   AC5  SKILL.md is the default flow only, at most 12,000 bytes
#   AC6  one fenced start command; a stage's final message never reaches the
#        stdout of `talos.sh run`
#   AC7  one end-state table, every end state of the talos.sh header in one row
#   AC8  the run section of the header lists every reason run can end on
#   AC9  the loop lives in refs/llm-loop.md plus continuation refs
#   AC10 README, docs/reference.md and the setup skill name the key
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

TALOS="$TALOS_ROOT/scripts/talos.sh"
SKILL_MD="$TALOS_ROOT/skills/pipeline/SKILL.md"
REFS="$TALOS_ROOT/skills/pipeline/refs"
ERR="$SANDBOX/stderr"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0

# ── AC5: SKILL.md is the default flow only ───────────────────────────────────
skill="$(cat "$SKILL_MD")"
assert_contains "$skill" "talos.sh run" "AC5 SKILL.md starts the driver (talos.sh run)"
for verb in next done prompt gate docs-gate post-merge; do
  assert_not_contains "$skill" "talos.sh $verb" "AC5 SKILL.md has no per-stage call (talos.sh $verb)"
done
size="$(wc -c < "$SKILL_MD" | tr -d ' ')"
[ "$size" -le 12000 ]; assert_eq "0" "$?" "AC5 SKILL.md is at most 12,000 bytes ($size)"
# The heal of `sweep` (merged-but-open issues, the blocked-backlog notice) stays
# in the default flow: one call, in the driver section, before the start command.
assert_eq "1" "$(grep -c 'talos\.sh sweep' "$SKILL_MD")" "AC5 SKILL.md calls talos.sh sweep on one line"
head_line="$(grep -n '^## Start the driver' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
sweep_line="$(grep -n 'talos\.sh sweep' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
run_line="$(grep -n 'talos\.sh run 2> \.talos/run\.err' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
[ "${head_line:-99999}" -lt "${sweep_line:-0}" ] && [ "${sweep_line:-99999}" -lt "${run_line:-0}" ]
assert_eq "0" "$?" "AC5 the sweep call sits in the driver section, before the start command"
assert_contains "$(grep 'talos\.sh sweep' "$SKILL_MD")" "heal=" "AC5 the sweep line says what a heal= line needs"

# ── AC6 (first half): the start command is one fenced command ────────────────
# (Each python program is written to a file first: bash 3.2 mis-parses a heredoc
# that holds a backtick inside a command substitution.)
cat > "$SANDBOX/start-command.py" <<'TALOS_Hq4Zr8Lm2Vx9Kd'
import re
import sys

text = open(sys.argv[1]).read()
blocks = [b for b in re.findall(r"^```[a-z]*\n(.*?)^```", text, re.S | re.M) if "talos.sh run" in b]
if len(blocks) != 1:
    print("blocks=%d" % len(blocks))
    sys.exit(0)
lines = [l for l in blocks[0].split("\n") if l.strip()]
print("blocks=1 lines=%d runs=%d" % (len(lines), blocks[0].count("talos.sh run")))
print(lines[0] if lines else "")
TALOS_Hq4Zr8Lm2Vx9Kd
start="$(python3 -I "$SANDBOX/start-command.py" "$SKILL_MD")"
assert_eq "blocks=1 lines=1 runs=1" "$(printf '%s\n' "$start" | head -n 1)" \
  "AC6 the start command is one fenced command that runs talos.sh run once"
start_cmd="$(printf '%s\n' "$start" | sed -n 2p)"
assert_contains "$start_cmd" "talos.sh run 2> .talos/run.err" "AC6 the start command sends stderr to .talos/run.err"
case "$start_cmd" in
  *"&") fail "AC6 the start command is not backgrounded by hand" "$start_cmd" ;;
  *) pass "AC6 the start command is not backgrounded by hand" ;;
esac
assert_contains "$skill" "longest time limit" "AC6 the start command gets the harness's longest time limit"

# ── AC7: one end-state table, read against the talos.sh header ───────────────
cat > "$SANDBOX/end-states.py" <<'TALOS_Wn3Jb7Tc5Ys1Pg'
import re
import sys

src = open(sys.argv[1]).read().split("\n")
skill = open(sys.argv[2]).read()
ACTIONS = ("relay", "fix", "ask-owner", "restart")
bad = []

# The header: every comment line before the code starts.
hdr = []
for line in src[1:]:
    if not line.startswith("#"):
        break
    hdr.append(line)

def enum(name):
    for line in hdr:
        if line.startswith("# %s-reasons: " % name):
            return line.split(": ", 1)[1].split()
    bad.append("the header has no %s-reasons line" % name)
    return []

def sub_list(name, word):
    out, on = [], False
    for line in hdr:
        if line.startswith("# %s-reasons: " % name):
            on = True
            continue
        if on and line.strip() == "#":
            break
        if on and line.startswith("#   %s: " % word):
            out = line.split(": ", 1)[1].split()
    if not out:
        bad.append("the header has no `%s:` list under %s-reasons" % (word, name))
    return out

run_reasons = enum("run")
next_reasons = enum("next")
waits = sub_list("next", "wait")

# The gate section: its verdict words and the four redispatch reasons.
start = [i for i, l in enumerate(hdr) if l.startswith("# gate ")]
end = [i for i, l in enumerate(hdr) if l.startswith("# gate-reasons: ")]
gate = hdr[start[0]:end[0]] if start and end else []
verdicts = sorted(set(re.findall(r"verdict=([a-z-]+)", "\n".join(gate))))
redispatch = []
for line in gate:
    m = re.search(r"verdict=redispatch\s+reason=(.*)$", line)
    if m:
        redispatch = [part.split()[0] for part in m.group(1).split("|") if part.split()]
if len(redispatch) != 4:
    bad.append("the gate section names %d redispatch reasons, want 4: %s" % (len(redispatch), redispatch))
hdr_text = "\n".join(hdr)
for shape in ("action=ask-owner issue=<N> question=", "stop merged pr=<M>"):
    if shape not in hdr_text:
        bad.append("the header no longer shows `%s`" % shape)

# The end states, as the lines `run` prints, each with the action of decision 5.
want = []
for r in waits:
    want.append(("stop action=wait reason=%s" % r, "relay"))
want.append(("stop action=wait reason=lease retry_after_s=30", "relay"))
want.append(("stop action=wait reason=ci pr=7 issue=3", "relay"))
want.append(("stop action=ask-owner issue=3 question=which of the two layouts?", "ask-owner"))
for v in verdicts:
    if v == "merge":
        continue  # the run merges and goes on: not an end state
    elif v == "handoff":
        want.append(("stop verdict=handoff", "relay"))
    elif v == "wait":
        want.append(("stop verdict=wait reason=ci-pending", "relay"))
        want.append(("stop verdict=wait reason=approvals-missing missing=qa:pass", "relay"))
    elif v == "block":
        want.append(("stop verdict=block reason=forbidden-files", "relay"))
        want.append(("stop verdict=block", "relay"))
    elif v == "ask-owner":
        want.append(("stop verdict=ask-owner reason=design-decision stage=reviewer rounds=2 area=scripts/a.sh", "ask-owner"))
        want.append(("stop verdict=ask-owner reason=design-decision stage=security", "ask-owner"))
    elif v == "redispatch":
        for r in redispatch:
            line = "stop verdict=redispatch reason=%s" % r
            if r == "stale-approvals":
                line += " stale=qa,reviewer"
            want.append((line, "fix" if r == "merge-conflict" else "restart"))
    else:
        bad.append("gate verdict `%s` has no expected action in this test" % v)
want.append(("stop merged pr=7", "relay"))
for r in run_reasons:
    if r == "dispatch-failed":
        want.append(("reason=dispatch-failed role=qa", "restart"))
    elif r == "checkout-return-failed":
        want.append(("stop merged pr=7 reason=checkout-return-failed", "fix"))
    elif r == "iterations-exhausted":
        want.append(("stop reason=iterations-exhausted max=20", "restart"))
    else:
        want.append(("stop reason=%s" % r, "relay"))
        want.append(("stop reason=%s pr=7 issue=3" % r, "relay"))
for r in next_reasons:
    want.append(("stop reason=%s" % r.replace("<provider-verb>", "ready-pr"), "relay"))
want.append(("stop reason=a-reason-no-header-names", "relay"))
want.append(("a line the table does not know", "relay"))

# The table: the one whose header row is `Driver end line (stdout) | Action`.
heads = [m.start() for m in re.finditer(r"^\| *Driver end line \(stdout\) *\| *Action *\|$", skill, re.M)]
rows = []
if len(heads) != 1:
    bad.append("SKILL.md has %d end-state tables, want 1" % len(heads))
else:
    for line in skill[heads[0]:].split("\n")[2:]:
        if not line.startswith("|"):
            break
        cells = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]
        if len(cells) != 2:
            bad.append("row with %d cells: %s" % (len(cells), line[:80]))
            continue
        rows.append(cells)

def to_regex(pattern):
    out = []
    toks = pattern.split(" ")
    for i, tok in enumerate(toks):
        if tok == "..." and i == len(toks) - 1:
            return re.compile("^" + " ".join(out) + r"( .*)?$")
        piece = re.escape(tok)
        piece = re.sub(r"<text>", ".+", piece) if i == len(toks) - 1 else piece
        out.append(re.sub(r"<[A-Za-z-]+>", r"\\S+", piece))
    return re.compile("^" + " ".join(out) + "$")

table = []
for cell, action in rows:
    word = re.match(r"\**([a-z-]+)", action)
    word = word.group(1) if word else ""
    if word not in ACTIONS:
        bad.append("row `%s`: the action cell starts with `%s`, want one of %s" % (cell[:50], action[:20], "/".join(ACTIONS)))
    pats = [p for p in re.findall(r"`([^`]+)`", cell) if p.startswith("stop ") or p.startswith("reason=dispatch-failed")]
    table.append((cell, word, action, [to_regex(p) for p in pats]))

if table:
    cell, word, action, pats = table[-1]
    if pats:
        bad.append("the last row names a driver line (`%s`); it is the row for any other line" % cell[:50])
    if word != "relay":
        bad.append("the last row's action is `%s`, want relay" % word)
    if "no other action" not in action:
        bad.append("the last row does not say `no other action`")
    for other in ("fix", "ask-owner", "restart"):
        if re.search(r"\b%s\b" % other, action):
            bad.append("the last row also names `%s`" % other)

for line, action in want:
    hits = [t for t in table if any(p.match(line) for p in t[3])]
    # A row that opens with "every other" is the catch-all for a `stop reason=`.
    specific = [t for t in hits if not t[0].lower().startswith("every other")]
    if len(specific) > 1:
        bad.append("`%s` matches %d rows" % (line, len(specific)))
        continue
    row = specific[0] if specific else (hits[0] if hits else (table[-1] if table else None))
    if row is None:
        bad.append("`%s` has no row" % line)
    elif row[1] != action:
        bad.append("`%s`: the table says %s, decision 5 says %s" % (line, row[1] or "nothing", action))

if "ends on the same line" not in skill or "never tried twice" not in skill:
    bad.append("the guard (a restart or fix that ends on the same line is relayed, never tried twice) is not stated")

print("\n".join(bad))
print("STATES=%d ROWS=%d" % (len(want), len(rows)))
TALOS_Wn3Jb7Tc5Ys1Pg
ac7="$(python3 -I "$SANDBOX/end-states.py" "$TALOS" "$SKILL_MD")"
assert_eq "" "$(printf '%s\n' "$ac7" | sed '$d')" \
  "AC7 every driver end state of the talos.sh header has exactly one row with the action of decision 5"
ac7_states="$(printf '%s\n' "$ac7" | tail -n 1 | sed -n 's/^STATES=\([0-9]*\) .*/\1/p')"
[ "${ac7_states:-0}" -ge 40 ]; assert_eq "0" "$?" "AC7 the end states were read from the header (${ac7_states:-0} lines checked)"

# The human-merge wait (merge.auto false): `next` never answers merge, so the
# driver never runs the merge gate. Its row keeps the hand-off the loop had, and
# refs/human-merge.md finds the PR on the line `state --summary` really prints.
hm_row="$(grep -F '| `stop action=wait reason=human-merge` |' "$SKILL_MD")"
assert_eq "1" "$(printf '%s\n' "$hm_row" | grep -c .)" "AC7 the human-merge wait has its own row"
assert_contains "$hm_row" "| relay" "AC7 the human-merge row's action is relay"
assert_contains "$hm_row" "refs/human-merge.md" "AC7 the human-merge row names the hand-off of refs/human-merge.md"
hm_ref="$(cat "$REFS/human-merge.md")"
for needle in "stop action=wait reason=human-merge" "talos.sh state --summary" "talos.sh gate merge" "--handoff"; do
  assert_contains "$hm_ref" "$needle" "AC7 refs/human-merge.md holds \`$needle\` for the hand-off after the driver"
done
printf '{"prs": [{"n": 7, "issue": 3, "head": "h", "owner": false, "stage": "human-merge"}], "queued": [], "inflight": [], "blocked": [], "held": [], "owners": []}' \
  > "$SANDBOX/hm-state.json"
hm_where="$(python3 -I "$TALOS_ROOT/scripts/pipeline-next.py" where "$SANDBOX/hm-state.json" 2>/dev/null \
  | sed -n 's/^next: //p' | sed -e 's/#7/#<PR>/' -e 's/#3/#<N>/')"
assert_eq "wait (human-merge) on PR #<PR> (#<N>)" "$hm_where" "AC7 the summary names the PR that waits on a human merge (control)"
assert_contains "$hm_ref" "where=next: $hm_where" "AC7 refs/human-merge.md reads the PR from the line state --summary prints"

# A driver the harness stopped at its time limit prints no end line: one row.
assert_eq "1" "$(grep -c '^| no end line.*| restart' "$SKILL_MD")" \
  "AC7 a driver the harness stopped (no end line) has one row, restart"

# ── AC8: the run section of the header lists every reason run can end on ─────
cat > "$SANDBOX/run-reasons.py" <<'TALOS_Dk9Pf2Xs6Rv4Nb'
import re
import sys

src = open(sys.argv[1]).read().split("\n")
listed = []
for line in src:
    if line.startswith("# run-reasons: "):
        listed = line.split(": ", 1)[1].split()
        break
# The code of `run`: from _run_fail to the verb dispatch at the end of the file.
first = [i for i, l in enumerate(src) if l.startswith("_run_fail() {")]
last = [i for i, l in enumerate(src) if l.startswith('verb="${1:-}"')]
code = [l for l in src[first[0]:last[0]] if not l.lstrip().startswith("#")] if first and last else []
found = set()
for line in code:
    found.update(re.findall(r"_talos_stop ([a-z][a-z-]+)", line))
    found.update(re.findall(r'_talos_emit stop "(?:merged pr=\$_pr )?reason=([a-z][a-z-]+)', line))
    found.update(re.findall(r'_talos_emit reason "([a-z][a-z-]+)', line))
missing = sorted(found - set(listed))
print(" ".join(missing))
print("FOUND=%d" % len(found))
TALOS_Dk9Pf2Xs6Rv4Nb
ac8="$(python3 -I "$SANDBOX/run-reasons.py" "$TALOS")"
assert_eq "" "$(printf '%s\n' "$ac8" | sed -n 1p)" \
  "AC8 every reason the run code ends on is in the header's run-reasons line"
ac8_found="$(printf '%s\n' "$ac8" | sed -n 's/^FOUND=//p')"
[ "${ac8_found:-0}" -ge 12 ]; assert_eq "0" "$?" "AC8 the reasons were read from the run code (${ac8_found:-0} found)"
RUN_REASONS=" $(sed -n 's/^# run-reasons: //p' "$TALOS" | head -n 1) "
for r in iterations-exhausted stage-blocked provider-failed merge-failed state-unavailable; do
  assert_contains "$RUN_REASONS" " $r " "AC8 the run-reasons line names $r"
done

# ── AC9: the loop lives in refs/llm-loop.md plus continuation refs ───────────
assert_file_exists "$REFS/llm-loop.md" "AC9 refs/llm-loop.md exists"
loop_files="$REFS/llm-loop.md"
n_cont=0
for f in "$REFS"/llm-loop-*.md; do
  [ -f "$f" ] || continue
  n_cont=$((n_cont + 1))
  loop_files="$loop_files $f"
  name="$(basename "$f" .md)"
  grep -q "$name" "$REFS/llm-loop.md" 2>/dev/null
  assert_eq "0" "$?" "AC9 llm-loop.md names its continuation ref $name"
  others="$(grep -l "$name" "$SKILL_MD" "$REFS"/*.md 2>/dev/null | grep -v '/llm-loop\.md$' | grep -v "/$name\.md\$" | tr '\n' ' ')"
  assert_eq "" "$others" "AC9 only llm-loop.md names the continuation ref $name"
done
[ "$n_cont" -ge 1 ]; assert_eq "0" "$?" "AC9 the loop has continuation refs ($n_cont)"
# shellcheck disable=SC2086 # the file list is meant to split into words
loop_text="$(cat $loop_files 2>/dev/null)"
for needle in "talos.sh next" "talos.sh done" "talos.sh prompt" "gate fix-round" "gate merge" "post-merge"; do
  assert_contains "$loop_text" "$needle" "AC9 the loop refs hold \`$needle\`"
done
for f in $loop_files; do
  [ -f "$f" ] || continue
  rsize="$(wc -c < "$f" | tr -d ' ')"
  [ "$rsize" -le 8000 ]; assert_eq "0" "$?" "AC9 $(basename "$f") is at most 8,000 bytes ($rsize)"
done
assert_eq "1" "$(grep -c 'llm-loop' "$SKILL_MD")" "AC9 SKILL.md names llm-loop on one line only"
assert_contains "$(grep 'llm-loop' "$SKILL_MD")" "ORCHESTRATOR=llm" \
  "AC9 SKILL.md names llm-loop where it says to read it when ORCHESTRATOR=llm"

# ── AC10: the docs name the opt-in and no longer say LLM-driven by default ───
for doc in README.md docs/reference.md skills/setup/SKILL.md; do
  body="$(cat "$TALOS_ROOT/$doc")"
  assert_contains "$body" "execution.orchestrator" "AC10 $doc names execution.orchestrator"
  for old in "LLM-driven by default" "For local and weak-model profiles" "local/weak-model option"; do
    assert_not_contains "$body" "$old" "AC10 $doc no longer says \`$old\`"
  done
done

# ── AC1-AC4: `talos.sh env` ──────────────────────────────────────────────────
# env_for <project JSON>: `env` under that config ('' = no config at all).
env_for() {
  rm -rf "${HOME:?}/.talos" "${SANDBOX:?}"/talos.pipeline.*
  [ -z "$1" ] || printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"
  OUT="$(bash "$TALOS" env 2>"$ERR")"
}
orch() { printf '%s\n' "$OUT" | sed -n 's/^ORCHESTRATOR=//p' | tr '\n' ' ' | sed 's/ $//'; }
refs() { printf '%s\n' "$OUT" | sed -n 's/^ref=//p' | tr '\n' ' ' | sed 's/ $//'; }
key_lines() { grep -c 'execution\.orchestrator' "$ERR"; }

row="$( . "$TALOS_ROOT/scripts/pipeline-defaults.sh"; _talos_defaults_row execution.orchestrator
        printf '%s|%s|%s|%s|%s' "$_TD_TYPE" "$_TD_DEFAULT" "$_TD_DERIVED" "$_TD_ENV" "$_TD_SCOPE" )"
assert_eq "enum|code|-|-|any" "$row" "AC1 pipeline-defaults.sh has the execution.orchestrator row (enum, code, any)"
env_for ''
assert_eq "code" "$(orch)" "AC1 with no config env prints exactly one ORCHESTRATOR=code line"

for v in llm LLM Llm; do
  env_for "$(printf '{"vcs": {"provider": "github"}, "execution": {"orchestrator": "%s"}}' "$v")"
  assert_eq "llm" "$(orch)" "AC2 execution.orchestrator $v prints ORCHESTRATOR=llm"
done
for v in auto true llm-loop; do
  env_for "$(printf '{"vcs": {"provider": "github"}, "execution": {"orchestrator": "%s"}}' "$v")"
  assert_eq "code" "$(orch)" "AC2 the unknown value $v prints ORCHESTRATOR=code"
  assert_eq "1" "$(key_lines)" "AC2 the unknown value $v gets one stderr line naming the key"
  line="$(grep 'execution\.orchestrator' "$ERR")"
  assert_contains "$line" "code" "AC2 the stderr line for $v names the value code"
  assert_contains "$line" "llm" "AC2 the stderr line for $v names the value llm"
done

for extra in '' ', "execution": {"orchestrator": "code"}'; do
  what="the key absent"; [ -z "$extra" ] || what="the key code"
  env_for "$(printf '{"vcs": {"provider": "file"}%s}' "$extra")"
  assert_eq "llm" "$(orch)" "AC3 vcs.provider file prints ORCHESTRATOR=llm ($what)"
  assert_eq "1" "$(key_lines)" "AC3 vcs.provider file gets one stderr line ($what)"
  assert_contains "$(grep 'execution\.orchestrator' "$ERR")" "vcs.provider" "AC3 the stderr line names vcs.provider ($what)"
  env_for "$(printf '{"vcs": {"provider": "github"}, "roles": {"planner": true}%s}' "$extra")"
  assert_eq "llm" "$(orch)" "AC3 roles.planner true prints ORCHESTRATOR=llm ($what)"
  assert_eq "1" "$(key_lines)" "AC3 roles.planner true gets one stderr line ($what)"
  assert_contains "$(grep 'execution\.orchestrator' "$ERR")" "roles.planner" "AC3 the stderr line names roles.planner ($what)"
done

BUSY='"vcs": {"provider": "github"}, "merge": {"auto": false}, "roles": {"adversarial": true}, "hooks": {"pre_dispatch": "echo hi"}, "agents": {"runner": "codex"}'
env_for ''
assert_eq "code" "$(orch)" "AC4 the default config is ORCHESTRATOR=code"
assert_eq "" "$(refs)" "AC4 the default config prints no ref= line"
env_for "{$BUSY}"
assert_eq "code" "$(orch)" "AC4 a config with every ref trigger is still ORCHESTRATOR=code"
assert_eq "" "$(refs)" "AC4 ORCHESTRATOR=code prints no ref= line (merge.auto false, adversarial, a hook, a non-claude runner)"
env_for "{$BUSY, \"execution\": {\"orchestrator\": \"llm\"}}"
assert_eq "llm-loop draft-order adversarial human-merge hooks harness" "$(refs)" \
  "AC4 ORCHESTRATOR=llm prints ref=llm-loop first, then main's lines in main's order"
env_for '{"vcs": {"provider": "github"}, "execution": {"orchestrator": "llm"}}'
assert_eq "llm-loop draft-order" "$(refs)" "AC4 llm on the default config: ref=llm-loop, then draft-order"

# ── AC6 (second half): a stage's final message stays out of run's stdout ─────
# The fixture of test-talos-run.sh: a copied scripts dir whose providers, agent
# and collect are stubs; talos.sh itself is the real one.
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR" "$SANDBOX/templates/prompts"
cp "$TALOS_ROOT"/scripts/* "$GS/"
cp -R "$TALOS_ROOT/templates/prompts/." "$SANDBOX/templates/prompts/"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-events.sh; do
  cat > "$GS/$s" <<'TALOS_Ys5Gc1Mq8Wt3Lh'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="$1"; else key="$n"; fi
printf '%s %s\n' "$n" "$*" >> "$d/journal"
case "$key" in list-prs | list-needs-owner | list-issues) printf '[]'; exit 0 ;; esac
# `done` hands the stage's final message to the role relay on stdin.
if [ "$n" = "notify" ] && [ "${3:-}" = "-" ]; then cat >> "$d/relay.stdin"; fi
a1="${2:-}"
if [ -f "$d/$key.$a1" ]; then cat "$d/$key.$a1"; elif [ -f "$d/$key" ]; then cat "$d/$key"; fi
exit 0
TALOS_Ys5Gc1Mq8Wt3Lh
done
cat > "$GS/pipeline-agent.sh" <<'TALOS_Bv6Nk3Zp9Xr2Jd'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
cat > "$d/agent.stdin"
printf 'agent %s\n' "$1" >> "$d/journal"
cat "$d/message"
TALOS_Bv6Nk3Zp9Xr2Jd
cat > "$GS/pipeline-status-file.sh" <<'TALOS_Lt8Rw4Hd7Qm5Fs'
#!/usr/bin/env bash
cat "${STUB_DIR:?}/collect.json"
TALOS_Lt8Rw4Hd7Qm5Fs
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
MARK="ZQXMARKER7"
run_stage() {  # $1 = the stage's final message
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$SANDBOX/.git/talos-lease.ledger"
  printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true}}' > "$PIPELINE_CONFIG"
  printf '{"prs": [], "pr_total": 0, "ignored": 0, "blocked": [], "queued": [9], "held": [], "owners": [], "capped": []}' \
    > "$STUB_DIR/collect.json"
  printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "body", "state": "open"}' \
    > "$STUB_DIR/view-issue.9"
  printf '%s\n' "$1" > "$STUB_DIR/message"
  OUT="$(TALOS_LEASE_TTL_S=1 bash "$GS/talos.sh" run --issue 9 --max-iterations 1 2>"$ERR")"
  RC=$?
}
run_stage "CONFIRMED: $MARK real and in scope
$MARK the second line of the relay"
assert_eq "0" "$RC" "AC6 a normal verdict: the run exits 0"
assert_contains "$(cat "$STUB_DIR/journal")" "agent validator" "AC6 a normal verdict: the stub stage ran"
assert_contains "$(cat "$STUB_DIR/relay.stdin" 2>/dev/null)" "$MARK" "AC6 a normal verdict: the marker is in the stage's relay (control)"
assert_contains "$OUT" "stop " "AC6 a normal verdict: stdout holds the driver's end line"
assert_not_contains "$OUT" "$MARK" "AC6 a normal verdict leaves no marker in the stdout of talos.sh run"
run_stage "BLOCKED: $MARK the issue cannot be read"
assert_contains "$OUT" "stop reason=stage-blocked role=validator" "AC6 a BLOCKED stage: stdout holds the driver's end line"
assert_contains "$(cat "$ERR")" "$MARK" "AC6 a BLOCKED stage: the reason is relayed on stderr (control)"
assert_not_contains "$OUT" "$MARK" "AC6 a BLOCKED stage leaves no marker in the stdout of talos.sh run"

finish
