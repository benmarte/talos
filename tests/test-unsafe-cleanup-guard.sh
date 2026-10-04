#!/usr/bin/env bash
# test-unsafe-cleanup-guard.sh -- a test or stub must not turn an empty path
# variable into `rm -rf /<name>` (#459, follow-up to #448 and the #436 QA
# incident), and the role profiles carry the standing scratch-script rule.
#
# Two rules scan tests/*.sh, tests/helpers.sh, tests/stubs/* and tests/canary/*:
#
#   R1 mktemp: a `$(mktemp ...)` / backtick mktemp / `$(safe_mktemp_dir ...)`
#      substitution must be followed DIRECTLY (after its closing quote) by
#      `|| <handler>` (not `|| true` or `|| :`); an unrelated `||` later on the
#      line does not count. An unchecked `X="$(mktemp -d)"` leaves X empty when
#      mktemp fails. `local X="$(mktemp -d)" || exit 1` is refused too: `local`
#      (also `export`, `declare`, `typeset`, `readonly`) returns 0, so the
#      handler never fires. Declare first, then assign. Prefer `safe_mktemp_dir` from helpers.sh, which also checks
#      the result is a non-empty directory. A substitution inside single quotes
#      is recipe text handed to another shell (tests/test-free-text-as-data.sh),
#      not run here, and is skipped.
#   R2 rm -rf: in a recursive `rm` (`-r`, `-R`, `-rf`, `-fr`, `--recursive`) an
#      unguarded variable may only be the WHOLE operand ("$X" or "${X}": empty,
#      it is `rm -rf ""`, a harmless error). Anywhere else -- "$X/sub", "$X"/*,
#      "/tmp/$X" -- it must be "${X:?}" so an empty X aborts instead of
#      deleting from `/`. A `$(...)` operand is refused (unverifiable). A bare
#      "$T" is refused too when T was assigned from an unguarded variable plus
#      other text (`T="$W/$f"`): T is never empty, so the guard on `rm` cannot
#      catch an empty W. Guard the base where T is built: `T="${W:?}/$f"`.
#      $SANDBOX and $HOME are exempt bases (make_sandbox sets them or exits).
#      A `/bin/rm` command is matched like `rm`.
#   R4 find -delete: the root operand of `find ... -delete` follows the R2 rule
#      (`find "$X"/ -delete` is `find / -delete` when X is empty).
#
# A third rule scans tests/ and scripts/ (#479):
#
#   R3 infinite producer: a pipeline must not feed `head` (or anything else)
#      from an unbounded source. `/dev/urandom` or `/dev/zero` read in a
#      pipeline stage that is followed by a `|` needs a byte count in that
#      stage (`head -c N`, `od -N N`, `dd count=N`), and `yes |` is refused.
#      With SIGPIPE ignored (the Actions runner does that) the producer gets
#      EPIPE instead of dying, and BSD `tr`/`yes` ignore it and run forever:
#      that hung every macOS main job for six hours. Use a bounded read, for
#      example `od -An -N8 -tx1 /dev/urandom | tr -d ' \n'`.
#
# Matching is per logical line (a backslash continuation is joined, and the
# finding names the line it starts on): comment lines are skipped, and a heredoc
# body that merely contains such text is scanned like code (reword it, or put
# the file on ALLOW). Variable tracking for the derived-path check is per file
# and in source order. The scan FAILS when it scans zero files. A fixture tree (GUARD_ROOT
# with a tests/ dir) proves each rule bites, so the guard cannot rot to a no-op.
#
# ALLOW: files another in-flight change owns. It is empty; add a file only while
# another change owns it, and remove the entry once the file is fixed.
#
# Also pins the one standing scratch-script line in agents/qa.md and
# agents/developer.md (#459).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox

ALLOW=""
SELF_REL="tests/test-unsafe-cleanup-guard.sh"

SCANNER="$SANDBOX/scan.py"
cat > "$SCANNER" <<'TALOS_Qm7Vd3pLx9aZc'
import os, re, sys

