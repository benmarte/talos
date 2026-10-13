#!/usr/bin/env bash
# bash3-lint.sh FILE... -- refuse GNU-only and bash 4+ constructs (#651).
# Prints `file:line: construct` for each hit and exits 1 if any; 0 when clean.
# A line opts out with a trailing `# bash3-ok: <reason>`; comment-only lines are skipped.
# Itself bash 3.2 / POSIX awk safe (no grep -P, no sed -i).
set -u

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
