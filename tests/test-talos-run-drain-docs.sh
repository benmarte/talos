#!/usr/bin/env bash
# test-talos-run-drain-docs.sh -- `scripts/talos.sh run`, part 4 of 4 (#472,
# #690): one run drains the queue, and the docs delta re-stamp. The body and the
# parts are described in tests/talos-run-sections.sh.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=4
. "$(dirname "$0")/talos-run-sections.sh"
