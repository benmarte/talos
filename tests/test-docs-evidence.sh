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
# same helpers through pipes). Every phrase check runs on whitespace-flattened
# text, so a claim wrapped over two lines cannot hide from a line-by-line grep.
set -u
. "$(dirname "$0")/helpers.sh"

README="$TALOS_ROOT/README.md"
GUIDE="$TALOS_ROOT/docs/user-guide.md"
CHANGELOG="$TALOS_ROOT/CHANGELOG.md"
SCRIPTS="$TALOS_ROOT/scripts"
EVIDENCE_SH="$SCRIPTS/pipeline-evidence.sh"
CONFIG_SH="$SCRIPTS/pipeline-config.sh"
YML_EXAMPLE="$TALOS_ROOT/talos.pipeline.yml.example"
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
  if printf '%s\n' "$readme_text" | has_config_row "evidence.$key" "$def"; then
    pass "README config table: evidence.$key ($def)"
  else fail "README config table: evidence.$key ($def)"; fi
done

if printf '%s\n' "$readme_text" | grep -q '^| `scripts/pipeline-evidence.sh '; then
  pass "README Scripts reference has a pipeline-evidence.sh row"
else fail "README Scripts reference has a pipeline-evidence.sh row"; fi

if [ -n "$readme_section" ]; then pass "README has the ## Evidence capture section"
else fail "README has the ## Evidence capture section"; fi
readme_lines="$(printf '%s\n' "$readme_section_text" | grep -c .)"
if [ "$readme_lines" -le 15 ]; then pass "README section is short ($readme_lines non-blank lines)"
else fail "README section is short" "$readme_lines non-blank lines, limit 15"; fi
for needle in 'off by default' '/pipeline-setup' 'evidence:' 'v2.99.0' \
  'public on public repos' 'cannot be deleted' \
  'docs/user-guide.md#attaching-evidence-to-the-pr-evidence-352)'; do
  check_has "$readme_section" "$needle" "README section mentions $needle"
done

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

for needle in '.talos/evidence' '.gitignore' 'git check-ignore -q -- <dir>/probe.png' \
  'v2.99.0' 'Write access' 'GitHub Enterprise Server' 'GITHUB_TOKEN' \
  'cannot be deleted' 'public on public repos' 'on-screen secrets' \
  'private staging directory' 'never opens' 'Ask me later' 'enabled: false' \
  'Playwright' 'Cypress' \
  '`github`' '`github-api`' '`gitlab`' '`azure`' '`file`' \
  'png' 'jpg' 'jpeg' 'gif' 'webm' 'mp4' 'mov' '`svg` and `html` are never published' \
  'never changes QA' 'A re-stamp never captures' 'check-url' 'pr.draft' \
  'arbitrary shell'; do
  case "$needle" in
    'never opens') check_has "$section" 'QA never opens, Reads or describes an image or video' "guide: the QA lean rule" ;;
    *) check_has "$section" "$needle" "guide mentions $needle" ;;
  esac
done

# No advice to put a token into CI for evidence, and no overclaim that capture
# is local (it runs evidence.command, which can do anything that command does).
check_has "$section" 'Do not add a long-lived token to CI just for evidence' "guide: no token in CI for evidence"
check_has "$section" 'in GitHub Actions leave `evidence.enabled` at `false`' "guide: leave evidence off in Actions"
check_has "$section" '`gh auth login`' "guide: a user token comes from gh auth login"
for term in 'personal access token' 'Personal access token' 'give it a PAT' 'add a PAT'; do
  check_lacks "$section" "$term" "guide does not advise a token in CI: $term"
done
check_has "$section" '`capture` makes no network call of its own, but it runs `evidence.command`' "guide: capture is not called local"
check_lacks "$section" '`capture`, `collect`, `dir` and `enabled` are local' "guide: no overclaim that capture is local"

# UNVERIFIED must sit on the private-repo claim itself.
if contains "$section" 'UNVERIFIED:** whether files attached to a **private** repo'; then
  pass "guide marks the private-repo visibility claim UNVERIFIED"
else fail "guide marks the private-repo visibility claim UNVERIFIED"; fi
check_has "$section" 'UNVERIFIED:** whether `gh --attach` and GitHub accept `.webm`' "guide marks .webm acceptance UNVERIFIED"

# None of the dropped branch-store design.
for term in 'evidence branch' 'prune' 'branches-ignore' 'store: pr' '[skip ci]' \
  'orphan' 'raw.githubusercontent'; do
  check_lacks "$section" "$term" "guide section has no dropped term: $term"
done
check_lacks "$readme_section" 'prune' "README section has no dropped term: prune"
check_lacks "$readme_section" 'store: pr' "README section has no dropped term: store: pr"

# README names no marker or label string (tests/test-contract.sh enforces
# membership; the evidence section keeps out of it altogether).
if printf '%s\n' "$readme_section_text" | grep -Eq '(^|[^/])talos:[a-z-]+|pipeline:[a-z-]+'; then
  fail "README evidence section names no marker or label string"
else pass "README evidence section names no marker or label string"; fi

# --- The stale 12 / 25 defaults are fixed in the three places ------------------
if grep -qF '(false, 10, 20, attach, user-facing)' "$CONFIG_SH" \
  && ! grep -qF '(false, 12, 25, attach, user-facing)' "$CONFIG_SH"; then
  pass "pipeline-config.sh comment says (false, 10, 20, attach, user-facing)"
else fail "pipeline-config.sh comment says (false, 10, 20, attach, user-facing)"; fi

yml_flat="$(flat < "$YML_EXAMPLE")"
check_has "$yml_flat" 'evidence.max_files: integer 1-100. Default: 10.' "yml example: max_files default 10"
check_has "$yml_flat" 'evidence.max_mb: integer 1-100. Default: 20.' "yml example: max_mb default 20"
check_lacks "$yml_flat" 'evidence.max_files: integer 1-100. Default: 12.' "yml example: no max_files default 12"
check_lacks "$yml_flat" 'evidence.max_mb: integer 1-100. Default: 25.' "yml example: no max_mb default 25"

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
