#!/usr/bin/env bash
# pipeline-isolation.sh — startup gate and per-issue preconditions for
# execution.isolation config (#98).
#
# Verbs:
#   validate    Read execution.isolation and issues.max_parallel from config;
#               exit 0 if the combination is valid, 1 if not.
#               Unknown / unimplemented modes are refused with a clear message.
#
# Environment:
#   PIPELINE_CONFIG   Absolute path to config file (passed through to
#                     pipeline-config.sh). If absent, pipeline-config.sh
#                     searches for talos.pipeline.yml/.yaml/.json.
#
# Config keys read:
#   execution.isolation   worktree (default) | branch | checkout (refused)
#   issues.max_parallel   integer, default 1
#
# Modes:
#   worktree   Default — unchanged from today; no new constraints.
#   branch     Stages run in the orchestrator's checkout on a per-issue branch.
#              Requires issues.max_parallel: 1. Enforced here at startup.
#   checkout   Recognised but refused — not yet implemented.
#   *          Any other value → refused with a list of valid values.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$REPO_ROOT/scripts/pipeline-config.sh"

verb="${1:-}"; shift || true

case "$verb" in
  validate)
    ISOLATION="$(bash "$CFG" execution.isolation worktree)"
    MAX_PARALLEL="$(bash "$CFG" issues.max_parallel 1)"

    case "$ISOLATION" in
      worktree)
        # Default — unchanged; no new constraints.
        exit 0
        ;;
      branch)
        if [ "$MAX_PARALLEL" -gt 1 ] 2>/dev/null; then
          printf 'ERROR: isolation: branch requires issues.max_parallel: 1 — two agents cannot safely share one checkout. Set max_parallel: 1 or switch to isolation: worktree.\n' >&2
          exit 1
        fi
        exit 0
        ;;
      checkout)
        printf 'ERROR: isolation: checkout is not yet implemented. Use isolation: worktree (default) or isolation: branch.\n' >&2
        exit 1
        ;;
      *)
        printf 'ERROR: Unknown isolation mode '"'"'%s'"'"'. Valid values: worktree, branch, checkout (checkout not yet implemented).\n' "$ISOLATION" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'usage: pipeline-isolation.sh validate\n' >&2
    exit 2
    ;;
esac
