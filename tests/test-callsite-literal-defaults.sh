#!/usr/bin/env bash
# test-callsite-literal-defaults.sh -- ratchet guard for #439 (epic #437): no
# NEW `cfg KEY "literal"` / `pipeline-config.sh KEY literal` call site.
#
# A default now lives in one place, the config schema table in
# scripts/pipeline-defaults.sh. A call that passes its own literal default (even
# "") is a second copy that can drift from the table. The call sites that
# existed when the table landed are listed in
# tests/fixtures/callsite-literal-defaults.allow, one line per occurrence:
#
#     <path relative to the repo root> TAB <the call, whitespace-normalised>
#
# This test fails on any literal-default call that is not on that list (counted
# per path and call, so a second copy of an allowed call is new too). Later
# tasks of the epic (#440 onward) migrate the listed calls to the table and
# delete their lines; the list ends empty. A line that no longer matches a call
# is only noted, never a failure, so removing a call never breaks an unrelated
# branch.
#
# A call with a default that is not a literal (`cfg board.owner "$_owner"`) is a
# derived default and is allowed; so is a call with no default at all.
#
# Scanned: scripts/*.sh (not the three files that implement the mechanism) and
# skills/**/*.md, skipping lines that are comments (first non-blank char "#").
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

def files():
    for f in sorted(glob.glob(os.path.join(root, "scripts", "*.sh"))):
        if os.path.basename(f) not in SKIP:
            yield f
    for f in sorted(glob.glob(os.path.join(root, "skills", "**", "*.md"), recursive=True)):
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

# ── The real tree: nothing outside the allow list ────────────────────────────
assert_file_exists "$ALLOW" "the allow list exists"
_real="$(_scan "$TALOS_ROOT" "$ALLOW")"
_new="$(printf '%s\n' "$_real" | grep '^NEW' || true)"
assert_eq "" "$_new" "no literal-default cfg / pipeline-config.sh call outside the allow list"
_stale_n="$(printf '%s\n' "$_real" | grep -c '^STALE' || true)"
[ "$_stale_n" = "0" ] || printf '  note: %s allow-list line(s) match no call any more; delete them\n' "$_stale_n"

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
