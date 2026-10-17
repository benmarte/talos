#!/usr/bin/env bash
# test-closing-keyword-unverified-wait.sh -- an unverified closing-keyword
# check never lets `talos.sh gate merge` through (#774, slice 6 of #753).
# A PR that says `Closes #N` must not close #N while a sibling PR is open, so a
# check that could not look (a failed sibling fetch, a failed PR fetch, an
# unresolved repo, a failed keyword scan) answers `verdict=wait`
# `reason=closing-keyword-unverified`: retryable, no label, no comment.
# siblings-capped keeps its block; a PR with no keyword still merges.
# Uses a journaling stub for pipeline-vcs.sh and the shared function extracted
# from the real script; no network.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
TALOS="$TALOS_ROOT/scripts/talos.sh"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── gate merge against a stub pipeline-vcs.sh (as in test-talos-gate.sh) ─────
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="${1:-}"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then { printf "[%s]\n" "$*"; cat "$a"; } >> "$d/bodies"; fi
  prev="$a"
done
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-mergebase.sh pipeline-draft-check.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
GATE="$GS/talos.sh"
HEAD_SHA="0123456789abcdef0123456789abcdef01234567"

set_stub() {
  printf '%s\n' "$2" > "$STUB_DIR/$1.rc"
  printf '%s' "${3:-}" > "$STUB_DIR/$1.out"
  printf '%s' "${4:-}" > "$STUB_DIR/$1.err"
}
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$SANDBOX/talos.pipeline.json"
  set_stub view-pr 0 '{"labels":[{"name":"qa:pass"},{"name":"review:approved"},{"name":"security:approved"},{"name":"docs:done"},{"name":"pipeline:review"}]}'
  set_stub view-issue 0 '{"labels":[{"name":"pipeline:review"}]}'
  set_stub pr-head 0 "$HEAD_SHA"
  set_stub read-comments 0 '{"comments":[]}'
  set_stub draft-check 0 "false"
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
called() { journal | grep -c "^$1 \|^vcs $1 "; }
bodies() { cat "$STUB_DIR/bodies" 2>/dev/null; }
gm() { OUT="$(bash "$GATE" gate merge 9 42 2>"$SANDBOX/stderr")"; RC=$?; }

# _unverified <id> <reason>: the marker ends in the wait, with no later gate,
# no label and no comment.
_unverified() {
  reset_stubs
  set_stub check-closing-keyword 0 "talos:closing-keyword-unverified pr=9 issue=42 reason=$2"
  gm
  assert_eq "verdict=wait
reason=closing-keyword-unverified" "$OUT" "$1 gate merge waits, retryably, on reason=$2"
  assert_eq "0" "$RC" "$1 the wait exits 0 ($2)"
  assert_eq "0" "$(called pr-checks-required)" "$1 no later gate verb runs: pr-checks-required not called ($2)"
  assert_eq "0" "$(called label-pr)" "$1 no label is written, so no pipeline:blocked ($2)"
  assert_eq "" "$(bodies)" "$1 no PR comment is posted ($2)"
}

_unverified "AC1" "sibling-fetch-failed"
_unverified "AC2" "pr-fetch-failed"
_unverified "AC3" "repo-unresolved"
_unverified "AC3" "sibling-check-failed"
_unverified "AC3" "keyword-scan-failed"

# AC4: capped still blocks, labels the PR, and posts the marker line.
reset_stubs; set_stub check-closing-keyword 0 "talos:closing-keyword-unverified pr=9 issue=42 reason=siblings-capped"
gm
assert_eq "verdict=block
reason=siblings-capped" "$OUT" "AC4 siblings-capped still blocks"
assert_contains "$(journal)" "vcs label-pr 9 --add pipeline:blocked" "AC4 the PR is labelled pipeline:blocked"
assert_contains "$(bodies)" "talos:closing-keyword-unverified pr=9 issue=42 reason=siblings-capped" "AC4 the marker line is the PR comment"

# AC5: no keyword -> the check answers nothing and the gate merges.
reset_stubs; set_stub check-closing-keyword 0 ""
gm
assert_eq "verdict=merge" "$OUT" "AC5 a PR with no closing keyword still merges, with no wait and no warn"

# ── the shared function: AC5 (lazy fetch) and AC6 (failed scan) ──────────────
_shared_src="$(awk '/^_github\(\) \{/{exit} /^_vcs_shared_read_attempt\(\) \{/{flag=1} flag{print}' "$VCS")"
eval "$_shared_src"
FETCH_LOG="$SANDBOX/siblings_fetch.log"
_siblings_fetch() { printf 'called\n' >> "$FETCH_LOG"; printf '[]'; }

: > "$FETCH_LOG"
out="$(printf '%s' 'Part of #42' | REPO="acme/widgets" _vcs_shared_check_closing_keyword 42 9 9 _siblings_fetch 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC5 a body with no keyword exits 0"
assert_eq "" "$out" "AC5 a body with no keyword prints nothing"
assert_eq "0" "$(wc -l < "$FETCH_LOG" | tr -d ' ')" "AC5 a body with no keyword never calls the sibling fetch"

: > "$FETCH_LOG"
out="$(printf '%s' 'Closes #42' | REPO="acme/widgets" _vcs_shared_check_closing_keyword 42 9 9 _siblings_fetch 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC6 a body with a keyword and no siblings exits 0"
assert_eq "" "$out" "AC6 a body with a keyword and no siblings prints no marker"
assert_eq "1" "$(wc -l < "$FETCH_LOG" | tr -d ' ')" "AC6 a body with a keyword still fetches the siblings once"

# python3 shadowed by a failing stub: the scan yields neither yes nor no.
BADPY="$SANDBOX/badpy"; mkdir -p "$BADPY"
printf '#!/bin/sh\nexit 1\n' > "$BADPY/python3"; chmod +x "$BADPY/python3"
: > "$FETCH_LOG"
out="$(printf '%s' 'Closes #42' | PATH="$BADPY:$PATH" REPO="acme/widgets" _vcs_shared_check_closing_keyword 42 9 9 _siblings_fetch 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC6 a failed keyword scan exits 0"
assert_eq "talos:closing-keyword-unverified pr=9 issue=42 reason=keyword-scan-failed" "$out" "AC6 a failed keyword scan prints the marker with the fixed reason"
assert_eq "0" "$(wc -l < "$FETCH_LOG" | tr -d ' ')" "AC6 a failed keyword scan fetches no siblings"

# ── AC7: the new reason is declared and documented ───────────────────────────
hdr="$(sed -n '1,/^set -/p' "$TALOS")"
assert_contains " $(printf '%s\n' "$hdr" | sed -n 's/^# gate-reasons: //p') " " closing-keyword-unverified " "AC7 # gate-reasons: lists closing-keyword-unverified"
assert_contains "$(printf '%s\n' "$hdr" | grep -A4 'verdict=wait' | head -n 8)" "closing-keyword-unverified" "AC7 the verdict=wait doc block lists closing-keyword-unverified"
assert_not_contains "$(printf '%s\n' "$hdr" | sed -n 's/^#   warn: //p')" "closing-keyword-unverified" "AC7 closing-keyword-unverified leaves the warn: list"
if grep -q '^| .*closing-keyword-unverified' "$TALOS_ROOT/docs/reference.md"; then
  pass "AC7 docs/reference.md has a table row for closing-keyword-unverified"
else fail "AC7 docs/reference.md has a table row for closing-keyword-unverified"; fi

finish
