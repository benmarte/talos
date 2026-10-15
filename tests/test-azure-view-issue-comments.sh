#!/usr/bin/env bash
# test-azure-view-issue-comments.sh -- azure `view-issue` includes the work
# item's comments, each body turned from the stored HTML back into markdown, so
# a PM spec posted through `comment-issue` is readable by --spec, --since-stage
# and pipeline-criteria.sh (#696). Uses the tests/stubs/az stub (no credentials);
# the HTML is written out literally in the stub bodies. Tests are named by the
# spec's criterion id (AC1 ...).
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

# A PM spec the way _md_to_html stores it (python `markdown` shape).
SPEC_HTML='<p><strong>PM spec:</strong> azure view-issue returns comments &amp; reads them.</p>
<p><strong>Acceptance criteria</strong></p>
<ul>
<li>[ ] AC1 reads the comments (test)</li>
<li>[ ] AC2 docs say so (prose: doc wording)</li>
<li>[x] AC3 handles &lt;tags&gt; (test)</li>
</ul>
<p><strong>Tests:</strong> <code>tests/x.sh</code></p>'

# _page <text> [author] [deleted] -- one comment object; <text> is JSON-escaped here.
_c() {  # $1=id $2=html text $3=uniqueName $4=isDeleted(true|false)
  TXT="$2" python3 -I -c '
import json, os, sys
print(json.dumps({"id": int(sys.argv[1]), "text": os.environ["TXT"], "isDeleted": sys.argv[3] == "true",
                  "createdBy": {"displayName": "Name", "uniqueName": sys.argv[2]},
                  "createdDate": "2026-10-15T00:00:%02dZ" % int(sys.argv[1])}))' "$1" "${3:-a@acme.com}" "${4:-false}"
}
_page() {  # comment objects as args -> {"comments":[...]}
  local IFS=,; printf '{"comments":[%s]}' "$*"
}
_field() {  # $1=python expr over d (the view-issue JSON on stdin)
  python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"
}

# ── AC1: item + comments, every page, deleted skipped ────────────────────────
_p1="$(_page "$(_c 1 'first' a@acme.com)" "$(_c 2 'gone' d@acme.com true)" | sed 's/}$/,"continuationToken":"tok2"}/')"
_p2="$(_page "$(_c 3 '<p>third</p>' c@acme.com)")"
out="$(STUB_AZURE_WI_COMMENTS_PAGE_first="$_p1" STUB_AZURE_WI_COMMENTS_PAGE_tok2="$_p2" bash "$VCS" view-issue 5 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC1 view-issue exits 0"
assert_eq "5|Fix login crash|Active|<div>desc</div>|bug,pipeline:dev" \
  "$(printf '%s' "$out" | _field "'|'.join([str(d['number']), d['title'], d['state'], d['body'], ','.join(l['name'] for l in d['labels'])])")" \
  "AC1 view-issue keeps the normalised work item keys"
assert_eq "first|a@acme.com|2026-10-15T00:00:01Z
third|c@acme.com|2026-10-15T00:00:03Z" \
  "$(printf '%s' "$out" | _field "'\n'.join('|'.join([c['body'], c['author']['login'], c['createdAt']]) for c in d['comments'])")" \
  "AC1 comments span every page, carry login/createdAt and skip the deleted one"
out="$(STUB_AZURE_WI_COMMENTS='{"comments":[]}' bash "$VCS" view-issue 5 2>/dev/null)"
assert_eq "[]" "$(printf '%s' "$out" | _field "d['comments']")" "AC1 a work item with no comments has comments: []"
out="$(STUB_AZURE_WI_COMMENTS_PAGE_first="$_p1" STUB_AZURE_WI_COMMENTS_PAGE_tok2="$_p2" STUB_AZURE_WI_FAIL_TOKEN=tok2 bash "$VCS" view-issue 5 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC1 view-issue exits 1 when a comments page fails"
assert_eq "" "$out" "AC1 view-issue prints nothing when a comments page fails"

