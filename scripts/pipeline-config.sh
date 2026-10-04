#!/usr/bin/env bash
# pipeline-config.sh — read a dot-path key from the project pipeline config.
#
# Usage:   pipeline-config.sh KEY [default]
#          pipeline-config.sh --has KEY     exit 0 when KEY is set in a config
#                                           file, 1 when it is not, 3 when it
#                                           is not found and a config file
#                                           could not be parsed
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
# Defaults (#439): a key absent from every config layer prints the default
# argument when one is given (even ""), else the key's default from the config
# schema table (pipeline-defaults.sh; empty for a derived key). With no config
# file at all, none of this spawns python3.
#
# Layers (#336, #441), lowest to highest: the table default, the global file
# ${TALOS_HOME:-$HOME/.talos}/talos.pipeline.{yml,yaml,json}, the repo's own
# config, then the key's environment variable (the table's env column, e.g.
# PIPELINE_SLACK_CHANNEL; set and non-empty). Each layer overrides the one below
# it key by key; dicts merge, scalars replace, and a list in a higher layer
# replaces the lower layer's list whole (no union). The global file may set any
# key except the repo-only ones (the table's scope column), which are dropped
# with one stderr note naming the key -- see the shared loader below.
#
#   --dump          every resolved key as NUL-delimited pairs (one python3 spawn)
#   --dump-layers   "agents.* key<TAB>project|global" lines (--resolve-all origin)
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
# closed downgrade) / "verify.timeout_ms" / "verify.ci_wait_s" /
# "hooks.timeout_s" / "notifications.cmd_timeout_s" / "status.log_days" /
# "status.log_max" / "status.resume_max_lines" (positive-integer
# validation, fail-closed to the caller's default) special cases as the
# single-key path, so a lookup
# against this dump is byte-identical to calling this script for that key
# directly. Purely additive: an early exit, does not touch anything below.

