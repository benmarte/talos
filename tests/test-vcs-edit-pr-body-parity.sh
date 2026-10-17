#!/usr/bin/env bash
# test-vcs-edit-pr-body-parity.sh -- edit-pr-body on gitlab and azure (#762,
# slice 2 of #753). The verb used to exit 2 `not implemented` on both, so a
# developer fix round could not update the PR body there. Uses the glab and az
# stubs (STUB_GITLAB_API_FAIL, STUB_AZURE_PATCH_FAIL fail the write); no
# credentials needed. Tests are named by the spec's criterion id (AC1 ...).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

_cfg() {
  case "$1" in
    gitlab) printf '{"vcs": {"provider": "gitlab", "repo": "acme/widget"}}\n' > talos.pipeline.json ;;
    azure)  printf '{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}\n' > talos.pipeline.json ;;
    file)   printf '{"vcs": {"provider": "file"}}\n' > talos.pipeline.json ;;
  esac
}
_run() { OUT="$(bash "$VCS" "$@" 2>"$SANDBOX/err")"; RC=$?; ERR="$(cat "$SANDBOX/err")"; }
# _run_stdin <stdin-text> <args...>
_run_stdin() { local _in="$1"; shift; OUT="$(printf '%s' "$_in" | bash "$VCS" "$@" 2>"$SANDBOX/err")"; RC=$?; ERR="$(cat "$SANDBOX/err")"; }
# _count <regex> -- the number of logged provider calls matching it.
_count() { local _n; _n="$(grep -c -- "$1" "$GH_LOG" || true)"; printf '%s' "${_n:-0}"; }
_gl_puts() { _count '^GLAB api --method PUT '; }
_az_patches() { _count '^AZ ARGS: \[rest\] \[--method\] \[patch\].*pullRequests/9\?'; }
_calls() { _count -E '^(GLAB api --method PUT|AZ ARGS: \[rest\] \[--method\] \[patch\])'; }
# _logged_description <GLAB|AZ> -- the description in the last logged JSON body.
_logged_description() {
  grep -- "^$1 BODY: " "$GH_LOG" | tail -1 | sed "s/^$1 BODY: //" \
    | python3 -I -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["description"])' 2>/dev/null
}
_chars() { python3 -I -c "import sys; sys.stdout.write('x' * $1)"; }

BODY=$'Summary with it\'s $(touch pwned) and `ticks`\n\nCloses #762'

# AC1 gitlab: one PUT to the encoded project's merge request, description = stdin
_cfg gitlab; : > "$GH_LOG"
_run_stdin "$BODY"$'\n' edit-pr-body 9 --body-file -
assert_eq "0" "$RC" "AC1 gitlab: edit-pr-body exits 0 (err: $ERR)"
assert_eq "edited pr=9 body" "$OUT" "AC1 gitlab: prints the edited line"
assert_eq "1" "$(_gl_puts)" "AC1 gitlab: exactly one glab api --method PUT"
assert_contains "$(cat "$GH_LOG")" "projects/acme%2Fwidget/merge_requests/9 " "AC1 gitlab: the encoded project's MR endpoint"
assert_eq "$BODY" "$(_logged_description GLAB)" "AC1 gitlab: the JSON description is the stdin text"
assert_eq "no" "$([ -e pwned ] && echo yes || echo no)" "AC1 gitlab: the body is never executed"

# AC2 azure: one PATCH to pullRequests/9, description = stdin
_cfg azure; : > "$GH_LOG"
_run_stdin "$BODY"$'\n' edit-pr-body 9 --body-file -
assert_eq "0" "$RC" "AC2 azure: edit-pr-body exits 0 (err: $ERR)"
assert_eq "edited pr=9 body" "$OUT" "AC2 azure: prints the edited line"
assert_eq "1" "$(_az_patches)" "AC2 azure: exactly one az rest --method patch to pullRequests/9"
assert_contains "$(cat "$GH_LOG")" "/_apis/git/repositories/widget/pullRequests/9?api-version=7.1" "AC2 azure: the pull request endpoint"
assert_eq "$BODY" "$(_logged_description AZ)" "AC2 azure: the JSON description is the stdin text"
assert_eq "no" "$([ -e pwned ] && echo yes || echo no)" "AC2 azure: the body is never executed"

# AC3 empty or whitespace-only body: exit 1, no request
for _p in gitlab azure; do
  _cfg "$_p"
  for _empty in '' '   ' $'\n\n \n'; do
    : > "$GH_LOG"
    _run_stdin "$_empty" edit-pr-body 9 --body-file -
    assert_eq "1" "$RC" "AC3 $_p: an empty body exits 1"
    assert_contains "$ERR" "the body is empty; nothing changed" "AC3 $_p: names the empty body"
    assert_eq "0" "$(_calls)" "AC3 $_p: an empty body sends no request"
  done
