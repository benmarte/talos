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

# ── --dump (#169) ─────────────────────────────────────────────────────────────
# Prints the whole resolved config once as NUL-delimited key/value pairs
# (key NUL value NUL key NUL value NUL ...) instead of one dot-path lookup.
# Callers that used to shell out to this script once per cfg() call (a fresh
# python3 process re-parsing the config file every time) can spawn python3
# once per script invocation instead: dump here, then answer every lookup
# from the cached output with pure shell. A key absent from the dump means
# "absent in config" — the caller applies its own caller-supplied default,
# exactly like the single-key path below does. Same file-lookup order, same
# YAML-then-JSON precedence, and the same "verify" (dict-form → commands
# list) / "verify.qa_mode" (merge.required_checks-derived default, fail-
# closed downgrade) special cases as the single-key path, so a lookup
# against this dump is byte-identical to calling this script for that key
# directly. Purely additive: an early exit, does not touch anything below.
if [ "${1:-}" = "--dump" ]; then
  _DCFG="${PIPELINE_CONFIG:-}"
  if [ -z "$_DCFG" ]; then
    for _dcandidate in "talos.pipeline.yml" "talos.pipeline.yaml" "talos.pipeline.json" \
                     ".claude-pipeline.yaml" "pipeline.yaml" \
                     ".claude-pipeline.json" "pipeline.json"; do
      if [ -f "$_dcandidate" ]; then
        _DCFG="$_dcandidate"
        break
      fi
    done
  fi
  # No config present (or unreadable) — nothing to dump; every lookup falls
  # back to its caller's default, same as "no config found" below.
  if [ -z "$_DCFG" ] || [ ! -f "$_DCFG" ]; then
    exit 0
  fi
  python3 - "$_DCFG" <<'PYEOF'
import sys

cfg_path = sys.argv[1]

def walk(obj, parts):
    for part in parts:
        if isinstance(obj, dict) and part in obj:
            obj = obj[part]
        else:
            return None
    return obj

try:
    try:
        import yaml
        with open(cfg_path) as f:
            cfg = yaml.safe_load(f) or {}
    except ImportError:
        import json
        with open(cfg_path) as f:
            cfg = json.load(f)
except Exception:
    # Unparseable config -- dump nothing; every key falls back to its
    # caller-supplied default, same as the single-key path's behaviour.
    cfg = {}

if not isinstance(cfg, dict):
    cfg = {}

flat = {}

def flatten(obj, prefix):
    if isinstance(obj, dict):
        for k, v in obj.items():
            flatten(v, "%s.%s" % (prefix, k) if prefix else k)
    elif obj is not None:
        flat[prefix] = obj

flatten(cfg, "")

# "verify" dict-form -> commands list (mirrors the single-key path). List
# form is already captured correctly by the generic flatten() above.
_raw_verify = cfg.get("verify")
if isinstance(_raw_verify, dict):
    flat["verify"] = _raw_verify.get("commands", [])

# verify.qa_mode derived default + fail-closed downgrade (mirrors the
# single-key path exactly, including the one-line stderr warning).
_required_checks = walk(cfg, "merge.required_checks".split("."))
_has_required_checks = isinstance(_required_checks, list) and len(_required_checks) > 0
_qa_mode = walk(cfg, "verify.qa_mode".split("."))
if _qa_mode is None:
    _qa_mode = "ci" if _has_required_checks else "local"
if _qa_mode == "ci" and not _has_required_checks:
    sys.stderr.write(
        "pipeline-config: verify.qa_mode=ci with empty/absent "
        "merge.required_checks -- resolving to 'local' (ci mode would "
        "pass QA vacuously with no required checks to poll)\n"
    )
    _qa_mode = "local"
flat["verify.qa_mode"] = _qa_mode

out = sys.stdout.buffer
for k, v in flat.items():
    if isinstance(v, bool):
        s = "true" if v else "false"
    elif isinstance(v, list):
        s = "\n".join(str(x) for x in v)
    else:
        s = str(v)
    out.write(k.encode("utf-8", "surrogateescape"))
    out.write(b"\x00")
    out.write(s.encode("utf-8", "surrogateescape"))
    out.write(b"\x00")
PYEOF
  exit 0
fi

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
# form (verify: {commands: [...], qa_mode: ..., targeted: ..., ci_wait_s: ...})
# so verify.qa_mode / verify.targeted / verify.ci_wait_s can be read with the
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
