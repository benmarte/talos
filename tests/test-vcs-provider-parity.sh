#!/usr/bin/env bash
# test-vcs-provider-parity.sh — every verb the stage prompts and scripts call
# must exist in every provider (_github, _gitlab, _azure, _file), unless a
# PARITY_EXCEPTIONS line (or a `# PARITY-EXCEPTION: <reason>` on the provider's
# case arm) records why not. tests/test-verb-parity.sh pins the _github set;
# this file compares the providers with each other (#753 slice 1).
#
# A verb counts as called when a prompt or script passes it to pipeline-vcs.sh
# (directly, through talos.sh's `_vcs` wrapper, or as pipeline-next.py's
# `vcs('<verb>')`). The table is also in docs/reference.md (Provider parity).
#
# Later slices add the missing verbs and delete the matching table lines; a
# table line left behind after that fails here as stale.
#
set -u
. "$(dirname "$0")/helpers.sh"
# No sandbox needed for the real-repo check: it only reads files. The fixtures
# live in a safe_mktemp_dir that is removed on exit.

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# parity_check <vcs-script> <exceptions-file> <caller-file>...
# Prints one line per problem (naming the provider and the verb) and returns 1
# when there is one; prints nothing and returns 0 otherwise.
parity_check() {
  python3 -I - "$@" <<'PYEOF'
import re, sys

vcs_path, exc_path = sys.argv[1], sys.argv[2]
callers = sys.argv[3:]

with open(vcs_path) as f:
    lines = f.readlines()

def function_body(name):
    start = None
    for i, line in enumerate(lines):
        if re.match(r'^' + re.escape(name) + r'\s*\(\)', line):
            start = i
            break
    if start is None:
        print(f'parity: function {name} not found in {vcs_path}')
        sys.exit(1)
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*\(\)', lines[i]):
            end = i
            break
    return lines[start:end]

# Case arms "    a|b)" (four-space indent, as test-verb-parity.sh reads them).
# An arm marked "# PARITY-EXCEPTION:" is a recorded gap, not a handler (the
# marker test-verb-parity.sh's extractor already skips).
arm_re = re.compile(r'^\s{4}([a-z][a-z0-9|-]+)\)(.*)$')
py_re = re.compile(r"\bverb == '([a-z][a-z0-9-]*)'")
# Verbs handled before dispatch, for every provider but file.
PRE_DISPATCH = ('edit-pr-body', 'conflict-files')

PROVIDERS = (('github', '_github'), ('gitlab', '_gitlab'),
             ('azure', '_azure'), ('file', '_file'))
handled, arm_excepted = {}, {}
for prov, fn in PROVIDERS:
    handled[prov], arm_excepted[prov] = set(), set()
    for line in function_body(fn):
        m = arm_re.match(line)
        if m:
            for v in m.group(1).split('|'):
                if 'PARITY-EXCEPTION:' in m.group(2):
                    arm_excepted[prov].add(v)
                else:
                    handled[prov].add(v)
        if prov == 'file':
            handled[prov].update(py_re.findall(line))
for prov in ('github', 'gitlab', 'azure'):
    handled[prov].update(PRE_DISPATCH)

universe = set(PRE_DISPATCH)
for prov, _ in PROVIDERS:
    universe |= handled[prov] | arm_excepted[prov]

# Verbs the callers pass to pipeline-vcs.sh; prose tokens fall out because
# they are not in the universe.
# They are called as `pipeline-vcs.sh <verb>`, through talos.sh's `_vcs <verb>`
# wrapper, or through pipeline-next.py's `vcs('<verb>', ...)`.
call_re = re.compile(
    r'pipeline-vcs\.sh["\']?[ \t]+([a-z][a-z0-9-]*)'
    r'|(?<![A-Za-z0-9_])_vcs["\']?[ \t]+([a-z][a-z0-9-]*)'
    r'|(?<![A-Za-z0-9_])vcs\(\s*[\'"]([a-z][a-z0-9-]*)[\'"]')
called = {}
for path in callers:
    try:
        with open(path, errors='replace') as f:
            text = f.read()
    except OSError:
        continue
    for m in call_re.finditer(text):
        v = m.group(1) or m.group(2) or m.group(3)
        if v in universe:
            called.setdefault(v, path)

table = {}
with open(exc_path) as f:
    for raw in f:
        raw = raw.strip()
        if not raw or raw.startswith('#'):
            continue
        m = re.match(r'^(\S+)\s+(\S+)\s+PARITY-EXCEPTION:\s*(\S.*)$', raw)
        if not m:
            print(f'parity: malformed exceptions line: {raw}')
            sys.exit(1)
        table[(m.group(1), m.group(2))] = m.group(3)

problems = []
for prov, _ in PROVIDERS:
    for v in sorted(called):
        if v in handled[prov] or (prov, v) in table or v in arm_excepted[prov]:
            continue
        problems.append(f'MISSING {prov} {v}: called by {called[v]}, '
                        f'{prov} has no case arm and the table has no PARITY-EXCEPTION line')
for (prov, v) in sorted(table):
    if prov not in handled:
        problems.append(f'STALE {prov} {v}: unknown provider')
    elif v in handled[prov]:
        problems.append(f'STALE {prov} {v}: exception, but {prov} now handles {v}')
    elif v not in called:
        problems.append(f'STALE {prov} {v}: exception, but no prompt or script calls {v}')

if problems:
    print('\n'.join(problems))
    sys.exit(1)
PYEOF
}

