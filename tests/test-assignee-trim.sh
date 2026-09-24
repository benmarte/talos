#!/usr/bin/env bash
# test-assignee-trim.sh -- issues.assignee is trimmed of leading/trailing
# whitespace before any comparison (#321), a follow-up to #305 (PR #316).
# Covers whitespace-only, " self ", " NONE " and " alice " on github and
# gitlab, asserting the exact argv the provider stub receives so a
# regression (an untrimmed value reaching gh/glab) fails loudly.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export STUB_ASSIGNEE_FILE="$SANDBOX/assignee.state"
export STUB_CURRENT_USER=operator1

# _cfg <provider> <assignee-json-value> -- write the config. The assignee
# value is embedded verbatim inside a JSON string, so callers pass it
# already JSON-escaped (tabs/newlines as \t/\n) when needed.
_cfg() {
  printf '{"vcs": {"provider": "%s", "repo": "acme/widget"}, "issues": {"assignee": "%s"}}\n' "$1" "$2" > talos.pipeline.json
}

# ── github ────────────────────────────────────────────────────────────────
_run_gh() {
  : > "$GH_LOG"
  out="$(bash "$VCS" "$@" 2>"$SANDBOX/err")"; rc=$?
  err="$(cat "$SANDBOX/err")"
  log="$(cat "$GH_LOG")"
}

# whitespace-only ("  ") -- trims to "" -- the existing empty-value notice,
# "none" path: no provider call at all.
_cfg github "  "; rm -f "$STUB_ASSIGNEE_FILE"
_run_gh assign-issue 42
assert_eq "0|" "$rc|$out" "github whitespace-only: assign-issue exits 0 with no success line"
assert_eq "" "$log" "github whitespace-only: no gh call at all"
assert_contains "$err" "issues.assignee is empty -- treating it as 'none'" \
  "github whitespace-only: the existing empty-value notice fires"

# " self " -- trims to "self": the operator is resolved and assigned, never
# the literal identity "self " (with a trailing space).
_cfg github " self "; rm -f "$STUB_ASSIGNEE_FILE"
_run_gh assign-issue 42
assert_eq "operator1" "$(cat "$STUB_ASSIGNEE_FILE" 2>/dev/null)" \
  "github ' self ': trimmed to self -- the operator identity is assigned"
assert_contains "$out" "assigned to operator1" "github ' self ': verified assignment reported"

# " NONE " -- trims and lower-cases to "none": no provider call.
_cfg github " NONE "; rm -f "$STUB_ASSIGNEE_FILE"
_run_gh assign-issue 42
assert_eq "0||" "$rc|$out|$err" "github ' NONE ': silent no-op"
assert_eq "" "$log" "github ' NONE ': no gh call at all"

# " alice " -- a literal identity, trimmed before being passed to gh.
_cfg github " alice "; rm -f "$STUB_ASSIGNEE_FILE"
_run_gh assign-issue 42
assert_eq "alice" "$(cat "$STUB_ASSIGNEE_FILE" 2>/dev/null)" \
  "github ' alice ': the trimmed identity is what gets assigned"
assert_contains "$log" "issue edit 42 --add-assignee alice" \
  "github ' alice ': gh receives the trimmed identity, no surrounding whitespace"

rm -f talos.pipeline.json "$STUB_ASSIGNEE_FILE"

# ── gitlab ────────────────────────────────────────────────────────────────
export STUB_GLAB_ARGV_LOG="$SANDBOX/glab-argv.log"

_run_gl() {
  : > "$STUB_GLAB_ARGV_LOG"
  out="$(bash "$VCS" "$@" 2>"$SANDBOX/err")"; rc=$?
  err="$(cat "$SANDBOX/err")"
  argv="$(cat "$STUB_GLAB_ARGV_LOG")"
}

# whitespace-only ("\t") -- trims to "" -- none, plus the notice.
_cfg gitlab "\t"; rm -f "$STUB_ASSIGNEE_FILE"
_run_gl assign-issue 42
assert_eq "0|" "$rc|$out" "gitlab whitespace-only: assign-issue exits 0 with no success line"
assert_eq "" "$argv" "gitlab whitespace-only: no glab call at all"
assert_contains "$err" "issues.assignee is empty -- treating it as 'none'" \
  "gitlab whitespace-only: the existing empty-value notice fires"

# " self " -- trims to "self": the operator is resolved and assigned.
_cfg gitlab " self "; rm -f "$STUB_ASSIGNEE_FILE"
_run_gl assign-issue 42
assert_eq "operator1" "$(cat "$STUB_ASSIGNEE_FILE" 2>/dev/null)" \
  "gitlab ' self ': trimmed to self -- the operator identity is assigned"
assert_contains "$out" "assigned to operator1" "gitlab ' self ': verified assignment reported"

# " NONE " -- trims and lower-cases to "none": no provider call.
_cfg gitlab " NONE "; rm -f "$STUB_ASSIGNEE_FILE"
_run_gl assign-issue 42
assert_eq "0||" "$rc|$out|$err" "gitlab ' NONE ': silent no-op"
assert_eq "" "$argv" "gitlab ' NONE ': no glab call at all"

# " alice " -- a literal identity, trimmed before being passed to glab.
_cfg gitlab " alice "; rm -f "$STUB_ASSIGNEE_FILE"
_run_gl assign-issue 42
assert_eq "alice" "$(cat "$STUB_ASSIGNEE_FILE" 2>/dev/null)" \
  "gitlab ' alice ': the trimmed identity is what gets assigned"
assert_contains "$argv" "[issue] [update] [42] [--assignee] [+alice] [-R] [acme/widget]" \
  "gitlab ' alice ': glab receives the trimmed identity, no surrounding whitespace"

unset STUB_CURRENT_USER STUB_ASSIGNEE_FILE STUB_GLAB_ARGV_LOG
rm -f talos.pipeline.json
finish
