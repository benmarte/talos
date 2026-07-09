#!/usr/bin/env bash
# pipeline-config.sh — read a dot-path key from the project pipeline config.
#
# Usage:   pipeline-config.sh KEY [default]
# Example: pipeline-config.sh board.project_number 1
#          pipeline-config.sh notifications.slack_channel ""
#          pipeline-config.sh merge.method squash
#
# Config file lookup order:
#   1. $PIPELINE_CONFIG env var (absolute path to config file)
#   2. ./talos.pipeline.yml (.yaml / .json variants)
#   3. Legacy names: ./.claude-pipeline.yaml, ./pipeline.yaml (+ .json variants)
#   4. No config found — returns the default (or empty string)
#
# YAML parsing:
#   Uses PyYAML (python3 -c "import yaml") if importable.
#   Falls back to JSON parsing for .json config files (rename yours to
#   talos.pipeline.json or pipeline.json).
#   Never crashes — missing keys, absent files, or parse errors all return
#   the default silently.
#
set -u

KEY="${1:-}"
DEFAULT="${2:-}"

[ -z "$KEY" ] && { printf '%s' "$DEFAULT"; exit 0; }

# ── Locate config file ────────────────────────────────────────────────────────
CFG="${PIPELINE_CONFIG:-}"
if [ -z "$CFG" ]; then
  # talos.* names win; .claude-pipeline.* / pipeline.* honored as legacy
  for candidate in "talos.pipeline.yml" "talos.pipeline.yaml" "talos.pipeline.json" \
                   ".claude-pipeline.yaml" "pipeline.yaml" \
                   ".claude-pipeline.json" "pipeline.json"; do
    if [ -f "$candidate" ]; then
      CFG="$candidate"
      break
    fi
  done
fi

# No config present — return default
if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then
  printf '%s' "$DEFAULT"
  exit 0
fi

# ── Parse and extract with Python ────────────────────────────────────────────
# The heredoc passes file path, key, and default as argv to avoid shell
# quoting issues with special characters in values.
python3 - "$CFG" "$KEY" "$DEFAULT" <<'PYEOF'
import sys

cfg_path = sys.argv[1]
key      = sys.argv[2]
default  = sys.argv[3] if len(sys.argv) > 3 else ""

def walk(obj, parts):
    for part in parts:
        if isinstance(obj, dict) and part in obj:
            obj = obj[part]
        else:
            return None
    return obj

try:
    # Prefer PyYAML for .yaml files; fall back to json for everything else.
    try:
        import yaml
        with open(cfg_path) as f:
            cfg = yaml.safe_load(f) or {}
    except ImportError:
        import json
        with open(cfg_path) as f:
            cfg = json.load(f)
except Exception:
    print(default, end="")
    sys.exit(0)

value = walk(cfg, key.split("."))
if value is None:
    print(default, end="")
elif isinstance(value, bool):
    # Normalise Python True/False to lowercase strings ("true"/"false") so
    # callers can do: [ "$(pipeline-config.sh board.enabled true)" = "true" ]
    print(str(value).lower(), end="")
elif isinstance(value, list):
    # Return lists as newline-separated values for easy shell iteration.
    print("\n".join(str(v) for v in value), end="")
else:
    print(str(value), end="")
PYEOF
