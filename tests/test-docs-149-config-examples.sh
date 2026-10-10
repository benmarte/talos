#!/usr/bin/env bash
# tests/test-docs-149-config-examples.sh
# Verifies that the three config examples added in #149 parse correctly, plus
# the hooks.* / events.* keys documented in #185 (README hooks section,
# docs/user-guide.md worked example, talos.pipeline.*.example).
#
# Strategy: use a sentinel default (__MISS__) that cannot be a real config
# value.  If the file fails to parse, pipeline-config.sh returns the caller's
# default silently -- the sentinel makes that visible as a test failure.
#
# Platform note (#526): config is JSON only, so every example runs as JSON on
# every platform; the old YAML variants of these blocks are gone with the
# YAML load paths.
#
# The test also deliberately corrupts each example and asserts the check goes
# RED, proving the sentinel approach actually catches bad config.
#
# #268 additionally asserts every key in pipeline-config.sh's
# _KNOWN_CONFIG_KEYS_JSON appears in at least one example config (regression
# guard against a wholly-undocumented key), and that the seven keys #268
# added examples for are real JSON structure (parsed and walked by dotted
# path, not a `_note` prose mention -- QA's first-round finding). A self-check
# proves the JSON structural assertion is
# not vacuous by removing one key from a temp copy and confirming it goes RED.
#
# Usage: bash tests/test-docs-149-config-examples.sh
#        (or via tests/run-tests.sh)

set -u

PASS=0
FAIL=0
SENTINEL="__MISS__"

# Resolve paths relative to this script's location.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_SH="$REPO_ROOT/scripts/pipeline-config.sh"
# helpers.sh points the user-level config lookup (#336) at an empty location, so
# a real ~/.talos can never answer a lookup here. Its pass/fail/assert_eq are
# redefined below with this file's own sentinel-aware versions.
. "$SCRIPT_DIR/helpers.sh"
SCRATCH="$(safe_mktemp_dir)" || exit 1
_SANDBOX_OWNER="${BASHPID:-$$}"
trap '_is_trap_owner && rm -rf "$SCRATCH"' EXIT

ok() {
  printf 'ok: %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ] && [ "$actual" != "$SENTINEL" ]; then
    ok "$label"
  else
    fail "$label -- expected '$expected', got '$actual'"
  fi
}

assert_not_eq() {
  local label="$1" bad="$2" actual="$3"
  if [ "$actual" != "$bad" ]; then
    ok "$label (RED -- corrupted config rejected)"
  else
    fail "$label -- sentinel check passed but should have failed (got '$actual')"
  fi
}

# ── 1. issues.label_filter ────────────────────────────────────────────────────
# JSON (always runs)

GOOD_LABEL_JSON="$SCRATCH/label_filter_good.json"
cat > "$GOOD_LABEL_JSON" <<'EOF'
{"issues": {"label_filter": "team:alice"}}
EOF

actual=$(PIPELINE_CONFIG="$GOOD_LABEL_JSON" bash "$CONFIG_SH" issues.label_filter "$SENTINEL")
assert_eq "label_filter/json: correct value from good config" "team:alice" "$actual"

# Corruption: wrong key path (issus instead of issues).
CORRUPT_LABEL_JSON="$SCRATCH/label_filter_corrupt.json"
cat > "$CORRUPT_LABEL_JSON" <<'EOF'
{"issus": {"label_filter": "team:alice"}}
EOF

actual=$(PIPELINE_CONFIG="$CORRUPT_LABEL_JSON" bash "$CONFIG_SH" issues.label_filter "$SENTINEL")
assert_not_eq "label_filter/json: sentinel returned for corrupted config" "team:alice" "$actual"

# ── 2. execution.isolation ────────────────────────────────────────────────────
# JSON (always runs)

GOOD_ISO_JSON="$SCRATCH/isolation_good.json"
cat > "$GOOD_ISO_JSON" <<'EOF'
{"execution": {"isolation": "branch"}}
EOF

