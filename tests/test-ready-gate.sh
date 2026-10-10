#!/usr/bin/env bash
# test-ready-gate.sh -- the QA pre-CI gate key (#535): `pr.ready_gate`.
#
#   AC1  unset reads off; qa-local and off accepted; anything else reads off with
#        one stderr warning naming the key
#   AC2  the effective gate is qa-local only when pr.draft resolves true and
#        roles.qa is on; otherwise off (one stderr line when it was asked for)
#   AC3  the defaults-table row, the generated docs table and its guards
#
# The resolver is `pipeline-draft-check.sh ready-gate`, the one place the value
# is derived.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

DC="$TALOS_ROOT/scripts/pipeline-draft-check.sh"
mkdir -p "$SANDBOX/proj" || exit 1   # no .github/workflows: the CI check answers `none`, draft stays true

# gate_in JSON: prints "<value>|<stderr>". The configs below are single-quoted
# literals (no braces next to a variable: bash 3.2 brace-expands those).
gate_in() {
  printf '%s\n' "$1" > "$SANDBOX/cfg.json"
  ( cd "$SANDBOX/proj" && PIPELINE_CONFIG="$SANDBOX/cfg.json" bash "$DC" ready-gate 2>"$SANDBOX/err" | tr -d '\n'; printf '|%s' "$(cat "$SANDBOX/err")" )
}
WARN_UNKNOWN="pipeline: pr.ready_gate: unknown value, reading it as off (use qa-local or off)"

# ── AC1 ──────────────────────────────────────────────────────────────────────
assert_eq "off|" "$(gate_in '{"vcs":{"provider":"github"}}')" "AC1 pr.ready_gate unset reads off, silent"
assert_eq "qa-local|" "$(gate_in '{"vcs":{"provider":"github"},"pr":{"ready_gate":"qa-local"}}')" "AC1 qa-local is accepted"
assert_eq "off|" "$(gate_in '{"vcs":{"provider":"github"},"pr":{"ready_gate":"off"}}')" "AC1 off is accepted, silent"
assert_eq "off|$WARN_UNKNOWN" "$(gate_in '{"vcs":{"provider":"github"},"pr":{"ready_gate":"banana"}}')" \
  "AC1 an unknown value reads off with one warning naming the key"
assert_eq "off|$WARN_UNKNOWN" "$(gate_in '{"vcs":{"provider":"github"},"pr":{"ready_gate":true}}')" \
  "AC1 a boolean value reads off with the same warning"

# ── AC2 ──────────────────────────────────────────────────────────────────────
assert_eq "off|pipeline: pr.ready_gate ignored: provider github-api cannot open draft PRs" \
  "$(gate_in '{"vcs":{"provider":"github-api"},"pr":{"ready_gate":"qa-local"}}')" "AC2 github-api reads off with one stderr line"
assert_eq "off|pipeline: pr.ready_gate ignored: provider file cannot open draft PRs" \
  "$(gate_in '{"vcs":{"provider":"file"},"pr":{"ready_gate":"qa-local"}}')" "AC2 file reads off with one stderr line"
assert_eq "off|pipeline: pr.ready_gate ignored: pr.draft is off, so there is no draft window" \
  "$(gate_in '{"vcs":{"provider":"github"},"pr":{"ready_gate":"qa-local","draft":false}}')" "AC2 pr.draft false reads off with one stderr line"
assert_eq "off|pipeline: pr.ready_gate ignored: roles.qa is off, so there is no QA stage to gate on" \
  "$(gate_in '{"vcs":{"provider":"github"},"pr":{"ready_gate":"qa-local"},"roles":{"qa":false}}')" "AC2 roles.qa false reads off with one stderr line"
assert_eq "off|" "$(gate_in '{"vcs":{"provider":"github"},"pr":{"draft":false},"roles":{"qa":false}}')" "AC2 not asked for: off and silent whatever else is set"
assert_eq "qa-local|" "$(gate_in '{"vcs":{"provider":"gitlab"},"pr":{"ready_gate":"qa-local"}}')" "AC2 gitlab with pr.draft defaulted on keeps qa-local"

# ── AC3: the defaults row, the generated docs table, the guards ──────────────
row="$( . "$TALOS_ROOT/scripts/pipeline-defaults.sh"; _talos_defaults_row pr.ready_gate; printf '%s|%s' "$_TD_DERIVED" "$_TD_DEFAULT" )"
assert_eq "-|off" "$row" "AC3 pr.ready_gate has a defaults-table row (not derived, default off)"
assert_contains "$(cat "$TALOS_ROOT/docs/reference.md")" '| `pr.ready_gate` | enum | `off` | - | any |' "AC3 docs/reference.md carries the generated row"
python3 -I "$TALOS_ROOT/tests/gen-config-table.py" --check "$TALOS_ROOT/docs/reference.md" 2>/dev/null
assert_eq "0" "$?" "AC3 the generated config table matches the defaults table"
assert_contains "$(cat "$TALOS_ROOT/tests/fixtures/config-golden-defaults.tsv")" "pr.ready_gate	off	table	" "AC3 the golden-defaults list pins the row"
printf '{"vcs":{"provider":"github"}}\n' > "$SANDBOX/none.json"
assert_eq "off" "$(cd "$SANDBOX/proj" && PIPELINE_CONFIG="$SANDBOX/none.json" bash "$TALOS_ROOT/scripts/pipeline-config.sh" pr.ready_gate)" "AC3 pipeline-config.sh answers off from the table"

finish
