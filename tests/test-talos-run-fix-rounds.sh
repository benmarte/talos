#!/usr/bin/env bash
# test-talos-run-fix-rounds.sh -- `scripts/talos.sh run`, part 2 of 4 (#472,
# #690): a QA FAIL and a review finding are developer fix rounds. The body and
# the parts are described in tests/talos-run-sections.sh.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=2
. "$(dirname "$0")/talos-run-sections.sh"
