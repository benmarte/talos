#!/usr/bin/env bash
# test-verify-timeout-cap.sh -- verify.timeout_ms never reaches a claude-runner
# stage above the harness's 600000 ms foreground cap, and a verify that times
# out ends as a documented stop (#674).
#   AC1-AC2  `talos.sh prompt qa|developer`: the rendered timeout is clamped
#   AC3-AC4  the stderr warning: claude runner over the cap only
#   AC5      `talos.sh run`: QA `BLOCKED: verify: timed out after <n> ms`
#   AC6      the stop reason is on the run-reasons line and in the reference
#   AC8      this repo's talos.pipeline.json verify fits the cap, per command
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
ERR="$SANDBOX/stderr"

# ── fixture: a copied scripts dir with stubbed providers (as test-spec-fault-648.sh)
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
cat > "$GS/pipeline-agent.sh" <<'TALOS_stubagent674Hn3Rt'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
role="$1"
cat > "$d/agent.stdin"
printf "agent %s\n" "$role" >> "$d/journal"
cnt="$(grep -c "^agent $role\$" "$d/journal")"
if [ -f "$d/message.$role.$cnt" ]; then cat "$d/message.$role.$cnt"; fi
if [ -f "$d/hook.$role.$cnt" ]; then . "$d/hook.$role.$cnt"; fi
exit 0
TALOS_stubagent674Hn3Rt
cat > "$GS/pipeline-status-file.sh" <<'TALOS_stubstatus674Wq8Vc'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
printf 'status-file collect\n' >> "$d/journal"
printf '%s' "$(cat "$d/collect.json" 2>/dev/null || echo '{}')"
TALOS_stubstatus674Wq8Vc

RUN="$GS/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
LEASE="$SANDBOX/.git/talos-lease.ledger"
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
# cfg_json TIMEOUT_MS QA_MODE [RUNNER]: the project config.
cfg_json() {
  local ag=""
  [ -z "${3:-}" ] || ag=", \"agents\": {\"runner\": \"$3\"}"
  printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1}, "roles": {"validator": true, "qa": true, "docs": true, "reviewer": true, "security": true}, "pr": {"draft": true}, "comments": {"enabled": false}, "verify": {"timeout_ms": %s, "ci_wait_s": 900, "qa_mode": "%s"}%s}' \
    "$1" "$2" "$ag" > "$SANDBOX/talos.pipeline.json"
}
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$LEASE" "${LEASE:?}.lock.d"
  cfg_json 600000 local
  printf '0\n' > "$STUB_DIR/events.cost.line.rc"; printf 'spend: 12 tokens' > "$STUB_DIR/events.cost.line.out"
}

# render ROLE ARGS...: run `prompt`; OUT is the rendered text, ERR the stderr.
render() {
  local f
  f="$(bash "$RUN" prompt "$@" 2> "$ERR" | sed -n 's/^prompt_file=//p')"
  OUT=""
  if [ -n "$f" ] && [ -f "$f" ]; then OUT="$(cat "$f")"; rm -f "${f:?}"; fi
}
warned() { grep -c 'verify.timeout_ms' "$ERR"; }

# ── AC1: the QA prompt gets the clamped timeout ──────────────────────────────
reset_stubs
cfg_json 1800000 local
render qa --issue 9 --pr 12
assert_contains "$OUT" "600000" "AC1 qa prompt: the verify timeout is 600000"
assert_not_contains "$OUT" "1800000" "AC1 qa prompt: 1800000 never reaches the prompt"

# ── AC2: the developer prompt, in both qa modes ──────────────────────────────
cfg_json 1800000 local
render developer --issue 9
assert_contains "$OUT" "Verify timeout: 600000 ms" "AC2 developer prompt (qa_mode local): clamped to 600000"
assert_not_contains "$OUT" "1800000" "AC2 developer prompt (qa_mode local): no 1800000"
cfg_json 1800000 ci
render developer --issue 9
assert_contains "$OUT" "Verify timeout: 600000 ms" "AC2 developer prompt (qa_mode ci): clamped to 600000"
assert_not_contains "$OUT" "1800000" "AC2 developer prompt (qa_mode ci): no 1800000"

