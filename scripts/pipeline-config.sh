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
# closed downgrade) / "verify.timeout_ms" / "verify.ci_wait_s" (positive-
# integer validation, fail-closed to the caller's default) special cases as
# the single-key path, so a lookup against this dump is byte-identical to
# calling this script for that key directly. Purely additive: an early
# exit, does not touch anything below.

# ── Known config keys (#176) ────────────────────────────────────────────────
# Every documented config key, "*" standing in for a dynamic segment
# (board.status_map.*, agents.roles.*.model, etc.). Defined once, here, at
# module level, as JSON -- the --dump path and the single-key path below
# each parse the config file in their own separate python3 process (so the
# unknown-key check itself can't literally be one shared function call, see
# both copies' comments), but both are handed this exact same JSON via argv
# instead of each embedding their own copy of the list as a Python literal.
_KNOWN_CONFIG_KEYS_JSON='[
  "base_branch", "release_branch", "repo",
  "vcs.provider", "vcs.repo", "vcs.token_env",
  "vcs.azure.org_url", "vcs.azure.project", "vcs.azure.work_item_type",
  "vcs.azure.area_path", "vcs.file.source.path",
  "board.enabled", "board.project_number", "board.owner",
  "board.status_field", "board.statuses.*", "board.status_map.*",
  "board.azure_states.*",
  "verify", "verify.commands", "verify.qa_mode", "verify.targeted",
  "verify.ci_wait_s", "verify.timeout_ms",
  "merge.auto", "merge.method", "merge.required_checks",
  "merge.delete_branch", "merge.forbidden_files",
  "merge.forbidden_files_replace", "merge.forbidden_files_allow",
  "merge.approval_waiver_paths",
  "issues.label_filter", "issues.skip_labels", "issues.max_parallel",
  "execution.isolation", "execution.worktree_warn_threshold",
  "roles.validator", "roles.pm", "roles.pm_skip_when_spec_present",
  "roles.qa", "roles.reviewer", "roles.security", "roles.docs",
  "roles.docs_mode", "roles.planner",
  "comments.enabled", "comments.header", "comments.templates_dir",
  "notifications.slack_channel", "notifications.discord_channel",
  "notifications.buzz_channel", "notifications.buzz_relay",
  "notifications.templates_dir", "notifications.threading",
  "notifications.events",
  "agents.runner", "agents.subagents", "agents.runner_args",
  "agents.runner_cmd", "agents.model",
  "agents.roles.*.model", "agents.roles.*.runner",
  "agents.roles.*.runner_cmd",
  "limits.max_fix_attempts", "limits.max_total_dispatches",
  "limits.max_retries",
  "markers.trusted_authors"
]'

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
  python3 - "$_DCFG" "$_KNOWN_CONFIG_KEYS_JSON" <<'PYEOF'
import sys

cfg_path = sys.argv[1]
known_keys_json = sys.argv[2]

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

# ── Unknown-key warning (#176) ──────────────────────────────────────────────
# This dump is what cfg() (pipeline-cfg-cache.sh) answers every lookup from,
# so it's the one place a typo in the config file is guaranteed to be seen
# exactly once per script invocation, regardless of how many keys the
# invoking script goes on to look up. The single-key path below runs this
# same check for direct (non-cached) callers -- it parses the file
# independently in its own python3 process, so the check can't literally be
# one shared function call, but both paths define the identical
# _warn_unknown_keys() helper (same wildcard-matching rules, same
# nearest-match suggestion, same env opt-out) against the same
# _KNOWN_CONFIG_KEYS list (module-level, passed in via argv -- see the
# top of this script) so a typo warns identically no matter which path
# answered the lookup. Runs against the config exactly as parsed -- not
# after any derived-default keys (verify.qa_mode, etc.) are synthesized
# below -- so only keys the user actually wrote are ever flagged.
import difflib
import json
import os

# Handed in via argv (module-level definition, see top of this script) so
# both this path and the single-key path below stay byte-identical for
# every key without either duplicating the list as a Python literal.
_KNOWN_CONFIG_KEYS = json.loads(known_keys_json)