root = sys.argv[1]
allow = set(sys.argv[2].split())
self_rel = sys.argv[3]

SUBST = re.compile(r'\$\(\s*(?:command\s+)?(?:mktemp|safe_mktemp_dir)\b|`\s*mktemp\b')
BAD_HANDLER = re.compile(r'\|\|\s*(?:true|:)\s*(?:$|[;)&|}])')
RM = re.compile(r'(?:(?<![\w./-])|(?<=bin/))rm((?:\s+-[A-Za-z-]+)+)\s')
FIND = re.compile(r'(?<![\w./-])find\s')
DECL = r'(?:(?:local|export|declare|typeset|readonly)\s+(?:-\w+\s+)*)'
MASKED = re.compile(r'\b' + DECL + r'\w+=\S*(?:\$\(\s*(?:command\s+)?(?:mktemp|safe_mktemp_dir)\b|`\s*mktemp\b)')
ASSIGN = re.compile(r'(?:^|[\s;&|({])(?:' + DECL + r')?(\w+)=("(?:[^"\\]|\\.)*"|\'[^\']*\'|[^\s;&|)]*)')
VAR = re.compile(r'\$\{(\w+)([^}]*)\}|\$(\w+)')
PIPE = re.compile(r'(?<!\|)\|(?!\|)')
DEVICE = re.compile(r'/dev/(?:urandom|zero)\b')
BOUNDED = re.compile(r'\bhead\s+(?:-[A-Za-z]*c|--bytes)|\bod\b.*\s(?:-[A-Za-z]*N|--read-bytes)|\bdd\b.*\bcount=')
YES = re.compile(r'^[\s({]*(?:\S+=\S*\s+)*(?:command\s+)?yes\b')
BARE = re.compile(r'''^["']?\$(?:\{\w+\}|\w+)["']?$''')


def files():
    t = os.path.join(root, "tests")
    for d, dirs, names in os.walk(t):
        rel = os.path.relpath(d, root)
        if rel.startswith(os.path.join("tests", "fixtures")):
            continue
        for n in sorted(names):
            p = os.path.join(rel, n)
            if p in allow or p == self_rel:
                continue
            if n.endswith(".sh") or rel.startswith(os.path.join("tests", "stubs")):
                yield p


def files_r3():
    # every file under tests/ (not fixtures) and scripts/; the guard itself holds the fixtures
    for top in ("tests", "scripts"):
        for d, dirs, names in os.walk(os.path.join(root, top)):
            rel = os.path.relpath(d, root)
            if rel.startswith(os.path.join("tests", "fixtures")):
                continue
            for n in sorted(names):
                p = os.path.join(rel, n)
                if p != self_rel and not n.endswith((".pyc", ".json")):
                    yield p


def logical_lines(path):
    # (line number, text) with a backslash continuation joined, so an `rm` or a
    # mktemp split across lines is one statement; the number is the first line
    buf, start = "", 0
    for ln, line in enumerate(open(path, errors="replace"), 1):
        if not buf:
            start = ln
        body = line.rstrip("\n")
        if body.endswith("\\"):
            buf += body[:-1] + " "
            continue
        yield start, buf + body
        buf = ""
    if buf:
        yield start, buf


def subst_end(line, i):
    # index just past the substitution that opens at line[i] ($( ... ) or `...`)
    if line[i] == "`":
        j = line.find("`", i + 1)
        return len(line) if j < 0 else j + 1
    depth, q, j = 0, "", i + 1
    while j < len(line):
        c = line[j]
        if q:
            if c == q:
                q = ""
        elif c in "\"'":
            q = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return len(line)


# make_sandbox sets both and exits the test when it cannot, so they are never empty
SAFE_BASES = ("SANDBOX", "HOME")


