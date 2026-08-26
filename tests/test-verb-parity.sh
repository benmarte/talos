#!/usr/bin/env bash
# test-verb-parity.sh — verify _github and _github_api expose the same verb set.
#
# Extraction: scan the pipeline-vcs.sh source for case arms inside each
# function's line range and compare the resulting verb lists.
#
# Deliberate divergence: annotate with "# PARITY-EXCEPTION: <verb>" inside the
# source file so the test does not become noise when a provider legitimately
# omits a verb.
#
# Mutation test (RED proof): insert a fake-test-verb arm into _github only and
# confirm the test detects "Only in _github: ['fake-test-verb']" and exits 1.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── Helper: extract verb names from a provider's case arms (from a file) ──────
# extract_verbs <file> <start_line> <end_line>
# Prints sorted unique verb names, one per line.
# Lines of the form "    <verb>)" at exactly 4 spaces of indentation are verbs.
# Also reads PARITY-EXCEPTION annotations to exclude intentional divergence.
extract_verbs() {
  local file="$1" start_line="$2" end_line="$3"
  python3 - "$file" "$start_line" "$end_line" <<'PYEOF'
import sys, re

path       = sys.argv[1]
start_line = int(sys.argv[2])
end_line   = int(sys.argv[3])

with open(path) as f:
    lines = f.readlines()

# Slice to function range (1-indexed, inclusive)
chunk = lines[start_line - 1 : end_line]

# Collect PARITY-EXCEPTION annotations
exceptions = set()
for line in chunk:
    m = re.search(r'#\s*PARITY-EXCEPTION:\s*([a-z][a-z-]+)', line)
    if m:
        exceptions.add(m.group(1))

# Extract case-arm verb labels: exactly 4 spaces then verb then ")"
verbs = set()
for line in chunk:
    m = re.match(r'^    ([a-z][a-z-]+)\)', line)
    if m:
        verb = m.group(1)
        if verb not in exceptions:
            verbs.add(verb)

for v in sorted(verbs):
    print(v)
PYEOF
}

# ── Find function boundaries ──────────────────────────────────────────────────
GITHUB_START="$(grep -n '^_github() {' "$VCS" | head -1 | cut -d: -f1)"
GITHUB_API_START="$(grep -n '^_github_api() {' "$VCS" | head -1 | cut -d: -f1)"
GITLAB_START="$(grep -n '^_gitlab() {' "$VCS" | head -1 | cut -d: -f1)"

# _github spans from GITHUB_START to (GITHUB_API_START - 1)
GITHUB_END=$(( GITHUB_API_START - 1 ))
# _github_api spans from GITHUB_API_START to (GITLAB_START - 1)
GITHUB_API_END=$(( GITLAB_START - 1 ))

# ── Extract verb sets ─────────────────────────────────────────────────────────
GITHUB_VERBS="$(extract_verbs "$VCS" "$GITHUB_START" "$GITHUB_END")"
GITHUB_API_VERBS="$(extract_verbs "$VCS" "$GITHUB_API_START" "$GITHUB_API_END")"

GITHUB_COUNT="$(printf '%s\n' "$GITHUB_VERBS" | grep -c . || true)"
GITHUB_API_COUNT="$(printf '%s\n' "$GITHUB_API_VERBS" | grep -c . || true)"

# ── Compute diff ──────────────────────────────────────────────────────────────
ONLY_GITHUB="$(comm -23 \
  <(printf '%s\n' "$GITHUB_VERBS") \
  <(printf '%s\n' "$GITHUB_API_VERBS") \
  | tr '\n' ' ' | sed 's/ $//')"
ONLY_API="$(comm -13 \
  <(printf '%s\n' "$GITHUB_VERBS") \
  <(printf '%s\n' "$GITHUB_API_VERBS") \
  | tr '\n' ' ' | sed 's/ $//')"

# ── Report counts ─────────────────────────────────────────────────────────────
assert_eq "$GITHUB_COUNT" "$GITHUB_API_COUNT" \
  "parity: _github ($GITHUB_COUNT verbs) == _github_api ($GITHUB_API_COUNT verbs)"

# ── Fail on non-empty diff ────────────────────────────────────────────────────
if [ -n "$ONLY_GITHUB" ]; then
  fail "parity: only in _github: ['${ONLY_GITHUB// /', '}']" \
    "Add these verbs to _github_api or annotate with # PARITY-EXCEPTION: <verb>"
else
  pass "parity: no verbs only in _github"
fi

if [ -n "$ONLY_API" ]; then
  fail "parity: only in _github_api: ['${ONLY_API// /', '}']" \
    "Add these verbs to _github or annotate with # PARITY-EXCEPTION: <verb>"
else
  pass "parity: no verbs only in _github_api"
fi

# ── Mutation test (RED proof) ─────────────────────────────────────────────────
# Insert fake-test-verb into _github only, re-run extraction on the mutant,
# confirm the diff contains exactly 'fake-test-verb'.
# RED comes from wrong behaviour (verb imbalance), not absence.
MUTANT_VCS="$SANDBOX/mutant-pipeline-vcs.sh"
cp "$VCS" "$MUTANT_VCS"

# Inject 'fake-test-verb) echo test ;;' just before _github's *) catch-all,
# within the _github function range. Python is used for safe line-based injection.
python3 - "$MUTANT_VCS" "$GITHUB_START" "$GITHUB_END" <<'PYEOF'
import sys, re
path       = sys.argv[1]
start_line = int(sys.argv[2])
end_line   = int(sys.argv[3])
lines = open(path).readlines()
# Find the *) catch-all within [start_line, end_line] (1-indexed)
for i in range(start_line - 1, end_line):
    if re.match(r'\s+\*\).*unknown verb', lines[i]):
        lines.insert(i, '    fake-test-verb) echo test ;;\n')
        break
open(path, 'w').writelines(lines)
PYEOF

# Re-derive boundaries in the mutant (injection shifts GITHUB_API_START by 1)
MUTANT_GITHUB_START="$(grep -n '^_github() {' "$MUTANT_VCS" | head -1 | cut -d: -f1)"
MUTANT_GITHUB_API_START="$(grep -n '^_github_api() {' "$MUTANT_VCS" | head -1 | cut -d: -f1)"
MUTANT_GITHUB_END=$(( MUTANT_GITHUB_API_START - 1 ))
MUTANT_GITHUB_API_END="$GITHUB_API_END"  # _github_api is unmodified

MUTANT_GITHUB_VERBS="$(extract_verbs "$MUTANT_VCS" "$MUTANT_GITHUB_START" "$MUTANT_GITHUB_END")"
MUTANT_ONLY_GITHUB="$(comm -23 \
  <(printf '%s\n' "$MUTANT_GITHUB_VERBS") \
  <(printf '%s\n' "$GITHUB_API_VERBS") \
  | tr '\n' ' ' | sed 's/ $//')"

if [ "$MUTANT_ONLY_GITHUB" = "fake-test-verb" ]; then
  pass "mutation: inserting fake-test-verb in _github only yields only-in-_github: ['fake-test-verb']"
else
  fail "mutation: expected 'fake-test-verb' only-in-_github divergence" \
    "got: '$MUTANT_ONLY_GITHUB'"
fi

finish
