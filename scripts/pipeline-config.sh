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
# User-level layer (#336): ${TALOS_HOME:-$HOME/.talos}/talos.pipeline.{yml,yaml,
# json} is loaded under whichever project config was found (or alone when there
# is none); the project config is merged over it key by key. Only its agents.*
# subtree is read -- see the shared loader below.
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
  "merge.approval_waiver_paths", "merge.union_paths",
  "merge.auto_sync",
  "issues.label_filter", "issues.skip_labels", "issues.max_parallel",
  "issues.assignee",
  "execution.isolation", "execution.worktree_warn_threshold",
  "roles.validator", "roles.pm", "roles.pm_skip_when_spec_present",
  "roles.qa", "roles.reviewer", "roles.security", "roles.adversarial",
  "roles.docs", "roles.docs_mode", "roles.planner", "roles.changelog_fragments",
  "comments.enabled", "comments.header", "comments.templates_dir",
  "notifications.slack_channel", "notifications.discord_channel",
  "notifications.buzz_channel", "notifications.buzz_relay",
  "notifications.buzz_timeout_s",
  "notifications.templates_dir", "notifications.threading",
  "notifications.events", "notifications.cmd", "notifications.cmd_timeout_s",
  "agents.runner", "agents.subagents", "agents.runner_args",
  "agents.runner_cmd", "agents.model", "agents.restamp_model",
  "agents.effort", "agents.restamp_effort",
  "agents.roles.*.model", "agents.roles.*.runner",
  "agents.roles.*.runner_cmd", "agents.roles.*.restamp_model",
  "agents.roles.*.effort", "agents.roles.*.restamp_effort",
  "limits.max_fix_attempts", "limits.max_total_dispatches",
  "limits.max_retries",
  "limits.tokens_per_issue", "limits.warn_at", "spend.comment",
  "pr.draft",
  "status.enabled", "status.file", "status.log_heading",
  "status.resume_heading", "status.fragments_dir", "status.archive_dir",
  "status.log_days", "status.log_max", "status.resume_max_lines",
  "markers.trusted_authors", "markers.verify_authors",
  "hooks.pre_dispatch", "hooks.post_stage", "hooks.timeout_s",
  "events.enabled", "events.path"
]'

# ── Shared config loader (#336) ───────────────────────────────────────────────
# One place that finds the config files and one that parses + merges them,
# used by both --dump and the single-key lookup below (they used to each carry
# their own copy of the file-lookup loop and the parse block).
#
# Two layers, project wins per leaf key:
#   1. user-level  ${TALOS_HOME:-$HOME/.talos}/talos.pipeline.{yml,yaml,json}
#                  Only its agents.* subtree is read -- board/merge/issue/
#                  verify settings describe a repo, not a user. Untrusted
#                  input: parsed as data only (JSON / yaml.safe_load), never
#                  sourced or evaluated; missing, unreadable, empty,
#                  malformed or non-mapping content behaves as absent
#                  (malformed/empty/non-mapping/unreadable prints one stderr
#                  warning; the lookup and its exit status are unaffected).
#   2. project     $PIPELINE_CONFIG, else the first existing ./talos.pipeline.*
#                  / legacy name. The user-level layer sits under whichever
#                  one is found.
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
# without a new installed file). Defines load_layers(project_path, user_path)
# -> (project, user, merged) and layer_map(project, user).
read -r -d '' _CFG_LOADER_PY <<'PYLOADER' || true
import os
import sys

def _warn(msg):
    sys.stderr.write("pipeline-config: [warn] %s\n" % msg)

def _parse_cfg_file(path):
    # Prefer PyYAML (safe_load only); fall back to json without it.
    try:
        import yaml
    except ImportError:
        yaml = None
    with open(path) as f:
        if yaml is not None:
            return yaml.safe_load(f)
        import json
        return json.load(f)

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
    try:
        raw = _parse_cfg_file(user_path)
    except Exception as e:
        # Type name only: a parser's message may echo file content.
        _warn("user-level config %s unreadable or malformed (%s) -- ignoring it"
              % (shown, type(e).__name__))
        return {}
    if raw is None:
        _warn("user-level config %s is empty -- ignoring it" % shown)
        return {}
    if not isinstance(raw, dict):
        _warn("user-level config %s must be a mapping -- ignoring it" % shown)
        return {}
    for k in raw:
        if k != "agents":
            _warn("user-level config %s: ignoring key %s (only agents.* is read "
                  "from the user-level file)" % (shown, repr(str(k))[:80]))
    agents = raw.get("agents")
    if agents is None:
        return {}
    if not isinstance(agents, dict):
        _warn("user-level config %s: agents must be a mapping -- ignoring it" % shown)
        return {}
    return {"agents": agents}

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

