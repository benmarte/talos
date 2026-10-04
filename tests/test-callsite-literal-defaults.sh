#!/usr/bin/env bash
# test-callsite-literal-defaults.sh -- guard for #439/#440 (epic #437): no
# `cfg KEY "literal"` / `pipeline-config.sh KEY literal` call site.
#
# A default lives in one place, the config schema table in
# scripts/pipeline-defaults.sh. A call that passes its own literal default (even
# "") is a second copy that can drift from the table. The guard is STRICT since
# #440: the allow file tests/fixtures/callsite-literal-defaults.allow is empty
# (this test fails if it gains an entry) and any literal-default call fails.
# The allow-file mechanism stays so the fixtures below can show each rule bites:
# one line per occurrence,
#
#     <path relative to the repo root> TAB <the call, whitespace-normalised>
#
# counted per path and call, so a second copy of an allowed call is new too. A
# line that no longer matches a call is only noted in the fixtures.
#
# Wrappers are covered too (#440): `_sf_posint KEY DEF`, `_sf_role_on KEY DEF`,
# and a helper that forwards a default (`pipeline-config.sh "$1" ""`,
# `cfg "$1" "$2"`) -- see WRAPCALL and FORWARD in the scanner.
#
# A call with a default that is not a literal (`cfg board.owner "$_owner"`) is a
# derived default and is allowed; so is a call with no default at all.
#
# Scanned: scripts/*.sh (not the three files that implement the mechanism) and
# skills/**/*.md and agents/**/*.md, skipping lines that are comments (first non-blank char "#").
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

ALLOW="$TALOS_ROOT/tests/fixtures/callsite-literal-defaults.allow"

# scan ROOT ALLOWFILE -- prints "NEW<TAB>path<TAB>call" per literal-default call
# beyond what the allow file lists, and "STALE<TAB>path<TAB>call" per allow line
# with no matching call.
IFS= read -r -d "" SCANNER <<'TALOS_PYscan4Hk8Wm2Qv' || true
import collections
import glob
import os
import re
import sys

root, allow_path = sys.argv[1], sys.argv[2]

SKIP = {"pipeline-config.sh", "pipeline-cfg-cache.sh", "pipeline-defaults.sh"}
# A key is a dotted path, one of the four top-level keys, or a quoted string
# starting with a letter (a templated key such as "agents.roles.$r.model").
# Prose that merely says "pipeline-config.sh would use" is not a call.
KEY = (r'''"[A-Za-z_][^"]*"|[a-z_][a-z0-9_]*(?:\.[A-Za-z0-9_*]+)+|'''
       r'''(?:base_branch|release_branch|repo|verify)(?![\w.])''')
DEF = r'''"(?:[^"\\]|\\.)*"|'[^']*'|[^\s"'`$()|;&<>]+'''
CALL = re.compile(
    r"(?<![\w-])(?P<fn>cfg|pipeline-config\.sh\"?|\"\$CFG(?:_SH)?\")[ \t]+(?P<key>" + KEY + r")"
    r"(?:[ \t]+(?P<def>" + DEF + r")(?![^\s)}\];|&\"'`]))?")

# Wrappers (#440). A helper that forwards a default hides the literal one level
# down, so the guard also reads:
#   _sf_posint KEY DEF MAX / _sf_role_on KEY DEF   (pipeline-status-file.sh): the
#       literal DEF after the key, exactly like a cfg call;
#   a call that forwards a positional default (`cfg "$1" "$2"`), and a wrapper
#       definition that does (`pipeline-config.sh "$1" ""`, `... "$1" "${2:-}"`):
#       whatever the default is, the table can never answer through it. Only
#       "$@" passes the caller's own argument list through unchanged.
WRAPCALL = re.compile(
    r"(?<![\w-])(?P<fn>_sf_posint|_sf_role_on)[ \t]+(?P<key>" + KEY + r")"
    r"(?:[ \t]+(?P<def>" + DEF + r")(?![^\s)}\];|&\"'`]))?")
FORWARD = re.compile(
    r"(?<![\w-])(?P<fn>cfg|pipeline-config\.sh\"?)[ \t]+(?P<key>\"\$[0-9]\")[ \t]+"
    r"(?P<def>\"(?:[^\"\\]|\\.)*\"|(?![0-9]*[<>])[^\s|;&<>)]+)")

def files():
    for f in sorted(glob.glob(os.path.join(root, "scripts", "*.sh"))):
        if os.path.basename(f) not in SKIP:
            yield f
    for sub in ("skills", "agents"):
        for f in sorted(glob.glob(os.path.join(root, sub, "**", "*.md"), recursive=True)):
            yield f