def risky_value(val):
    # a path built from unguarded variables plus other text: never empty, even
    # when the variables are, so `rm -rf "$T"` on it deletes from the wrong place.
    # One guarded base (${W:?} or $SANDBOX) anchors the whole path.
    v = val.strip("\"'")
    if "$(" in v or "`" in v or BARE.match(val):
        return False
    risky = False
    for m in VAR.finditer(v):
        mod = m.group(2) or ""
        if (m.group(1) or m.group(3)) in SAFE_BASES or mod.startswith(":?"):
            return False
        if m.group(3) is not None or not mod.startswith((":-", ":=", ":+")):
            risky = True
    return risky


def infinite_producer(line):
    for seg in PIPE.split(line)[:-1]:  # a stage that feeds a later one
        if YES.match(seg):
            return "yes |"
        m = DEVICE.search(seg)
        if m and not BOUNDED.search(seg):
            return m.group(0) + " without a byte count"
    return None


def operands(rest, in_sq):
    # split on whitespace outside quotes; stop at an unquoted ; & | newline, or
    # (when the rm sits inside a single-quoted trap string) at the closing quote
    toks, cur, q = [], "", ""
    i = 0
    while i < len(rest):
        c = rest[i]
        if q:
            cur += c
            if c == q:
                q = ""
        elif in_sq and c == "'":
            break
        elif c in "\"'":
            q = c
            cur += c
        elif c in ";&|":
            break
        elif c == ")" and not cur.count("("):
            break
        elif c.isspace():
            if cur:
                toks.append(cur)
                cur = ""
        else:
            cur += c
        i += 1
    if cur:
        toks.append(cur)
    return toks


def unsafe_operand(tok):
    if tok.startswith("'"):
        return False
    if "$(" in tok or "`" in tok:
        return True
    if BARE.match(tok):
        return False
    for m in VAR.finditer(tok):
        mod = m.group(2) or ""
        if m.group(1) is not None and mod.startswith(":?"):
            continue
        return True
    return False


bad = []
n = 0
for rel in files():
    n += 1
    derived = set()
    for ln, line in logical_lines(os.path.join(root, rel)):
        s = line.strip()
        if s.startswith("#"):
            continue
        for m in SUBST.finditer(line):
            if line[:m.start()].count("'") % 2:
                continue  # inside a single-quoted string: data, not code
            tail = line[subst_end(line, m.start()):]
            tail = tail.lstrip('"').lstrip()  # the closing quote, then the handler
            if not tail.startswith("||") or BAD_HANDLER.match(tail):
                bad.append("%s:%d: R1 unchecked mktemp: %s" % (rel, ln, s))
                break
        if MASKED.search(line):
            bad.append("%s:%d: R1 mktemp behind local/export/declare (its status is masked): %s" % (rel, ln, s))
        for m in ASSIGN.finditer(line):
            if risky_value(m.group(2)):
                derived.add(m.group(1))
            else:
                derived.discard(m.group(1))
        for m in RM.finditer(line):
            flags = m.group(1)
            if not re.search(r'-[A-Za-z]*[rR]|--recursive', flags):
                continue
            for tok in operands(line[m.end():], line[:m.start()].count("'") % 2 == 1):
                if unsafe_operand(tok):
                    bad.append("%s:%d: R2 unguarded rm -r operand %s: %s" % (rel, ln, tok, s))
                    break
                v = VAR.fullmatch(tok.strip("\"'"))
                if v and not (v.group(2) or "").startswith(":?") and (v.group(1) or v.group(3)) in derived:
                    bad.append("%s:%d: R2 rm -r operand %s is built from an unguarded variable (use \"${BASE:?}/...\"): %s" % (rel, ln, tok, s))
                    break
        for m in FIND.finditer(line):
            if "-delete" not in line[m.end():] or line[:m.start()].count("'") % 2:
                continue
            for tok in operands(line[m.end():], False):
                if tok.startswith(("-", "(", "!")):
                    break
                if unsafe_operand(tok):
                    bad.append("%s:%d: R4 unguarded find ... -delete root %s: %s" % (rel, ln, tok, s))
                    break
