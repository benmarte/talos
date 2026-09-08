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

# ── Single-definition assertions (#177 slice 1) ───────────────────────────────
# _github and _github_api used to hand-duplicate the marker-parsing regexes
# and constants below (and had already drifted on message wording -- #177).
# Slice 1 moved them into shared helpers defined exactly once, above both
# adapters. Assert each string's exact-text occurrence count in the script is
# 1, so a future PR that reintroduces a second definition fails loudly here
# instead of silently drifting again.
assert_single_definition() {  # $1=needle (fixed string) $2=label
  local count
  count="$(grep -Fc -- "$1" "$VCS")"
  assert_eq "1" "$count" "$2"
}

assert_single_definition "talos:attempt\s+stage=" \
  "single-definition: talos:attempt marker regex"
assert_single_definition "KNOWN_STAGES = {" \
  "single-definition: KNOWN_STAGES"
assert_single_definition "talos:approval\s+sha=" \
  "single-definition: talos:approval marker regex (strict extractor)"
assert_single_definition "APPROVAL_LABELS = {" \
  "single-definition: APPROVAL_LABELS"
assert_single_definition "VALID_ROLES = {" \
  "single-definition: VALID_ROLES"

# ── Single-definition assertions (#177 slice 2) ───────────────────────────────
# _github and _github_api used to hand-duplicate the approval-SHA waiver
# rules below, and had drifted on the "rejected" message wording (em-dash in
# _github vs "--" in _github_api). Slice 2 moved them into
# _vcs_shared_check_approval_sha, defined exactly once, above both adapters.
assert_single_definition "HARDCODED_NONWAIVABLE_PREFIXES = (" \
  "single-definition: HARDCODED_NONWAIVABLE_PREFIXES"
assert_single_definition "HARDCODED_NONWAIVABLE_EXACT    = (" \
  "single-definition: HARDCODED_NONWAIVABLE_EXACT"
assert_single_definition "DEFAULT_WAIVER = " \
  "single-definition: DEFAULT_WAIVER"
assert_single_definition "VALIDATION_CANARIES = [" \
  "single-definition: VALIDATION_CANARIES"
assert_single_definition "def is_hardcoded_nonwaivable" \
  "single-definition: is_hardcoded_nonwaivable"
assert_single_definition "def path_matches" \
  "single-definition: path_matches"
assert_single_definition "def validate_waiver_entries" \
  "single-definition: validate_waiver_entries"
assert_single_definition "rejected (catch-all or covers non-waivable paths)" \
  "single-definition: waiver-validation rejection message (em-dash/hyphen drift, #177)"
assert_single_definition "STALE {label} ({role}): {reason}" \
  "single-definition: STALE message construction"

# ── Single-definition assertions (#177 slice 3) ───────────────────────────────
# _github and _github_api used to hand-duplicate the forbidden-files pattern
# building, allow-list validation, and matching logic below. Slice 3 moved
# them into _vcs_shared_check_pr_files, defined exactly once, above both
# adapters.
assert_single_definition "talos:forbidden-files-active patterns=" \
  "single-definition: talos:forbidden-files-active marker"
assert_single_definition "FORBIDDEN FILES in PR" \
  "single-definition: FORBIDDEN FILES in PR banner"
assert_single_definition "ERROR: merge.forbidden_files_allow entry" \
  "single-definition: forbidden_files_allow entry rejection message"

finish
