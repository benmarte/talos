#!/usr/bin/env bash
# test-talos-run-merge-conflict-850.sh -- `talos.sh run` turns a merge gate's
# `redispatch reason=merge-conflict` into one developer merge-base fix round
# (#850). The section is part 850 of tests/talos-run-sections.sh (reuses its
# merge_fixture and ALL_APPROVALS); AC ids are the spec's.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=850 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"
finish
