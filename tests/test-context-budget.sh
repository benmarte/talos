#!/usr/bin/env bash
# test-context-budget.sh -- the LLM orchestrator's context budget (#605).
# Under ORCHESTRATOR=llm, `talos.sh next` reads the session size from the
# transcript TALOS_TRANSCRIPT_PATH names (the #604 reader): at or over
# execution.context_budget_tokens it starts no new issue and stops with one
# resume line, while in-flight work is still answered. An unknown size is one
# warn line. The fixture is test-talos-next.sh's: a copied scripts dir whose
# collect, provider and budget guard are stubs; the lease ledger is real.
#   AC1 the key and its default
#   AC2 over budget: a queued pick becomes the stop and the resume line, no lease
#   AC3 over budget: an in-flight issue and a PR-side stage are answered as usual
#   AC4 no transcript path: one warn reason=context-unknown line and the action
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
unset TALOS_RUN_PID TALOS_TRANSCRIPT_PATH
ERR="$SANDBOX/stderr"
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"

cat > "$GS/pipeline-status-file.sh" <<'TALOS_ctxstatusRm4Wq8Zp'
#!/usr/bin/env bash
# stub collect: one JSON file.
printf '%s' "$(cat "${STUB_DIR:?}/collect.json" 2>/dev/null || echo '{}')"
exit 0
TALOS_ctxstatusRm4Wq8Zp
cat > "$GS/pipeline-vcs.sh" <<'TALOS_ctxvcsTn6Kx2Bv'
#!/usr/bin/env bash
# Verb-level provider stub: <verb>.<a1>.json from $STUB_DIR, exit 0.
FX="${STUB_DIR:?}"
verb="$1"; shift
printf '%s %s\n' "$verb" "$*" >> "$FX/calls.log"
if [ -f "$FX/$verb.${1:-}.json" ]; then cat "$FX/$verb.${1:-}.json"
elif [ -f "$FX/$verb.json" ]; then cat "$FX/$verb.json"; fi
exit 0
TALOS_ctxvcsTn6Kx2Bv
printf '#!/usr/bin/env bash\nexit 0\n' > "$GS/pipeline-budget.sh"
TN="$GS/talos.sh"

export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
cfg() {  # $1 = execution object
  printf '{"vcs": {"provider": "github"}, "issues": {"max_parallel": 1, "claim": false}, "roles": {"validator": true, "pm": true, "developer": true}, "execution": %s}' \
    "${1:-\{\}}" > "$PIPELINE_CONFIG"
}
issue() {  # $1=n $2=label
  printf '{"number": %s, "title": "issue %s", "labels": [{"name": "%s"}], "body": ""}' "$1" "$1" "$2" > "$STUB_DIR/view-issue.$1.json"
}
state() {  # $1 = prs JSON, $2 = queued JSON, $3 = inflight JSON
  printf '{"prs": %s, "pr_total": 0, "ignored": 0, "blocked": [], "queued": %s, "held": [], "inflight": %s, "owners": [], "capped": []}' \
    "$1" "$2" "$3" > "$STUB_DIR/collect.json"
}
LEASE="$SANDBOX/.git/talos-lease.ledger"
lease_reset() { rm -rf "$LEASE" "${LEASE:?}.lock.d"; }
nx() { OUT="$(bash "$TN" next "$@" 2>"$ERR")"; RC=$?; }

# A transcript whose latest call carries <n> tokens of context (cache read).
transcript() {  # $1 = path, $2 = context tokens of the last call
  {
    printf '{"timestamp": "2026-10-11T10:00:00Z", "message": {"id": "m1", "usage": {"input_tokens": 5, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 0, "output_tokens": 50}}}\n'
    printf '{"timestamp": "2026-10-11T10:05:00Z", "message": {"id": "m2", "usage": {"input_tokens": 0, "cache_read_input_tokens": %s, "cache_creation_input_tokens": 0, "output_tokens": 50}}}\n' "$2"
  } > "$1"
}
BIG="$SANDBOX/big.jsonl"
transcript "$BIG" 200000

# ── AC1: the key ─────────────────────────────────────────────────────────────
cfg '{}'
assert_eq "150000" "$(bash "$GS/pipeline-config.sh" execution.context_budget_tokens 2>/dev/null)" \
  "AC1 execution.context_budget_tokens defaults to 150000"
assert_contains "$(cat "$GS/pipeline-defaults.sh")" "execution.context_budget_tokens	int	150000" \
  "AC1 the key is an int in the defaults table"

# ── AC2: over budget, a queued pick stops with one resume line ───────────────
cfg '{"orchestrator": "llm"}'
issue 7 "pipeline:ready"
state '[]' '[7]' '[]'
lease_reset
TALOS_TRANSCRIPT_PATH="$BIG" nx
assert_eq "0" "$RC" "AC2 the budget stop exits 0"
assert_eq "stop reason=context-budget size=200000 budget=150000
resume=/talos:pipeline" "$OUT" "AC2 a queued issue is not started: the stop line and one resume line"
assert_not_contains "$(cat "$LEASE" 2>/dev/null)" "issue=7" "AC2 no lease is taken for the queued issue"

# ── AC3: over budget, in-flight work is still answered ───────────────────────
issue 24 "pipeline:dev"
state '[]' '[]' '[24]'
lease_reset
TALOS_TRANSCRIPT_PATH="$BIG" nx --issue 24
assert_eq "action=dispatch stage=developer issue=24" "$OUT" "AC3 an in-flight issue's next stage is answered over the budget"
state '[{"n": 17, "issue": 71, "head": "a4f9", "owner": false, "stage": "docs"}]' '[7]' '[]'
issue 71 "pipeline:dev"
lease_reset
TALOS_TRANSCRIPT_PATH="$BIG" nx
assert_eq "action=dispatch stage=docs pr=17 issue=71" "$OUT" "AC3 a PR-side stage is answered over the budget"

# ── AC4: no transcript path ──────────────────────────────────────────────────
state '[]' '[7]' '[]'
lease_reset
nx
assert_eq "warn reason=context-unknown
action=dispatch stage=validator issue=7" "$OUT" "AC4 an unknown session size is one warn line and the usual action"

finish