found = collections.Counter()
for f in files():
    rel = os.path.relpath(f, root)
    with open(f, errors="replace") as fh:
        for line in fh:
            if line.lstrip().startswith("#"):
                continue
            for m in CALL.finditer(line):
                d = m.group("def")
                if d is None or "$" in d or "`" in d:
                    continue  # no default, or a computed one: allowed
                found[(rel, " ".join([m.group("fn"), m.group("key"), d]))] += 1
            for m in WRAPCALL.finditer(line):
                d = m.group("def")
                if d is None or "$" in d or "`" in d:
                    continue
                found[(rel, " ".join([m.group("fn"), m.group("key"), d]))] += 1
            for m in FORWARD.finditer(line):
                found[(rel, " ".join([m.group("fn"), m.group("key"), m.group("def")]))] += 1

allowed = collections.Counter()
if os.path.exists(allow_path):
    with open(allow_path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            rel, _, call = line.partition("\t")
            allowed[(rel, call)] += 1

for k in sorted(found):
    for _ in range(found[k] - allowed.get(k, 0)):
        print("NEW\t%s\t%s" % k)
for k in sorted(allowed):
    for _ in range(allowed[k] - found.get(k, 0)):
        print("STALE\t%s\t%s" % k)
TALOS_PYscan4Hk8Wm2Qv

_scan() { python3 -I -c "$SCANNER" "$1" "$2"; }
_row() { printf '%s\t%s\t%s' "$1" "$2" "$3"; }

# ── The real tree: strict, the allow list is empty ───────────────────────────
assert_file_exists "$ALLOW" "the allow list exists"
_entries="$(grep -c -v -e '^#' -e '^[[:space:]]*$' "$ALLOW" || true)"
assert_eq "0" "$_entries" "the allow list is empty (every call site reads the table)"
_real="$(_scan "$TALOS_ROOT" "$ALLOW")"
assert_eq "" "$_real" "no literal-default cfg / pipeline-config.sh call in scripts/ or skills/"

# ── Fixtures: the guard goes red, and only when it should ────────────────────
FIX="$SANDBOX/fixture-tree"
mkdir -p "$FIX/scripts" "$FIX/skills/demo" || exit 1
NOALLOW="$SANDBOX/empty.allow"
: > "$NOALLOW"

cat > "$FIX/scripts/pipeline-demo.sh" <<'TALOS_FIXa9Xr3Tq7Lm2Wd'
#!/usr/bin/env bash
warn_at="$(cfg limits.warn_at "0.8")"
TALOS_FIXa9Xr3Tq7Lm2Wd
_out="$(_scan "$FIX" "$NOALLOW")"
assert_eq "$(_row NEW scripts/pipeline-demo.sh 'cfg limits.warn_at "0.8"')" "$_out" \
  "guard is red on a fixture call: cfg limits.warn_at \"0.8\""

printf '%s\t%s\n' "scripts/pipeline-demo.sh" 'cfg limits.warn_at "0.8"' > "$SANDBOX/one.allow"
assert_eq "" "$(_scan "$FIX" "$SANDBOX/one.allow")" "the same call on the allow list passes"

cat >> "$FIX/scripts/pipeline-demo.sh" <<'TALOS_FIXb5Vn8Ck4Ps6Ye'
again="$(cfg limits.warn_at "0.8")"
TALOS_FIXb5Vn8Ck4Ps6Ye
assert_eq "$(_row NEW scripts/pipeline-demo.sh 'cfg limits.warn_at "0.8"')" "$(_scan "$FIX" "$SANDBOX/one.allow")" \
  "a second copy of an allowed call is new"

cat > "$FIX/scripts/pipeline-demo.sh" <<'TALOS_FIXc2Jd7Rw9Hg3Zq'
#!/usr/bin/env bash
# cfg limits.warn_at "0.8"   <- a comment is not a call
a="$(cfg limits.warn_at)"
b="$(cfg board.owner "$_default_owner")"
c="$(cfg base_branch 2>/dev/null)"
d="$(cfg "board.status_map.$s" "$s")"
e="$(bash "$SCRIPT_DIR/pipeline-config.sh" --dump)"
f="$(cfg_helper limits.warn_at "0.8")"
TALOS_FIXc2Jd7Rw9Hg3Zq
assert_eq "" "$(_scan "$FIX" "$NOALLOW")" \
  "comments, no-default, computed-default, flag and look-alike calls are not flagged"
cat > "$FIX/scripts/pipeline-demo.sh" <<'TALOS_FIXd8Lk4Nm1Bt5Xv'
#!/usr/bin/env bash
a="$(cfg board.owner "$_default_owner")"
c="$(cfg base_branch 2>/dev/null)"
TALOS_FIXd8Lk4Nm1Bt5Xv
assert_eq "" "$(_scan "$FIX" "$NOALLOW")" "no-default and computed-default calls are allowed"

cat > "$FIX/scripts/pipeline-demo.sh" <<'TALOS_FIXe3Qp6Gh2Wy9Ks'
#!/usr/bin/env bash
x=$(bash scripts/pipeline-config.sh merge.method squash)
y="$(cfg events.enabled true | tr '[:upper:]' '[:lower:]')"
z="$(cfg status.file TALOS_STATUS.md)"
TALOS_FIXe3Qp6Gh2Wy9Ks
_out="$(_scan "$FIX" "$NOALLOW" | cut -f3)"
assert_contains "$_out" "pipeline-config.sh merge.method squash" "a bare literal on a pipeline-config.sh call is flagged"
assert_contains "$_out" "cfg events.enabled true" "a bare literal before a pipe is flagged"
assert_contains "$_out" "cfg status.file TALOS_STATUS.md" "a bare literal before a closing paren is flagged"

# Wrappers (#440): a literal passed to a helper, and a helper that forwards a default
cat > "$FIX/scripts/pipeline-demo.sh" <<'TALOS_FIXg4Hy7Bn2Xs8Mt'
#!/usr/bin/env bash
cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$1" "${2:-}" 2>/dev/null; }
_dc_cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$1" "" 2>/dev/null | tr 'A-Z' 'a-z'; }
LOG_DAYS="$(_sf_posint status.log_days 30 36500)"
_sf_role_on roles.qa true && roles="${roles}qa,"
v="$(cfg "$1" "$2")"
TALOS_FIXg4Hy7Bn2Xs8Mt
_out="$(_scan "$FIX" "$NOALLOW" | cut -f3)"
assert_contains "$_out" 'pipeline-config.sh" "$1" "${2:-}"' "a wrapper that forwards a default is flagged"
assert_contains "$_out" 'pipeline-config.sh" "$1" ""' "a wrapper that passes an empty default is flagged"
assert_contains "$_out" "_sf_posint status.log_days 30" "a literal passed to _sf_posint is flagged"
assert_contains "$_out" "_sf_role_on roles.qa true" "a literal passed to _sf_role_on is flagged"
assert_contains "$_out" 'cfg "$1" "$2"' "a call that forwards a positional default is flagged"
cat > "$FIX/scripts/pipeline-demo.sh" <<'TALOS_FIXh9Rk3Wd6Pq1Zv'
#!/usr/bin/env bash
cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$@"; }
_dc_cfg() { bash "$SCRIPT_DIR/pipeline-config.sh" "$1" 2>/dev/null | tr 'A-Z' 'a-z'; }
_sf_posint() { local v; v="$(cfg "$1")"; printf '%s' "$v"; }
LOG_DAYS="$(_sf_posint status.log_days)"
_sf_role_on roles.qa && roles="${roles}qa,"
TALOS_FIXh9Rk3Wd6Pq1Zv
assert_eq "" "$(_scan "$FIX" "$NOALLOW")" "wrappers that pass the caller's arguments through, and calls with no default, are not flagged"

: > "$FIX/scripts/pipeline-demo.sh"
cat > "$FIX/skills/demo/SKILL.md" <<'TALOS_FIXf6Dm1Vc8Jn4Th'
Read it with `bash scripts/pipeline-config.sh status.enabled unset` first.
Then `bash scripts/pipeline-config.sh agents.model` with no default.
TALOS_FIXf6Dm1Vc8Jn4Th
assert_eq "$(_row NEW skills/demo/SKILL.md 'pipeline-config.sh status.enabled unset')" "$(_scan "$FIX" "$NOALLOW")" \
  "a literal default in a skill playbook is flagged"

printf '%s\t%s\n' "scripts/gone.sh" 'cfg a.b "c"' > "$SANDBOX/stale.allow"
: > "$FIX/skills/demo/SKILL.md"
assert_eq "$(_row STALE scripts/gone.sh 'cfg a.b "c"')" "$(_scan "$FIX" "$SANDBOX/stale.allow")" \
  "an allow line with no matching call is reported as stale, not as new"

finish