# ── AC2: a stored PM spec comes back as markdown ─────────────────────────────
conv() {  # $1=html -> the converted body of the only comment
  STUB_AZURE_WI_COMMENTS="$(_page "$(_c 1 "$1")")" bash "$VCS" view-issue 5 2>/dev/null \
    | python3 -I -c 'import json, sys; sys.stdout.write(json.load(sys.stdin)["comments"][0]["body"])'
}
body="$(conv "$SPEC_HTML")"
assert_eq "**PM spec:** azure view-issue returns comments & reads them." "$(printf '%s\n' "$body" | sed -n 1p)" \
  "AC2 the converted spec starts with **PM spec:**"
assert_contains "$body" '**Tests:** `tests/x.sh`' "AC2 the Tests: line keeps its backticks"
assert_contains "$body" "
- [ ] AC1 reads the comments (test)
- [ ] AC2 docs say so (prose: doc wording)
- [x] AC3 handles <tags> (test)
" "AC2 each criterion is its own checklist line"

# ── AC3: every checkbox form _md_to_html can emit ────────────────────────────
assert_eq "- [ ] one
- [x] two" "$(conv '<ul><li>[ ] one</li><li>[x] two</li></ul>')" "AC3 literal [ ] / [x] text"
assert_eq "- [ ] one
- [x] two" "$(conv '<ul><li>☐ one</li><li>☑ two</li></ul>')" "AC3 U+2610 / U+2611"
assert_eq "- [ ] one
- [x] two
- [x] three" "$(conv '<ul class="task-list"><li><input type="checkbox" disabled="" />one</li><li><input type="checkbox" disabled="" checked="" /> two</li><li><p><input checked type=checkbox>three</p></li></ul>')" \
  "AC3 <input type=checkbox> with and without checked"
assert_eq "- [ ] one" "$(conv '<ul><li><input type="checkbox" value="checked"> one</li></ul>')" "AC3 value=checked is not a ticked box"
assert_eq "- plain item" "$(conv '<ul><li>plain item</li></ul>')" "AC3 a list item with no box stays a plain bullet"

# ── AC4: block tags, emphasis, code, entities ────────────────────────────────
assert_eq "a
b
c
d
e" "$(conv '<h1>a</h1><p>b</p>c<br>d<br/>e')" "AC4 block tags become newlines"
assert_eq "x *em* y **st** z \`co\` w" "$(conv '<p>x <em>em</em> y <strong>st</strong> z <code>co</code> w</p>')" "AC4 <em> <strong> <code> become markdown"
assert_eq 'if (a < b && c > d) { "q" '"'s'"' }' "$(conv '<pre><code>if (a &lt; b &amp;&amp; c &gt; d) { &quot;q&quot; &#39;s&#39; }</code></pre>')" \
  "AC4 <pre><code> keeps its text, entities unescaped"
assert_eq "keep this" "$(conv '<span style="x">keep</span> <a href="http://u">this</a>')" "AC4 remaining tags are dropped"
assert_eq '& < > " '"'" "$(conv '<p>&amp; &lt; &gt; &quot; &#39;</p>')" "AC4 entities are unescaped"

