#!/usr/bin/env bash
# test-timing-guard.sh -- wall-clock assertions are load-tolerant (#593).
#   AC1 assert_cut_short: a bounded wait is judged against a same-run baseline
#   AC2 assert_linear: a scan's growth order, not a fixed number of seconds
#   AC3 no test file compares an elapsed time with a literal number of seconds
#   AC4 the clock the converted tests read measures a real wait
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

# verdict <helper> <args...>: PASS or FAIL as the helper would record it, run in
# a subshell so this file's own counters are untouched.
verdict() {
  ( _PASS=0; _FAIL=0; "$@" >/dev/null 2>&1; [ "$_FAIL" -eq 0 ] && [ "$_PASS" -eq 1 ] && echo PASS || echo FAIL )
}

# ── AC1 ──────────────────────────────────────────────────────────────────────
assert_eq "PASS" "$(verdict assert_cut_short x 3 2 10)" "AC1 a wait cut short (3 s over a 2 s baseline, uncut 10 s) passes"
assert_eq "FAIL" "$(verdict assert_cut_short x 13 2 10)" "AC1 an uncut wait (13 s over a 2 s baseline, uncut 10 s) fails"
assert_eq "PASS" "$(verdict assert_cut_short x 23 21 10)" "AC1 a heavily loaded run (21 s baseline) still passes a cut wait"
assert_eq "FAIL" "$(verdict assert_cut_short x 31 21 10)" "AC1 a heavily loaded run still fails an uncut wait"

# ── AC2 ──────────────────────────────────────────────────────────────────────
assert_eq "PASS" "$(verdict assert_linear x 0.2 3 16)" "AC2 linear growth (0.2 s -> 3 s at 16x the input) passes"
assert_eq "FAIL" "$(verdict assert_linear x 0.2 51 16)" "AC2 quadratic growth (0.2 s -> 51 s at 16x the input) fails"
assert_eq "PASS" "$(verdict assert_linear x 1.5 22 16)" "AC2 a loaded run that slows both inputs alike passes"

# ── AC3 ──────────────────────────────────────────────────────────────────────
OFFENDERS="$(python3 -I - "$TALOS_ROOT/tests" <<'PYEOF'
import glob, os, re, sys
pat = re.compile(r'(\b(_?elapsed|ELAPSED|_secs|SECS|_dt)\b[^#\n]*?(-lt|-le|<=?)\s*[0-9]+)'
                 r'|(exit !\(s < [0-9]+\))'
                 r'|(float\(sys\.argv\[[0-9]\]\)(\s*-\s*float\(sys\.argv\[[0-9]\]\))? < [0-9.]+)'
                 r'|(\$T1 - \$T0 < [0-9]+)')
skip = {"helpers.sh", "test-timing-guard.sh"}
for f in sorted(glob.glob(os.path.join(sys.argv[1], "test-*.sh"))):
    if os.path.basename(f) in skip:
        continue
    for i, line in enumerate(open(f, errors="replace"), 1):
        if not line.lstrip().startswith("#") and pat.search(line):
            print("%s:%d" % (os.path.basename(f), i))
PYEOF
)"
assert_eq "" "$OFFENDERS" "AC3 no test compares an elapsed time with a literal number of seconds outside the helpers"

# ── AC4 ──────────────────────────────────────────────────────────────────────
# wall_s and since_s each run in their own process. A clock that counts from its
# own process's start reads 0 for any wait, and every assertion fed by it passes
# whatever it times: AC1 and AC2 above only see synthetic numbers.
T0="$(wall_s)"
sleep 1
WAITED="$(since_s "$T0")"
if python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 1 else 1)' "$WAITED"; then
  pass "AC4 since_s reads at least 1 s across a 1 s sleep"
else
  fail "AC4 since_s reads at least 1 s across a 1 s sleep" "read ${WAITED}s"
fi

finish
