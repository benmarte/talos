#!/usr/bin/env bash
# test-azure-wi-line-breaks.sh -- Azure work-item comments round-trip line for
# line (a single newline survives _md_to_html and the HTML-to-markdown read
# back) and read oldest first, so a spec's **Tests:** line stays alone and a
# revised **PM spec:** is the one that takes effect (#703). Uses the
# tests/stubs/az stub (no credentials); pandoc and the python `markdown` module
# are pinned with shims on PATH so each _md_to_html path runs on any machine.
# Tests are named by the spec's criterion id (AC1 ...).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
CRIT="$TALOS_ROOT/scripts/pipeline-criteria.sh"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}}
EOF
git config user.email "test@talos.invalid"
git config user.name "talos-test"

export STUB_AZURE_WORKITEM_JSON='{"id":5,"fields":{"System.Title":"Fix login crash","System.State":"Active","System.Tags":"bug; pipeline:dev","System.Description":"<div>desc</div>"}}'

REAL_PY="$(command -v python3)"

# python3 shim: `python3 -I - args` (the _md_to_html script on stdin) is logged
# to $SHIM_PY_LOG and run with $SHIM_PY_PRE put in front of it; every other
# call goes straight to the real python3.
SHIM_PY="$SANDBOX/shim-py"; mkdir -p "$SHIM_PY"
cat > "$SHIM_PY/python3" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-I" ] && [ "\${2:-}" = "-" ]; then
  script="\$(cat)"
  [ -n "\${SHIM_PY_LOG:-}" ] && printf '%s\n' "\$script" > "\$SHIM_PY_LOG"
  shift 2
  exec "$REAL_PY" -I -c "\${SHIM_PY_PRE:-}"\$'\n'"\$script" "\$@"
fi
exec "$REAL_PY" "\$@"
EOF
chmod +x "$SHIM_PY/python3"
# pandoc shims: one that fails (so _md_to_html moves on), one that records.
NO_PANDOC="$SANDBOX/shim-nopandoc"; mkdir -p "$NO_PANDOC"
printf '#!/bin/bash\nexit 127\n' > "$NO_PANDOC/pandoc"; chmod +x "$NO_PANDOC/pandoc"
REC_PANDOC="$SANDBOX/shim-recpandoc"; mkdir -p "$REC_PANDOC"
cat > "$REC_PANDOC/pandoc" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$SHIM_PANDOC_ARGS"
cat >/dev/null
printf '<p>from pandoc</p>'
EOF
chmod +x "$REC_PANDOC/pandoc"
# No markdown module: the built-in fallback runs.
NO_MARKDOWN="import sys; sys.modules['markdown'] = None"

# _md_to_html lives inside pipeline-vcs.sh (a dispatcher), so lift it out.
sed -n '/^_md_to_html() {/,/^}/p' "$VCS" > "$SANDBOX/md_to_html.sh"
fallback_html() {  # $1=markdown -> HTML from the built-in fallback
  ( PATH="$SHIM_PY:$NO_PANDOC:$PATH"; export SHIM_PY_PRE="$NO_MARKDOWN"
    . "$SANDBOX/md_to_html.sh"; _md_to_html "$1" )
}

# ── AC1: the fallback keeps a single newline as <br> ─────────────────────────
assert_eq '<p>line one<br>line two</p>' "$(fallback_html $'line one\nline two')" \
  "AC1 a two-line paragraph is one <p> with the lines joined by <br>"
assert_eq '<p>line one</p>
<p>line two</p>' "$(fallback_html $'line one\n\nline two')" \
  "AC1 a blank-line-separated pair is still two <p>"
assert_eq '<p><strong>Tests:</strong> <code>a.cs</code> (filter: <code>X</code>)<br>Notes: one [Fact] &amp; more.</p>' \
  "$(fallback_html $'**Tests:** `a.cs` (filter: `X`)\nNotes: one [Fact] & more.')" \
  "AC1 inline markup is rendered per line and the break sits between the lines"

# ── AC2: python-markdown gets nl2br, pandoc gets hard_line_breaks ────────────
export SHIM_PY_LOG="$SANDBOX/md.py"
( PATH="$SHIM_PY:$NO_PANDOC:$PATH"; . "$SANDBOX/md_to_html.sh"; _md_to_html $'a\nb' >/dev/null )
assert_contains "$(cat "$SHIM_PY_LOG" 2>/dev/null)" "'nl2br'" "AC2 the python-markdown path asks for the nl2br extension"
unset SHIM_PY_LOG
export SHIM_PANDOC_ARGS="$SANDBOX/pandoc.args"
out="$( PATH="$REC_PANDOC:$PATH"; . "$SANDBOX/md_to_html.sh"; _md_to_html $'a\nb' )"
assert_eq "<p>from pandoc</p>" "$out" "AC2 the pandoc path is used when pandoc is on PATH"
assert_eq "-f gfm+hard_line_breaks -t html" "$(cat "$SHIM_PANDOC_ARGS" 2>/dev/null)" \
  "AC2 pandoc is called with -f gfm+hard_line_breaks"

