#!/usr/bin/env bash
# Config contract for the post-merge sibling sync (#289): `talos.sh env` reads
# merge.auto_sync (MERGE_AUTO_SYNC) with default true, and the key is in the
# known-keys list so pipeline-config.sh raises no unknown-key warning. The sync
# ladder itself is run by tests/test-talos-postmerge.sh and tests/test-mergesync.sh.
set -u
. "$(dirname "$0")/helpers.sh"

CFG="$TALOS_ROOT/scripts/pipeline-defaults.sh"  # the known-keys list is the table's key column (#439)

# Step 0 is `talos.sh env` (#465): the variable and its default live in its table.
assert_eq "merge.auto_sync" "$(talos_env_key MERGE_AUTO_SYNC)" "env: MERGE_AUTO_SYNC reads merge.auto_sync"
assert_eq "true" "$(talos_env_default MERGE_AUTO_SYNC)" "env: merge.auto_sync defaults to true"

cfg_keys="$(grep -c "merge.auto_sync" "$CFG")"
assert_eq "1" "$cfg_keys" "config: merge.auto_sync in known keys"

finish