# ── Fixtures ─────────────────────────────────────────────────────────────────
FIX="$(safe_mktemp_dir "${TMPDIR:-/tmp}/talos-vcs-parity.XXXXXX")" || exit 1
trap 'rm -rf "${FIX:?}"' EXIT

# A fake vcs script: every provider handles `list-prs`; github alone handles
# `frob-pr`; the pre-dispatch verbs belong to the universe regardless.
write_fake_vcs() {  # $1=path $2=extra gitlab arm ("" for none)
  cat >"$1" <<FAKE
_github() {
  case "\$1" in
    list-prs) : ;;
    frob-pr) : ;;
    *) : ;;
  esac
}
_gitlab() {
  case "\$1" in
    list-prs) : ;;
$2
    *) : ;;
  esac
}
_azure() {
  case "\$1" in
    list-prs|frob-pr) : ;;
    *) : ;;
  esac
}
_file() {
  case "\$1" in
    list-prs) : ;;
    *) : ;;
  esac
}
FAKE
}

write_fake_vcs "$FIX/vcs-missing.sh" ""
write_fake_vcs "$FIX/vcs-has-arm.sh" "    frob-pr) : ;;"
cat >"$FIX/prompt.md" <<'PROMPT'
Run `bash scripts/pipeline-vcs.sh frob-pr 7` then `pipeline-vcs.sh list-prs`.
The wrapper pipeline-vcs.sh only prints, and pipeline-vcs.sh is called by hand.
PROMPT

# The file provider lacks frob-pr too, so every fixture records it.
printf 'file frob-pr PARITY-EXCEPTION: local-only\n' >"$FIX/exc-file-only"
{ cat "$FIX/exc-file-only"
  printf 'gitlab frob-pr PARITY-EXCEPTION: not built yet\n'; } >"$FIX/exc-gitlab"
{ cat "$FIX/exc-file-only"
  printf 'azure frob-pr PARITY-EXCEPTION: nothing\n'; } >"$FIX/exc-stale-azure"
{ cat "$FIX/exc-file-only"
  printf 'gitlab frob-pr PARITY-EXCEPTION: stale on purpose\n'; } >"$FIX/exc-stale-gitlab"

out="$(parity_check "$FIX/vcs-missing.sh" "$FIX/exc-file-only" "$FIX/prompt.md")"; rc=$?
assert_eq "1" "$rc" "AC1 a called verb missing from gitlab with no table line fails the check"
assert_contains "$out" "MISSING gitlab frob-pr" "AC1 the failure names gitlab and frob-pr"
case "$out" in
  *"MISSING azure"*|*"MISSING file"*|*"MISSING github"*)
    fail "AC1 only gitlab is reported" "$out" ;;
  *) pass "AC1 only gitlab is reported" ;;
esac

out="$(parity_check "$FIX/vcs-missing.sh" "$FIX/exc-gitlab" "$FIX/prompt.md")"; rc=$?
assert_eq "0" "$rc" "AC2 the table line 'gitlab frob-pr PARITY-EXCEPTION: ...' makes the check pass"
assert_eq "" "$out" "AC2 a passing check prints nothing"

out="$(parity_check "$FIX/vcs-has-arm.sh" "$FIX/exc-stale-gitlab" "$FIX/prompt.md")"; rc=$?
assert_eq "1" "$rc" "AC3 an exception for a verb the provider now handles fails the check"
assert_contains "$out" "STALE gitlab frob-pr" "AC3 the failure is a stale exception naming gitlab and frob-pr"

# prompt.md says "pipeline-vcs.sh only" and "pipeline-vcs.sh is". Where a
# provider has an `only` arm the token is a verb and gets checked; where no
# provider does, it is prose and the check passes.
sed 's/^    list-prs) : ;;$/    list-prs|only) : ;;/' "$FIX/vcs-missing.sh" >"$FIX/vcs-only.sh"
out="$(parity_check "$FIX/vcs-only.sh" "$FIX/exc-gitlab" "$FIX/prompt.md")"
assert_contains "$out" "only" "AC4 a token that is some provider's verb is checked"
out="$(parity_check "$FIX/vcs-missing.sh" "$FIX/exc-gitlab" "$FIX/prompt.md")"; rc=$?
assert_eq "0" "$rc" "AC4 prose tokens ('only', 'is') that no provider handles are ignored"

