#!/usr/bin/env bash
# Stub test runner for the criteria-first worked example (#421). It prints the
# same assertion labels tests/helpers.sh does (`  ok  <label>` on stdout,
# `FAIL  <label>` on stderr) so pipeline-criteria.sh can map them to ids. The
# "implementation" is a file: red until feature.txt says done, green after.
# Run from the repo root of the example (the sandbox).
if [ -f feature.txt ] && [ "$(cat feature.txt)" = "done" ]; then
  printf '  ok  AC1 greet prints hello when feature.txt says done\n'
  exit 0
fi
printf 'FAIL  AC1 greet prints hello when feature.txt says done\n' >&2
printf '      expected: done | actual: <missing>\n' >&2
exit 1