actual=$(PIPELINE_CONFIG="$GOOD_ISO_JSON" bash "$CONFIG_SH" execution.isolation "$SENTINEL")
assert_eq "isolation/json: correct value from good config" "branch" "$actual"

# Corruption: wrong key path (executon instead of execution).
CORRUPT_ISO_JSON="$SCRATCH/isolation_corrupt.json"
cat > "$CORRUPT_ISO_JSON" <<'EOF'
{"executon": {"isolation": "branch"}}
EOF

actual=$(PIPELINE_CONFIG="$CORRUPT_ISO_JSON" bash "$CONFIG_SH" execution.isolation "$SENTINEL")
assert_not_eq "isolation/json: sentinel returned for corrupted config" "branch" "$actual"

# ── 3. agents.roles.<role>.model ─────────────────────────────────────────────
# JSON (always runs)

GOOD_MODEL_JSON="$SCRATCH/model_good.json"
cat > "$GOOD_MODEL_JSON" <<'EOF'
{
  "agents": {
    "model": "claude-haiku-4-5-20251001",
    "roles": {
      "reviewer": {"model": "claude-opus-5"},
      "security": {"model": "claude-opus-5"}
    }
  }
}
EOF

actual=$(PIPELINE_CONFIG="$GOOD_MODEL_JSON" bash "$CONFIG_SH" agents.roles.reviewer.model "$SENTINEL")
assert_eq "roles.reviewer.model/json: correct value from good config" "claude-opus-5" "$actual"

actual=$(PIPELINE_CONFIG="$GOOD_MODEL_JSON" bash "$CONFIG_SH" agents.model "$SENTINEL")
assert_eq "agents.model/json: correct global default from same config" "claude-haiku-4-5-20251001" "$actual"

# Corruption: wrong key path (agents.role instead of agents.roles).
CORRUPT_MODEL_JSON="$SCRATCH/model_corrupt.json"
cat > "$CORRUPT_MODEL_JSON" <<'EOF'
{
  "agents": {
    "model": "claude-haiku-4-5-20251001",
    "role": {"reviewer": {"model": "claude-opus-5"}}
  }
}
EOF

actual=$(PIPELINE_CONFIG="$CORRUPT_MODEL_JSON" bash "$CONFIG_SH" agents.roles.reviewer.model "$SENTINEL")
assert_not_eq "roles.reviewer.model/json: sentinel returned for corrupted config" "claude-opus-5" "$actual"

# ── 4. hooks.pre_dispatch / hooks.post_stage / hooks.timeout_s (#185) ────────
# JSON (always runs)

GOOD_HOOKS_JSON="$SCRATCH/hooks_good.json"
cat > "$GOOD_HOOKS_JSON" <<'EOF'
{
  "hooks": {
    "pre_dispatch": "scripts/talos-hook.sh",
    "post_stage": "scripts/talos-hook.sh",
    "timeout_s": 45
  }
}
EOF

actual=$(PIPELINE_CONFIG="$GOOD_HOOKS_JSON" bash "$CONFIG_SH" hooks.pre_dispatch "$SENTINEL")
assert_eq "hooks.pre_dispatch/json: correct value from good config" "scripts/talos-hook.sh" "$actual"

actual=$(PIPELINE_CONFIG="$GOOD_HOOKS_JSON" bash "$CONFIG_SH" hooks.post_stage "$SENTINEL")
assert_eq "hooks.post_stage/json: correct value from good config" "scripts/talos-hook.sh" "$actual"

actual=$(PIPELINE_CONFIG="$GOOD_HOOKS_JSON" bash "$CONFIG_SH" hooks.timeout_s "$SENTINEL")
assert_eq "hooks.timeout_s/json: correct value from good config" "45" "$actual"

# Corruption: wrong key path (hook instead of hooks).
CORRUPT_HOOKS_JSON="$SCRATCH/hooks_corrupt.json"
cat > "$CORRUPT_HOOKS_JSON" <<'EOF'
{
  "hook": {
    "pre_dispatch": "scripts/talos-hook.sh"
  }
}
EOF