def load_layers(project_path, user_path):
    project = {}
    if project_path:
        try:
            project = _parse_cfg_file(project_path) or {}
        except Exception:
            # Unparseable project config: treated as absent (the warning is
            # emitted once in-process by pipeline-vcs.sh at startup). Every
            # key falls back to the user-level layer or the caller default.
            project = {}
    if not isinstance(project, dict):
        project = {}
    user = _load_user_layer(user_path, project_path)
    return project, user, _deep_merge(user, project)

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

# --dump-layers (#336): one "key<TAB>layer" line per agents.* leaf, for
# pipeline-agent.sh --resolve-all's origin column. One python3 spawn.
if [ "${1:-}" = "--dump-layers" ]; then
  _LPROJ="$(_locate_project_cfg)"
  _LUSER="$(_locate_user_cfg)"
  if [ -z "$_LPROJ" ] && [ -z "$_LUSER" ]; then exit 0; fi
  python3 -I - "$_LPROJ" "$_LUSER" "$_CFG_LOADER_PY" <<'PYEOF'
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
  if [ -z "$_DCFG" ] && [ -z "$_DUSER" ]; then
    exit 0
  fi
  python3 -I - "$_DCFG" "$_KNOWN_CONFIG_KEYS_JSON" "$_DUSER" "$_CFG_LOADER_PY" <<'PYEOF'
import sys

known_keys_json = sys.argv[2]
exec(sys.argv[4])

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
    unit = {"verify.timeout_ms": "milliseconds", "verify.ci_wait_s": "seconds", "hooks.timeout_s": "seconds", "notifications.cmd_timeout_s": "seconds", "status.log_days": "days", "status.log_max": "entries", "status.resume_max_lines": "lines"}.get(key)
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

for _int_key in ("verify.timeout_ms", "verify.ci_wait_s", "hooks.timeout_s", "notifications.cmd_timeout_s", "status.log_days", "status.log_max", "status.resume_max_lines"):
    if _int_key in flat:
        _validated = _validate_int_key(_int_key, flat[_int_key])
        if _validated is None:
            # Same as an absent key: the caller applies its own default.
            del flat[_int_key]
        else:
            flat[_int_key] = _validated

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

KEY="${1:-}"
DEFAULT="${2:-}"

[ -z "$KEY" ] && { printf '%s' "$DEFAULT"; exit 0; }

# ── Locate config files (shared loader, see above) ───────────────────────────
CFG="$(_locate_project_cfg)"
USER_CFG="$(_locate_user_cfg)"

# No config present — return default
if [ -z "$CFG" ] && [ -z "$USER_CFG" ]; then
  printf '%s' "$DEFAULT"
  exit 0
fi

# ── Parse and extract with Python ────────────────────────────────────────────
# The heredoc passes file paths, key, default, the known-keys JSON and the
# shared loader source as argv to avoid shell quoting issues with special
# characters in values.
python3 -I - "$CFG" "$KEY" "$DEFAULT" "$_KNOWN_CONFIG_KEYS_JSON" "$USER_CFG" "$_CFG_LOADER_PY" <<'PYEOF'
import sys

key      = sys.argv[2]
default  = sys.argv[3] if len(sys.argv) > 3 else ""
known_keys_json = sys.argv[4] if len(sys.argv) > 4 else "[]"
exec(sys.argv[6])

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
# (`[ "$SECONDS" -ge <VERIFY_CI_WAIT_S> ]`) in the QA CI-wait loop.
# hooks.timeout_s (#181, shared with hooks.post_stage per #182) bounds how
# long a hooks.pre_dispatch or hooks.post_stage command may run before
# pipeline-hooks.sh kills it. notifications.cmd_timeout_s (#184) bounds how
# long a notifications.cmd command may run before pipeline-notify.sh kills
# it. All four must be a positive
# integer -- a non-integer or non-positive config value (or one carrying
# shell metacharacters) is a config error, not a value an agent (or
# pipeline-hooks.sh/pipeline-notify.sh) can act on, so fail closed to the
# caller-supplied default (600000 / 900 / 30 / 10 respectively) and warn
# once on stderr rather than handing a subagent a garbage timeout or an
# injectable string.
# Mirrors the --dump path above: both define the identical
# _validate_int_key(key, value) helper (same units, same
# fail-closed-to-absent behaviour, same one-line stderr warning) so the
# two paths stay byte-identical for these keys.
def _validate_int_key(key, value):
    unit = {"verify.timeout_ms": "milliseconds", "verify.ci_wait_s": "seconds", "hooks.timeout_s": "seconds", "notifications.cmd_timeout_s": "seconds", "status.log_days": "days", "status.log_max": "entries", "status.resume_max_lines": "lines"}.get(key)
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
