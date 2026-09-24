#!/usr/bin/env bash
# test-gitlab-assignee-cli.sh -- the exact glab command lines behind the
# gitlab adapter's create-issue / assign-issue (#299), and the
# issues.assignee: "" behaviour (#305). glab is not installed in CI, so
# tests/stubs/glab models the real CLI: unknown flags fail, issue view -F json
# returns assignees[].username, update's "+user" appends while a bare user
# replaces, and create prints the new issue's web_url on stdout.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
git remote set-url origin git@gitlab.com:acme/widget.git
export STUB_ASSIGNEE_FILE="$SANDBOX/assignee.state"
export STUB_GLAB_ARGV_LOG="$SANDBOX/glab-argv.log"
printf 'Body line\n' > "$SANDBOX/body.md"

# _cfg [assignee] -- no argument = key absent (default self).
_cfg() {
  if [ $# -gt 0 ]; then
    printf '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}, "issues": {"assignee": "%s"}}\n' "$1" > talos.pipeline.json
  else
    printf '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}\n' > talos.pipeline.json
  fi
}
# _run <verb args...> -- sets out / err / rc / argv (one glab call per line).
_run() {
  : > "$STUB_GLAB_ARGV_LOG"
  out="$(bash "$VCS" "$@" 2>"$SANDBOX/err")"; rc=$?
  err="$(cat "$SANDBOX/err")"
  argv="$(cat "$STUB_GLAB_ARGV_LOG")"
}
_state() { cat "$STUB_ASSIGNEE_FILE" 2>/dev/null; }

VIEW='[issue] [view] [42] [--output] [json] [-R] [acme/widget] '
UPDATE='[issue] [update] [42] [--assignee] [+operator1] [-R] [acme/widget] '
CREATE='[issue] [create] [--title] [t305] [--description] [Body line] [--label] [pipeline:ready] [-R] [acme/widget] '

# ── the stub itself models real glab ─────────────────────────────────────────
printf 'human\n' > "$STUB_ASSIGNEE_FILE"
out="$(glab issue view 42 --output json -R acme/widget)"
assert_eq "human" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(a["username"] for a in json.load(sys.stdin)["assignees"]))')" \
  "stub: issue view -F json returns assignees[].username"
glab issue view 42 --json assignees >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "stub: an unknown flag (gh's --json) fails like real glab"
glab issue update 42 --add-assignee alice >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "stub: gh's --add-assignee is not a glab flag"
glab issue update 42 --assignee +alice -R acme/widget
assert_eq "$(printf 'human\nalice')" "$(_state)" "stub: --assignee +user appends, keeping the existing assignee"
glab issue update 42 --assignee bob -R acme/widget
assert_eq "bob" "$(_state)" "stub: a bare --assignee user replaces every existing assignee"
glab issue update 42 --assignee +alice,bob >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "stub: mixing + and bare assignees is rejected like real glab"
glab issue create --title only >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "stub: non-interactive create without --description fails like real glab"

# ── create-issue with issues.assignee: self (key absent) ─────────────────────
_cfg; rm -f "$STUB_ASSIGNEE_FILE"
export STUB_CURRENT_USER=operator1
_run create-issue "t305" "$SANDBOX/body.md" --label pipeline:ready
assert_eq 0 "$rc" "self: create-issue exits 0"
assert_eq "https://gitlab.com/acme/widget/-/issues/42" "$out" "self: create-issue stdout is glab's URL line only"
assert_eq "$(printf '%s\n%s\n%s\n%s\n%s' "$CREATE" "$VIEW" '[api] [user] ' "$UPDATE" "$VIEW")" "$argv" \
  "self: exact glab argv for create, view, api user, update (+user) and the read-back view"
assert_eq "operator1" "$(_state)" "self: the new issue is assigned to the operator"
assert_contains "$err" "assign-issue: #42 assigned to operator1" "self: the verified assignment is reported"

# ── an existing assignee is preserved ────────────────────────────────────────
printf 'human\n' > "$STUB_ASSIGNEE_FILE"
_run assign-issue 42
assert_eq "0|" "$rc|$out" "preserve: assign-issue exits 0 with no success line"
assert_eq "$VIEW" "$argv" "preserve: only the view read runs -- no update call"
assert_eq "human" "$(_state)" "preserve: the existing assignee is untouched"
assert_contains "$err" "#42 already assigned to human; preserving" "preserve: says why it did nothing"

# The adapter's write, replayed against an assigned issue: "+" keeps the
# human, so even a racing write cannot unassign anyone.
glab issue update 42 --assignee +operator1 -R acme/widget
assert_eq "$(printf 'human\noperator1')" "$(_state)" "preserve: the adapter's +user write keeps an existing assignee"

# ── issues.assignee: "" = none, with a one-line notice ───────────────────────
_cfg ""; rm -f "$STUB_ASSIGNEE_FILE"
_run create-issue "t305" "$SANDBOX/body.md" --label pipeline:ready
assert_eq 0 "$rc" "empty: create-issue exits 0"
assert_eq "https://gitlab.com/acme/widget/-/issues/42" "$out" "empty: create-issue stdout unchanged"
assert_eq "$CREATE" "$argv" "empty: only the create call runs -- no view, api user or update"
assert_eq "" "$(_state)" "empty: the new issue stays unassigned"
assert_eq "pipeline-vcs: assign-issue: issues.assignee is empty -- treating it as 'none' (not assigning); remove the key for 'self'" \
  "$err" "empty: exactly one stderr notice line"

_run assign-issue 42
assert_eq "0|" "$rc|$out" "empty: assign-issue exits 0 with no success line"
assert_eq "" "$argv" "empty: assign-issue makes no glab call"
assert_eq "1" "$(printf '%s\n' "$err" | grep -c "treating it as 'none'")" "empty: assign-issue prints the notice once"

# `none` stays silent -- the notice is only for the ambiguous empty value.
_cfg none
_run assign-issue 42
assert_eq "0||" "$rc|$out|$err" "none: assign-issue is still a silent no-op"
assert_eq "" "$argv" "none: no glab call"

unset STUB_CURRENT_USER STUB_ASSIGNEE_FILE STUB_GLAB_ARGV_LOG
rm -f talos.pipeline.json
finish
