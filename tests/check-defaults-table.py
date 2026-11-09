#!/usr/bin/env python3
"""Check that the config defaults table is well formed.

  python3 -I tests/check-defaults-table.py [scripts/pipeline-defaults.sh]

Exits 0 when every row has six fields, a unique key and a valid type, derived,
env-override, scope and default column; otherwise prints one line per problem,
naming the row's key, and exits 1. It never counts rows, so adding a key needs
no edit to any test (tests/test-config-defaults-table.sh calls it).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_FILE = os.path.join(ROOT, "scripts", "pipeline-defaults.sh")
TYPES = ("str", "path", "int", "float", "bool", "enum", "list", "secret")


def problems(src):
    m = re.search(r"<<'(TALOS_\w+)' \|\| true\n(.*?)\n\1\n", src, re.S)
    if not m:
        return ["no defaults table found"]
    bad = []
    seen = set()
    for line in m.group(2).split("\n"):
        r = line.split("\t")
        key = r[0]
        if len(r) != 6:
            bad.append("%s: %d fields, want 6" % (key, len(r)))
            continue
        _, typ, default, derived, env, scope = r
        if scope not in ("any", "repo"):
            bad.append("%s: scope column %r" % (key, scope))
        if key in seen:
            bad.append("%s: duplicate key" % key)
        seen.add(key)
        if typ not in TYPES:
            bad.append("%s: type %r" % (key, typ))
        if derived not in ("derived", "-"):
            bad.append("%s: derived column %r" % (key, derived))
        if env != "-" and not re.fullmatch(r"[A-Z][A-Z0-9_]*", env):
            bad.append("%s: env-override %r" % (key, env))
        if derived == "derived" and default != "":
            bad.append("%s: a derived key keeps an empty default" % key)
        if typ == "secret" and default != "":
            bad.append("%s: a secret key has no default (it holds an env:NAME reference)" % key)
        if typ == "bool" and default not in ("", "true", "false"):
            bad.append("%s: bool default %r" % (key, default))
        if typ == "int" and not re.fullmatch(r"[0-9]*", default):
            bad.append("%s: int default %r" % (key, default))
        if typ == "float" and not re.fullmatch(r"([0-9]+(\.[0-9]+)?)?", default):
            bad.append("%s: float default %r" % (key, default))
        if re.search(r"[^\x20-\x7e]", default):
            bad.append("%s: default has a control or non-ASCII character" % key)
    return bad


def main(argv):
    path = argv[1] if len(argv) > 1 else DEFAULT_FILE
    bad = problems(open(path).read())
    if bad:
        print("\n".join(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
