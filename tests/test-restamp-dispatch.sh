#!/usr/bin/env bash
# Cheap delta re-stamp for stale approvals (#258): the config keys it reads.
#
# The re-stamp flow itself (RESTAMP_FAIL strips the stale label, then the
# verdict relays) is run by tests/test-talos-done.sh; the prompt by
# tests/test-talos-prompt.sh. What stays here is the config contract:
# agents.restamp_model / agents.roles.<role>.restamp_model are known keys (a
# regression would make pipeline-config.sh warn on every lookup).
set -u
. "$(dirname "$0")/helpers.sh"

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"

_dump_out="$(bash "$CFG_SH" --dump 2>&1 >/dev/null)"
assert_eq "" "$_dump_out" "pipeline-config.sh --dump warns on nothing with no config present"

finish
