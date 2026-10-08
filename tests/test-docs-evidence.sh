#!/usr/bin/env bash
# README.md and docs/user-guide.md describe evidence capture (#412, sub-task 9
# of epic #352): the README has one short section, one row per `evidence.*`
# key and one Scripts reference row; the guide's `### Attaching evidence to the
# PR` section carries the detail. Every verb, flag, key and status value the
# docs name must exist in scripts/ (that is the point of this test), the
# guide says 10 files / 20 MiB / 10 MiB and never the stale 12 / 25, it has none
# of the terms of the dropped branch-store design, and it marks the private-repo
# visibility claim UNVERIFIED. The three places that used to say 12 / 25 are
# fixed too.
#
# The tests only read files (the negative controls feed planted text to the
# same helpers through pipes). The checks are on structure (headings, verb,
# key and status names, defaults, links, counts), not on the wording of the
# prose (#456); they run on whitespace-flattened text, so a name wrapped over
# two lines cannot hide from a line-by-line grep.
set -u
. "$(dirname "$0")/helpers.sh"

README="$TALOS_ROOT/README.md"
GUIDE="$TALOS_ROOT/docs/user-guide.md"
CHANGELOG="$TALOS_ROOT/CHANGELOG.md"
SCRIPTS="$TALOS_ROOT/scripts"
EVIDENCE_SH="$SCRIPTS/pipeline-evidence.sh"
CONFIG_SH="$SCRIPTS/pipeline-config.sh"
JSON_EXAMPLE="$TALOS_ROOT/talos.pipeline.json.example"

flat() { tr '\n' ' ' | tr -s ' '; }

contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }  # $1=text $2=literal

check_has() {  # $1=flattened text $2=literal $3=label
  if contains "$1" "$2"; then pass "$3"; else fail "$3" "missing: $2"; fi
}

check_lacks() {  # $1=flattened text $2=literal $3=label
  if contains "$1" "$2"; then fail "$3" "present: $2"; else pass "$3"; fi
}

# The text under the `### ` / `## ` heading that starts with the given prefix,
# read from stdin, up to the next `### ` or `## ` heading (`####` subsections
# belong to it).
section_of() {  # $1=heading line prefix
  awk -v h="$1" '
    index($0, h) == 1 { s = 1; next }
    s && /^###? / { exit }
    s { print }
  '
}