# ── AC3: one warning over the cap, none at or under it ───────────────────────
cfg_json 1800000 local
render qa --issue 9 --pr 12
assert_eq "1" "$(warned)" "AC3 over the cap: one warning naming verify.timeout_ms"
assert_contains "$(cat "$ERR")" "600000" "AC3 over the cap: the warning names the cap"
cfg_json 600000 local
render qa --issue 9 --pr 12
assert_eq "0" "$(warned)" "AC3 at the cap: no warning"
cfg_json 300000 local
render qa --issue 9 --pr 12
assert_eq "0" "$(warned)" "AC3 under the cap: no warning"
assert_contains "$OUT" "300000" "AC3 under the cap: the value is rendered as set"

# ── AC4: a non-claude runner is left alone ───────────────────────────────────
cfg_json 1800000 local codex
render qa --issue 9 --pr 12
assert_contains "$OUT" "1800000" "AC4 codex runner: 1800000 rendered unchanged"
assert_eq "0" "$(warned)" "AC4 codex runner: no warning"

# ── AC5: QA `BLOCKED: verify: timed out` is the verify-timeout stop ──────────
rn() { OUT="$(TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 bash "$RUN" run --max-iterations 1 2>"$ERR")"; RC=$?; }
qa_fixture() {  # the PR is at stage ready; QA's report is $1
  reset_stubs
  printf '{"prs":[{"n":12,"issue":9,"head":"a4f9","owner":false,"stage":"ready"}],"pr_total":1,"ignored":0,"blocked":[],"queued":[],"held":[],"owners":[],"capped":[]}' > "$STUB_DIR/collect.json"
  printf ready > "$STUB_DIR/pr-is-draft.12"; printf 1 > "$STUB_DIR/pr-is-draft.12.rc"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  printf '%s\n' "$1" > "$STUB_DIR/message.qa.1"
}
stop_line() { printf '%s\n' "$OUT" | grep '^stop '; }
qa_fixture 'BLOCKED: verify: timed out after 600000 ms'
rn
assert_eq "0" "$RC" "AC5 verify timeout: the run exits 0"
assert_eq "stop reason=verify-timeout role=qa pr=12" "$(stop_line)" "AC5 verify timeout: the verify-timeout stop"
assert_contains "$(journal)" "vcs label-pr 12 --add pipeline:blocked" "AC5 verify timeout: the PR is pipeline:blocked"
assert_contains "$(journal)" "vcs label-issue 9 --add pipeline:blocked" "AC5 verify timeout: the issue is pipeline:blocked"
qa_fixture 'BLOCKED: the verify command needs approval'
rn
assert_eq "stop reason=stage-blocked role=qa" "$(stop_line)" "AC5 another BLOCKED: stays stage-blocked"
qa_fixture 'BLOCKED: spec: no criteria checklist'
rn
assert_eq "stop reason=spec-unusable issue=9 pr=12" "$(stop_line)" "AC5 BLOCKED: spec: stays spec-unusable"

# ── AC6: documented ──────────────────────────────────────────────────────────
assert_contains "$(sed -n 's/^# run-reasons: *//p' "$TALOS_ROOT/scripts/talos.sh" | head -n 1)" "verify-timeout" "AC6 verify-timeout is on the run-reasons line"
assert_contains "$(grep '^| `verify-timeout' "$TALOS_ROOT/docs/reference.md")" "--shard" "AC6 the reference row names an action (--shard)"

# ── AC8: this repo's own verify fits the cap, per command ────────────────────
_cmds="$(python3 -I -c 'import json, sys
v = json.load(open(sys.argv[1]))["verify"]
print("\n".join(v["commands"])); print("T=%s" % v["timeout_ms"])' "$TALOS_ROOT/talos.pipeline.json")"
for i in 1 2 3 4; do
  assert_contains "$_cmds" "bash tests/run-tests.sh --quiet --shard $i/4" "AC8 talos.pipeline.json runs shard $i/4"
done
assert_eq "4" "$(printf '%s\n' "$_cmds" | grep -c '^bash ')" "AC8 talos.pipeline.json has exactly four verify commands"
_t="$(printf '%s\n' "$_cmds" | sed -n 's/^T=//p')"
if [ "$_t" -le 600000 ] 2>/dev/null; then _ok=ok; else _ok="timeout_ms=$_t"; fi
assert_eq "ok" "$_ok" "AC8 talos.pipeline.json timeout_ms is at most 600000"

finish