done

# AC4 body over 65536 characters: the existing cap message, no request
for _p in gitlab azure; do
  _cfg "$_p"; : > "$GH_LOG"
  _run_stdin "$(_chars 65537)" edit-pr-body 9 --body-file -
  assert_eq "1" "$RC" "AC4 $_p: a body over 65536 characters exits 1"
  assert_contains "$ERR" "body is longer than 65536 characters" "AC4 $_p: the character-cap message"
  assert_eq "0" "$(_calls)" "AC4 $_p: an over-long body sends no request"
done

# AC5 azure: 4001 characters is refused, exactly 4000 is sent unchanged
_cfg azure; : > "$GH_LOG"
_run_stdin "$(_chars 4001)" edit-pr-body 9 --body-file -
assert_eq "1" "$RC" "AC5 azure: 4001 characters exits 1"
assert_contains "$ERR" "4000 characters" "AC5 azure: names the 4000-character limit"
assert_contains "$ERR" "nothing changed" "AC5 azure: says nothing changed"
assert_eq "0" "$(_calls)" "AC5 azure: 4001 characters sends no request"
: > "$GH_LOG"
_chars 4001 > "$SANDBOX/long.md"
_run --dry-run edit-pr-body 9 --body-file "$SANDBOX/long.md"
assert_eq "1" "$RC" "AC5 azure: 4001 characters exits 1 under --dry-run too"
assert_eq "0" "$(_calls)" "AC5 azure: --dry-run with 4001 characters sends no request"
: > "$GH_LOG"
_run_stdin "$(_chars 4000)" edit-pr-body 9 --body-file -
assert_eq "0" "$RC" "AC5 azure: exactly 4000 characters exits 0 (err: $ERR)"
assert_eq "$(_chars 4000)" "$(_logged_description AZ)" "AC5 azure: 4000 characters are sent unchanged"
# gitlab has no such limit
_cfg gitlab; : > "$GH_LOG"
_run_stdin "$(_chars 4001)" edit-pr-body 9 --body-file -
assert_eq "0" "$RC" "AC5 gitlab: 4001 characters is fine (err: $ERR)"

# AC6 a failing provider call: exit 1, no edited line
_cfg gitlab; : > "$GH_LOG"
OUT="$(printf 'x\n' | STUB_GITLAB_API_FAIL=1 bash "$VCS" edit-pr-body 9 --body-file - 2>"$SANDBOX/err")"; RC=$?
assert_eq "1" "$RC" "AC6 gitlab: a failing PUT exits 1"
assert_not_contains "$OUT" "edited pr=" "AC6 gitlab: no edited line on failure"
_cfg azure; : > "$GH_LOG"
OUT="$(printf 'x\n' | STUB_AZURE_PATCH_FAIL=1 bash "$VCS" edit-pr-body 9 --body-file - 2>"$SANDBOX/err")"; RC=$?
assert_eq "1" "$RC" "AC6 azure: a failing PATCH exits 1"
assert_not_contains "$OUT" "edited pr=" "AC6 azure: no edited line on failure"

# AC7 --dry-run: the planned call, exit 0, no request
printf '%s\n' "$BODY" > "$SANDBOX/body.md"
for _p in gitlab azure; do
  _cfg "$_p"; : > "$GH_LOG"
  _run --dry-run edit-pr-body 9 --body-file "$SANDBOX/body.md"
  assert_eq "0" "$RC" "AC7 $_p: --dry-run exits 0 (err: $ERR)"
  assert_contains "$OUT" "[dry-run]" "AC7 $_p: prints the planned call"
  assert_not_contains "$OUT" "edited pr=" "AC7 $_p: --dry-run does not claim an edit"
  assert_eq "0" "$(_calls)" "AC7 $_p: --dry-run sends no request"
done

# AC8 usage errors exit 2 before any body is read
for _p in gitlab azure; do
  _cfg "$_p"; : > "$GH_LOG"
  _run edit-pr-body x --body-file "$SANDBOX/nope";  assert_eq "2" "$RC" "AC8 $_p: a non-numeric PR exits 2"
  _run edit-pr-body 9 --body-file;                  assert_eq "2" "$RC" "AC8 $_p: --body-file with no value exits 2"
  _run edit-pr-body 9 "positional body";            assert_eq "2" "$RC" "AC8 $_p: a positional body exits 2"
  assert_eq "0" "$(_calls)" "AC8 $_p: a usage error sends no request"
done

# AC9 file still has no PRs
_cfg file
_run edit-pr-body 9 --body-file "$SANDBOX/nope"
assert_eq "2" "$RC" "AC9 file: edit-pr-body exits 2"
assert_contains "$ERR" "not implemented for provider 'file'" "AC9 file: says it is not implemented"

rm -f talos.pipeline.json
finish
