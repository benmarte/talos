#!/usr/bin/env bash
# test-reference-reasons-documented.sh -- every stop reason on the `# run-reasons:`
# and `# docs-gate-reasons:` lines of scripts/talos.sh has a row in docs/reference.md.
set -u
. "$(dirname "$0")/helpers.sh"

# _reasons <talos.sh> <run|docs-gate> -- the reasons on that comment line.
_reasons() {
  sed -n "s/^# ${2}-reasons: *//p" "$1" | head -n 1
}

# _rows <reference.md> <run|docs-gate> -- the table rows to look in: every row
# for run (the stop-reason table), the rows of the docs-gate section for
# docs-gate. One row per line.
_rows() {
  case "$2" in
    run) grep '^| `' "$1" ;;
    *) awk '/^### /{on=($0 ~ /^### Stale approvals/)} on && /^\| `/' "$1" ;;
  esac
}

# _documented <reason> <rows-file> -- 0 when a row's first code span is the reason,
# starts with it, or carries it as `reason=<reason>`, and the row has an action.
_documented() {
  awk -v r="$1" -F'|' '
    { span = $2; sub(/^ *`/, "", span); sub(/`.*$/, "", span)
      act = $3; gsub(/[ \t]/, "", act)
      if (act == "") next
      if (span == r || index(span, r " ") == 1) found = 1
      n = split(span, w, " ")
      for (i = 1; i <= n; i++) if (w[i] == "reason=" r) found = 1 }
    END { exit found ? 0 : 1 }' "$2"
}

# check_reasons <talos.sh> <reference.md> <run|docs-gate> -- prints each missing reason.
check_reasons() {
  local _cr_rows _cr_r _cr_bad=""
  _cr_rows="$(mktemp)" || return 2
  _rows "$2" "$3" > "$_cr_rows"
  for _cr_r in $(_reasons "$1" "$3"); do
    _documented "$_cr_r" "$_cr_rows" || _cr_bad="$_cr_bad $_cr_r"
  done
  rm -f "$_cr_rows"
  [ -z "$_cr_bad" ] && return 0
  printf '%s\n' "$_cr_bad" | sed 's/^ //'
  return 1
}

TALOS_SH="$TALOS_ROOT/scripts/talos.sh"
REF="$TALOS_ROOT/docs/reference.md"

if [ -n "$(_reasons "$TALOS_SH" run)" ]; then pass "AC1 talos.sh has a run-reasons line"
else fail "AC1 talos.sh has a run-reasons line"; fi
if miss="$(check_reasons "$TALOS_SH" "$REF" run)"; then
  pass "AC1 every run-reasons reason has a stop-reason table row"
else fail "AC1 every run-reasons reason has a stop-reason table row" "missing: $miss"; fi

if [ -n "$(_reasons "$TALOS_SH" docs-gate)" ]; then pass "AC2 talos.sh has a docs-gate-reasons line"
else fail "AC2 talos.sh has a docs-gate-reasons line"; fi
if miss="$(check_reasons "$TALOS_SH" "$REF" docs-gate)"; then
  pass "AC2 every docs-gate-reasons reason has a docs-gate table row"
else fail "AC2 every docs-gate-reasons reason has a docs-gate table row" "missing: $miss"; fi

# AC3 the lists are read at test time: a reason added to a line only fails the check.
fx="$(mktemp -d)" || exit 1
[ -d "$fx" ] || exit 1
sed 's/^# run-reasons: /# run-reasons: zz-new-run-reason /' "$TALOS_SH" > "$fx/run.sh"
sed 's/^# docs-gate-reasons: /# docs-gate-reasons: zz-new-gate-reason /' "$TALOS_SH" > "$fx/gate.sh"
if miss="$(check_reasons "$fx/run.sh" "$REF" run)"; then
  fail "AC3 an undocumented run reason fails the check"
else assert_eq "zz-new-run-reason" "$miss" "AC3 an undocumented run reason fails the check"; fi
if miss="$(check_reasons "$fx/gate.sh" "$REF" docs-gate)"; then
  fail "AC3 an undocumented docs-gate reason fails the check"
else assert_eq "zz-new-gate-reason" "$miss" "AC3 an undocumented docs-gate reason fails the check"; fi
rm -rf "${fx:?}"

finish
