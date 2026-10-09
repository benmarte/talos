#!/usr/bin/env bash
# test-docs-defaults-vs-table.sh -- the docs and the example configs agree with
# the config schema table (#446, closes the "docs" criterion of epic #437).
#
# scripts/pipeline-defaults.sh is the one place a default is written. This test
# fails when:
#   - a key table row in docs/user-guide.md (the "Config reference" section) or
#     in README.md states a default that differs from the table;
#   - a table key has no row in the user guide, or a row names a key the table
#     does not have;
#   - a `default:` / "default X" / "X (default)" statement in
#     a `_note` of talos.pipeline.json.example differs from the table (the
#     YAML example is gone with the YAML load paths, #526);
#   - a key path in talos.pipeline.json or talos.pipeline.json.example is not a
#     table key;
#   - the README "Config reference" section grows past ~15 lines or loses its
#     pointers to `pipeline-config.sh --show` and the user guide.
#
# Format-only differences are normalised: `[]`, `""` and "unset" all mean an
# empty default; a list is compared by its items (`[a, b]` against the table's
# a\nb); `<role>` is `*`; `0.8` equals `0.80`. A key whose table column 4 says
# "derived" has a computed default the table cannot state: its row must exist
# but its stated default is not compared.
#
# A prose default cell ("unset", "session default", an em dash) is accepted only
# for a key whose table default is empty; a key with a table default needs a row
# whose cell starts with that value in backticks.
#
# The fixtures at the bottom prove the check is not vacuous: each edits a TEMP
# COPY (a changed default, a deleted row, a README table, a changed example
# default) and asserts it goes red. The real files are never modified.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

TABLE="$TALOS_ROOT/scripts/pipeline-defaults.sh"
GUIDE="$TALOS_ROOT/docs/user-guide.md"
README="$TALOS_ROOT/README.md"
JEX="$TALOS_ROOT/talos.pipeline.json.example"
JLIVE="$TALOS_ROOT/talos.pipeline.json"

IFS= read -r -d '' CHECK_PY <<'TALOS_PYdocs8Kx4Rm2Zq' || true
import json
import re
import sys

table_path, guide_path, readme_path, jex_path, jlive_path = sys.argv[1:6]
problems = []
stats = {"rows": 0, "compared": 0, "json": 0}


def fail(msg):
    problems.append(msg)


def norm_key(k):
    return re.sub(r"<[A-Za-z_]+>", "*", k.strip())


# ── the table ────────────────────────────────────────────────────────────────
src = open(table_path).read()
m = re.search(r"<<'(TALOS_\w+)' \|\| true\n(.*?)\n\1\n", src, re.S)
TABLE = {}
for line in m.group(2).split("\n"):
    key, typ, default, derived, env, scope = line.split("\t")
    TABLE[key] = {"type": typ, "default": default.replace("\\n", "\n"),
                  "derived": derived == "derived"}
SEGMENTS = {s for k in TABLE for s in k.split(".") if s != "*"}
TOP = {k.split(".")[0] for k in TABLE}


def matches_table(path):
    """True when the dotted path is a table key ('*' stands for any segment)."""
    p = path.split(".")
    for k in TABLE:
        t = k.split(".")
        if len(t) == len(p) and all(a == "*" or a == b for a, b in zip(t, p)):
            return True
    return False


# ── value normalisation ──────────────────────────────────────────────────────
def norm_list_text(inner):
    items = []
    for it in inner.split(","):
        it = it.strip().strip("'\"`").strip()
        if it:
            items.append(it)
    return "\n".join(items)


def norm_literal(lit):
    lit = lit.strip()
    if lit in ("[]", '""', "''", ""):
        return ""
    if lit.startswith("[") and lit.endswith("]"):
        return norm_list_text(lit[1:-1])
    if len(lit) >= 2 and lit[0] == lit[-1] and lit[0] in "\"'":
        return lit[1:-1]
    return lit


def same(a, b):
    if a == b:
        return True
    try:
        return float(a) == float(b)
    except ValueError:
        return False


def shown(v):
    return repr(v.replace("\n", "\\n"))


