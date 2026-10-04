#!/usr/bin/env bash
# tests/test-runner-conformance.sh -- one stage, every runner (#362, part of #353).
#
# scripts/pipeline-agent.sh promises the same thing for every runner: the role
# body (frontmatter stripped) is prepended to the task and handed to the
# runner. tests/test-agent-runner.sh pins that for claude, codex and custom
# only. This test drives `pipeline-agent.sh developer -` through every id in
# TALOS_RUNNERS (scripts/pipeline-contract.sh, the single source of the runner
# list) against the stubs in tests/stubs/, and checks the list agrees with the
# three places that restate it: the two validation `case` arms and the dispatch
# `case` in pipeline-agent.sh, and the header of the "Harness feature matrix"
# table in docs/user-guide.md.
#
# Coverage note: pi coverage is `pi -p` only (the headless runner that
# pipeline-agent.sh dispatches). pi's inline mode (skills/pipeline/SKILL.md,
# "inline mode") never calls pipeline-agent.sh and is NOT covered here.
#
# TALOS_CONFORMANCE_CONTRACT (optional) points at an alternate contract file;
# it exists so the negative control (a scratch copy of the contract with a
# seventh runner id) can be run against this same test.
set -u
. "$(dirname "$0")/helpers.sh"

CONTRACT="${TALOS_CONFORMANCE_CONTRACT:-$TALOS_ROOT/scripts/pipeline-contract.sh}"
. "$CONTRACT"
if ! declare -p TALOS_RUNNERS >/dev/null 2>&1; then
  fail "setup: TALOS_RUNNERS is defined" "missing after sourcing $CONTRACT"
  finish
  exit 1
fi

make_sandbox
use_stubs
export RUNNER_LOG="$SANDBOX/runner.log"
AGENT="$TALOS_ROOT/scripts/pipeline-agent.sh"
ROLE_FILE="$TALOS_ROOT/agents/developer.md"
DOCS="$TALOS_ROOT/docs/user-guide.md"

# ids / display names of TALOS_RUNNERS, one per line, in contract order.
RUNNER_IDS="$(for _e in "${TALOS_RUNNERS[@]}"; do printf '%s\n' "${_e%%|*}"; done)"
RUNNER_NAMES="$(for _e in "${TALOS_RUNNERS[@]}"; do printf '%s\n' "${_e#*|}"; done)"

# assert_same_ids <label> <expected ids> <actual ids> -- set equality that
# names every missing and every extra id on failure.
assert_same_ids() {
  local label="$1" want have missing extra
  want="$(printf '%s\n' "$2" | sed '/^$/d' | sort -u)"
  have="$(printf '%s\n' "$3" | sed '/^$/d' | sort -u)"
  missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have") | tr '\n' ' ')"
  extra="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$have") | tr '\n' ' ')"
  if [ -z "$missing" ] && [ -z "$extra" ]; then
    pass "$label"
  else
    fail "$label" "missing: ${missing:-<none>}| extra: ${extra:-<none>}"
  fi
}

# Same awk pipeline-agent.sh uses to strip frontmatter, so the expected prompt
# is built from the role file the same way (the body keeps the blank line after
# the closing ---, and $(...) strips trailing newlines).
ROLE_BODY="$(awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; next} !fm' "$ROLE_FILE")"

