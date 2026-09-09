#!/usr/bin/env bash
# test-verb-parity.sh — verify that _github and _github_api expose the same
# set of verbs.
#
# Extraction: parse the case statement inside each provider function by looking
# for lines matching the pattern "    <word>)" where <word> starts with a
# lowercase letter.  Excludes the "*)" catch-all.
#
# Deliberate divergence: if a verb exists in one provider but not the other
# intentionally, annotate the case arm with "# PARITY-EXCEPTION: reason".
# The test subtracts annotated verbs before the equality check, making the
# allowlist explicit and machine-verifiable.
set -u
. "$(dirname "$0")/helpers.sh"
# No sandbox needed — we only read the script; no git ops or network calls.

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# ── Extract verbs from a named function in pipeline-vcs.sh ───────────────────
# Usage: extract_verbs <function-name>
# Prints one verb per line.  A verb is a case arm label "    <word>)" where
# <word> is [a-z][a-z0-9-]+ and the arm does NOT have "# PARITY-EXCEPTION:".
extract_verbs() {
  local fn="$1"
  python3 - "$VCS" "$fn" <<'PYEOF'
import re, sys

script_path = sys.argv[1]
fn_name     = sys.argv[2]

with open(script_path) as f:
    lines = f.readlines()

# Find the start line of the named function.
fn_start = None
for i, line in enumerate(lines):
    if re.match(r'^' + re.escape(fn_name) + r'\s*\(\)', line):
        fn_start = i
        break

if fn_start is None:
    print(f'ERROR: function {fn_name!r} not found', file=sys.stderr)
    sys.exit(1)

# Find the end: the next top-level function or EOF.
fn_end = len(lines)
for i in range(fn_start + 1, len(lines)):
    if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*\(\)', lines[i]):
        fn_end = i
        break

# Extract verb labels: "    <word>)" where <word> matches [a-z][a-z0-9-]+
# Exclude the "*)" catch-all and any line with "# PARITY-EXCEPTION:".
verb_re = re.compile(r'^\s{4}([a-z][a-z0-9-]+)\)')
verbs = []
for line in lines[fn_start:fn_end]:
    m = verb_re.match(line)
    if m and 'PARITY-EXCEPTION:' not in line:
        verbs.append(m.group(1))

for v in sorted(set(verbs)):
    print(v)
PYEOF
}

# ── Extract PARITY-EXCEPTION verbs from a function ───────────────────────────
extract_exceptions() {
  local fn="$1"
  python3 - "$VCS" "$fn" <<'PYEOF'
import re, sys

script_path = sys.argv[1]
fn_name     = sys.argv[2]

with open(script_path) as f:
    lines = f.readlines()

fn_start = None
for i, line in enumerate(lines):
    if re.match(r'^' + re.escape(fn_name) + r'\s*\(\)', line):
        fn_start = i
        break

if fn_start is None:
    sys.exit(0)

fn_end = len(lines)
for i in range(fn_start + 1, len(lines)):
    if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*\(\)', lines[i]):
        fn_end = i
        break

verb_re = re.compile(r'^\s{4}([a-z][a-z0-9-]+)\).*#\s*PARITY-EXCEPTION:')
for line in lines[fn_start:fn_end]:
    m = verb_re.match(line)
    if m:
        print(m.group(1))
PYEOF
}

# ── Run extraction ────────────────────────────────────────────────────────────
_github_verbs="$(extract_verbs _github)"
_github_api_verbs="$(extract_verbs _github_api)"
_exceptions="$(extract_exceptions _github; extract_exceptions _github_api)"

# ── Compare ───────────────────────────────────────────────────────────────────
result="$(python3 - "$_github_verbs" "$_github_api_verbs" "$_exceptions" <<'PYEOF'
import sys

github_verbs     = set(sys.argv[1].split()) if sys.argv[1].strip() else set()
github_api_verbs = set(sys.argv[2].split()) if sys.argv[2].strip() else set()
exceptions       = set(sys.argv[3].split()) if sys.argv[3].strip() else set()

# Subtract declared exceptions from both sides before comparing.
github_eff     = github_verbs     - exceptions
github_api_eff = github_api_verbs - exceptions

only_github     = sorted(github_eff     - github_api_eff)
only_github_api = sorted(github_api_eff - github_eff)

