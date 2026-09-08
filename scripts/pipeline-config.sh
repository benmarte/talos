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
    # Config file present but unparseable. Return the caller-supplied default.
    # The warning is emitted once in-process by pipeline-vcs.sh at startup.
    # Direct invocations of pipeline-config.sh degrade silently -- not a crash,
    # not permanent silence, and nothing an external process can suppress.
    print(default, end='')
    sys.exit(0)

value = walk(cfg, key.split("."))

# "verify" is historically a flat list of shell commands. Also accept a dict
# form (verify: {commands: [...], qa_mode: ..., targeted: ..., ci_wait_s: ...,
# timeout_ms: ...}) so verify.qa_mode / verify.targeted / verify.ci_wait_s /
# verify.timeout_ms can be read with the
# normal dot-path lookup below without disturbing what plain "verify" returns
# to existing callers (a newline-joined command list).
if key == "verify" and isinstance(value, dict):
    value = value.get("commands", [])

# verify.qa_mode has a config-derived default that overrides whatever default
# the caller passed in: "ci" when merge.required_checks is a non-empty list
# (CI is already the suite oracle), "local" otherwise. An explicit
# verify.qa_mode value in config always wins over this derived default --
# EXCEPT that "ci" with an empty/absent merge.required_checks list is a
# fail-open trap: QA would trust CI as the oracle for a check list that has
# nothing in it, i.e. pass vacuously without ever running verify: locally
# or observing any real CI signal. Fail closed instead: resolve to "local"
# and warn once on stderr, regardless of whether "ci" came from this derived
# default or from an explicit verify.qa_mode: ci in the config.
if key == "verify.qa_mode":
    required_checks = walk(cfg, "merge.required_checks".split("."))
    has_required_checks = isinstance(required_checks, list) and len(required_checks) > 0
    if value is None:
        value = "ci" if has_required_checks else "local"
    if value == "ci" and not has_required_checks:
        sys.stderr.write(
            "pipeline-config: verify.qa_mode=ci with empty/absent "
            "merge.required_checks -- resolving to 'local' (ci mode would "
            "pass QA vacuously with no required checks to poll)\n"
        )
        value = "local"

# verify.timeout_ms (#205) is the explicit foreground timeout, in
# milliseconds, that developer/QA prompts substitute into their verify and
# CI-wait instructions. It must be a positive integer -- a non-integer or
# non-positive config value is a config error, not a value an agent can act
# on, so fail closed to the caller-supplied default (600000 from Step 0) and
# warn once on stderr rather than handing a subagent a garbage timeout.
if key == "verify.timeout_ms" and value is not None:
    try:
        iv = int(value)
        if iv <= 0:
            raise ValueError
        value = iv
    except (TypeError, ValueError):
        sys.stderr.write(
            "pipeline-config: verify.timeout_ms must be a positive integer "
            "(milliseconds) -- got: %r -- using default\n" % (value,)
        )
        value = None

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