for rel in files_r3():
    for ln, line in enumerate(open(os.path.join(root, rel), errors="replace"), 1):
        if line.strip().startswith("#"):
            continue
        why = infinite_producer(line)
        if why:
            bad.append("%s:%d: R3 unbounded producer in a pipe (%s): %s" % (rel, ln, why, line.strip()))
print("scanned=%d" % n)
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
TALOS_Qm7Vd3pLx9aZc

# --- the real tree --------------------------------------------------------
out="$(python3 -I "$SCANNER" "$TALOS_ROOT" "$ALLOW" "$SELF_REL" 2>&1)"; rc=$?
scanned="$(printf '%s\n' "$out" | sed -n 's/^scanned=//p')"
case "$scanned" in ''|*[!0-9]*) scanned=0 ;; esac
if [ "$scanned" -gt 0 ]; then pass "scan: read $scanned test file(s)"; else fail "scan: read zero test files" "$out"; fi
assert_eq_ctx "0" "$rc" "tests/ and scripts/ have no unchecked mktemp, no unguarded rm -r operand, no unbounded producer in a pipe" "$out"

# --- fixtures: each rule bites, each safe form passes ---------------------
FIX="$SANDBOX/fix"
mkdir -p "$FIX/tests/stubs" || exit 1

scan_fixture() {  # $1=file body; sets FOUT and FRC
  printf '%s\n' "$1" > "$FIX/tests/test-fixture.sh"
  FOUT="$(python3 -I "$SCANNER" "$FIX" "" "$SELF_REL" 2>&1)"; FRC=$?
}
expect_flag() {  # $1=label $2=line $3=rule
  scan_fixture "$2"; local o="$FOUT"
  assert_eq "1" "$FRC" "fixture: flagged -- $1"
  assert_contains "$o" "$3" "fixture: names $3 -- $1"
}
expect_ok() {  # $1=label $2=line
  scan_fixture "$2"; local o="$FOUT"
  assert_eq "0" "$FRC" "fixture: accepted -- $1$( [ "$FRC" -ne 0 ] && printf ': %s' "$o" )"
}

expect_flag "bare mktemp -d" 'D="$(mktemp -d)"' R1
expect_flag "mktemp with template" 'D="$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")"' R1
expect_flag "mktemp file" 'F="$(mktemp)"' R1
expect_flag "backtick mktemp" 'F=`mktemp`' R1
expect_flag "helper without a handler" 'D="$(safe_mktemp_dir)"' R1
expect_flag "|| true is no handler" 'D="$(mktemp -d)" || true' R1
expect_flag "|| : is no handler" 'D="$(mktemp -d)" || :' R1
expect_ok "mktemp || exit 1" 'D="$(mktemp -d)" || exit 1'
expect_ok "helper || exit 1" 'D="$(safe_mktemp_dir "$SANDBOX/x.XXXXXX")" || exit 1'
expect_ok "mktemp || fallback assignment" 'T="$(mktemp "$C/.tmp.XXXXXX" 2>/dev/null)" || T=""'
expect_ok "mktemp named in a comment" '# D="$(mktemp -d)" is the unsafe form'
expect_ok "mktemp inside single quotes (recipe text)" "run_recipe 'F=\"\$(mktemp)\"'"
expect_ok "mktemp as a word, not a substitution" 'for t in bash mktemp rm; do :; done'