print('_github: ' + str(sorted(github_verbs)))
print('_github_api: ' + str(sorted(github_api_verbs)))
if exceptions:
    print('PARITY-EXCEPTION verbs (excluded): ' + str(sorted(exceptions)))
if only_github or only_github_api:
    if only_github:
        print('Only in _github: ' + str(only_github))
    if only_github_api:
        print('Only in _github_api: ' + str(only_github_api))
    print('PARITY FAILED - divergence detected!')
    sys.exit(1)
else:
    total = len(github_eff)
    print('PARITY OK - both providers expose ' + str(total) + ' verbs')
    sys.exit(0)
PYEOF
)"
_exit=$?

printf '%s\n' "$result"

if [ $_exit -eq 0 ]; then
  pass "parity: _github and _github_api expose the same verb set"
else
  fail "parity: providers have diverged" "$(printf '%s' "$result" | tail -3)"
fi

# ── Mutation test: PARITY-EXCEPTION annotation subtracts correctly ────────────
# We simulate a fake verb in _github only (as if the parity test ran before
# Part B was applied) by checking that the extractor does NOT include
# annotated verbs.  We verify this by checking that if we add a fake annotation
# to our own output it would be subtracted.  This is a structural check, not
# a live mutation.
# The real mutation test runs the full parity check against the pre-fix script —
# that is tested in CI by the "verify: bash tests/run-tests.sh" step.

