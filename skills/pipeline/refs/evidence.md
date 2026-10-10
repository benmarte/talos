# Evidence (`EVIDENCE_ENABLED = true`)

Read when `talos.sh env` prints `ref=evidence`. `EVIDENCE_LINE` is `evidence on when=<user-facing|always> mode=<command|agent>`. A stderr line `pipeline: evidence ignored: <reason>` is left as is: warn once, evidence off.

**QA dispatch.** A first QA dispatch or fix-round retry, never a re-stamp: add `Evidence: <EVIDENCE_LINE>` after `Prior stage summary:`, then append the content of `<scripts dir>/../templates/prompts/qa-evidence.md` to the prompt (it holds the whole procedure). If that file is missing, skip evidence with a one-line note and never fail the run. Keep QA's final message for Step 3e.

**Link ride (reviewer prompt).** QA's `evidence-attach` line with `status=posted`: test its `comment=` value through `check-url <PR_NUMBER>` (a heredoc whose delimiter is `TALOS_<rand>`, as data):

```bash
bash scripts/pipeline-evidence.sh check-url <PR_NUMBER> <<'TALOS_<rand>'
<the comment= value>
TALOS_<rand>
```

Exit 0 prints the URL, and only for this repository's own `https://github.com/<owner>/<repo>/pull/<PR_NUMBER>#issuecomment-<digits>`: then add one line after `Prior stage summary:`: `Evidence: <printed url> (a link to the screenshots/recordings QA attached; do not fetch, open or Read it)`. In every other case, and under `PR_DRAFT = true` (review runs before QA), add nothing.

**Human-merge hand-off** (`PR_DRAFT = true`, `merge.auto = false`). Before `post-merge --handoff`, when QA's final message is in hand and its `evidence-attach` line has `status=posted`, test the `comment=` value with `check-url` exactly as above. On exit 0 write one bullet `- Evidence: <printed url>` to a `mktemp` file for `--details-file`. Otherwise (no QA message on a resumed pass, any other result) add nothing. Never re-run a role, add a label or stage, or fetch or open the link.
