#!/usr/bin/env bash
# test-bash3-lint.sh -- refuse GNU-only and bash 4+ constructs in scripts/ and tests/ (#651).
#   AC1 the repo at head is clean          AC2 each banned construct is refused
#   AC3 a hit names file, line, construct  AC4 `# bash3-ok: <reason>` opts a line out
#   AC5 comment-only lines are skipped     AC6 portable forms pass
#   AC8 the known false positives are not flagged
# A cloud (Linux, bash 5, GNU sed) run cannot see a macOS (bash 3.2, BSD sed) break;
# this lint is the pre-merge stand-in. It is itself bash 3.2 / POSIX awk safe.
# Fixture lines are written to temp files at run time, and this file is not scanned.
set -u
. "$(dirname "$0")/helpers.sh"

# bash3_scan FILE...: print `file:line: construct` for each banned line; rc 1 if any.
bash3_scan() {
  awk '
    BEGIN {
      BSC = sprintf("%c", 92)
      pre = "(^|[^[:alnum:]_./-])"           # start of a command word
      cl = "([ \t]+-[A-Za-z]+)*[ \t]+"      # option clusters before the one we want
      sedw = pre "sed[ \t]"
      n = 0
      re[++n] = sedw "([^|;]*[ \t])?-[A-Za-z]*i";                    nm[n] = "sed -i"
      re[++n] = sedw "[^|;]*--in-place";                             nm[n] = "sed -i"
      re[++n] = pre "grep" cl "-[A-Za-z]*P";                         nm[n] = "grep -P"
      re[++n] = pre "readlink" cl "-[A-Za-z]*f";                     nm[n] = "readlink -f"
      re[++n] = pre "date" cl "-[A-Za-z]*d([^A-Za-z]|$)";            nm[n] = "date -d"
      re[++n] = "(^|[ \t|;(&`])tac([ \t|;)]|$)";                     nm[n] = "tac"
      re[++n] = pre "(declare|typeset|local)" cl "-[A-Za-z]*A";      nm[n] = "declare -A"
      re[++n] = "[$][{][A-Za-z_][A-Za-z0-9_]*,,";                    nm[n] = "${var,,}"
      re[++n] = "[$][{][A-Za-z_][A-Za-z0-9_]*[\\^][\\^]";            nm[n] = "${var^^}"
      re[++n] = pre "mapfile([ \t]|$)";                              nm[n] = "mapfile"
      re[++n] = pre "readarray([ \t]|$)";                            nm[n] = "readarray"
      re[++n] = "&>>";                                               nm[n] = "&>>"
      nre = n
    }
    FNR == 1 { ln = 0 }
    { ln++ }
    /^[ \t]*#/ { next }                                  # comment-only line
    /#[ ]bash3-ok:[ \t]*[^ \t]/ { next }                 # opted out, with a reason
    {
      for (i = 1; i <= nre; i++)
        if ($0 ~ re[i]) { print FILENAME ":" ln ": " nm[i]; bad = 1 }
      # sed: \b anywhere in the line, or \n in the replacement of s<d>pat<d>repl<d>
      if (match($0, sedw)) {
        rest = substr($0, RSTART + RLENGTH)
        if (index(rest, BSC "b")) { print FILENAME ":" ln ": sed " BSC "b"; bad = 1 }
        if (match(rest, "(^|[ \t\047\"{;])s")) {
          d = substr(rest, RSTART + RLENGTH, 1)
          if (d != "" && d != BSC && d !~ /[[:alnum:] \t]/) {
            k = split(substr(rest, RSTART + RLENGTH + 1), p, d)
            if (k >= 3 && index(p[2], BSC "n")) { print FILENAME ":" ln ": sed " BSC "n"; bad = 1 }
          }
        }
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$@"
}

# `--scan FILE...`: the scanner alone, for the exit-code check (AC3).
if [ "${1:-}" = "--scan" ]; then shift; bash3_scan "$@"; exit $?; fi

make_sandbox || exit 1
FX="$(safe_mktemp_dir)" || exit 1

# line_hits <line>: what the scanner prints for a one-line file holding <line>.
line_hits() { printf '%s\n' "$1" > "$FX/l.sh"; bash3_scan "$FX/l.sh" | sed "s|^$FX/||"; }

# ── AC1 ──────────────────────────────────────────────────────────────────────
FILES="$(find "$TALOS_ROOT/scripts" "$TALOS_ROOT/tests" -name '*.sh' \
  -not -path "$TALOS_ROOT/tests/fixtures/*" -not -name test-bash3-lint.sh | sort)"
# shellcheck disable=SC2086
HEAD_HITS="$(bash3_scan $FILES | sed "s|^$TALOS_ROOT/||")"
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
out="$(bash "$TALOS_ROOT/tests/test-bash3-lint.sh" --scan "$FX/bad.sh")"; rc=$?
assert_contains "$out" "bad.sh:2: tac" "AC3 a hit names the file, the line number and the construct"
assert_eq "1" "$rc" "AC3 the lint exits non-zero on a hit"
bash "$TALOS_ROOT/tests/test-bash3-lint.sh" --scan "$TALOS_ROOT/tests/helpers.sh" >/dev/null; assert_eq "0" "$?" "AC3 the lint exits 0 on a clean file"

# ── AC4 ──────────────────────────────────────────────────────────────────────
assert_eq "" "$(line_hits 'tac f # bash3-ok: guarded by command -v')" "AC4 a marker with a reason opts the line out"
assert_eq "l.sh:1: tac" "$(line_hits 'tac f # bash3-ok:')" "AC4 a marker with no reason does not opt out"
assert_eq "l.sh:1: tac" "$(line_hits 'tac f # bash3-ok:   ')" "AC4 a marker with a blank reason does not opt out"

# ── AC5 ──────────────────────────────────────────────────────────────────────
assert_eq "" "$(line_hits '# no declare -A and no mapfile here')" "AC5 a comment-only line is not flagged"
assert_eq "" "$(line_hits '   # sed -i is banned')" "AC5 an indented comment-only line is not flagged"

# ── AC6 ──────────────────────────────────────────────────────────────────────
for ok in "sed 's/a/b/' f" "awk '{print}' f" "grep -E 'a+' f" "date -u +%s" \
          "date -u +%Y-%m-%d" 'echo "${var}"' "sed -n '1p' f" "sed -e 's/a/b/g' f" \
          "date -u -v-2H +%s" 'readlink "$0"' 'pgrep -P $$' "stack=1; local x=1"; do
  assert_eq "" "$(line_hits "$ok")" "AC6 portable form passes: $ok"
done

# ── AC8 ──────────────────────────────────────────────────────────────────────
assert_eq "" "$(line_hits "python3 -I -c 're.compile(r\"\\bfoo\\b\")'")" "AC8 a python \\b with no sed is not flagged"
assert_eq "" "$(line_hits 'pgrep -P "$pid"')" "AC8 pgrep -P is not grep -P"

finish
