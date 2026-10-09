#!/usr/bin/env bash
# test-verb-parity.sh — verify that the single GitHub implementation (_github,
# behind vcs.provider github and github-api) exposes every verb either former
# implementation had.
#
# Extraction: parse the case statement inside each provider function by looking
# for lines matching the pattern "    <word>)" where <word> starts with a
# lowercase letter.  Excludes the "*)" catch-all.
#
set -u
. "$(dirname "$0")/helpers.sh"
# No sandbox needed — we only read the script; no git ops or network calls.

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
CONTRACT="$TALOS_ROOT/scripts/pipeline-contract.sh"

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
verb_re = re.compile(r'^\s{4}([a-z][a-z0-9|-]+)\)')
verbs = []
for line in lines[fn_start:fn_end]:
    m = verb_re.match(line)
    if m and 'PARITY-EXCEPTION:' not in line:
        verbs.extend(m.group(1).split('|'))

for v in sorted(set(verbs)):
    print(v)
PYEOF
}

# ── Run extraction ────────────────────────────────────────────────────────────
# One GitHub implementation serves vcs.provider github AND github-api (#551):
# its verb set must stay the 41 verbs the two former implementations each
# exposed (so neither provider lost a verb in the merge) plus the assignee
# verbs added since (#560).
EXPECTED_VERBS="approve-pr assign-issue check-approval-sha check-attempt check-closing-keyword check-epic-acceptance check-pr-files checkout-pr close-issue comment-issue comment-pr create-issue create-pr current-user diff-pr draft-pr edit-pr-body find-pr issue-assignees label-issue label-pr list-assignees list-issues list-needs-owner list-prs mark-needs-owner merge-pr pr-checks pr-checks-required pr-ci-runs pr-files pr-head pr-is-draft pr-mergeable read-attempt read-comments ready-pr record-attempt rerun-ci unassign-issue update-branch upsert-pr-comment view-issue view-pr"
_github_verbs="$(extract_verbs _github)"

assert_eq "$(printf '%s\n' $EXPECTED_VERBS | sort | tr '\n' ' ')" "$(printf '%s\n' $_github_verbs | sort | tr '\n' ' ')" \
  "parity: _github serves exactly the 41 verbs both former GitHub providers had, plus the 3 assignee verbs added since (#560)"
assert_eq "0" "$(grep -c '^_github_api()' "$VCS")" "parity: there is no second GitHub implementation"
assert_contains "$(sed -n '/^_vcs_dispatch_provider()/,/^}/p' "$VCS")" "github|github-api) _github " \
  "parity: github and github-api dispatch to the same function"

# ── Single-definition registry (#177 slices 1-5) ──────────────────────────────
# The two GitHub providers used to hand-duplicate every marker regex, waiver
# rule, and provider-independent constant below (and had already drifted on
# message wording in several -- see the per-slice notes preserved next to
# each entry). Slices 1-4 moved each into a shared helper defined exactly
# once, above both adapters; slice 5 replaced the one-assertion-per-string
# call sites below with this single registry, iterated in a loop. Adding a
# new shared symbol to pipeline-vcs.sh only ever needs ONE new line here --
# no new call site, no new assert_single_definition invocation.
#
# Format: one "label\tneedle[\tfile]" trio per (non-comment, non-blank)
# line. needle is matched with `grep -F` (a literal substring, no regex
# metacharacters), so a needle containing a literal tab would break the
# split -- none do. file defaults to $VCS when the third field is absent.
read -r -d '' SINGLE_DEFINITION_REGISTRY <<REGISTRY || true
# --- slice 1: attempt/approval marker regexes and role/label constants ---
single-definition: talos:attempt marker regex	talos:attempt\s+stage=
single-definition: talos:approval marker regex (strict extractor)	talos:approval\s+sha=
# KNOWN_STAGES/APPROVAL_LABELS/VALID_ROLES (#128) moved to
# scripts/pipeline-contract.sh (#178) -- pipeline-vcs.sh derives them from
# TALOS_ROLES/TALOS_APPROVAL_LABELS/TALOS_APPROVAL_ROLES via
# _vcs_shared_contract_env() instead of hand-restating the sets, so the
# single-definition assertion moves to the contract arrays it derives from.
single-definition: KNOWN_STAGES (TALOS_ROLES, contract for #178)	TALOS_ROLES=(	$CONTRACT
single-definition: APPROVAL_LABELS (TALOS_APPROVAL_LABELS, contract for #178)	TALOS_APPROVAL_LABELS=(	$CONTRACT
single-definition: VALID_ROLES (TALOS_APPROVAL_ROLES, contract for #178)	TALOS_APPROVAL_ROLES=(	$CONTRACT
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

assert_single_definition() {  # $1=needle (fixed string) $2=label $3=file (default $VCS)
  local count file="${3:-$VCS}"
  count="$(grep -Fc -- "$1" "$file")"
  assert_eq "1" "$count" "$2"
}

while IFS="$(printf '\t')" read -r _label _needle _file; do
  case "$_label" in
    ''|'#'*) continue ;;
  esac
  assert_single_definition "$_needle" "$_label" "$_file"
done <<REGISTRY_LINES
$SINGLE_DEFINITION_REGISTRY
REGISTRY_LINES

# ── Marker literals must live only in _vcs_shared_* (#177 slice 5) ────────────
# The registry above proves each marker/waiver/constant string is defined
# exactly once *somewhere* in the file. This check additionally proves
# *where*: no embedded `python3 -c "..."` block inside _github() or
# _github() may itself contain a literal "talos:" marker string. If one
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
for fn in ('_github',):
    start, end = function_bounds(fn)
    for line_no, block in python_blocks(start, end):
        if 'talos:' in block:
            violations.append(f'{fn} line {line_no + 1}: python3 -c block contains a talos: literal')

if violations:
    print('\n'.join(violations))
    sys.exit(1)
print('OK - no talos: marker literals inside python3 -c blocks in _github')
sys.exit(0)
PYEOF
}

marker_check="$(check_marker_literals_in_python_blocks)"
marker_rc=$?
printf '%s\n' "$marker_check"
if [ "$marker_rc" -eq 0 ]; then
  pass "single-definition: no talos: marker literal inside a python3 -c block in _github"
else
  fail "single-definition: talos: marker literal found inside an adapter's python3 -c block" "$marker_check"
fi

finish