# True when a markdown table row in the stdin text starts with the key as its
# whole first cell and carries the default in the second cell.
has_config_row() {  # $1=key $2=default cell text (without backticks)
  awk -F'|' -v k="\`$1\`" -v d="$2" '
    { c1 = $2; c2 = $3; gsub(/^ +| +$/, "", c1); gsub(/^ +| +$/, "", c2); gsub(/`/, "", c2) }
    c1 == k && index(c2, d) == 1 { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

# True when the stdin text names a whole number, not a part of a longer one.
mentions_number() {  # $1=number
  grep -Eq "(^|[^0-9A-Za-z.])$1([^0-9A-Za-z]|\$)"
}

# Words of the form `<prefix>...` found in the stdin text, one per line, unique.
words_like() {  # $1=ERE for the word
  grep -oE "$1" | sort -u
}

readme_text="$(cat "$README")"
guide_text="$(cat "$GUIDE")"
section_text="$(printf '%s\n' "$guide_text" | section_of '### Attaching evidence to the PR')"
section="$(printf '%s\n' "$section_text" | flat)"
readme_section_text="$(printf '%s\n' "$readme_text" | section_of '## Evidence capture')"
readme_section="$(printf '%s\n' "$readme_section_text" | flat)"
readme_flat="$(printf '%s\n' "$readme_text" | flat)"

KEYS="enabled command dir include when store max_files max_mb"
VERBS="capture collect upload attach dir enabled check-url"
STATUSES="posted empty over-cap refused failed"

# --- README ------------------------------------------------------------------
for pair in 'enabled|false' 'command|unset' 'dir|.talos/evidence' 'include|unset' \
  'when|user-facing' 'store|attach' 'max_files|10' 'max_mb|20'; do
  key="${pair%%|*}"; def="${pair#*|}"
  if printf '%s\n' "$guide_text" | has_config_row "evidence.$key" "$def"; then
    pass "user guide config table: evidence.$key ($def)"
  else fail "user guide config table: evidence.$key ($def)"; fi
done

if grep -q '^| `scripts/pipeline-evidence.sh ' <<<"$readme_text"; then
  pass "README Scripts reference has a pipeline-evidence.sh row"
else fail "README Scripts reference has a pipeline-evidence.sh row"; fi

if [ -n "$readme_section" ]; then pass "README has the ## Evidence capture section"
else fail "README has the ## Evidence capture section"; fi
readme_lines="$(printf '%s\n' "$readme_section_text" | grep -c .)"
if [ "$readme_lines" -le 15 ]; then pass "README section is short ($readme_lines non-blank lines)"
else fail "README section is short" "$readme_lines non-blank lines, limit 15"; fi
for needle in '/talos:setup' 'evidence:' 'v2.99.0' \
  'docs/user-guide.md#attaching-evidence-to-the-pr-evidence-352)'; do
  check_has "$readme_section" "$needle" "README section mentions $needle"
done
# The visibility warning is there, whatever its wording.
check_has "$(printf '%s' "$readme_section" | tr '[:upper:]' '[:lower:]')" 'public' "README section warns about public visibility"

# --- User guide: the section -------------------------------------------------
if [ -n "$section" ]; then pass "guide has the ### Attaching evidence to the PR section"
else fail "guide has the ### Attaching evidence to the PR section"; fi

for pair in 'enabled|false' 'command|unset' 'dir|.talos/evidence' 'include|unset' \
  'when|user-facing' 'store|attach' 'max_files|10' 'max_mb|20'; do
  key="${pair%%|*}"; def="${pair#*|}"
  if printf '%s\n' "$section_text" | has_config_row "evidence.$key" "$def"; then
    pass "guide key table: evidence.$key ($def)"
  else fail "guide key table: evidence.$key ($def)"; fi
done

# Every verb the docs name exists as a case arm of the dispatcher.
for verb in $VERBS; do
  if grep -Eq "^  $verb\) shift; cmd_" "$EVIDENCE_SH"; then
    pass "pipeline-evidence.sh has the $verb verb"
  else fail "pipeline-evidence.sh has the $verb verb"; fi
  check_has "$section" "\`$verb" "guide documents $verb"
done
for verb in capture collect upload attach dir enabled; do
  check_has "$readme_flat" "$verb" "README Scripts row names $verb"
done
# ... and every `pipeline-evidence.sh <word>` the docs write is a real verb.
for word in $(printf '%s\n%s\n' "$guide_text" "$readme_text" \
  | words_like 'pipeline-evidence\.sh [a-z][a-z-]*' | sed 's/^pipeline-evidence\.sh //'); do
  case " $VERBS " in
    *" $word "*) pass "docs name a real verb: pipeline-evidence.sh $word" ;;
    *) fail "docs name a real verb: pipeline-evidence.sh $word" "not a verb of $EVIDENCE_SH" ;;
  esac
done
# ... and a verb that appears only as the first cell of a Commands table row
# (no `pipeline-evidence.sh` in front of it) is checked too, both ways: every
# row is a real verb and every verb has a row.
commands_text="$(printf '%s\n' "$section_text" | awk '
  /^#### Commands/ { s = 1; next }
  s && /^\|/ { t = 1; print; next }
  s && t { exit }')"
table_verbs() {  # stdin: markdown text; prints the first word of each row's first cell
  awk -F'|' '
    $2 ~ /^ *`[a-z]/ { c = $2; sub(/^ *`/, "", c); sub(/[ `].*$/, "", c); print c }
  '
}
row_verbs="$(printf '%s\n' "$commands_text" | table_verbs)"
for word in $row_verbs; do
  case " $VERBS " in
    *" $word "*) pass "Commands table row is a real verb: $word" ;;
    *) fail "Commands table row is a real verb: $word" "not a verb of $EVIDENCE_SH" ;;
  esac
done
for verb in capture collect upload attach dir enabled; do
  case " $(printf '%s' "$row_verbs" | tr '\n' ' ') " in
    *" $verb "*) pass "Commands table has a row for $verb" ;;
    *) fail "Commands table has a row for $verb" ;;
  esac
done

# Every flag the guide section names exists in scripts/.
# `--grep` is the user's own Playwright flag in the example command, not Talos's.
for flag in $(printf '%s\n' "$section_text" | words_like '(^|[^A-Za-z0-9-])--[a-z][a-z-]*' | sed 's/^[^-]*//'); do
  [ "$flag" = "--grep" ] && continue
  if grep -rqF -- "$flag" "$SCRIPTS"; then pass "scripts/ has the $flag flag"
  else fail "scripts/ has the $flag flag" "named in the guide, not found in scripts/"; fi
done
for flag in --since --stage --dry-run --attach; do
  check_has "$section" "$flag" "guide names $flag"
done

# Every evidence.* key the docs name is a key the validator knows.
for key in $(printf '%s\n%s\n' "$section_text" "$readme_section_text" \
  | words_like '(^|[^A-Za-z0-9_-])evidence\.[a-z_]+[a-z]' | sed 's/^.*evidence\.//'); do
  case " $KEYS " in
    *" $key "*) ;;
    *) fail "docs name a real key: evidence.$key" "not a key of $CONFIG_SH"; continue ;;
  esac
  if grep -qF "\"evidence.$key\"" "$CONFIG_SH"; then pass "pipeline-config.sh knows evidence.$key"
  else fail "pipeline-config.sh knows evidence.$key"; fi
done
for key in $KEYS; do
  check_has "$section" "evidence.$key" "guide names evidence.$key"
done

# Every status value is one `_attach_status` can print, and the guide has it.
for status in $STATUSES; do
  if grep -Eq "echo $status( |;|\$)" "$EVIDENCE_SH"; then pass "pipeline-evidence.sh can print status $status"
  else fail "pipeline-evidence.sh can print status $status"; fi
  check_has "$section" "\`$status\`" "guide documents status $status"
done
check_has "$section" 'evidence-attach pr=<n> status=<s>' "guide shows the evidence-attach line"
check_has "$section" 'evidence unavailable' "guide: exit 2 with empty stdout reads as evidence unavailable"
check_has "$section" 'evidence on when=' "guide shows the enabled output line"

# --- User guide: the facts ---------------------------------------------------
if printf '%s\n' "$section_text" | mentions_number 10 \
  && printf '%s\n' "$section_text" | mentions_number 20; then
  pass "guide says 10 files / 20 MiB / 10 MiB"
else fail "guide says 10 files / 20 MiB / 10 MiB"; fi
check_has "$section" '10 files, 20 MiB in total and 10 MiB per file' "guide states the three caps together"
for stale in 12 25; do
  if printf '%s\n' "$section_text" | mentions_number "$stale"; then
    fail "guide does not say the stale default $stale" "found $stale"
  else pass "guide does not say the stale default $stale"; fi
done
if grep -q '^_EVIDENCE_DEFAULT_MAX_FILES=10$' "$EVIDENCE_SH" \
  && grep -q '^_EVIDENCE_DEFAULT_MAX_MB=20$' "$EVIDENCE_SH" \
  && grep -Eq '^_EVIDENCE_FILE_MB=10( |$)' "$EVIDENCE_SH"; then
  pass "the scripts really default to 10 / 20 / 10"
else fail "the scripts really default to 10 / 20 / 10"; fi

# Identifiers the section has to name: paths, config values, providers, file
# types, the verb and the draft key. Not sentences.
for needle in '.talos/evidence' '.gitignore' 'v2.99.0' 'GITHUB_TOKEN' 'enabled: false' \
  'Playwright' 'Cypress' \
  '`github`' '`github-api`' '`gitlab`' '`azure`' '`file`' \
  'png' 'jpg' 'jpeg' 'gif' 'webm' 'mp4' 'mov' 'svg' 'html' \
  'check-url' 'pr.draft'; do
  check_has "$section" "$needle" "guide mentions $needle"
done

# Structure: the subsections, in order, and where the caveats live.
subs="$(printf '%s\n' "$section_text" | sed -n 's/^#### //p' | tr '\n' '|')"
assert_eq 'Turning it on|`.gitignore` is required|Commands|What each stage does|Requirements and limits|Rendering|Security|Not verified|' \
  "$subs" "guide section has its eight subsections in order"
not_verified="$(printf '%s\n' "$section_text" | awk '/^#### Not verified/ {s = 1; next} s && /^#### / {exit} s')"
unv_total="$(printf '%s\n' "$section_text" | grep -c 'UNVERIFIED:')"
unv_in="$(printf '%s\n' "$not_verified" | grep -c 'UNVERIFIED:')"
if [ "$unv_in" -ge 3 ]; then pass "the Not verified subsection holds the UNVERIFIED items ($unv_in)"
else fail "the Not verified subsection holds the UNVERIFIED items" "found $unv_in, want at least 3"; fi
assert_eq "$unv_total" "$unv_in" "every UNVERIFIED marker in the section sits under Not verified"
security_items="$(printf '%s\n' "$section_text" | awk '/^#### Security/ {s = 1; next} s && /^#### / {exit} s && /^- /' | grep -c .)"
if [ "$security_items" -ge 3 ]; then pass "the Security subsection is a list ($security_items items)"
else fail "the Security subsection is a list" "found $security_items items, want at least 3"; fi

# No advice to put a credential into CI for evidence, and no overclaim that
# capture is local (it runs evidence.command, which can do anything that
# command does). Two layers. The floor is the original four fixed spellings
# plus the claims the section has to keep making: it catches everything the
# first version of this guard caught. On top of it, advises_credential reads
# clauses, so a rewording the floor does not know is still caught.
check_has "$section" 'Do not add a long-lived token to CI just for evidence' "guide: no token in CI for evidence"
check_has "$section" 'in GitHub Actions leave `evidence.enabled` at `false`' "guide: leave evidence off in Actions"
check_has "$section" '`gh auth login`' "guide: a user token comes from gh auth login"
for term in 'personal access token' 'Personal access token' 'give it a PAT' 'add a PAT'; do
  check_lacks "$section" "$term" "guide does not advise a token in CI: $term"
done
check_has "$section" '`capture` makes no network call of its own, but it runs `evidence.command`' "guide: capture is not called local"
check_lacks "$section" '`capture`, `collect`, `dir` and `enabled` are local' "guide: no overclaim that capture is local"

# The clause guard. The text is cut into clauses at sentence ends, `;`, `:`,
# commas and a joining but/and/then/instead/otherwise, so a negation in one
# clause cannot excuse an instruction in the next. A clause is flagged when
#   - it names a personal access token, a PAT or GH_TOKEN at all, or
#   - it has a credential word (token, credential, secret) and an instruction
#     verb (add, create, store, put, set, use, give, provide, export, paste,
#     generate, pass, configure, supply, inject),
# unless the verb itself is negated: the clause has `do not` / `never` /
# `must not` / `should not` straight in front of the verb (only `ever`, `also`
# or `just` may sit between), as in "Do not add a long-lived token". A
# negation anywhere else in the clause excuses nothing.
CRED_GUARD_PY='
import re, sys
VERBS = r"(?:add|create|store|put|set|give|provide|export|paste|generate|use|pass|configure|supply|inject)"
NEG_DIRECT = re.compile(r"\b(?:do not|don.t|never|must not|should not|shouldn.t)\s+(?:(?:ever|also|just)\s+)?" + VERBS + r"\b", re.I)
VERB = re.compile(r"\b" + VERBS + r"\b", re.I)
CRED = re.compile(r"token|credential|secret", re.I)
NAMED = re.compile(r"personal access token|\bPAT\b|\bGH_TOKEN\b", re.I)
text = " ".join(sys.stdin.read().split())
for sent in re.split(r"(?<=[.!?])\s+", text):
    for clause in re.split(r"[;:]\s+|,\s*|\s+(?:but|and|then|instead|otherwise)\s+", sent):
        if NEG_DIRECT.search(clause):
            continue
        if NAMED.search(clause) or (CRED.search(clause) and VERB.search(clause)):
            print(clause)
'
advises_credential() {  # stdin: text; prints each offending clause
  python3 -I -c "$CRED_GUARD_PY"
}
offending="$(printf '%s\n' "$section_text" | advises_credential)"
assert_eq "" "$offending" "guide advises no credential for CI (clause guard)"
actions_item="$(printf '%s\n' "$section_text" | awk '/^- \*\*Not the Actions/ {s = 1} s && /^$/ {exit} s' | flat)"
check_has "$actions_item" 'GITHUB_TOKEN' "guide has the Not-the-Actions-GITHUB_TOKEN item"
check_has "$actions_item" 'leave `evidence.enabled` at `false`' "the Actions item tells the reader to leave evidence off"
check_has "$actions_item" 'gh auth login' "the Actions item names where a user token comes from"

# None of the dropped branch-store design.
for term in 'evidence branch' 'prune' 'branches-ignore' 'store: pr' '[skip ci]' \
  'orphan' 'raw.githubusercontent'; do
  check_lacks "$section" "$term" "guide section has no dropped term: $term"
done
check_lacks "$readme_section" 'prune' "README section has no dropped term: prune"
check_lacks "$readme_section" 'store: pr' "README section has no dropped term: store: pr"

# README names no marker or label string (tests/test-contract.sh enforces
# membership; the evidence section keeps out of it altogether).
if grep -Eq '(^|[^/])talos:[a-z-]+|pipeline:[a-z-]+' <<<"$readme_section_text"; then
  fail "README evidence section names no marker or label string"
else pass "README evidence section names no marker or label string"; fi

# --- The stale 12 / 25 defaults are fixed in the three places ------------------
if grep -qF '(false, 10, 20, attach, user-facing)' "$CONFIG_SH" \
  && ! grep -qF '(false, 12, 25, attach, user-facing)' "$CONFIG_SH"; then
  pass "pipeline-config.sh comment says (false, 10, 20, attach, user-facing)"
else fail "pipeline-config.sh comment says (false, 10, 20, attach, user-facing)"; fi


json_note="$(python3 -I -c '
import json, sys
print(json.load(open(sys.argv[1]))["_note"])
' "$JSON_EXAMPLE" 2>/dev/null)"
if [ -n "$json_note" ]; then pass "json example still parses and has a _note"
else fail "json example still parses and has a _note"; fi
check_has "$json_note" 'evidence.max_files (integer 1-100, default 10)' "json example _note: max_files default 10"
check_has "$json_note" 'evidence.max_mb (integer 1-100, default 20)' "json example _note: max_mb default 20"
check_lacks "$json_note" 'evidence.max_files (integer 1-100, default 12)' "json example _note: no max_files default 12"
check_lacks "$json_note" 'evidence.max_mb (integer 1-100, default 25)' "json example _note: no max_mb default 25"

# --- CHANGELOG ---------------------------------------------------------------
if grep -E '^- \*\*.*#412' "$CHANGELOG" | grep -q 'evidence'; then
  pass "CHANGELOG has a bullet for #412"
else fail "CHANGELOG has a bullet for #412"; fi

# --- Negative controls: the helpers go red on planted text -------------------
planted='### Attaching evidence to the PR
Body one.
#### Sub
Still the section.
### Next heading
Not the section.'
planted_section="$(printf '%s\n' "$planted" | section_of '### Attaching evidence to the PR' | flat)"
check_lacks "$planted_section" 'Not the section.' "negative control: section_of stops at the next heading"
check_has "$planted_section" 'Still the section.' "negative control: section_of keeps #### subsections"

if printf 'default 12 files\n' | mentions_number 12; then
  pass "negative control: mentions_number finds a stale number"
else fail "negative control: mentions_number finds a stale number"; fi
if printf 'see #352 and v2.102.0 and 1-100 and 0125\n' | mentions_number 12; then
  fail "negative control: mentions_number ignores parts of longer tokens"
else pass "negative control: mentions_number ignores parts of longer tokens"; fi

planted_table='| `evidence.max_mb` | `25` | text |
| `evidence.max_mb_extra` | `20` | text |'
if printf '%s\n' "$planted_table" | has_config_row 'evidence.max_mb' '20'; then
  fail "negative control: has_config_row checks the default and the whole key cell"
else pass "negative control: has_config_row checks the default and the whole key cell"; fi
if printf '%s\n' "$planted_table" | has_config_row 'evidence.max_mb' '25'; then
  pass "negative control: has_config_row finds a real row"
else fail "negative control: has_config_row finds a real row"; fi

# Self-test of the clause guard: hostile sentences of each kind are flagged, the
# sentences the guide really uses are not.
for hostile in \
  'If `gh auth login` is not an option, add a PAT to your CI secrets.' \
  'Add a PAT to your CI secrets.' \
  'Create a personal access token for the job.' \
  'A personal access token works in CI.' \
  'Store a token in the repository secrets.' \
  'Give the workflow a long-lived credential.' \
  'Do not worry about the cost, store a token in the repository secrets.' \
  'Never mind the warning: put the credential in your CI environment.' \
  'Do not hesitate to add a PAT.' \
  'Export GH_TOKEN in the workflow.' \
  'Set GITHUB_TOKEN to a token with repo scope.' \
  'You may init the job and use a secret for it.'; do
  if [ -n "$(printf '%s\n' "$hostile" | advises_credential)" ]; then
    pass "negative control: the credential guard flags: $hostile"
  else fail "negative control: the credential guard flags: $hostile"; fi
done
for fine in 'Do not add a long-lived token to CI just for evidence: in GitHub Actions leave `evidence.enabled` at `false`.' \
  'Never put a token in CI.' 'Evidence upload needs a user token, which on a dev machine is `gh auth login`.' \
  'Initialise the directory.'; do
  assert_eq "" "$(printf '%s\n' "$fine" | advises_credential)" "negative control: the credential guard accepts: $fine"
done

bogus="$(printf 'run pipeline-evidence.sh frobnicate now\n' | words_like 'pipeline-evidence\.sh [a-z][a-z-]*' | sed 's/^pipeline-evidence\.sh //')"
case " $VERBS " in
  *" $bogus "*) fail "negative control: a made-up verb is not accepted" ;;
  *) pass "negative control: a made-up verb is not accepted" ;;
esac
bogus="$(printf '| `frobnicate <pr>` | text | 0 |\n| `capture` | text | 0 |\n' | table_verbs | head -n 1)"
case " $VERBS " in
  *" $bogus "*) fail "negative control: a bare table-cell verb is read and rejected" ;;
  *) assert_eq "frobnicate" "$bogus" "negative control: a bare table-cell verb is read and rejected" ;;
esac
if grep -rqF -- '--frobnicate' "$SCRIPTS"; then
  fail "negative control: a made-up flag is not found in scripts/"
else pass "negative control: a made-up flag is not found in scripts/"; fi

finish