expect_flag "rm -rf var/sub" 'rm -rf "$X/sub"' R2
expect_flag "rm -rf var glob" 'rm -rf "$X"/*' R2
expect_flag "rm -rf braces var/sub" 'rm -rf "${X}/sub"' R2
expect_flag "rm -rf /prefix/var" 'rm -rf "/tmp/$X"' R2
expect_flag "rm -fr second operand" 'rm -fr "${A:?}" "$B/x"' R2
expect_flag "rm -r (no f)" 'rm -r "$X/sub"' R2
expect_flag "rm -R" 'rm -R "$X/sub"' R2
expect_flag "rm --recursive" 'rm --recursive "$X/sub"' R2
expect_flag "after && in a function body" '[ -d "$X" ] && rm -rf "$X/sub"' R2
expect_flag "command substitution operand" 'rm -rf "$(cmd)/sub"' R2
expect_flag "unquoted var/sub" 'rm -rf $X/sub' R2
expect_ok "rm -rf bare var" 'rm -rf "$X"'
expect_ok "rm -rf bare braces var, two operands" 'rm -rf "${X}" "$Y"'
expect_ok "rm -rf with a :? guard before /sub" 'rm -rf "${X:?}/sub"'
expect_ok "rm -rf with a :? guard before a glob" 'rm -rf "${X:?}"/*'
expect_ok "rm -rf literal path" 'rm -rf .claude templates'
expect_ok "rm -f (not recursive) var/sub" 'rm -f "$X/sub"'
expect_flag "inside a single-quoted trap string (scanned like code)" "trap 'rm -rf \"\$X/sub\"' EXIT" R2
expect_ok "trap string with a bare variable" "trap 'rm -rf \"\$X\"' EXIT"
expect_ok "rm -rf then a harmless pipe" 'rm -rf "${X:?}/a" | cat'
expect_ok "rm word in a path, not a command" 'cd "$X/form-rm -r/y"'

expect_flag "mktemp with an unrelated || later on the line" 'D="$(mktemp -d)"; [ -d "$D" ] || echo x' R1
expect_flag "mktemp then && ... || (handler not adjacent)" 'D="$(mktemp -d)" && cd "$D" || exit 1' R1
expect_flag "local masks the mktemp status" 'local X="$(mktemp -d)" || exit 1' R1
expect_flag "local -r masks the mktemp status" 'local -r X="$(mktemp -d)" || exit 1' R1
expect_flag "export masks the mktemp status" 'export X="$(mktemp)" || exit 1' R1
expect_flag "declare masks the mktemp status" 'declare X=$(mktemp) || exit 1' R1
expect_ok "declare first, assign second" 'local X; X="$(mktemp -d)" || exit 1'
expect_ok "handler on a continuation line" 'D="$(mktemp -d)" \
  || exit 1'
expect_flag "mktemp split across lines, no handler" 'D="$(mktemp -d \
  "$T/x.XXXXXX")"' R1

expect_flag "rm -rf continued across lines" 'rm -rf \
  "$X/sub"' R2
expect_flag "/bin/rm -rf var/sub" '/bin/rm -rf "$X/sub"' R2
expect_flag "derived path: T built from W, then rm of T" 'T="$W/$f"
rm -rf "$T"' R2
expect_flag "derived path via local" 'local T="$W/$f"
rm -rf "$T"' R2
expect_flag "derived path on one line" 'T="$W/$f"; rm -rf "$T"' R2
expect_ok "derived path, base guarded where it is built" 'T="${W:?}/$f"
rm -rf "$T"'
expect_ok "derived path from \$SANDBOX (make_sandbox guarantees it)" 'T="$SANDBOX/$f"
rm -rf "$T"'
expect_ok "a bare alias of W is not derived" 'T="$W"
rm -rf "$T"'
expect_ok "derived path later reassigned to a guarded value" 'T="$W/$f"
T="${W:?}/$f"
rm -rf "$T"'
expect_ok "rm of a variable never assigned a path" 'rm -rf "$T"'

expect_flag "find root var/ then -delete" 'find "$X"/ -delete' R4
expect_flag "find root var/sub with tests" 'find "$X/sub" -type f -name "*.tmp" -delete' R4
expect_ok "find root guarded with :?" 'find "${X:?}"/ -delete'
expect_ok "find whole-operand var" 'find "$X" -delete'
expect_ok "find literal root" 'find . -name x -delete'
expect_ok "find without -delete" 'find "$X"/ -name x'

