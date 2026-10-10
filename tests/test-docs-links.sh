#!/usr/bin/env bash
# test-docs-links.sh -- every relative markdown link in the docs, playbooks, role
# profiles and templates resolves: the file exists and, for a #fragment into a
# markdown file, the heading exists. Also: nothing points at the removed
# docs/user-guide.md. No prose is pinned.
set -u
. "$(dirname "$0")/helpers.sh"

# The checker is held in a variable first: a heredoc with backticks inside $( )
# is a parse trap on bash 3.2.
IFS= read -r -d '' LINK_PY <<'TALOS_PYlnk9Hx3Vt6Bd' || true
import os
import re

FILES = ["README.md", "CHANGELOG.md", "CLAUDE.md"]
for top in ("docs", "skills", "agents", "templates"):
    for d, _, names in os.walk(top):
        FILES += [os.path.join(d, n) for n in names
                  if n.endswith(".md") and n != "CHANGELOG-archive.md"]

def slug(h):
    h = h.strip().replace("`", "").lower()
    h = re.sub(r"[^a-z0-9 _-]", "", h)
    return h.replace(" ", "-")

def anchors(path):
    found, fence = set(), False
    for line in open(path, encoding="utf-8"):
        if line.startswith("```"):
            fence = not fence
        m = None if fence else re.match(r"#{1,6}\s+(.*)", line)
        if m:
            found.add(slug(m.group(1)))
    return found

LINK = re.compile(r"\]\(([^)\s]+)\)")
INLINE_CODE = re.compile(r"`[^`]*`")
bad = []
for f in sorted(FILES):
    text, fence = [], False
    for line in open(f, encoding="utf-8"):
        if line.startswith("```"):
            fence = not fence
            continue
        if not fence:
            text.append(INLINE_CODE.sub("", line))
    for target in LINK.findall("".join(text)):
        if re.match(r"[a-z][a-z0-9+.-]*:", target):
            continue
        path, _, frag = target.partition("#")
        full = os.path.normpath(os.path.join(os.path.dirname(f), path)) if path else f
        if not os.path.exists(full):
            bad.append("%s: %s -> missing file" % (f, target))
        elif frag and full.endswith(".md") and frag not in anchors(full):
            bad.append("%s: %s -> no heading #%s in %s" % (f, target, frag, full))
print("\n".join(bad))
TALOS_PYlnk9Hx3Vt6Bd

out="$(cd "$TALOS_ROOT" && python3 -I -c "$LINK_PY")"
assert_eq "" "$out" "every relative markdown link resolves"

stale="$(cd "$TALOS_ROOT" && grep -rIl 'user-guide\.md' README.md CLAUDE.md docs/reference.md skills agents templates scripts install.sh tests talos.pipeline.json.example 2>/dev/null | grep -v '^tests/test-docs-links.sh$' || true)"
assert_eq "" "$stale" "nothing references the removed docs/user-guide.md"

finish