# ── doc tables ───────────────────────────────────────────────────────────────
def doc_rows(text):
    """Rows of the tables headed `| Key | Default | ...` (other tables in the
    same file, such as a key-to-variable list, are not key tables)."""
    rows = []
    in_keys = False
    for line in text.split("\n"):
        if not line.startswith("|"):
            in_keys = False
            continue
        if re.match(r"\|\s*Key\s*\|\s*Default\s*\|", line):
            in_keys = True
            continue
        if not in_keys:
            continue
        cells = re.split(r"(?<!\\)\|", line)
        if len(cells) < 4:
            continue
        km = re.fullmatch(r"\s*`([a-z_][A-Za-z0-9_.<>*]*)`\s*", cells[1])
        if not km:
            continue
        rows.append((norm_key(km.group(1)), cells[2].strip()))
    return rows


def check_doc(label, rows, require_known, dups=True):
    seen = {}
    for key, cell in rows:
        if key not in TABLE:
            # Another table (the comment templates, say) may share the shape.
            if require_known:
                fail("%s: row `%s` names a key the table does not have" % (label, key))
            continue
        stats["rows"] += 1
        if dups and key in seen:
            fail("%s: duplicate row for %s" % (label, key))
        seen[key] = cell
        row = TABLE[key]
        if row["derived"]:
            continue
        stats["compared"] += 1
        if cell.startswith("`"):
            end = cell.find("`", 1)
            value = norm_literal(cell[1:end]) if end > 0 else None
            prose = False
        else:
            value, prose = None, True
        if row["default"] == "":
            if not prose and value != "":
                fail("%s: `%s` states default %s, the table has an empty default"
                     % (label, key, shown(value or "")))
        elif prose or value is None or not same(value, row["default"]):
            fail("%s: `%s` states %s, the table default is %s"
                 % (label, key, shown(cell), shown(row["default"])))
    return seen


def section(text, heading, stop=r"^## "):
    m = re.search(r"^## %s\s*$" % re.escape(heading), text, re.M)
    if not m:
        return None
    rest = text[m.end():]
    n = re.search(stop, rest, re.M)
    return rest[: n.start()] if n else rest


guide = open(guide_path).read()
guide_cfg = section(guide, "Config reference")
if guide_cfg is None:
    fail("user guide: no '## Config reference' section")
    guide_cfg = ""
seen = check_doc("user guide", doc_rows(guide_cfg), True)
# Key tables elsewhere in the guide (the evidence keys) state
# defaults too: same comparison, no duplicate or unknown-row rule.
check_doc("user guide", doc_rows(guide.replace(guide_cfg, "")), False, dups=False)
for key in TABLE:
    if key not in seen:
        fail("user guide: table key `%s` has no row in the Config reference" % key)

readme = open(readme_path).read()
check_doc("README", doc_rows(readme), False)
# The README section ends at its first subsection (### Hooks and the rest are other topics).
rsec = section(readme, "Config reference", r"^#{2,3} ")
if rsec is None:
    fail("README: no '## Config reference' section")
else:
    body = [l for l in rsec.split("\n") if l.strip()]
    if len(body) > 15:
        fail("README: the Config reference section is %d lines, limit 15" % len(body))
    if "pipeline-config.sh --show" not in rsec:
        fail("README: the Config reference section does not point at pipeline-config.sh --show")
    if "docs/user-guide.md#config-reference" not in rsec:
        fail("README: the Config reference section does not link docs/user-guide.md#config-reference")


# ── statements in free text (the YAML example's comments, a JSON _note) ──────
KEY_TOKEN = re.compile(r"(?<![A-Za-z0-9_.<>*/-])([a-z_]+(?:\.(?:[a-z_]+|<[a-z_]+>|\*))+)")
VALUES = (
    (re.compile(r"\s*:?\s*(true|false)\b"), lambda g: g),
    (re.compile(r"\s*:?\s*(-?\d+(?:\.\d+)?)(?![\w-]|\.\d)"), lambda g: g),
    (re.compile(r"\s*:?\s*(\"[^\"]*\")"), norm_literal),
    (re.compile(r"\s*:?\s*(\[[^\]]*\])"), norm_literal),
    (re.compile(r"\s*:?\s*(unset|empty)\b"), lambda g: ""),
    (re.compile(r"\s*:\s*([A-Za-z0-9_./-]*[A-Za-z0-9_/-])"), lambda g: g),
)


def statements(text):
    """Yield (offset, value, bare) for every default statement in text."""
    for dm in re.finditer(r"\b[Dd]efaults?\b", text):
        rest = text[dm.end(): dm.end() + 240]
        for rx, conv in VALUES:
            vm = rx.match(rest)
            if vm:
                bare = rx is VALUES[-1][0]
                yield dm.start(), conv(vm.group(1)), bare
                break
    for dm in re.finditer(r"(\"[^\"]*\"|[A-Za-z0-9_./-]+)\s+\(default\)", text):
        yield dm.start(), norm_literal(dm.group(1)), False