# ── AC3: the reader turns every <br> form into one newline ───────────────────
_c() {  # $1=id $2=html text $3=createdDate
  TXT="$2" python3 -I -c '
import json, os, sys
print(json.dumps({"id": int(sys.argv[1]), "text": os.environ["TXT"], "isDeleted": False,
                  "createdBy": {"displayName": "Name", "uniqueName": "a@acme.com"},
                  "createdDate": sys.argv[2]}))' "$1" "$3"
}
_page() {  # comment objects as args -> {"comments":[...]}
  local IFS=,; printf '{"comments":[%s]}' "$*"
}
_field() {  # $1=python expr over d (JSON on stdin)
  python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"
}
conv() {  # $1=html -> the converted body of the only comment
  STUB_AZURE_WI_COMMENTS="$(_page "$(_c 1 "$1" 2026-10-15T00:00:01Z)")" bash "$VCS" view-issue 5 2>/dev/null \
    | python3 -I -c 'import json, sys; sys.stdout.write(json.load(sys.stdin)["comments"][0]["body"])'
}
assert_eq "a
b
c
d" "$(conv '<p>a<br>b<br/>c<br />d</p>')" "AC3 <br>, <br/> and <br /> each become one newline"
assert_eq "a
b" "$(conv '<p>a<br>
b</p>')" "AC3 a <br> followed by a literal newline leaves no blank line"
assert_eq "a
b" "$(conv '<p>a<BR />
b</p>')" "AC3 an upper-case <BR /> followed by a literal newline leaves no blank line"

# ── AC4: a Tests: line followed by a notes line posts and reads back alone ───
export STUB_AZURE_STATE_DIR="$SANDBOX/state4"; mkdir -p "$STUB_AZURE_STATE_DIR"
export STUB_AZURE_POST_AUTHOR="bot@acme.com"
export STUB_AZURE_WI_COMMENTS='{"comments":[]}'
SPEC_MD='**PM spec:** a spec whose Tests line is followed by a notes line.

**Acceptance criteria**
- [ ] AC1 first thing (test)
- [ ] AC2 second thing (prose: doc wording)

**Tests:** `a.cs` (filter: `X`)
Notes on the tests file: one `[Fact]` per test.'
( PATH="$SHIM_PY:$NO_PANDOC:$PATH"; export SHIM_PY_PRE="$NO_MARKDOWN"
  bash "$VCS" comment-issue 5 "$SPEC_MD" >/dev/null 2>&1 )
assert_eq "0" "$?" "AC4 comment-issue posts the spec (fallback _md_to_html)"
body="$(bash "$VCS" view-issue 5 --spec 2>/dev/null | _field "d['comments'][0]['body']")"
assert_contains "$body" '**Tests:** `a.cs` (filter: `X`)
Notes on the tests file: one `[Fact]` per test.' "AC4 the notes line reads back on its own line, below the Tests line"
assert_eq '**Tests:** `a.cs` (filter: `X`)' "$(printf '%s\n' "$body" | grep -F '**Tests:**')" \
  "AC4 the Tests line carries nothing of the notes"
out="$(bash "$CRIT" spec-usable 5 2>&1)"; rc=$?
assert_eq "0:spec-usable: ok" "$rc:$out" "AC4 spec-usable answers ok"
unset STUB_AZURE_STATE_DIR STUB_AZURE_POST_AUTHOR STUB_AZURE_WI_COMMENTS

# ── AC5/AC6: comments come back oldest first ─────────────────────────────────
_old="$(_c 1 '<p><strong>PM spec:</strong> old spec</p>' 2026-10-14T09:00:00Z)"
_new="$(_c 2 '<p><strong>PM spec:</strong> revised spec</p>' 2026-10-15T09:00:00Z)"
_mid="$(_c 3 '<p>middle note</p>' 2026-10-14T12:00:00Z)"
export STUB_AZURE_WI_COMMENTS="$(_page "$_new" "$_mid" "$_old")"   # newest first, as ADO answers
out="$(bash "$VCS" view-issue 5 --spec 2>/dev/null)"
assert_eq "**PM spec:** revised spec" "$(printf '%s' "$out" | _field "d['comments'][0]['body']")" \
  "AC5 view-issue --spec answers the newer PM spec when the API lists it first"
out="$(bash "$VCS" view-issue 5 2>/dev/null)"
assert_eq "**PM spec:** old spec|middle note|**PM spec:** revised spec" "$(printf '%s' "$out" | _field "'|'.join(c['body'] for c in d['comments'])")" \
  "AC5 view-issue lists the comments oldest first"
# pages merge first, then sort: the newest comment on the first page stays last
_p1="$(_page "$_new" | sed 's/}$/,"continuationToken":"tok2"}/')"
_p2="$(_page "$_old")"
out="$(STUB_AZURE_WI_COMMENTS_PAGE_first="$_p1" STUB_AZURE_WI_COMMENTS_PAGE_tok2="$_p2" bash "$VCS" view-issue 5 2>/dev/null)"
assert_eq "2026-10-14T09:00:00Z,2026-10-15T09:00:00Z" "$(printf '%s' "$out" | _field "','.join(c['createdAt'] for c in d['comments'])")" \
  "AC5 comments from every page are sorted together"
# equal timestamps keep the API order
_t1="$(_c 1 '<p>tie one</p>' 2026-10-15T09:00:00Z)"
_t2="$(_c 2 '<p>tie two</p>' 2026-10-15T09:00:00Z)"
out="$(STUB_AZURE_WI_COMMENTS="$(_page "$_t1" "$_t2")" bash "$VCS" view-issue 5 2>/dev/null)"
assert_eq "tie one,tie two" "$(printf '%s' "$out" | _field "','.join(c['body'] for c in d['comments'])")" \
  "AC5 equal timestamps keep the order the API gave"

out="$(bash "$VCS" read-comments 5 --work-item 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC6 read-comments --work-item exits 0"
assert_eq "2026-10-14T09:00:00Z,2026-10-14T12:00:00Z,2026-10-15T09:00:00Z" \
  "$(printf '%s' "$out" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(",".join(c["createdAt"] for c in (d["comments"] if isinstance(d, dict) else d)))')" \
  "AC6 read-comments --work-item lists comments oldest first"
unset STUB_AZURE_WI_COMMENTS

finish