# ── AC5: attempt marker survives raw or HTML-escaped ─────────────────────────
M='<!-- talos:attempt stage=developer count=1 total=1 -->'
assert_eq "Talos attempt record
$M" "$(conv "<p>Talos attempt record</p>
$M")" "AC5 a raw marker survives"
assert_eq "Talos attempt record
$M" "$(conv "<p>Talos attempt record</p>
&lt;!-- talos:attempt stage=developer count=1 total=1 --&gt;")" "AC5 an HTML-escaped marker survives as the raw marker"
assert_eq "Talos attempt record
$M" "$(conv "Talos attempt record
$M")" "AC5 a marker in an unconverted (markdown) comment is untouched"

# ── AC6: --spec and --since-stage run on the converted comments ──────────────
_old="$(_c 1 '<p><strong>PM spec:</strong> old spec</p>')"
_new="$(_c 2 "$SPEC_HTML")"
_verdict="$(_c 3 '<p><strong>Agent:</strong> developer (talos)</p><p>done</p>')"
_human="$(_c 4 '<p>looks good, ship it</p>' o@acme.com)"
_marker="$(_c 5 "<p>Talos attempt record</p>
$M")"
export STUB_AZURE_WI_COMMENTS="$(_page "$_old" "$_new" "$_verdict" "$_human" "$_marker")"
err="$SANDBOX/view.err"
out="$(bash "$VCS" view-issue 5 --spec 2>"$err")"; rc=$?
assert_eq "0" "$rc" "AC6 view-issue --spec exits 0"
assert_eq "title,body,labels,comments" "$(printf '%s' "$out" | _field "','.join(d.keys())")" "AC6 --spec prints {title, body, labels, comments}"
assert_eq "1" "$(printf '%s' "$out" | _field "len(d['comments'])")" "AC6 --spec keeps one comment"
assert_eq "**PM spec:** azure view-issue returns comments & reads them." "$(printf '%s' "$out" | _field "d['comments'][0]['body'].splitlines()[0]")" \
  "AC6 --spec keeps the latest PM spec, converted"
assert_eq "" "$(grep 'not implemented' "$err")" "AC6 --spec no longer prints the not-implemented note"
out="$(bash "$VCS" view-issue 5 --since-stage 2>"$err")"; rc=$?
assert_eq "0" "$rc" "AC6 view-issue --since-stage exits 0"
assert_eq "title,body,labels,comments,earlier_comments" "$(printf '%s' "$out" | _field "','.join(d.keys())")" "AC6 --since-stage prints the delta shape"
assert_eq "**Agent:** developer (talos)" "$(printf '%s' "$out" | _field "d['comments'][0]['body'].splitlines()[0]")" \
  "AC6 --since-stage's boundary is the latest stage comment, converted"
assert_eq "2" "$(printf '%s' "$out" | _field "len(d['comments'])")" "AC6 --since-stage keeps the boundary and the human comment after it"
assert_eq "" "$(grep 'not implemented' "$err")" "AC6 --since-stage no longer prints the not-implemented note"
out="$(STUB_AZURE_WI_COMMENTS_FAIL=1 bash "$VCS" view-issue 5 --spec 2>/dev/null)"; rc=$?
assert_eq "1:" "$rc:$out" "AC6 --spec fails closed when the comments read fails"
unset STUB_AZURE_WI_COMMENTS

# ── AC7: spec-usable / ids / qa-run see a spec that came through comment-issue
export STUB_AZURE_STATE_DIR="$SANDBOX/state7"; mkdir -p "$STUB_AZURE_STATE_DIR"
export STUB_AZURE_POST_AUTHOR="bot@acme.com"
export STUB_AZURE_WI_COMMENTS='{"comments":[]}'
SPEC_MD='**PM spec:** posted through comment-issue.

**Acceptance criteria**
- [ ] AC1 first thing (test)
- [ ] AC2 second thing (prose: doc wording)

**Tests:** `tests/x.sh`'
bash "$VCS" comment-issue 5 "$SPEC_MD" >/dev/null 2>&1
assert_eq "0" "$?" "AC7 comment-issue posts the spec"
out="$(bash "$CRIT" spec-usable 5 2>&1)"; rc=$?
assert_eq "0:spec-usable: ok" "$rc:$out" "AC7 spec-usable is ok for the stored-HTML spec"
spec_file="$SANDBOX/spec7.md"
bash "$VCS" view-issue 5 --spec 2>/dev/null | _field "d['comments'][0]['body']" > "$spec_file"
assert_eq "AC1 test
AC2 prose" "$(bash "$CRIT" ids "$spec_file" 2>&1)" "AC7 ids sees the criteria with the right ids and kinds"
unset STUB_AZURE_STATE_DIR STUB_AZURE_POST_AUTHOR STUB_AZURE_WI_COMMENTS

# ── AC9: --dry-run ────────────────────────────────────────────────────────────
out="$(bash "$VCS" --dry-run view-issue 5 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC9 view-issue --dry-run exits 0"
assert_contains "$out" "az boards work-item show --id 5" "AC9 --dry-run prints the work-item show command"
assert_contains "$out" "[dry-run] az rest GET .../workItems/5/comments" "AC9 --dry-run prints a [dry-run] line for the comments read"

finish
