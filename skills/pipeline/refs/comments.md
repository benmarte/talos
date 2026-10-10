# Posting a stage comment yourself

Read before the orchestrator posts a templated comment itself (for example blocked.md after `verdict=block`). Subagents post their own findings comments, and `talos.sh done` / `post-merge` render the rest.

Comment: verdict plus 2-5 bullets; the inline fallback applies only if the template is missing. `HEADER` is required: empty means exit 1 and nothing is posted. Export every variable the template uses (an unset one drops the render to the inline fallback). `comment-issue`/`comment-pr` refuse (exit 1, nothing posted) a body that still holds a placeholder whose NAME appears in the templates. A failed post is never treated as done: report it.

```bash
TMPL="<TMPL_DIR>/<template>.md"
[ -f "$TMPL" ] || TMPL=".claude/talos/templates/comments/<template>.md"
read -r -d '' SUMMARY <<'TALOS_<rand>' || true
<one-line>
TALOS_<rand>
read -r -d '' DETAILS <<'TALOS_<rand>' || true
<bullet list>
TALOS_<rand>
export SUMMARY DETAILS COMMENT_BODY COMMENT_URL
COMMENT_BODY="$(HEADER="<HEADER>" ISSUE="#<N>" PR="<PR_or_empty>" VERDICT="<VERDICT>" \
  python3 -I -c "import os,string,sys
if not os.environ.get('HEADER'): sys.exit('HEADER is unset or empty -- set it from the prompt Comment header: line; nothing posted')
with open(sys.argv[1]) as f: t = string.Template(f.read())
print(t.substitute(os.environ).strip())" "$TMPL")" || exit 1
COMMENT_URL="$(bash scripts/pipeline-vcs.sh comment-issue <N> "$COMMENT_BODY")" || {
  echo "comment-issue failed for #<N>" >&2
}
COMMENT_URL="$(bash scripts/pipeline-vcs.sh comment-pr <PR> "$COMMENT_BODY")" || {
  echo "comment-pr failed for #<PR>" >&2
}
```
