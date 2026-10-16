#!/usr/bin/env bash
# test-talos-run.sh -- `scripts/talos.sh run`, part 1 of 4 (#472, #690): the
# loop, the verdict reading, the provider contract, the pass cap and lease, the
# in-flight fallback and the draft-window completion. The body and the parts
# are described in tests/talos-run-sections.sh.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=1
. "$(dirname "$0")/talos-run-sections.sh"