def _present_leaf_keys(obj, prefix, out):
    if isinstance(obj, dict):
        for k, v in obj.items():
            _present_leaf_keys(v, "%s.%s" % (prefix, k) if prefix else k, out)
    elif obj is not None:
        out.append(prefix)

def _key_matches(parts, template_parts):
    return len(parts) == len(template_parts) and all(
        t == "*" or t == p for t, p in zip(template_parts, parts)
    )

def _warn_unknown_keys(cfg_obj):
    if os.environ.get("TALOS_CONFIG_STRICT_KEYS", "1") == "0":
        return
    if not isinstance(cfg_obj, dict):
        return
    present = []
    _present_leaf_keys(cfg_obj, "", present)
    templates = [t.split(".") for t in _KNOWN_CONFIG_KEYS]
    for key in present:
        if key.split(".")[-1] == "_note":
            continue
        parts = key.split(".")
        if any(_key_matches(parts, t) for t in templates):
            continue
        candidates = []
        for t in templates:
            if len(t) == len(parts):
                candidates.append(
                    ".".join(tp if tp != "*" else p for tp, p in zip(t, parts))
                )
            else:
                candidates.append(".".join(t))
        match = difflib.get_close_matches(key, candidates, n=1, cutoff=0.6)
        if match:
            sys.stderr.write(
                "pipeline-config: [warn] unknown config key %r "
                "(did you mean %r?)\n" % (key, match[0])
            )
        else:
            sys.stderr.write(
                "pipeline-config: [warn] unknown config key %r\n" % key
            )

try:
    _warn_unknown_keys(cfg)
except Exception as _e:
    # The unknown-key check must never take stdout down with it -- a
    # crash here (e.g. an unexpected cfg shape) would abort the whole
    # python3 process before flat/stdout is built, silently breaking
    # every caller's config lookup, not just the warning. Fail loud
    # instead of silent: one line naming the reason, then continue.
    sys.stderr.write(
        "pipeline-config: [warn] unknown-key check unavailable: %s\n"
        % _e
    )

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

# verify.timeout_ms / verify.ci_wait_s (#205 review follow-up): this dump is
# what cfg() answers every lookup from (pipeline-cfg-cache.sh), so it must
# mirror the single-key path's positive-integer validation below or a
# non-integer/injectable config value would reach a caller unvalidated,
# reopening the shell-injection surface that validation closed on the
# direct path. This block and the single-key path below run as separate
# python3 processes, so the validation can't literally be one shared
# function call -- instead both define the identical _validate_int_key(key,
# value) helper (same units, same fail-closed-to-absent behaviour, same
# one-line stderr warning) so the two paths stay byte-identical for these
# keys.
def _validate_int_key(key, value):
    unit = {"verify.timeout_ms": "milliseconds", "verify.ci_wait_s": "seconds"}.get(key)
    if unit is None or value is None:
        return value
    try:
        iv = int(value)
        if iv <= 0:
            raise ValueError
        return iv
    except (TypeError, ValueError):
        sys.stderr.write(
            "pipeline-config: %s must be a positive integer (%s) -- got: %r "
            "-- using default\n" % (key, unit, value)
        )
        return None

for _int_key in ("verify.timeout_ms", "verify.ci_wait_s"):
    if _int_key in flat:
        _validated = _validate_int_key(_int_key, flat[_int_key])
        if _validated is None:
            # Same as an absent key: the caller applies its own default.
            del flat[_int_key]
        else:
            flat[_int_key] = _validated

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
# The heredoc passes file path, key, default, and the known-keys JSON as
# argv to avoid shell quoting issues with special characters in values.
python3 - "$CFG" "$KEY" "$DEFAULT" "$_KNOWN_CONFIG_KEYS_JSON" <<'PYEOF'
import sys

cfg_path = sys.argv[1]
key      = sys.argv[2]
default  = sys.argv[3] if len(sys.argv) > 3 else ""
known_keys_json = sys.argv[4] if len(sys.argv) > 4 else "[]"

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