expect_flag "tr from urandom into head (the #479 hang)" "rand() { LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 16; }" R3
expect_flag "cat urandom into head" 'cat /dev/urandom | head -c 8' R3
expect_flag "urandom as an operand, piped on" 'tr -dc a-z /dev/urandom | head -c 8' R3
expect_flag "zero into head" 'cat /dev/zero | head -c 8' R3
expect_flag "yes into head" 'yes | head -n 3' R3
expect_flag "yes with an argument into a pipe" 'yes y | cmd' R3
expect_flag "yes after a subshell paren" '( yes | head -n 1 )' R3
expect_flag "urandom with a trailing pipe (continued line)" 'tr -dc a-z < /dev/urandom |' R3
expect_flag "dd from zero without a count" 'dd if=/dev/zero bs=1k | tr x y' R3
expect_ok "head -c on the read side" 'head -c 64 /dev/urandom | od -An -tx1'
expect_ok "od -N on the read side" "LC_ALL=C od -An -N8 -tx1 /dev/urandom | tr -d ' \\n'"
expect_ok "od --read-bytes" 'od -An --read-bytes=8 /dev/urandom | cmd'
expect_ok "dd with a count" 'dd if=/dev/zero bs=1024 count=1100 2>/dev/null | tr x y'
expect_ok "head -c on zero" "head -c 65537 /dev/zero | tr '\\0' a > f"
expect_ok "zero as stdin with no pipe" 'bash x.sh >o 2>e < /dev/zero'
expect_ok "urandom last in the pipeline" 'cmd | cat /dev/urandom'
expect_ok "yes as a word in text" 'echo yes | cat'
expect_ok "yes inside a pattern" "grep -E 'yes|no' f | cat"
expect_ok "|| after a producer is not a pipe" 'head -c 4 /dev/urandom || exit 1'
expect_ok "urandom named in a comment" '# tr </dev/urandom | head is the hang'

# R3 also scans scripts/
mkdir -p "$FIX/scripts" || exit 1
printf '%s\n' 'x="$(tr -dc a-z </dev/urandom | head -c 4)"' > "$FIX/scripts/pipeline-fixture.sh"
printf '%s\n' 'echo ok' > "$FIX/tests/test-fixture.sh"
o="$(python3 -I "$SCANNER" "$FIX" "" "$SELF_REL" 2>&1)"; frc=$?
assert_eq "1" "$frc" "fixture: scripts/ is scanned for an unbounded producer"
assert_contains "$o" "scripts/pipeline-fixture.sh:1: R3" "fixture: names the scripts/ file and line"
rm -f "$FIX/scripts/pipeline-fixture.sh"

# an allow-listed file and a stub are covered; a clean tree passes
printf '%s\n' 'D="$(mktemp -d)"' > "$FIX/tests/stubs/gh"
printf '%s\n' 'echo ok' > "$FIX/tests/test-fixture.sh"
o="$(python3 -I "$SCANNER" "$FIX" "" "$SELF_REL" 2>&1)"; frc=$?
assert_eq "1" "$frc" "fixture: tests/stubs/* is scanned"
o="$(python3 -I "$SCANNER" "$FIX" "tests/stubs/gh" "$SELF_REL" 2>&1)"; frc=$?
assert_eq "0" "$frc" "fixture: an allow-listed path is skipped"
EMPTY="$SANDBOX/empty"; mkdir -p "$EMPTY/tests" || exit 1
o="$(python3 -I "$SCANNER" "$EMPTY" "" "$SELF_REL" 2>&1)"
assert_contains "$o" "scanned=0" "fixture: an empty tests/ reports scanned=0 (the real run fails on it)"

# --- the standing scratch-script line in the role profiles (#459) ---------
LINE_RE='Scratch scripts: check every `mktemp`/`create` result is a non-empty directory before use, delete only via `"${VAR:?}"/...`, and never use a command'"'"'s output after hiding its stderr unless you checked it'
for role in qa developer; do
  f="$TALOS_ROOT/agents/$role.md"
  assert_eq "1" "$(grep -cF -- "$LINE_RE" "$f")" "agents/$role.md carries the standing scratch-script line exactly once"
done

finish
