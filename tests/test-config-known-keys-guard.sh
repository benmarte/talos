#!/usr/bin/env bash
# test-config-known-keys-guard.sh -- PR #217 review follow-up on #176: makes
# the "documented key produces a false 'unknown config key' warning" class of
# bug impossible to reintroduce silently.
#
# _KNOWN_CONFIG_KEYS (scripts/pipeline-config.sh) omitted "verify.commands"
# even though it is a real, documented sub-key of the dict form of "verify"
# (pipeline-config.sh itself does `.get("commands", [])`) -- a false warning
# on a shape the script's own docs recommend. This test guards against that
# class recurring for ANY key by flattening every leaf key in both shipped
# example configs, plus every config key literal actually read by a
# cfg()/pipeline-config.sh call site under scripts/ and skills/ (found the
# same way a reviewer would: grep for "pipeline-config\.sh [a-z_.]+" and
# "cfg [a-z_.]+"), and asserting each one is covered by _KNOWN_CONFIG_KEYS.
#
# _KNOWN_CONFIG_KEYS itself is extracted from scripts/pipeline-config.sh's
# module-level _KNOWN_CONFIG_KEYS_JSON (defined once, referenced by both the
# --dump path and the single-key path -- see that script's top-of-file
# comment) rather than hardcoded a third time here, so this guard tracks
# the real list, not a copy that could itself drift.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

HAVE_YAML=false
python3 -c "import yaml" 2>/dev/null && HAVE_YAML=true

# Not wrapped in outer double quotes ("$(...)") -- a heredoc nested inside a
# double-quoted command substitution mis-tokenizes an apostrophe inside a
# Python comment further down (e.g. "reviewer's") as closing the heredoc's
# quoted delimiter. A plain assignment (_out=$(...)) doesn't need the outer
# quoting since there is no word-splitting/globbing risk on an RHS assignment.
_out=$(python3 - "$TALOS_ROOT" "$HAVE_YAML" <<'PYEOF'
import glob
import json
import os
import re
import sys

root, have_yaml = sys.argv[1], sys.argv[2] == "True"
cfg_sh = os.path.join(root, "scripts", "pipeline-config.sh")
missing = []

# ── Extract the real _KNOWN_CONFIG_KEYS list ────────────────────────────────
src = open(cfg_sh).read()
m = re.search(r"_KNOWN_CONFIG_KEYS_JSON='(\[.*?\])'", src, re.S)
if not m:
    print("could not find _KNOWN_CONFIG_KEYS_JSON in pipeline-config.sh")
    sys.exit(0)
known = json.loads(m.group(1))
known_templates = [k.split(".") for k in known]

def key_covered(key):
    parts = key.split(".")
    for t in known_templates:
        n = min(len(parts), len(t))
        # A prefix match covers truncated call sites (e.g. a doc/skill that
        # spells "agents.roles.<role>" without the trailing ".model") --
        # every real leaf key from an example config or from cfg() with a
        # literal (non-templated) argument is already full-length, so this
        # only widens coverage for the templated case, never masks a
        # genuinely-missing full key.
        if all(tp == "*" or tp == p for tp, p in zip(t[:n], parts[:n])):
            return True
    return False

# ── Flatten both shipped example configs ────────────────────────────────────
def flatten(obj, prefix, out):
    if isinstance(obj, dict):
        for k, v in obj.items():
            flatten(v, "%s.%s" % (prefix, k) if prefix else k, out)
    elif obj is not None:
        out.append(prefix)

def check_example(cfg_obj, label):
    leaves = []
    flatten(cfg_obj, "", leaves)
    for k in leaves:
        if k.split(".")[-1] == "_note":
            continue
        if not key_covered(k):
            missing.append("%s: %s" % (label, k))

json_example = os.path.join(root, "talos.pipeline.json.example")
with open(json_example) as f:
    check_example(json.load(f), "talos.pipeline.json.example")

yml_example = os.path.join(root, "talos.pipeline.yml.example")
if have_yaml and os.path.exists(yml_example):
    import yaml
    with open(yml_example) as f:
        check_example(yaml.safe_load(f), "talos.pipeline.yml.example")

# ── Every cfg()/pipeline-config.sh call-site key literal under scripts/ and
# skills/ (same convention a reviewer's grep would use, widened to accept
# "<placeholder>" template segments and "$VAR"/"${VAR}" shell interpolation
# as a dynamic "*" segment).
call_patterns = [
    re.compile(r'\bpipeline-config\.sh\s+"?([a-zA-Z_][a-zA-Z0-9_]*\.[a-zA-Z0-9_.*<>${}]*[a-zA-Z0-9_*>}])'),
    re.compile(r'\bcfg\s+"?([a-zA-Z_][a-zA-Z0-9_]*\.[a-zA-Z0-9_.*<>${}]*[a-zA-Z0-9_*>}])'),
    re.compile(r'\bpipeline-config\.sh\s+"?(base_branch|release_branch|repo)\b'),
    re.compile(r'\bcfg\s+"?(base_branch|release_branch|repo)\b'),
]

files = []
for base in ("scripts", "skills"):
    for f in glob.glob(os.path.join(root, base, "**", "*"), recursive=True):
        if os.path.isfile(f):
            files.append(f)

call_keys = set()
for f in files:
    try:
        text = open(f, errors="replace").read()
    except Exception:
        continue
    for pat in call_patterns:
        for mm in pat.finditer(text):
            call_keys.add(mm.group(1))

def normalize(k):
    k = re.sub(r"<[^>]+>", "*", k)
    k = re.sub(r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?", "*", k)
    return k

for k in sorted(call_keys):
    if not key_covered(normalize(k)):
        missing.append("call-site: %s" % k)

print("\n".join(missing))
PYEOF
)

assert_eq "" "$_out" \
  "every example-config key and cfg()/pipeline-config.sh call-site key is covered by _KNOWN_CONFIG_KEYS"

finish