actual=$(PIPELINE_CONFIG="$CORRUPT_HOOKS_JSON" bash "$CONFIG_SH" hooks.pre_dispatch "$SENTINEL")
assert_not_eq "hooks.pre_dispatch/json: sentinel returned for corrupted config" "scripts/talos-hook.sh" "$actual"

# ── 5. events.enabled / events.path (#185) ────────────────────────────────────
# JSON (always runs)

GOOD_EVENTS_JSON="$SCRATCH/events_good.json"
cat > "$GOOD_EVENTS_JSON" <<'EOF'
{
  "events": {
    "enabled": false,
    "path": ".talos/custom-events.jsonl"
  }
}
EOF

actual=$(PIPELINE_CONFIG="$GOOD_EVENTS_JSON" bash "$CONFIG_SH" events.enabled "$SENTINEL")
assert_eq "events.enabled/json: correct value from good config" "false" "$actual"

actual=$(PIPELINE_CONFIG="$GOOD_EVENTS_JSON" bash "$CONFIG_SH" events.path "$SENTINEL")
assert_eq "events.path/json: correct value from good config" ".talos/custom-events.jsonl" "$actual"

# Corruption: wrong key path (event instead of events).
CORRUPT_EVENTS_JSON="$SCRATCH/events_corrupt.json"
cat > "$CORRUPT_EVENTS_JSON" <<'EOF'
{
  "event": {
    "path": ".talos/custom-events.jsonl"
  }
}
EOF

actual=$(PIPELINE_CONFIG="$CORRUPT_EVENTS_JSON" bash "$CONFIG_SH" events.path "$SENTINEL")
assert_not_eq "events.path/json: sentinel returned for corrupted config" ".talos/custom-events.jsonl" "$actual"

# ── 6. Every known config key has an example somewhere, and #268's seven ─────
# keys (previously missing entirely) are real JSON structure -- not merely
# mentioned in prose -- and appear in both example configs (#268 fix round).
#
# _KNOWN_CONFIG_KEYS_JSON (generated from the table in pipeline-defaults.sh,
# #439) is the single source of truth
# for the unknown-key warning (#176); this reads that same list so a key
# added there later without a matching example fails here instead of
# drifting silently.
#
# QA's first-round finding: a bare `leaf in jsn` substring check is satisfied
# by the leaf name appearing ANYWHERE in the file, including inside the
# free-text `_note` prose field -- so a key documented only in prose (never
# added as real JSON structure) passed silently. Fixed here two ways:
#   - JSON: json_structural() parses the file and walks the actual object
#     tree by dotted path (a `*` wildcard segment matches any one concrete
#     key, e.g. a role name under agents.roles.*) -- this is the only check
#     used for #268's seven keys (BOTH_REQUIRED below), so a key present only
#     in _note prose does NOT satisfy it. json_note_mentions() is a fallback
#     for the general (non-#268) key set only: an exact, word-boundary-
#     anchored match of the FULL dotted path (never a bare leaf substring).
#   (The yml-side leaf check is gone with the YAML load paths (#526): the
#    canonical JSON example is the only example config.)
KEY_CHECK_PY="$SCRATCH/check_known_keys.py"
cat > "$KEY_CHECK_PY" <<'PYEOF'
import os, re, subprocess, sys, json

cfg_path, json_path = sys.argv[1], sys.argv[2]
# The known-keys list is generated from the config schema table (#439), which
# sits next to pipeline-config.sh.
defaults_sh = os.path.join(os.path.dirname(cfg_path), "pipeline-defaults.sh")
keys = json.loads(subprocess.run(
    ["bash", "-c", '. "$1"; _talos_known_keys_json', "_", defaults_sh],
    capture_output=True, text=True, check=True).stdout)
json_text = open(json_path).read()
json_data = json.load(open(json_path))

# #268's seven keys, previously missing from both files entirely -- these
# must be real JSON structure (not a prose mention).
BOTH_REQUIRED = {
    "vcs.token_env", "board.status_map.*", "merge.forbidden_files_replace",
    "merge.forbidden_files_allow", "execution.isolation",
    "notifications.buzz_relay", "limits.max_total_dispatches",
}


