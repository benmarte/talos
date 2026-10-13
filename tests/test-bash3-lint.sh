#!/usr/bin/env bash
# test-bash3-lint.sh -- refuse GNU-only and bash 4+ constructs in scripts/ and tests/ (#651).
#   AC1 the repo at head is clean          AC2 each banned construct is refused
#   AC3 a hit names file, line, construct  AC4 `# bash3-ok: <reason>` opts a line out
#   AC5 comment-only lines are skipped     AC6 portable forms pass
#   AC8 the known false positives are not flagged
# A cloud (Linux, bash 5, GNU sed) run cannot see a macOS (bash 3.2, BSD sed) break;
# scripts/bash3-lint.sh is the pre-merge stand-in and this file drives it.
# Fixture lines are written to temp files at run time, and this file is not scanned.
set -u
. "$(dirname "$0")/helpers.sh"

LINT="$TALOS_ROOT/scripts/bash3-lint.sh"
bash3_scan() { bash "$LINT" "$@" 2>/dev/null; }

make_sandbox || exit 1
FX="$(safe_mktemp_dir)" || exit 1

# line_hits <line>: what the scanner prints for a one-line file holding <line>.
line_hits() { printf '%s\n' "$1" > "$FX/l.sh"; bash3_scan "$FX/l.sh" | sed "s|^$FX/||"; }

# assert_clean <line> <label>: the lint ran (rc 0) and printed nothing for <line>.
assert_clean() {
  printf '%s\n' "$1" > "$FX/l.sh"
  local o rc; o="$(bash "$LINT" "$FX/l.sh" 2>&1)"; rc=$?
  assert_eq "0:" "$rc:$o" "$2"
}

# ── AC1 ──────────────────────────────────────────────────────────────────────
FILES="$(find "$TALOS_ROOT/scripts" "$TALOS_ROOT/tests" -name '*.sh' \
  -not -path "$TALOS_ROOT/tests/fixtures/*" -not -name test-bash3-lint.sh \
  -not -name bash3-lint.sh | sort)"
# shellcheck disable=SC2086
bash3_scan $FILES >/dev/null; head_rc=$?
HEAD_HITS="$(bash3_scan $FILES | sed "s|^$TALOS_ROOT/||")"
assert_eq "0" "$head_rc" "AC1 the lint runs and exits 0 on scripts/ and tests/"
assert_eq "" "$HEAD_HITS" "AC1 no unmarked GNU-only or bash 4+ construct under scripts/ and tests/"

# ── AC2 ──────────────────────────────────────────────────────────────────────
check_refused() {  # $1=construct label  $2=line
  assert_eq "l.sh:1: $1" "$(line_hits "$2" | head -1)" "AC2 refuses $1: $2"
}
check_refused "sed -i" "sed -i 's/a/b/' f"
check_refused "sed -i" "sed -n -i 's/a/b/' f"
check_refused "sed -i" "sed -Ei 's/a/b/' f"
check_refused "sed \\b" "sed 's/\\bfoo/bar/' f"
check_refused "sed \\n" "sed 's/a/x\\ny/' f"
check_refused "grep -P" "grep -P 'a+' f"
check_refused "grep -P" "grep -qP 'a+' f"
check_refused "grep -P" "grep -oP 'a+' f"
check_refused "readlink -f" "readlink -f \"\$0\""
check_refused "date -d" "date -u -d '-2 hours' +%s"
check_refused "tac" "tac f | head -1"
check_refused "declare -A" "declare -A map"
check_refused '${var,,}' 'x="${v,,}"'
check_refused '${var^^}' 'x="${v^^}"'
check_refused "mapfile" "mapfile -t a < f"
check_refused "readarray" "readarray -t a < f"
check_refused "&>>" "cmd &>> log"

# ── AC3 ──────────────────────────────────────────────────────────────────────
printf '%s\n' 'echo ok' 'tac f' > "$FX/bad.sh"
out="$(bash3_scan "$FX/bad.sh")"; bash3_scan "$FX/bad.sh" >/dev/null; rc=$?
assert_contains "$out" "bad.sh:2: tac" "AC3 a hit names the file, the line number and the construct"
assert_eq "1" "$rc" "AC3 the lint exits non-zero on a hit"
bash "$LINT" "$TALOS_ROOT/tests/helpers.sh" >/dev/null 2>&1; assert_eq "0" "$?" "AC3 the lint exits 0 on a clean file"

# ── AC4 ──────────────────────────────────────────────────────────────────────
assert_clean 'tac f # bash3-ok: guarded by command -v' "AC4 a marker with a reason opts the line out"
assert_eq "l.sh:1: tac" "$(line_hits 'tac f # bash3-ok:')" "AC4 a marker with no reason does not opt out"
assert_eq "l.sh:1: tac" "$(line_hits 'tac f # bash3-ok:   ')" "AC4 a marker with a blank reason does not opt out"

# ── AC5 ──────────────────────────────────────────────────────────────────────
assert_clean '# no declare -A and no mapfile here' "AC5 a comment-only line is not flagged"
assert_clean '   # sed -i is banned' "AC5 an indented comment-only line is not flagged"

# ── AC6 ──────────────────────────────────────────────────────────────────────
for ok in "sed 's/a/b/' f" "awk '{print}' f" "grep -E 'a+' f" "date -u +%s" \
          "date -u +%Y-%m-%d" 'echo "${var}"' "sed -n '1p' f" "sed -e 's/a/b/g' f" \
          "date -u -v-2H +%s" 'readlink "$0"' 'pgrep -P $$' "stack=1; local x=1"; do
  assert_clean "$ok" "AC6 portable form passes: $ok"
done

# ── AC8 ──────────────────────────────────────────────────────────────────────
assert_clean "python3 -I -c 're.compile(r\"\\bfoo\\b\")'" "AC8 a python \\b with no sed is not flagged"
assert_clean 'pgrep -P "$pid"' "AC8 pgrep -P is not grep -P"

finish