def explicit_key(text, offset):
    """The table key named in the same sentence, before the statement."""
    best = None
    for km in KEY_TOKEN.finditer(text[:offset]):
        k = norm_key(km.group(1))
        if k in TABLE:
            best = (k, km.end())
    if best is None:
        return None
    between = re.sub(r"\b(?:e\.g|i\.e)\.", "", text[best[1]:offset])
    return None if re.search(r"\.\s", between) else best[0]


def check_statement(label, key, value, bare):
    if key is None or key not in TABLE:
        return
    row = TABLE[key]
    if row["derived"]:
        return
    if bare and (row["default"] == "" or row["type"] not in ("enum", "path", "str")):
        return
    stats[label] += 1
    if not same(value, row["default"]):
        fail("%s: `%s` is stated with default %s, the table default is %s"
             % ("json note", key, shown(value), shown(row["default"])))


# ── talos.pipeline.json.example and talos.pipeline.json ──────────────────────
def leaves(node, prefix=()):
    if isinstance(node, dict) and node:
        for k, v in node.items():
            yield from leaves(v, prefix + (k,))
    else:
        yield prefix, node


for path, label in ((jex_path, "talos.pipeline.json.example"), (jlive_path, "talos.pipeline.json")):
    data = json.load(open(path))
    for p, val in leaves(data):
        if p and p[0].startswith("_"):
            if isinstance(val, str):
                text = re.sub(r"\s+", " ", val)
                for off, value, bare in statements(text):
                    check_statement("json", explicit_key(text, off), value, bare)
            continue
        dotted = ".".join(p)
        if not matches_table(dotted):
            fail("%s: key path %s is not a table key" % (label, dotted))

for p in problems:
    print("FAIL: " + p)
print("INFO: rows=%(rows)d compared=%(compared)d json=%(json)d" % stats)
TALOS_PYdocs8Kx4Rm2Zq

# run_check GUIDE README YML [JSON-EXAMPLE]  -> prints the checker's output
run_check() {
  python3 -I -c "$CHECK_PY" "$TABLE" "$1" "$2" "${3:-$JEX}" "$JLIVE"
}

# ── the real files are green ─────────────────────────────────────────────────
OUT="$(run_check "$GUIDE" "$README" 2>&1)"
_fails="$(printf '%s\n' "$OUT" | grep -c '^FAIL: ')"
if [ "$_fails" = "0" ]; then
  pass "docs and examples agree with the config table"
else
  fail "docs and examples agree with the config table" "$(printf '%s\n' "$OUT" | grep '^FAIL: ' | head -20)"
fi

_info="$(printf '%s\n' "$OUT" | grep '^INFO: ')"
_n() { printf '%s' "$_info" | sed -n "s/.*$1=\([0-9]*\).*/\1/p"; }
# Floors, so a parser that silently finds nothing cannot pass: the table has
# ~120 rows, ~95 of them with a comparable default; the YAML example and the
# JSON note state dozens of defaults.
for pair in "rows:100" "compared:70" "json:25"; do
  _k="${pair%%:*}" _min="${pair##*:}"
  _v="$(_n "$_k")"
  if [ -n "$_v" ] && [ "$_v" -ge "$_min" ]; then pass "the check reads enough $_k ($_v >= $_min)"
  else fail "the check reads enough $_k" "got '${_v:-none}', want at least $_min"; fi
done

# ── red on a changed default in a temp copy of the guide ─────────────────────
T="$SANDBOX/copies"
mkdir -p "$T" || exit 1

sed 's/^| `merge.method` | `squash` |/| `merge.method` | `merge` |/' "$GUIDE" > "$T/guide-changed.md"
if cmp -s "$GUIDE" "$T/guide-changed.md"; then
  fail "fixture: the merge.method row edit applied" "the row was not found in the user guide"
else
  OUT="$(run_check "$T/guide-changed.md" "$README" 2>&1)"
  assert_contains "$OUT" 'FAIL: user guide: `merge.method` states' "a changed default in a copy of the user guide is red"
fi

# a list default, a bool default and an empty default
sed 's/^| `issues.skip_labels` | `\[pipeline:blocked, wontfix\]`/| `issues.skip_labels` | `[pipeline:blocked]`/' "$GUIDE" > "$T/guide-list.md"
if cmp -s "$GUIDE" "$T/guide-list.md"; then
  fail "fixture: the issues.skip_labels row edit applied" "the row was not found in the user guide"