# ── Unknown-key warning (#176) ──────────────────────────────────────────────
# This path parses the config file independently of the --dump path above
# (two separate python3 processes), so the check can't literally be one
# shared function call, but both paths define the identical
# _warn_unknown_keys() helper (same wildcard-matching rules, same
# nearest-match suggestion, same env opt-out) against the same
# _KNOWN_CONFIG_KEYS list (module-level, passed in via argv -- see the
# top of this script) so a typo warns identically no matter which path
# answered the lookup. cfg() (pipeline-cfg-cache.sh) calls --dump once per script
# invocation and answers every lookup from that cache, so a cached caller
# only hits the --dump path's copy of this check; a direct (non-cached)
# call to this script hits this copy instead, once per invocation.
import difflib
import json
import os

# Handed in via argv (module-level definition, see top of this script) so
# both this path and the --dump path above stay byte-identical for every
# key without either duplicating the list as a Python literal.
_KNOWN_CONFIG_KEYS = json.loads(known_keys_json)

def _present_leaf_keys(obj, prefix, out):
    if isinstance(obj, dict):
        for k, v in obj.items():
            _present_leaf_keys(v, "%s.%s" % (prefix, k) if prefix else k, out)
    elif obj is not None:
        out.append(prefix)

def _key_matches(parts, template_parts):
    return len(parts) == len(template_parts) and all(
        t == "*" or t == p for t, p in zip(template_parts, parts)
    )

def _warn_unknown_keys(cfg_obj):
    if os.environ.get("TALOS_CONFIG_STRICT_KEYS", "1") == "0":
        return
    if not isinstance(cfg_obj, dict):
        return
    present = []
    _present_leaf_keys(cfg_obj, "", present)
    templates = [t.split(".") for t in _KNOWN_CONFIG_KEYS]
    for key in present:
        if key.split(".")[-1] == "_note":
            continue
        parts = key.split(".")
        if any(_key_matches(parts, t) for t in templates):
            continue
        candidates = []
        for t in templates:
            if len(t) == len(parts):
                candidates.append(
                    ".".join(tp if tp != "*" else p for tp, p in zip(t, parts))
                )
            else:
                candidates.append(".".join(t))
        match = difflib.get_close_matches(key, candidates, n=1, cutoff=0.6)
        if match:
            sys.stderr.write(
                "pipeline-config: [warn] unknown config key %r "
                "(did you mean %r?)\n" % (key, match[0])
            )
        else:
            sys.stderr.write(
                "pipeline-config: [warn] unknown config key %r\n" % key
            )

try:
    _warn_unknown_keys(cfg)
except Exception as _e:
    # The unknown-key check must never take stdout down with it -- a
    # crash here (e.g. an unexpected cfg shape) would abort the whole
    # python3 process before flat/stdout is built, silently breaking
    # every caller's config lookup, not just the warning. Fail loud
    # instead of silent: one line naming the reason, then continue.
    sys.stderr.write(
        "pipeline-config: [warn] unknown-key check unavailable: %s\n"
        % _e
    )

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
# CI-wait instructions. verify.ci_wait_s (#205 security follow-up) is
# interpolated unquoted into a literal, agent-executed shell test
# (`[ "$SECONDS" -ge <VERIFY_CI_WAIT_S> ]`) in the QA CI-wait loop. Both
# must be a positive integer -- a non-integer or non-positive config value
# (or one carrying shell metacharacters) is a config error, not a value an
# agent can act on, so fail closed to the caller-supplied default (600000 /
# 900 respectively, from Step 0) and warn once on stderr rather than
# handing a subagent a garbage timeout or an injectable string. Mirrors the
# --dump path above: both define the identical _validate_int_key(key,
# value) helper (same units, same fail-closed-to-absent behaviour, same
# one-line stderr warning) so the two paths stay byte-identical for these
# keys.
def _validate_int_key(key, value):
    unit = {"verify.timeout_ms": "milliseconds", "verify.ci_wait_s": "seconds"}.get(key)
    if unit is None or value is None:
        return value
    try:
        iv = int(value)
        if iv <= 0:
            raise ValueError
        return iv
    except (TypeError, ValueError):
        sys.stderr.write(
            "pipeline-config: %s must be a positive integer (%s) -- got: %r "
            "-- using default\n" % (key, unit, value)
        )
        return None

value = _validate_int_key(key, value)

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