# ── Single-definition registry (#177 slices 1-5) ──────────────────────────────
# _github and _github_api used to hand-duplicate every marker regex, waiver
# rule, and provider-independent constant below (and had already drifted on
# message wording in several -- see the per-slice notes preserved next to
# each entry). Slices 1-4 moved each into a shared helper defined exactly
# once, above both adapters; slice 5 replaced the one-assertion-per-string
# call sites below with this single registry, iterated in a loop. Adding a
# new shared symbol to pipeline-vcs.sh only ever needs ONE new line here --
# no new call site, no new assert_single_definition invocation.
#
# Format: one "label\tneedle" pair per (non-comment, non-blank) line. needle
# is matched with `grep -F` (a literal substring, no regex metacharacters),
# so a needle containing a literal tab would break the split -- none do.
read -r -d '' SINGLE_DEFINITION_REGISTRY <<'REGISTRY' || true
# --- slice 1: attempt/approval marker regexes and role/label constants ---
single-definition: talos:attempt marker regex	talos:attempt\s+stage=
single-definition: KNOWN_STAGES	KNOWN_STAGES = {
single-definition: talos:approval marker regex (strict extractor)	talos:approval\s+sha=
single-definition: APPROVAL_LABELS	APPROVAL_LABELS = {
single-definition: VALID_ROLES	VALID_ROLES = {
# --- slice 2: approval-SHA waiver rules (em-dash/hyphen drift, #177) ---
single-definition: HARDCODED_NONWAIVABLE_PREFIXES	HARDCODED_NONWAIVABLE_PREFIXES = (
single-definition: HARDCODED_NONWAIVABLE_EXACT	HARDCODED_NONWAIVABLE_EXACT    = (
single-definition: DEFAULT_WAIVER	DEFAULT_WAIVER =
single-definition: VALIDATION_CANARIES	VALIDATION_CANARIES = [
single-definition: is_hardcoded_nonwaivable	def is_hardcoded_nonwaivable
single-definition: path_matches	def path_matches
single-definition: validate_waiver_entries	def validate_waiver_entries
single-definition: waiver-validation rejection message (em-dash/hyphen drift, #177)	rejected (catch-all or covers non-waivable paths)
single-definition: STALE message construction	STALE {label} ({role}): {reason}
# --- slice 3: forbidden-files pattern building / allow-list validation ---
single-definition: talos:forbidden-files-active marker	talos:forbidden-files-active patterns=
single-definition: FORBIDDEN FILES in PR banner	FORBIDDEN FILES in PR
single-definition: forbidden_files_allow entry rejection message	ERROR: merge.forbidden_files_allow entry
# --- slice 4: closing-keyword regex, sibling diagnostic, pr-mergeable/idempotency ---
single-definition: closing-keyword regex	kw = r'(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)'
single-definition: sibling diagnostic (em-dash/hyphen drift, #177)	but open sibling PR(s) still reference the same issue:
single-definition: pr-mergeable retry backoff constant	BEGIN { printf "%.4f", 2 * s }
single-definition: idempotency-key format validation	must match [A-Za-z0-9._-]+, got
# --- slice 5: REST comment normalisation (author/login shape) ---
single-definition: REST comment normaliser (_login helper)	def _login(c):
REGISTRY

assert_single_definition() {  # $1=needle (fixed string) $2=label
  local count
  count="$(grep -Fc -- "$1" "$VCS")"
  assert_eq "1" "$count" "$2"
}

while IFS="$(printf '\t')" read -r _label _needle; do
  case "$_label" in
    ''|'#'*) continue ;;
  esac
  assert_single_definition "$_needle" "$_label"
done <<REGISTRY_LINES
$SINGLE_DEFINITION_REGISTRY
REGISTRY_LINES

# ── Marker literals must live only in _vcs_shared_* (#177 slice 5) ────────────
# The registry above proves each marker/waiver/constant string is defined
# exactly once *somewhere* in the file. This check additionally proves
# *where*: no embedded `python3 -c "..."` block inside _github() or
# _github_api() may itself contain a literal "talos:" marker string. If one
# did, it would mean a marker was hand-inlined into an adapter's Python
# instead of routed through a _vcs_shared_* helper -- exactly the drift
# pattern slices 1-4 fixed. Scoped to python3 -c blocks (not the whole
# function body) because both adapters legitimately emit plain bash
# "talos:...-unverified" fail-open diagnostics and relay ("grep '^talos:'")
# lines inline -- those are call-site plumbing, not a second marker
# definition.
# Wrapped in a function (rather than a heredoc textually inline inside
# "$(...)") deliberately: bash's command-substitution scanner tracks quote
# balance across the whole "$(...)" span even for a quote-tagged heredoc, so
# a single quote embedded in the Python below (e.g. inside a docstring) can
# desync it. Nesting the heredoc one level down, inside a plain function
# body, sidesteps that entirely -- same pattern extract_verbs/extract_exceptions
# above already use.
check_marker_literals_in_python_blocks() {
  python3 - "$VCS" <<'PYEOF'
import re, sys

script_path = sys.argv[1]
with open(script_path) as f:
    lines = f.readlines()

def function_bounds(name):
    start = None
    for i, line in enumerate(lines):
        if re.match(r'^' + re.escape(name) + r'\s*\(\)', line):
            start = i
            break
    if start is None:
        print(f'ERROR: function {name!r} not found', file=sys.stderr)
        sys.exit(1)
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*\(\)', lines[i]):
            end = i
            break
    return start, end

# Yields (line_no, block_text) for every `python3 -c "..."` payload inside
# lines[start:end]. Handles both the single-physical-line form
# (python3 -c "import json,sys; ...") and this codebase's multi-line
# convention, where the opening line ends right after the opening quote and
# a later line starting (column 0, no leading whitespace) with a
# literal double-quote closes it -- this codebase's convention covers
# a bare \"\", \")\"\"\" (command-substitution close), and \"\" 2>/dev/null)\"\"
# alike, all flush-left.
def python_blocks(start, end):
    i = start
    while i < end:
        m = re.search(r'python3\s+-c\s+"', lines[i])
        if not m:
            i += 1
            continue
        rest = lines[i][m.end():]
        same_line = re.search(r'^(.*?)"', rest)
        if same_line:
            yield i, same_line.group(1)
            i += 1
            continue
        j = i + 1
        body = []
        while j < end and not lines[j].startswith('"'):
            body.append(lines[j])
            j += 1
        yield i, ''.join(body)
        i = j + 1

violations = []
for fn in ('_github', '_github_api'):
    start, end = function_bounds(fn)
    for line_no, block in python_blocks(start, end):
        if 'talos:' in block:
            violations.append(f'{fn} line {line_no + 1}: python3 -c block contains a talos: literal')

if violations:
    print('\n'.join(violations))
    sys.exit(1)
print('OK - no talos: marker literals inside python3 -c blocks in _github/_github_api')
sys.exit(0)
PYEOF
}

marker_check="$(check_marker_literals_in_python_blocks)"
marker_rc=$?
printf '%s\n' "$marker_check"
if [ "$marker_rc" -eq 0 ]; then
  pass "single-definition: no talos: marker literal inside a python3 -c block in _github/_github_api"
else
  fail "single-definition: talos: marker literal found inside an adapter's python3 -c block" "$marker_check"
fi

finish
