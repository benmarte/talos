#!/usr/bin/env bash
# test-talos-run-state-reads.sh -- `scripts/talos.sh run`, part 3 of 4 (#472,
# #690): the merge arm's gate answers, the developer's `pr=<N>` word, the
# collected state read once per state and BLOCKED for any role. The body and
# the parts are described in tests/talos-run-sections.sh.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=3
. "$(dirname "$0")/talos-run-sections.sh"
