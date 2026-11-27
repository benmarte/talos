#!/usr/bin/env bash
# test-azure-headings-1101.sh -- an azure work-item comment stores a markdown
# heading as <hN>; `view-issue` turns it back into `#`xN + text, so
# `## Threat model` survives the round trip and the threat stage's output is
# seen (#1101). Uses the tests/stubs/az stub: no credentials, no network. Tests
# are named by the spec's criterion id (AC1 ...).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
TALOS="$TALOS_ROOT/scripts/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '%s\n' '{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}},' \
  ' "roles": {"validator": true, "pm": true}, "pipeline": {"risk_areas": ["login"]},' \
  ' "markers": {"trusted_authors": ["bot@acme.com"]}, "issues": {"max_parallel": 1, "assignee": "none"}}' > "$PIPELINE_CONFIG"
export STUB_CURRENT_USER=bot@acme.com
git config user.email "test@talos.invalid"
git config user.name "talos-test"
git remote set-url origin https://dev.azure.com/acme/proj/_git/widget

export STUB_AZURE_WORKITEM_JSON='{"id":5,"fields":{"System.Title":"routing","System.State":"New","System.Tags":"pipeline:dev","System.Description":"<div>just prose</div>"}}'

_c() {  # $1=html text -> one comment object, JSON-escaped here
  TXT="$1" python3 -I -c '
import json, os
print(json.dumps({"id": 1, "text": os.environ["TXT"], "isDeleted": False,
                  "createdBy": {"displayName": "Bot", "uniqueName": "bot@acme.com"},
                  "createdDate": "2026-10-15T00:00:01Z"}))'
}
_page() { printf '{"comments":[%s]}' "$1"; }
conv() {  # $1=html -> the converted body of the only comment
  STUB_AZURE_WI_COMMENTS="$(_page "$(_c "$1")")" bash "$VCS" view-issue 5 2>/dev/null \
    | python3 -I -c 'import json, sys; sys.stdout.write(json.load(sys.stdin)["comments"][0]["body"])'
}

# ── AC1: the threat model heading survives ──────────────────────────────────
assert_eq "## Threat model" "$(conv '<h2>Threat model</h2>')" "AC1 <h2> comes back as a ## line"
assert_eq "## Threat model" "$(conv '<h2 id="threat-model">Threat model</h2>')" "AC1 <h2 id=...> comes back as a ## line"

# ── AC2: every level, either case, each on its own line ─────────────────────
for _n in 1 2 3 4 5 6; do
  _hashes="$(printf '%.*s' "$_n" '######')"
  assert_eq "a
$_hashes Head $_n
b" "$(conv "a<h$_n>Head $_n</h$_n>b")" "AC2 <h$_n> is $_n # on its own line"
  assert_eq "$_hashes Head $_n" "$(conv "<H$_n CLASS=\"x\">Head $_n</H$_n>")" "AC2 <H$_n> upper case with an attribute"
done
# pandoc wraps a long heading, and its tag, over several lines.
assert_eq '## A **long** heading with `code` & more
text' "$(conv '<h2
id="a-long-heading">A <strong>long</strong> heading
with <code>code</code> &amp; more</h2>
<p>text</p>')" "AC2 a wrapped heading with inline markup stays one line"
assert_eq "a
b" "$(conv '<h2></h2>a<h3>b')" "AC2 an empty or unclosed heading adds no # and takes no other text"

# ── AC4: <pre> text is verbatim ─────────────────────────────────────────────
assert_eq '## Real
<h2>shown</h2>' "$(conv '<h2>Real</h2><pre><code>&lt;h2&gt;shown&lt;/h2&gt;</code></pre>')" \
  "AC4 an escaped <h2> inside <pre> stays as written, beside a converted heading"
assert_eq '## Real
raw' "$(conv '<h2>Real</h2><pre><h2>raw</h2></pre>')" "AC4 a raw <h2> inside <pre> gets no ##"

# ── AC5: the other conversions keep their output ────────────────────────────
assert_eq '**st** *em* `co`
- plain
- [ ] one
- [x] two' "$(conv '<p><strong>st</strong> <em>em</em> <code>co</code></p><ul><li>plain</li><li>[ ] one</li><li><input type="checkbox" checked="" /> two</li></ul>')" \
  "AC5 strong, em, code, list items and checkboxes convert as before"

# ── AC3: next routes past the threat stage ──────────────────────────────────
printf '{"timestamp": "2026-10-11T10:00:00Z", "message": {"id": "m1", "usage": {"input_tokens": 5, "cache_read_input_tokens": 1000, "output_tokens": 50}}}\n' > "$SANDBOX/session.jsonl"
export TALOS_TRANSCRIPT_PATH="$SANDBOX/session.jsonl"
export STUB_AZURE_WORKITEM_LIST='[{"id": 5, "fields": {"System.Title": "routing", "System.State": "New", "System.Tags": "pipeline:dev"}}]'
export STUB_AZURE_PR_LIST='[]'
next_with() {  # $1=the latest PM spec's stored HTML -> next's action line
  reset_leases
  STUB_AZURE_WI_COMMENTS="$(_page "$(_c "$1")")" bash "$TALOS" next --issue 5 2>"$SANDBOX/stderr"
}
assert_eq "action=dispatch stage=threat issue=5" \
  "$(next_with '<p><strong>PM spec:</strong> login</p><ul><li>[ ] AC9 y (test)</li></ul>')" \
  "AC3 control: a risk-area spec with no threat model goes to the threat stage"
assert_eq "action=dispatch stage=developer issue=5" \
  "$(next_with '<p><strong>PM spec:</strong> login</p><h2>Threat model</h2><ul><li>[ ] AC9 y (test)</li></ul>')" \
  "AC3 a spec with <h2>Threat model</h2> goes to the developer"

finish