# An arm-level marker is an exception too, and an unreferenced table line is stale.
write_fake_vcs "$FIX/vcs-marked.sh" "    frob-pr) : ;; # PARITY-EXCEPTION: stub"
out="$(parity_check "$FIX/vcs-marked.sh" "$FIX/exc-file-only" "$FIX/prompt.md")"; rc=$?
assert_eq "0" "$rc" "an arm carrying '# PARITY-EXCEPTION:' counts as an exception"
out="$(parity_check "$FIX/vcs-missing.sh" "$FIX/exc-stale-azure" "$FIX/prompt.md")"; rc=$?
assert_contains "$out" "STALE azure frob-pr" "an exception for a verb azure handles is stale"
printf 'gitlab never-called PARITY-EXCEPTION: x\n' >>"$FIX/exc-gitlab"
out="$(parity_check "$FIX/vcs-missing.sh" "$FIX/exc-gitlab" "$FIX/prompt.md")"
assert_contains "$out" "STALE gitlab never-called" "an exception for a verb nobody calls is stale"

# ── The real repo ────────────────────────────────────────────────────────────
# Today's gaps, computed by running the check against the code. Each later
# slice of #753 adds the verb and deletes its line.
read -r -d '' PARITY_EXCEPTIONS <<'TABLE' || true
# provider verb PARITY-EXCEPTION: reason
file assign-issue PARITY-EXCEPTION: local-only by design
file assign-pr PARITY-EXCEPTION: local-only by design (no PRs)
file attach-files PARITY-EXCEPTION: local-only by design (no PRs)
file check-approval-sha PARITY-EXCEPTION: local-only by design (no PRs, no approvals)
file comment-pr PARITY-EXCEPTION: local-only by design (no PRs)
file conflict-files PARITY-EXCEPTION: local-only by design (no PRs)
file edit-pr-body PARITY-EXCEPTION: local-only by design (no PRs)
file list-needs-owner PARITY-EXCEPTION: local-only by design
file mark-needs-owner PARITY-EXCEPTION: local-only by design
file pr-head PARITY-EXCEPTION: local-only by design (no PRs)
file pr-head-ref PARITY-EXCEPTION: local-only by design (no PRs)
file read-attempt PARITY-EXCEPTION: local-only by design (no comments)
file read-comments PARITY-EXCEPTION: local-only by design (no comments)
file record-attempt PARITY-EXCEPTION: local-only by design (no comments)
file upsert-pr-comment PARITY-EXCEPTION: local-only by design (no PRs)
TABLE
printf '%s\n' "$PARITY_EXCEPTIONS" >"$FIX/exceptions"

callers=()
while IFS= read -r f; do callers+=("$f"); done < <(
  { ls "$TALOS_ROOT"/agents/*.md "$TALOS_ROOT"/scripts/*.sh "$TALOS_ROOT"/scripts/*.py
    find "$TALOS_ROOT/skills" -type f; } 2>/dev/null)

out="$(parity_check "$VCS" "$FIX/exceptions" "${callers[@]}")"; rc=$?
assert_eq "0" "$rc" "AC5 the real repo has no unrecorded provider gap and no stale exception"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" >&2

case "$PARITY_EXCEPTIONS" in
  *"gitlab edit-pr-body PARITY-EXCEPTION:"*|*"azure edit-pr-body PARITY-EXCEPTION:"*)
    fail "AC10 gitlab and azure edit-pr-body are no longer exceptions" ;;
  *"file edit-pr-body PARITY-EXCEPTION:"*) pass "AC10 only the file edit-pr-body exception is kept" ;;
  *) fail "AC10 only the file edit-pr-body exception is kept" ;;
esac

for want in "gitlab conflict-files" "azure conflict-files"; do
  case "$PARITY_EXCEPTIONS" in
    *"$want PARITY-EXCEPTION:"*) fail "AC7 the table no longer records: $want" ;;
    *) pass "AC7 the table no longer records: $want" ;;
  esac
done
case "$PARITY_EXCEPTIONS" in
  *"file conflict-files PARITY-EXCEPTION:"*) pass "AC7 only the file conflict-files exception is kept" ;;
  *) fail "AC7 only the file conflict-files exception is kept" ;;
esac

for want in "gitlab upsert-pr-comment" \
            "gitlab mark-needs-owner" "gitlab list-needs-owner"; do
  case "$PARITY_EXCEPTIONS" in
    *"$want PARITY-EXCEPTION:"*) fail "AC5 the table no longer records: $want" ;;
    *) pass "AC5 the table no longer records: $want" ;;
  esac
done

parity_out="$(bash "$TALOS_ROOT/tests/test-verb-parity.sh" 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC6 tests/test-verb-parity.sh still passes unchanged"
[ "$rc" -eq 0 ] || printf '%s\n' "$parity_out" >&2

finish