else
  OUT="$(run_check "$T/guide-list.md" "$README" 2>&1)"
  assert_contains "$OUT" 'FAIL: user guide: `issues.skip_labels` states' "a changed list default is red"
fi
sed 's/^| `board.enabled` | `true` |/| `board.enabled` | `false` |/' "$GUIDE" > "$T/guide-bool.md"
if cmp -s "$GUIDE" "$T/guide-bool.md"; then
  fail "fixture: the board.enabled row edit applied" "the row was not found in the user guide"
else
  OUT="$(run_check "$T/guide-bool.md" "$README" 2>&1)"
  assert_contains "$OUT" 'FAIL: user guide: `board.enabled` states' "board.enabled stated as false is red (the #446 drift)"
fi

# a key table outside the Config reference (the evidence keys) is checked too
sed 's/^| `evidence.when` | `user-facing` |/| `evidence.when` | `always` |/' "$GUIDE" > "$T/guide-status.md"
if cmp -s "$GUIDE" "$T/guide-status.md"; then
  fail "fixture: the evidence.when row edit applied" "the row was not found in the user guide"
else
  OUT="$(run_check "$T/guide-status.md" "$README" 2>&1)"
  assert_contains "$OUT" 'FAIL: user guide: `evidence.when` states' "a changed default in the evidence key table is red"
fi

# ── red on a deleted row ─────────────────────────────────────────────────────
grep -v '^| `limits.warn_at` |' "$GUIDE" > "$T/guide-norow.md"
OUT="$(run_check "$T/guide-norow.md" "$README" 2>&1)"
assert_contains "$OUT" 'table key `limits.warn_at` has no row' "a table key with no row in the user guide is red"

# ── red on a row for a key the table does not have ───────────────────────────
sed 's/^| `limits.warn_at` |/| `limits.warn_att` |/' "$GUIDE" > "$T/guide-unknown.md"
OUT="$(run_check "$T/guide-unknown.md" "$README" 2>&1)"
assert_contains "$OUT" 'row `limits.warn_att` names a key the table does not have' "a row for an unknown key is red"

# ── README rows are checked too (a temp README with a table row) ─────────────
{ cat "$README"; printf '\n| Key | Default | Description |\n|-----|---------|-------------|\n| `merge.method` | `rebase` | x |\n'; } > "$T/readme-table.md"
OUT="$(run_check "$GUIDE" "$T/readme-table.md" 2>&1)"
assert_contains "$OUT" 'FAIL: README: `merge.method` states' "a changed default in a copy of the README is red"

# ── README section size and pointers ─────────────────────────────────────────
{ printf '## Config reference\n\nSee `pipeline-config.sh --show` and docs/user-guide.md#config-reference.\n\n'
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do printf 'line %s\n' "$_i"; done; } > "$T/readme-long.md"
OUT="$(run_check "$GUIDE" "$T/readme-long.md" 2>&1)"
assert_contains "$OUT" 'README: the Config reference section is' "a README Config reference section over 15 lines is red"
printf '## Config reference\n\nSee the user guide.\n' > "$T/readme-nopointer.md"
OUT="$(run_check "$GUIDE" "$T/readme-nopointer.md" 2>&1)"
assert_contains "$OUT" 'does not point at pipeline-config.sh --show' "a README section without the --show pointer is red"

# ── red on a changed default in a temp copy of the JSON example's _note ──────
sed 's/verify.ci_wait_s (default 900,/verify.ci_wait_s (default 600,/' "$JEX" > "$T/example-changed.json"
if cmp -s "$JEX" "$T/example-changed.json"; then
  fail "fixture: the verify.ci_wait_s note edit applied" "the statement was not found in the JSON example"
else
  OUT="$(run_check "$GUIDE" "$README" "$T/example-changed.json" 2>&1)"
  assert_contains "$OUT" 'json note: `verify.ci_wait_s` is stated with default' "a changed default in a copy of the JSON example note is red"
fi
sed 's/"max_parallel": 1/"max_paralel": 1/' "$JEX" > "$T/example-typo.json"
OUT="$(run_check "$GUIDE" "$README" "$T/example-typo.json" 2>&1)"
assert_contains "$OUT" 'key path issues.max_paralel is not a table key' "a mistyped key path in the JSON example is red"

finish