# ── Known config keys (#176, #439) ──────────────────────────────────────────
# Every documented config key, "*" standing in for a dynamic segment
# (board.status_map.*, agents.roles.*.model, etc.). The list is the key column
# of the config schema table in pipeline-defaults.sh (#439); it is generated
# from there (_talos_known_keys_json) at the two places that hand it to python3,
# so it can never drift from the table. The --dump path and the single-key path
# below each parse the config file in their own separate python3 process (so
# the unknown-key check itself can't literally be one shared function call, see
# both copies' comments), but both are handed this exact same JSON via argv
# instead of each embedding their own copy of the list as a Python literal.
#
# A partial install may not ship pipeline-defaults.sh yet: then the table is
# empty and the unknown-key check is skipped (an empty list matches nothing).
_CFG_SELF="${BASH_SOURCE[0]}"
case "$_CFG_SELF" in */*) _CFG_SELF_DIR="${_CFG_SELF%/*}" ;; *) _CFG_SELF_DIR="." ;; esac
# The table is loaded only when it is intact (pipeline-defaults-check.sh, shared
# with pipeline-cfg-cache.sh): readable, complete (it ends with its sentinel, so
# a truncated copy is refused) and holding a row for every security-relevant key.
if [ -f "$_CFG_SELF_DIR/pipeline-defaults-check.sh" ] \
   && . "$_CFG_SELF_DIR/pipeline-defaults-check.sh" \
   && _talos_load_defaults "$_CFG_SELF_DIR/pipeline-defaults.sh"; then
  :
else
  echo "pipeline-config: pipeline-defaults.sh missing or unusable next to $0 -- no table defaults, unknown-key check off" >&2
  # Fail closed (#440): with no usable table, a key that has no caller default
  # reads empty -- fine for most keys, but not for the ones that gate a merge, a
  # dispatch budget or a hook. For those the lookup fails (status 1) instead of
  # guessing; the single-key path below turns that into exit 3 when the config
  # does not set the key either. The key list is _talos_security_key in
  # pipeline-defaults-check.sh; when that file is missing too nothing can say
  # which keys are safe to guess, so every key is treated as security-relevant.
  if ! [ "$(type -t _talos_security_key)" = "function" ]; then _talos_security_key() { return 0; }; fi
  _talos_default() { ! _talos_security_key "${1:-}"; }
  _talos_known_keys_json() { printf '[]'; }
  _talos_scope_env_json() { printf '[]'; }
  _talos_env_dump() { :; }
  _talos_env_value() { return 1; }
fi

# ── Shared config loader (#336) ───────────────────────────────────────────────
# One place that finds the config files and one that parses + merges them,
# used by both --dump and the single-key lookup below (they used to each carry
# their own copy of the file-lookup loop and the parse block).
#
# Three file/env layers, the higher one wins per leaf key (#441):
#   1. user-level  ${TALOS_HOME:-$HOME/.talos}/talos.pipeline.{yml,yaml,json}
#                  Every key is read except the repo-only ones (the table's
#                  scope column: keys that describe one repository -- board,
#                  verify commands, merge file lists, ...). A repo-only key
#                  found here is dropped and prints ONE stderr line that names
#                  the key and never its value. Untrusted input: parsed as data
#                  only (JSON / yaml.safe_load), never sourced or evaluated;
#                  missing, unreadable, empty, malformed or non-mapping content
#                  behaves as absent (malformed/empty/non-mapping/unreadable
#                  prints one stderr warning; the lookup and its exit status
#                  are unaffected).
#                  The file must also be trusted (#443): a regular file (or a
#                  symlink you own to one), owned by the current user, not group-
#                  or world-writable, since hooks.* and notifications.cmd run
#                  commands. Otherwise ONE stderr line names it and the fix, and
#                  the layer is read as absent. The check is the shared one in
#                  pipeline-secrets.sh (the same stat helper as ~/.talos/.env),
#                  run inside the loader's python3 process: no extra spawn.
#   2. project     $PIPELINE_CONFIG, else the first existing ./talos.pipeline.*
#                  / legacy name. The user-level layer sits under whichever
#                  one is found.
#   3. env         the variable in the table's env column, when set and not
#                  empty. No generic TALOS_CFG_* scheme.
# The validators below (positive integers, spend, evidence, fallback, effort)
# run on the merged value, so they hold whichever layer supplied it.
# Names tried, in order, for the project file; the first three also bound the
# user-level lookup (same extension order, no legacy names).
_CFG_NAMES=("talos.pipeline.yml" "talos.pipeline.yaml" "talos.pipeline.json"
            ".claude-pipeline.yaml" "pipeline.yaml"
            ".claude-pipeline.json" "pipeline.json")

# Prints the project config path, or nothing when there is none.
_locate_project_cfg() {
  local _p="${PIPELINE_CONFIG:-}" _n
  if [ -z "$_p" ]; then
    for _n in "${_CFG_NAMES[@]}"; do
      if [ -f "$_n" ]; then _p="$_n"; break; fi
    done
  fi
  if [ -n "$_p" ] && [ -f "$_p" ]; then printf '%s' "$_p"; fi
}

# Prints the user-level config path, or nothing when there is none.
_locate_user_cfg() {
  local _dir _n
  if [ -n "${TALOS_HOME:-}" ]; then _dir="$TALOS_HOME"
  elif [ -n "${HOME:-}" ]; then _dir="$HOME/.talos"
  else return 0
  fi
  for _n in "${_CFG_NAMES[@]:0:3}"; do
    if [ -f "$_dir/$_n" ]; then printf '%s' "$_dir/$_n"; return 0; fi
  done
}

# Python half of the loader. Handed to each python3 process as an argv string
# and exec()'d at the top, so the --dump and single-key processes share one
# definition (they are separate processes and cannot import a shared module
# without a new installed file). Defines load_layers(project_path, user_path,
# env=True) -> (project, user, merged) and layer_map(project, user).
# The scope/env data comes from the table in pipeline-defaults.sh: use
# _cfg_loader_src, which prepends it as _CFG_TABLE, never this variable raw.
read -r -d '' _CFG_LOADER_PY <<'PYLOADER' || true
import os
import sys

# Which file layers failed to parse ("project" / "user"): --has reads it so a
# parse error is not mistaken for "the key is absent" (#440).
_LOAD_ERRORS = []

def _warn(msg):
    sys.stderr.write("pipeline-config: [warn] %s\n" % msg)

def _parse_cfg_file(path):
    # Prefer PyYAML (safe_load only); fall back to json without it.
    # -I drops the user site; append it back (never insert: cwd and the
    # stdlib must keep winning) so a pip --user PyYAML still parses YAML config (#395).
    try:
        import site, sys
        sys.path.append(site.getusersitepackages())
    except Exception:
        pass
    try:
        import yaml
    except ImportError:
        yaml = None
    with open(path) as f:
        if yaml is not None:
            return yaml.safe_load(f)
        import json
        return json.load(f)

# Repo-only scope (#441): the table's scope column, as key templates ("*" is
# one dynamic segment). A leaf is repo-only when it equals a template, is a
# shorter prefix of one (a scalar where a mapping belongs), or sits below a
# template that ends in "*". The bare `verify:` list (the verify.commands alias)
# is its own template, so it never captures the any-scope verify.* siblings.
_REPO_ONLY = [k.split(".") for k, scope, _env in _CFG_TABLE if scope == "repo"]

def _is_repo_only(parts):
    return any(
        all(t == "*" or t == p for t, p in zip(tmpl, parts))
        and (len(parts) <= len(tmpl) or tmpl[-1] == "*")
        for tmpl in _REPO_ONLY)

def _drop_repo_only(obj, parts, shown):
    # Copy of the user-level mapping without its repo-only leaves, one stderr
    # note per dropped leaf. The note names the key (repr'd and cut, so a key
    # can never carry a newline or control sequence) and never the value.
    out = {}
    for k, v in obj.items():
        sub = parts + [str(k)]
        if isinstance(v, dict):
            kept = _drop_repo_only(v, sub, shown)
            if kept or not v:  # a mapping emptied by the drops is not left behind
                out[k] = kept
        elif _is_repo_only(sub):
            if v is not None:
                _warn("user-level config %s: ignoring repo-only key %s (set it "
                      "in the repo's config file, not the user-level one)"
                      % (shown, repr(".".join(sub))[:80]))
        else:
            out[k] = v
    return out

def _apply_env(merged):
    # Layer 4: each table key's environment variable, when set and non-empty.
    # Works on a deep copy so the project/user dicts layer_map() reads stay as
    # loaded. Wildcard keys never have an env variable.
    import copy
    out = copy.deepcopy(merged)
    for key, _scope, var in _CFG_TABLE:
        if var == "-" or "*" in key:
            continue
        val = os.environ.get(var)
        if not val:
            continue
        node = out
        parts = key.split(".")
        for part in parts[:-1]:
            if not isinstance(node.get(part), dict):
                node[part] = {}
            node = node[part]
        node[parts[-1]] = val
    return out

def _load_user_layer(user_path, project_path):
    if not user_path:
        return {}
    try:
        if project_path and os.path.realpath(user_path) == os.path.realpath(project_path):
            return {}  # the project file IS the user-level file: one layer only
    except Exception:
        pass
    # repr() of every name below: a key or path from the file can never carry
    # a newline or terminal control sequence into the message.
    shown = repr(user_path)
    # Trust check (#443): this file drives hooks.* and notifications.cmd, which
    # run commands, so it must be ours and not writable by anyone else. A file
    # that fails is refused with one line and read as absent: every key falls
    # back to the repo file or the defaults, never a crash.
    try:
        problem = trust_problem(os.geteuid(), "config-file", user_path)
    except NameError:
        problem = ("the trust check is not installed (pipeline-secrets.sh is missing)",
                   "reinstall Talos")
    except Exception as e:
        problem = ("the trust check failed (%s)" % type(e).__name__, "check the file")
    if problem:
        _warn("refusing global config %s: %s; %s -- using defaults" % (shown, problem[0], problem[1]))
        return {}
    try:
        raw = _parse_cfg_file(user_path)
    except Exception as e:
        # Type name only: a parser's message may echo file content.
        _LOAD_ERRORS.append("user")
        _warn("user-level config %s unreadable or malformed (%s) -- ignoring it"
              % (shown, type(e).__name__))
        return {}
    if raw is None:
        _warn("user-level config %s is empty -- ignoring it" % shown)
        return {}
    if not isinstance(raw, dict):
        _warn("user-level config %s must be a mapping -- ignoring it" % shown)
        return {}
    return _drop_repo_only(raw, [], shown)

def _deep_merge(base, over):
    out = dict(base)
    for k, v in over.items():
        if v is None and k in out:
            continue  # an empty project leaf does not erase the user-level one
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out

def load_layers(project_path, user_path, env=True):
    # env=False: the file layers only (--has asks whether a config FILE sets a key).
    project = {}
    if project_path:
        try:
            project = _parse_cfg_file(project_path) or {}
        except Exception:
            # Unparseable project config: treated as absent (the warning is
            # emitted once in-process by pipeline-vcs.sh at startup). Every
            # key falls back to the user-level layer or the caller default.
            project = {}
            _LOAD_ERRORS.append("project")
    if not isinstance(project, dict):
        project = {}
    user = _load_user_layer(user_path, project_path)
    merged = _deep_merge(user, project)
    return project, user, (_apply_env(merged) if env else merged)

def layer_map(project, user):
    # dotted agents.* leaf key -> "project" | "global" (the file that supplied
    # the winning value). Keys with control characters are skipped.
    out = {}
    def leaves(obj, prefix, label):
        if isinstance(obj, dict):
            for k, v in obj.items():
                leaves(v, "%s.%s" % (prefix, k) if prefix else str(k), label)
        elif obj is not None:
            out[prefix] = label
    leaves(user.get("agents"), "agents", "global")
    leaves(project.get("agents"), "agents", "project")
    return {k: v for k, v in out.items() if all(32 <= ord(c) != 127 for c in k)}
PYLOADER

# The loader source handed to python: the table's scope/env rows as _CFG_TABLE,
# then the loader itself. Every python3 call below passes this, never
# $_CFG_LOADER_PY alone.
#
# The global file's trust check (#443) is the python function trust_problem from
# pipeline-secrets.sh (_TALOS_TRUST_LIB), prepended here so the loader and the
# .env check share one definition. Without that file the function is undefined
# and _load_user_layer refuses the global file (fail closed).
# shellcheck disable=SC1091
[ -f "$_CFG_SELF_DIR/pipeline-secrets.sh" ] && . "$_CFG_SELF_DIR/pipeline-secrets.sh"
_cfg_loader_src() { printf '_CFG_TABLE = %s\n%s\n%s' "$(_talos_scope_env_json)" "${_TALOS_TRUST_LIB:-}" "$_CFG_LOADER_PY"; }

# ── Evidence-key validator (#405, part of #352) ──────────────────────────────
# Python half of the evidence.* validation. Like _CFG_LOADER_PY it is handed to
# each python3 process as an argv string and exec()'d (inside the existing
# `python3 -I` process), so --dump and the single-key lookup share ONE
# definition instead of a third pair of copies. Defines
# _validate_evidence_key(key, value) -> the validated value, or None after one
# stderr warning (callers treat None as absent), and _evidence_apply(flat) for
# the --dump dict. A key outside evidence.* passes through untouched. Defaults
# (false, 10, 20, attach, user-facing) belong to the CALLER; nothing here
# injects one. Evidence is uploaded with `gh pr comment --attach` only (owner
# decision on #352).
read -r -d '' _CFG_EVIDENCE_PY <<'PYEVIDENCE' || true
import re

# Enum keys as a table so a new value (e.g. "pr" for evidence.store) is a
# one-word edit; the warning text is built from the tuple.
_EVIDENCE_ENUMS = {
    "evidence.when": ("user-facing", "always"),
    "evidence.store": ("attach",),
}
_EVIDENCE_KEYS = (
    "evidence.enabled", "evidence.command", "evidence.dir",
    "evidence.include", "evidence.when", "evidence.store",
    "evidence.max_files", "evidence.max_mb",
)

def _ev_reject(key, want, value):
    shown = repr(value)
    if len(shown) > 80:
        shown = shown[:77] + "..."
    sys.stderr.write(
        "pipeline-config: %s must be %s -- got: %s -- using default\n"
        % (key, want, shown)
    )
    return None

def _validate_evidence_key(key, value):
    if value is None or key not in _EVIDENCE_KEYS:
        return value
    if key == "evidence.enabled":
        if not isinstance(value, bool):
            return _ev_reject(key, "true or false", value)
        return value
    if key in _EVIDENCE_ENUMS:
        allowed = _EVIDENCE_ENUMS[key]
        if not isinstance(value, str) or value not in allowed:
            return _ev_reject(key, "one of " + "|".join(allowed), value)
        return value
    if key in ("evidence.max_files", "evidence.max_mb"):
        # Strict: a real int or a 1-4 digit string, never a bool, a float
        # (12.0), padding (" 12 ") or underscores ("1_0").
        iv = None
        if isinstance(value, bool):
            pass
        elif isinstance(value, int):
            iv = value
        elif isinstance(value, str) and re.fullmatch(r"[0-9]{1,4}", value):
            iv = int(value)
        if iv is None or not 1 <= iv <= 100:
            return _ev_reject(key, "an integer from 1 to 100", value)
        return iv
    if key == "evidence.dir":
        # Value-only checks: a relative path of at most 200 characters from
        # [A-Za-z0-9._/-] that does not start with "-" or "/" (so no space,
        # shell metacharacter, glob, control character or backslash), with no
        # ".." component, not ".", and no ".git" component at any depth (any
        # case; "." and empty components are dropped first). realpath /
        # tracked-file checks are run time.
        ok = isinstance(value, str) and re.fullmatch(
            r"[A-Za-z0-9._][A-Za-z0-9._/-]{0,199}", value) is not None
        if ok:
            parts = [p for p in value.split("/") if p not in ("", ".")]
            ok = (
                bool(parts) and ".." not in parts
                and ".git" not in [p.lower() for p in parts]
            )
        if not ok:
            return _ev_reject(
                key, "a relative path of at most 200 characters from "
                "A-Z a-z 0-9 . _ / - (no leading - or /, no .. component, "
                "not . and no .git component)", value)
        return value
    if key == "evidence.include":
        # A list of 1-20 basename globs of at most 64 characters; a bare
        # string, [], too many items or ONE bad item makes the whole value
        # absent (fail closed).
        if not (isinstance(value, list) and 1 <= len(value) <= 20 and all(
                isinstance(x, str) and re.fullmatch(r"[A-Za-z0-9*?._-]{1,64}", x)
                for x in value)):
            return _ev_reject(
                key, "a list of 1-20 basename globs of 1-64 characters "
                "matching [A-Za-z0-9*?._-] (no /)", value)
        return value
    if key == "evidence.command":
        if not (isinstance(value, str) and len(value) <= 2000
                and "\0" not in value):
            return _ev_reject(
                key, "a string of at most 2000 characters with no NUL", value)
        return value
    return value

def _evidence_apply(flat):
    for _ev_key in _EVIDENCE_KEYS:
        if _ev_key in flat:
            _ev_val = _validate_evidence_key(_ev_key, flat[_ev_key])
            if _ev_val is None:
                del flat[_ev_key]
            else:
                flat[_ev_key] = _ev_val
PYEVIDENCE

# ── Runner-failover validators (#418) ────────────────────────────────────────
# Same shape as _CFG_EVIDENCE_PY: one snippet exec()'d by both the --dump and
# the single-key python3 processes. _validate_fallback_key(key, value) returns
# the value, or None after one stderr warning (callers read None as absent).
#   agents.fallback, agents.roles.<role>.fallback: a list of 1-5 runner ids, no
#     duplicates inside the list. "Not the primary" depends on the role, so
#     pipeline-agent.sh checks that at resolve time.
#   agents.provider_down_s: an integer 60-86400; the default (900) is the
#     caller's.
# _FALLBACK_RUNNERS restates TALOS_RUNNERS (scripts/pipeline-contract.sh);
# tests/test-runner-failover.sh asserts the two sets are equal.
read -r -d '' _CFG_FALLBACK_PY <<'PYFALLBACK' || true
import re

_FALLBACK_RUNNERS = ("claude", "pi", "codex", "gemini", "antigravity", "custom")

def _fb_reject(key, want, value):
    shown = repr(value)
    if len(shown) > 80:
        shown = shown[:77] + "..."
    sys.stderr.write(
        "pipeline-config: %s must be %s -- got: %s -- ignoring it\n"
        % (key, want, shown)
    )
    return None

def _is_fallback_key(key):
    parts = key.split(".")
    return key == "agents.fallback" or (
        len(parts) == 4 and parts[:2] == ["agents", "roles"] and parts[3] == "fallback")

def _validate_fallback_key(key, value):
    if value is None:
        return value
    if key == "agents.provider_down_s":
        iv = None
        if isinstance(value, bool):
            pass
        elif isinstance(value, int):
            iv = value
        elif isinstance(value, str) and re.fullmatch(r"[0-9]{1,6}", value):
            iv = int(value)
        if iv is None or not 60 <= iv <= 86400:
            return _fb_reject(key, "an integer from 60 to 86400 (seconds)", value)
        return iv
    if not _is_fallback_key(key):
        return value
    if not (isinstance(value, list) and 1 <= len(value) <= 5
            and all(isinstance(x, str) and x in _FALLBACK_RUNNERS for x in value)
            and len(set(value)) == len(value)):
        return _fb_reject(
            key, "a list of 1-5 distinct runners from " + "|".join(_FALLBACK_RUNNERS),
            value)
    return value

def _fallback_apply(flat):
    for _fb_key in [k for k in flat if _is_fallback_key(k) or k == "agents.provider_down_s"]:
        _fb_val = _validate_fallback_key(_fb_key, flat[_fb_key])
        if _fb_val is None:
            del flat[_fb_key]
        else:
            flat[_fb_key] = _fb_val
PYFALLBACK

# ── Integer-key validator (#440, part of #437) ───────────────────────────────
# Same shape as the snippets above: one definition exec()'d by both the --dump
# and the single-key python3 processes. Every int row of the table is either
# listed in _INT_KEYS (unit, lowest, highest accepted value) or has its own
# validator above (limits.tokens_per_issue, evidence.max_files/max_mb,
# agents.provider_down_s), or is left to a consumer that already refuses or
# falls back with its own message (issues.max_parallel, #120; limits.max_retries,
# #194). tests/test-config-int-validators.sh checks that split row by row.
# _validate_int_key(key, value) -> the value as an int, or None after one stderr
# warning (callers read None as absent, so the table default applies).
# Accepted: an int, a whole float (12.0) or a string of digits; never a bool.
# Negative numbers, "abc", 1.5, and values above the key's highest are rejected.
read -r -d '' _CFG_INT_PY <<'PYINT' || true
import math
import re

_INT_KEYS = {
    "verify.timeout_ms": ("milliseconds", 1, 86400000),
    "verify.ci_wait_s": ("seconds", 1, 86400),
    "hooks.timeout_s": ("seconds", 1, 86400),
    "notifications.cmd_timeout_s": ("seconds", 1, 86400),
    "notifications.buzz_timeout_s": ("seconds", 1, 3600),
    "status.log_days": ("days", 1, 999999),
    "status.log_max": ("entries", 1, 999999),
    "status.resume_max_lines": ("lines", 1, 999999),
    "limits.max_fix_attempts": ("attempts", 1, 100),
    "limits.max_total_dispatches": ("dispatches", 1, 1000),
    "execution.worktree_warn_threshold": ("worktrees", 0, 10000),
    "board.project_number": ("project number", 1, 2147483647),
}

def _validate_int_key(key, value):
    spec = _INT_KEYS.get(key)
    if spec is None or value is None:
        return value
    unit, lo, hi = spec
    iv = None
    if isinstance(value, bool):
        pass
    elif isinstance(value, int):
        iv = value
    elif isinstance(value, float):
        if math.isfinite(value) and value == int(value):
            iv = int(value)
    elif isinstance(value, str) and re.fullmatch(r"\s*[0-9]{1,18}\s*", value):
        iv = int(value)
    if iv is not None and lo <= iv <= hi:
        return iv
    what = "a positive integer" if lo >= 1 else "a non-negative integer"
    if iv is not None and iv > hi:
        sys.stderr.write(
            "pipeline-config: %s must be at most %d (%s) -- got: %r -- using default\n"
            % (key, hi, unit, value))
    else:
        sys.stderr.write(
            "pipeline-config: %s must be %s (%s) -- got: %r -- using default\n"
            % (key, what, unit, value))
    return None

def _int_apply(flat):
    for _int_key in _INT_KEYS:
        if _int_key in flat:
            _validated = _validate_int_key(_int_key, flat[_int_key])
            if _validated is None:
                # Same as an absent key: the caller gets the table default.
                del flat[_int_key]
            else:
                flat[_int_key] = _validated
PYINT

# --dump-layers (#336): one "key<TAB>layer" line per agents.* leaf, for
# pipeline-agent.sh --resolve-all's origin column. One python3 spawn.
if [ "${1:-}" = "--dump-layers" ]; then
  _LPROJ="$(_locate_project_cfg)"
  _LUSER="$(_locate_user_cfg)"
  if [ -z "$_LPROJ" ] && [ -z "$_LUSER" ]; then exit 0; fi
  python3 -I - "$_LPROJ" "$_LUSER" "$(_cfg_loader_src)" <<'PYEOF'
import sys
exec(sys.argv[3])
_project, _user, _merged = load_layers(sys.argv[1], sys.argv[2])
for _k, _l in layer_map(_project, _user).items():
    sys.stdout.write("%s\t%s\n" % (_k, _l))
PYEOF
  exit 0
fi

if [ "${1:-}" = "--dump" ]; then
  _DCFG="$(_locate_project_cfg)"
  _DUSER="$(_locate_user_cfg)"
  # No config present (or unreadable) — nothing to dump; every lookup falls
  # back to its caller's default, same as "no config found" below.
  # Env overrides still apply (pure shell, no python3 spawn).
  if [ -z "$_DCFG" ] && [ -z "$_DUSER" ]; then
    _talos_env_dump
    exit 0
  fi
  python3 -I - "$_DCFG" "$(_talos_known_keys_json)" "$_DUSER" "$(_cfg_loader_src)" "$_CFG_EVIDENCE_PY" "$_CFG_FALLBACK_PY" "$_CFG_INT_PY" <<'PYEOF'
import sys

known_keys_json = sys.argv[2]
exec(sys.argv[4])
exec(sys.argv[5])
exec(sys.argv[6])
exec(sys.argv[7])

def walk(obj, parts):
    for part in parts:
        if isinstance(obj, dict) and part in obj:
            obj = obj[part]
        else:
            return None
    return obj

# Merged project-over-user-level config (see the shared loader above).
# Unparseable project config -- treated as absent; every key falls back to
# the user-level layer or its caller-supplied default.
_project_cfg, _user_cfg, cfg = load_layers(sys.argv[1], sys.argv[3])

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
    if not isinstance(cfg_obj, dict) or not _KNOWN_CONFIG_KEYS:
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

# Positive-integer keys (verify.timeout_ms, hooks.timeout_s, limits.max_fix_attempts,
# ...): validated by the shared snippet (_CFG_INT_PY), the same one the
# single-key path below runs, so this dump (what cfg() answers every lookup
# from, pipeline-cfg-cache.sh) and a direct call stay byte-identical for these
# keys. An invalid value warns once on stderr and is dropped: the caller then
# gets the key's table default.
_int_apply(flat)

# limits.tokens_per_issue / limits.warn_at / spend.comment (#378): the
# per-issue spend guard's config. Same fail-closed-to-absent shape as
# _validate_int_key (an invalid value warns once on stderr and returns None,
# so the caller's default applies), but none of these fits it: 0 is the
# silent "guard off" value for tokens_per_issue, warn_at is a decimal in
# (0, 1], and spend.comment is a strict bool. The defaults (empty / 0.8 /
# true) are the CALLER's -- the dump never injects them. Defined identically
# in the --dump process and the single-key process (separate python3 spawns,
# like _validate_int_key).
def _validate_spend_key(key, value):
    if value is None:
        return value
    if key == "limits.tokens_per_issue":
        try:
            if isinstance(value, bool) or (isinstance(value, float) and value != int(value)):
                raise ValueError
            iv = int(value)
            if iv == 0:
                return None  # explicit off: silent, same as unset
            if iv < 0:
                raise ValueError
            return iv
        except (TypeError, ValueError, OverflowError):
            sys.stderr.write(
                "pipeline-config: %s must be a positive integer (tokens) -- "
                "got: %r -- treating the guard as off\n" % (key, value)
            )
            return None
    if key == "limits.warn_at":
        try:
            if isinstance(value, bool):
                raise ValueError
            fv = float(value)
            if not (0 < fv <= 1):  # also rejects nan; inf is > 1
                raise ValueError
            return fv
        except (TypeError, ValueError, OverflowError):
            sys.stderr.write(
                "pipeline-config: %s must be a number greater than 0 and at "
                "most 1 -- got: %r -- using default\n" % (key, value)
            )
            return None
    if key == "spend.comment":
        if not isinstance(value, bool):
            sys.stderr.write(
                "pipeline-config: %s must be true or false -- got: %r -- "
                "using default\n" % (key, value)
            )
            return None
        return value
    return value

for _spend_key in ("limits.tokens_per_issue", "limits.warn_at", "spend.comment"):
    if _spend_key in flat:
        _validated = _validate_spend_key(_spend_key, flat[_spend_key])
        if _validated is None:
            # Same as an absent key: the caller applies its own default.
            del flat[_spend_key]
        else:
            flat[_spend_key] = _validated

# evidence.* (#405): validated by the shared snippet (_CFG_EVIDENCE_PY); an
# invalid value warns once and is dropped, like the spend keys above.
_evidence_apply(flat)

# agents.fallback / agents.roles.<role>.fallback / agents.provider_down_s
# (#418): validated by the shared snippet (_CFG_FALLBACK_PY), same shape.
_fallback_apply(flat)

# agents.restamp_model / agents.roles.<role>.restamp_model derived default
# (#258): role restamp -> global restamp -> agents.model, mirroring
# verify.qa_mode's derived-default pattern above -- a re-stamp dispatch
# should default to the same cheap tier as agents.model, not silently fall
# back to the session default the way an unset agents.roles.<role>.model
# does. This dump only ever contains keys named up front, so only roles
# already present under agents.roles get a computed entry here; a role
# with no agents.roles.<role> block at all still resolves correctly
# through the single-key path's identical fallback chain below, since a
# cfg() cache miss on this key is exactly "absent -- use the caller's
# default" (agents.model, read separately).
_agents_model = walk(cfg, "agents.model".split("."))
_global_restamp = walk(cfg, "agents.restamp_model".split("."))
if _global_restamp is None or _global_restamp == "":
    _global_restamp = _agents_model
if _global_restamp is not None and _global_restamp != "":
    flat["agents.restamp_model"] = _global_restamp
elif "agents.restamp_model" in flat:
    del flat["agents.restamp_model"]

_roles_cfg = walk(cfg, "agents.roles".split("."))
if isinstance(_roles_cfg, dict):
    for _role_name in _roles_cfg:
        _role_restamp = walk(cfg, ["agents", "roles", _role_name, "restamp_model"])
        _resolved = _role_restamp
        if _resolved is None or _resolved == "":
            _resolved = walk(cfg, "agents.restamp_model".split("."))
        if _resolved is None or _resolved == "":
            _resolved = _agents_model
        _rkey = "agents.roles.%s.restamp_model" % _role_name
        if _resolved is not None and _resolved != "":
            flat[_rkey] = _resolved
        elif _rkey in flat:
            del flat[_rkey]

# agents.effort / agents.roles.<role>.effort / agents.restamp_effort /
# agents.roles.<role>.restamp_effort (#271): reasoning-effort lever
# alongside agents.model/.restamp_model. Allowed values low/medium/high/max
# -- anything else is reported on stderr and treated as absent, mirroring
# _validate_int_key's fail-closed-to-absent shape for a fixed string enum.
# restamp_effort's derived-default chain mirrors the restamp_model block
# just above exactly, with agents.effort standing in for agents.model as
# the base key -- effort has no runner-independent session default the way
# an unset model falls back to the harness default, so bottoming out at an
# empty agents.effort really does mean "let the runner apply its own
# default effort".
_EFFORT_VALUES = ("low", "medium", "high", "max")

def _valid_effort(effort_key, effort_value):
    if effort_value is None or effort_value == "":
        return None
    if effort_value not in _EFFORT_VALUES:
        sys.stderr.write(
            "pipeline-config: %s must be one of low, medium, high, max -- "
            "got: %r -- using default\n" % (effort_key, effort_value)
        )
        return None
    return effort_value

for _ekey in [
    k for k in list(flat.keys())
    if k == "agents.effort" or (k.startswith("agents.roles.") and k.endswith(".effort"))
]:
    _evalue = _valid_effort(_ekey, flat[_ekey])
    if _evalue is None:
        del flat[_ekey]
    else:
        flat[_ekey] = _evalue

_agents_effort = flat.get("agents.effort")
_global_restamp_effort = _valid_effort("agents.restamp_effort", walk(cfg, "agents.restamp_effort".split("."))) or _agents_effort
if _global_restamp_effort:
    flat["agents.restamp_effort"] = _global_restamp_effort
elif "agents.restamp_effort" in flat:
    del flat["agents.restamp_effort"]

if isinstance(_roles_cfg, dict):
    for _role_name in _roles_cfg:
        _role_restamp_effort = _valid_effort(
            "agents.roles.%s.restamp_effort" % _role_name,
            walk(cfg, ["agents", "roles", _role_name, "restamp_effort"]),
        )
        _resolved_effort = _role_restamp_effort or _global_restamp_effort
        _rekey_effort = "agents.roles.%s.restamp_effort" % _role_name
        if _resolved_effort:
            flat[_rekey_effort] = _resolved_effort
        elif _rekey_effort in flat:
            del flat[_rekey_effort]

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

# ── --has KEY (#439, #440) ────────────────────────────────────────────────────
# Exit 0 when KEY is set (a non-null value, a subtree counts) in any file layer,
# exit 1 when it is absent -- for the "is it configured at all" probes that used
# to pass a sentinel default (`pipeline-config.sh status.enabled unset`). Never
# consults the table: a key that only has a table default is NOT set. No config
# file means exit 1 with no python3 spawn. Exit 3 when KEY was not found AND a
# config file could not be parsed (malformed, or PyYAML missing for a YAML file):
# the answer is unknown, and "absent" would send a caller to write a block over
# a config it could not read. A key found in the layer that did parse is still 0.
if [ "${1:-}" = "--has" ]; then
  _HKEY="${2:-}"
  [ -n "$_HKEY" ] || exit 1
  _HPROJ="$(_locate_project_cfg)"
  _HUSER="$(_locate_user_cfg)"
  if [ -z "$_HPROJ" ] && [ -z "$_HUSER" ]; then exit 1; fi
  python3 -I - "$_HPROJ" "$_HKEY" "$_HUSER" "$(_cfg_loader_src)" <<'PYEOF'
import sys
exec(sys.argv[4])
_project, _user, _merged = load_layers(sys.argv[1], sys.argv[3], env=False)
_obj = _merged
def _absent():
    if not _LOAD_ERRORS:
        return 1
    sys.stderr.write("pipeline-config: --has: a config file could not be parsed; "
                     "cannot tell whether the key is set\n")
    return 3
for _part in sys.argv[2].split("."):
    if isinstance(_obj, dict) and _part in _obj:
        _obj = _obj[_part]
    else:
        sys.exit(_absent())
sys.exit(0 if _obj is not None else _absent())
PYEOF
  exit $?
fi

KEY="${1:-}"
# Default (#439): an explicit second argument -- even "" -- is the caller's own
# fallback and wins over the table, so every `KEY "literal"` call keeps its
# behaviour. With no second argument the table default answers (empty for an
# unknown or derived key).
_NODEFAULT=""
if [ "$#" -ge 2 ]; then DEFAULT="$2"; else DEFAULT="$(_talos_default "$KEY")" || _NODEFAULT=1; fi

# Fail closed (#440): no caller default, no table (pipeline-defaults.sh missing)
# and the key is security-relevant -- stop rather than print a made-up value.
_cfg_fail_closed() {
  echo "pipeline-config: $KEY is not set in any config and pipeline-defaults.sh is missing, so its default is unknown; refusing to guess for a security-relevant key" >&2
  exit 3
}

[ -z "$KEY" ] && { printf '%s' "$DEFAULT"; exit 0; }

# ── Locate config files (shared loader, see above) ───────────────────────────
CFG="$(_locate_project_cfg)"
USER_CFG="$(_locate_user_cfg)"

# No config present — return default
if [ -z "$CFG" ] && [ -z "$USER_CFG" ]; then
  # The key's env override (#441) still applies: pure shell, no python3 spawn.
  if _ENVV="$(_talos_env_value "$KEY")"; then printf '%s' "$_ENVV"; else
    [ -z "$_NODEFAULT" ] || _cfg_fail_closed
    printf '%s' "$DEFAULT"
  fi
  exit 0
fi

# ── Parse and extract with Python ────────────────────────────────────────────
# The heredoc passes file paths, key, default, the known-keys JSON and the
# shared loader source as argv to avoid shell quoting issues with special
# characters in values.
python3 -I - "$CFG" "$KEY" "$DEFAULT" "$(_talos_known_keys_json)" "$USER_CFG" "$(_cfg_loader_src)" "$_CFG_EVIDENCE_PY" "$_CFG_FALLBACK_PY" "$_CFG_INT_PY" "$_NODEFAULT" <<'PYEOF'
import sys

key      = sys.argv[2]
default  = sys.argv[3] if len(sys.argv) > 3 else ""
known_keys_json = sys.argv[4] if len(sys.argv) > 4 else "[]"
exec(sys.argv[6])
exec(sys.argv[7])
exec(sys.argv[8])
exec(sys.argv[9])

def walk(obj, parts):
    for part in parts:
        if isinstance(obj, dict) and part in obj:
            obj = obj[part]
        else:
            return None
    return obj

# Merged project-over-user-level config (see the shared loader above). An
# unparseable project file is treated as absent, so the lookup degrades to
# the user-level layer or the caller-supplied default -- not a crash.
_project_cfg, _user_cfg, cfg = load_layers(sys.argv[1], sys.argv[5])

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
    if not isinstance(cfg_obj, dict) or not _KNOWN_CONFIG_KEYS:
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

# Positive-integer keys (verify.timeout_ms and verify.ci_wait_s, which a stage
# interpolates unquoted into an agent-run shell test; hooks.timeout_s and
# notifications.cmd_timeout_s, which bound a hook or sink command; the limits
# and status integers): a non-integer, out-of-range value, or one carrying shell
# metacharacters is a config error, not something a caller can act on, so it
# falls back to the key's table default with one stderr warning. Defined once,
# in _CFG_INT_PY, and run by this path and the --dump path above alike.

# limits.tokens_per_issue / limits.warn_at / spend.comment (#378): the
# per-issue spend guard's config. Same fail-closed-to-absent shape as
# _validate_int_key (an invalid value warns once on stderr and returns None,
# so the caller's default applies), but none of these fits it: 0 is the
# silent "guard off" value for tokens_per_issue, warn_at is a decimal in
# (0, 1], and spend.comment is a strict bool. The defaults (empty / 0.8 /
# true) are the CALLER's -- the dump never injects them. Defined identically
# in the --dump process and the single-key process (separate python3 spawns,
# like _validate_int_key).
def _validate_spend_key(key, value):
    if value is None:
        return value
    if key == "limits.tokens_per_issue":
        try:
            if isinstance(value, bool) or (isinstance(value, float) and value != int(value)):
                raise ValueError
            iv = int(value)
            if iv == 0:
                return None  # explicit off: silent, same as unset
            if iv < 0:
                raise ValueError
            return iv
        except (TypeError, ValueError, OverflowError):
            sys.stderr.write(
                "pipeline-config: %s must be a positive integer (tokens) -- "
                "got: %r -- treating the guard as off\n" % (key, value)
            )
            return None
    if key == "limits.warn_at":
        try:
            if isinstance(value, bool):
                raise ValueError
            fv = float(value)
            if not (0 < fv <= 1):  # also rejects nan; inf is > 1
                raise ValueError
            return fv
        except (TypeError, ValueError, OverflowError):
            sys.stderr.write(
                "pipeline-config: %s must be a number greater than 0 and at "
                "most 1 -- got: %r -- using default\n" % (key, value)
            )
            return None
    if key == "spend.comment":
        if not isinstance(value, bool):
            sys.stderr.write(
                "pipeline-config: %s must be true or false -- got: %r -- "
                "using default\n" % (key, value)
            )
            return None
        return value
    return value

# agents.restamp_model / agents.roles.<role>.restamp_model derived default
# (#258): role restamp -> global restamp -> agents.model. Mirrors the
# --dump path's identical block above -- see that copy's comment for why
# the two can't literally be one shared function call.
if key == "agents.restamp_model":
    if value is None or value == "":
        value = walk(cfg, "agents.model".split("."))
elif key.startswith("agents.roles.") and key.endswith(".restamp_model"):
    if value is None or value == "":
        value = walk(cfg, "agents.restamp_model".split("."))
        if value is None or value == "":
            value = walk(cfg, "agents.model".split("."))

# agents.effort / agents.roles.<role>.effort / agents.restamp_effort /
# agents.roles.<role>.restamp_effort (#271): reasoning-effort lever
# alongside agents.model/.restamp_model. Mirrors the --dump path's
# identical block above -- see that copy's comment for the full rationale
# (allowed values, why restamp_effort's base key is agents.effort, and why
# an invalid value falls through the chain like an absent one).
_EFFORT_VALUES = ("low", "medium", "high", "max")

def _valid_effort(effort_key, effort_value):
    if effort_value is None or effort_value == "":
        return None
    if effort_value not in _EFFORT_VALUES:
        sys.stderr.write(
            "pipeline-config: %s must be one of low, medium, high, max -- "
            "got: %r -- using default\n" % (effort_key, effort_value)
        )
        return None
    return effort_value

if key == "agents.effort" or (key.startswith("agents.roles.") and key.endswith(".effort")):
    value = _valid_effort(key, value)
elif key == "agents.restamp_effort":
    value = _valid_effort(key, value) or _valid_effort("agents.effort", walk(cfg, "agents.effort".split(".")))
elif key.startswith("agents.roles.") and key.endswith(".restamp_effort"):
    value = (
        _valid_effort(key, value)
        or _valid_effort("agents.restamp_effort", walk(cfg, "agents.restamp_effort".split(".")))
        or _valid_effort("agents.effort", walk(cfg, "agents.effort".split(".")))
    )

value = _validate_int_key(key, value)
value = _validate_spend_key(key, value)
value = _validate_evidence_key(key, value)
value = _validate_fallback_key(key, value)

if value is None:
    if len(sys.argv) > 10 and sys.argv[10] == "1":
        # No caller default and no table (pipeline-defaults.sh missing) for a
        # security-relevant key: fail closed (#440), same as _cfg_fail_closed.
        sys.stderr.write(
            "pipeline-config: %s is not set in any config and pipeline-defaults.sh "
            "is missing, so its default is unknown; refusing to guess for a "
            "security-relevant key\n" % key)
        sys.exit(3)
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