# ── Every runner gets the role body and the task ────────────────────────────
for ID in $RUNNER_IDS; do
  TOKEN="conformance-task-token-$ID-$$"
  ERRFILE="$SANDBOX/$ID.stderr"
  : > "$RUNNER_LOG"
  CUSTOM_OUT="$SANDBOX/custom.stdin"
  if [ "$ID" = custom ]; then
    rm -f "$CUSTOM_OUT"
    printf '{"agents": {"runner": "custom", "runner_cmd": "cat > %s"}}\n' "$CUSTOM_OUT" > talos.pipeline.json
  else
    printf '{"agents": {"runner": "%s"}}\n' "$ID" > talos.pipeline.json
  fi
  printf '%s\n' "$TOKEN" | bash "$AGENT" developer - >/dev/null 2>"$ERRFILE"
  rc=$?
  assert_eq "0" "$rc" "$ID: pipeline-agent.sh developer - exits 0"
  assert_contains "$(cat "$ERRFILE")" "talos:runner role=developer runner=$ID" \
    "$ID: stderr announces the resolved runner"

  if [ "$ID" = custom ]; then
    # custom: the prompt reaches runner_cmd on stdin, byte for byte.
    printf '%s\n\n---\n\n%s' "$ROLE_BODY" "$TOKEN" > "$SANDBOX/custom.expected"
    if [ -f "$CUSTOM_OUT" ] && cmp -s "$SANDBOX/custom.expected" "$CUSTOM_OUT"; then
      pass "custom: stdin equals <role body>, blank line, ---, blank line, <task>"
    else
      fail "custom: stdin equals <role body>, blank line, ---, blank line, <task>" \
        "cmp: $(cmp "$SANDBOX/custom.expected" "$CUSTOM_OUT" 2>&1 | head -c 200)"
    fi
  else
    log="$(cat "$RUNNER_LOG")"
    assert_contains "$log" 'You are the **Developer**' "$ID: runner receives the role body"
    assert_contains "$log" "$TOKEN" "$ID: runner receives the task token"
    assert_not_contains "$log" 'tools:' "$ID: runner prompt has no frontmatter"
  fi
done
rm -f talos.pipeline.json

# ── The runner list agrees with pipeline-agent.sh ───────────────────────────
# Validation arm of the --resolve block, validation arm of the main flow, and
# the dispatch arms (the `case "$RUNNER" in` that follows `RC=0`).
arm_ids() { sed 's/).*//' | tr '|' '\n' | tr -d ' '; }

RESOLVE_ARM="$(awk '/case "\$_RESOLVED_RUNNER" in/ {n=1; next} n {print; exit}' "$AGENT" | arm_ids)"
VALID_ARM="$(awk '/^RC=0$/ {exit} /^case "\$RUNNER" in$/ {n=1; next} n {print; exit}' "$AGENT" | arm_ids)"
# Dispatch arms are found by pattern (a bare `name)` line at the dispatch case's
# own nesting depth), not by indentation or column: the function body may be
# indented or not, and a nested case inside an arm must not count.
DISPATCH_ARMS="$(awk '
  /^RC=0$/ { r = 1; next }
  r && !d && /^[[:space:]]*case "\$RUNNER" in[[:space:]]*$/ { d = 1; depth = 1; next }
  d {
    if ($0 ~ /^[[:space:]]*case .* in[[:space:]]*$/) depth++
    else if ($0 ~ /^[[:space:]]*esac[[:space:]]*$/) { depth--; if (depth == 0) exit }
    else if (depth == 1 && $0 ~ /^[[:space:]]*[a-z]+\)[[:space:]]*$/) { l = $0; gsub(/[[:space:]]|\)/, "", l); print l }
  }' "$AGENT")"

assert_same_ids "TALOS_RUNNERS ids == --resolve validation arm" "$RUNNER_IDS" "$RESOLVE_ARM"
assert_same_ids "TALOS_RUNNERS ids == validation arm" "$RUNNER_IDS" "$VALID_ARM"
assert_same_ids "TALOS_RUNNERS ids == dispatch arms" "$RUNNER_IDS" "$DISPATCH_ARMS"

# ── Display names agree with the docs table header ──────────────────────────
# Header row of the table under "## Harness feature matrix", minus the first
# ("Feature") cell.
DOC_HEADER="$(awk '/^## Harness feature matrix/ {s=1; next} s && /^\|/ {print; exit}' "$DOCS")"
DOC_NAMES="$(printf '%s\n' "$DOC_HEADER" \
  | awk -F'|' '{for (i = 3; i < NF; i++) {c = $i; gsub(/^ +| +$/, "", c); print c}}')"
assert_eq "$RUNNER_NAMES" "$DOC_NAMES" "TALOS_RUNNERS display names == docs table header (in order)"

finish
