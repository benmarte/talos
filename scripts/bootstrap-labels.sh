#!/usr/bin/env bash
# Create the pipeline:* label state machine in the current repo (idempotent).
# Usage: bash scripts/bootstrap-labels.sh [owner/repo]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Label list is the single source of truth in pipeline-contract.sh (#178) --
# guarded like every other pipeline-*.sh's cfg-cache source, since a
# partial install/sync may not yet ship it.
if [ -f "$SCRIPT_DIR/pipeline-contract.sh" ]; then
  . "$SCRIPT_DIR/pipeline-contract.sh"
else
  echo "bootstrap-labels: pipeline-contract.sh not found next to this script -- aborting" >&2
  exit 1
fi

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
echo "Bootstrapping pipeline labels in $REPO"

labels=(
  "${TALOS_STAGE_LABELS[@]}"
  "${TALOS_APPROVAL_LABELS[@]}"
  "${TALOS_MISC_LABELS[@]}"
)

for entry in "${labels[@]}"; do
  name="${entry%%|*}"; rest="${entry#*|}"
  color="${rest%%|*}"; desc="${rest#*|}"
  gh label create "$name" --color "$color" --description "$desc" --repo "$REPO" 2>/dev/null \
    && echo "  + $name" \
    || gh label edit "$name" --color "$color" --description "$desc" --repo "$REPO" >/dev/null \
    && echo "  ~ $name (updated)"
done
echo "Done. Add 'pipeline:ready' to an issue to start the pipeline."