def json_walk(data, segments):
    node = data
    for seg in segments:
        if seg == "*":
            if not isinstance(node, dict) or not node:
                return False
            node = next(iter(node.values()))
            continue
        if not isinstance(node, dict) or seg not in node:
            return False
        node = node[seg]
    return True


def json_structural(key):
    return json_walk(json_data, key.split("."))


def json_note_mentions(key):
    # A wildcard segment is spelled "*" in the table and "<role>" in the
    # note's prose (the table's placeholder convention); accept both.
    base = key[:-2] if key.endswith(".*") else key
    pattern = r"(?<![\w.])" + re.escape(base).replace(r"\*", r"(?:\*|<role>)") + r"(?![\w])"
    return re.search(pattern, json_text) is not None



missing_json = []            # no known key may be undocumented in the example
missing_both_required = []   # #268's seven keys: real JSON structure, not prose

for k in keys:
    if not (json_structural(k) or json_note_mentions(k)):
        missing_json.append(k)
    if k in BOTH_REQUIRED and not json_structural(k):
        missing_both_required.append(k)

print("MISSING_JSON=" + ",".join(missing_json))
print("MISSING_BOTH_REQUIRED=" + ",".join(missing_both_required))
PYEOF

JSON_EXAMPLE="$REPO_ROOT/talos.pipeline.json.example"
CFG_SH="$REPO_ROOT/scripts/pipeline-config.sh"

KEY_CHECK_OUT=$(python3 "$KEY_CHECK_PY" "$CFG_SH" "$JSON_EXAMPLE")
MISSING_JSON=$(printf '%s\n' "$KEY_CHECK_OUT" | sed -n 's/^MISSING_JSON=//p')
MISSING_BOTH_REQUIRED=$(printf '%s\n' "$KEY_CHECK_OUT" | sed -n 's/^MISSING_BOTH_REQUIRED=//p')

if [ -z "$MISSING_JSON" ]; then
  ok "config examples: every known config key appears in the canonical example config"
else
  fail "config examples: known key(s) missing from the canonical example config: $MISSING_JSON"
fi

if [ -z "$MISSING_BOTH_REQUIRED" ]; then
  ok "config examples: #268's seven keys (vcs.token_env, board.status_map, merge.forbidden_files_replace, merge.forbidden_files_allow, execution.isolation, notifications.buzz_relay, limits.max_total_dispatches) are real JSON structure in the canonical example"
else
  fail "config examples: #268 key(s) missing real JSON structure in the canonical example: $MISSING_BOTH_REQUIRED"
fi

# Prove the JSON structural check is not vacuous: strip one #268 key
# (vcs.token_env) from a temp copy of the JSON example -- keeping its _note
# prose mention intact -- and confirm the check now reports it missing. This
# is exactly the regression QA's first round hit (a key present only in
# prose passing silently).
CORRUPT_JSON_EXAMPLE="$SCRATCH/json_example_missing_token_env.json"
python3 -c "
import json
d = json.load(open('$JSON_EXAMPLE'))
del d['vcs']['token_env']
json.dump(d, open('$CORRUPT_JSON_EXAMPLE', 'w'))
"
CORRUPT_CHECK_OUT=$(python3 "$KEY_CHECK_PY" "$CFG_SH" "$CORRUPT_JSON_EXAMPLE")
CORRUPT_MISSING=$(printf '%s\n' "$CORRUPT_CHECK_OUT" | sed -n 's/^MISSING_BOTH_REQUIRED=//p')
case ",$CORRUPT_MISSING," in
  *,vcs.token_env,*)
    ok "config examples: JSON structural check catches vcs.token_env removed from JSON structure, even though the _note prose still mentions it (RED -- regression caught)"
    ;;
  *)
    fail "config examples: removing vcs.token_env's JSON structure did not trip the check -- the check is vacuous (got: '$CORRUPT_MISSING')"
    ;;
esac

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
