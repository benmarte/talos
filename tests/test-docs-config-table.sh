#!/usr/bin/env bash
# test-docs-config-table.sh -- the config key tables in docs/reference.md are
# generated from scripts/pipeline-defaults.sh by tests/gen-config-table.py, so
# they cannot drift from the defaults. This replaces the old prose-pinning doc
# tests: one generated block, one comparison.
#
# Fix a failure with:  python3 tests/gen-config-table.py --write docs/reference.md
set -u
. "$(dirname "$0")/helpers.sh"

GEN="$TALOS_ROOT/tests/gen-config-table.py"
REF="$TALOS_ROOT/docs/reference.md"

python3 -I "$GEN" --check "$REF" 2>/dev/null
assert_eq "0" "$?" "docs/reference.md config tables match scripts/pipeline-defaults.sh (python3 tests/gen-config-table.py --write docs/reference.md)"

# The check is not vacuous: a table with one default changed is reported.
mk="$(mktemp -d "${TMPDIR:-/tmp}/talos-cfgtbl.XXXXXX")" || exit 1
trap 'rm -rf "$mk"' EXIT
sed 's/| `issues.max_parallel` | int | `1` |/| `issues.max_parallel` | int | `9` |/' "$REF" > "$mk/ref.md"
if python3 -I "$GEN" --check "$mk/ref.md" 2>/dev/null; then
  fail "a wrong default in the docs table is detected"
else
  pass "a wrong default in the docs table is detected"
fi

# Every table key appears exactly once in the generated output.
n_rows="$(python3 -I "$GEN" | grep -c '^| `')"
n_keys="$(python3 -I - "$TALOS_ROOT/scripts/pipeline-defaults.sh" <<'TALOS_PYcnt4Rw8Qz2Lm'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"<<'(TALOS_\w+)' \|\| true\n(.*?)\n\1\n", src, re.S)
print(len(m.group(2).split("\n")))
TALOS_PYcnt4Rw8Qz2Lm
)"
assert_eq "$n_keys" "$n_rows" "the generated tables list every defaults row"

# Every key path in the repo's own config and in the shipped example is a table
# key (a "*" in the table stands for one dynamic segment; agents.profiles.<name>.K
# holds any agents.K; keys starting with "_" are notes).
IFS= read -r -d '' KEYS_PY <<'TALOS_PYkey6Jd2Nw9Ps' || true
import json
import re
import sys

src = open(sys.argv[1]).read()
m = re.search(r"<<'(TALOS_\w+)' \|\| true\n(.*?)\n\1\n", src, re.S)
table = [r.split("\t")[0].split(".") for r in m.group(2).split("\n")]

def known(path):
    if len(path) >= 4 and path[:2] == ["agents", "profiles"]:
        path = ["agents"] + path[3:]
    return any(len(t) == len(path) and all(a == "*" or a == b for a, b in zip(t, path))
               for t in table)

bad = []
def walk(node, path):
    if isinstance(node, dict) and node and path != ["agents", "profiles"]:
        for k, v in node.items():
            if not k.startswith("_"):
                walk(v, path + [k])
    elif path and not known(path) and not known(path + ["x"]) and not any(
            t[:len(path)] == path for t in table):
        bad.append(".".join(path))

for f in sys.argv[2:]:
    walk(json.load(open(f)), [])
print("\n".join(bad))
TALOS_PYkey6Jd2Nw9Ps
bad_keys="$(python3 -I -c "$KEYS_PY" "$TALOS_ROOT/scripts/pipeline-defaults.sh" "$TALOS_ROOT/talos.pipeline.json" "$TALOS_ROOT/talos.pipeline.json.example")"
assert_eq "" "$bad_keys" "every key in talos.pipeline.json and the example is a defaults-table key"

finish
