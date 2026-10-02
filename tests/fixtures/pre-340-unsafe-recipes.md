<!-- The nine unsafe recipes on main before #340 (29dc539), verbatim. tests/test-role-profile-quoting.sh asserts the scanner flags every case. -->

<!-- case 1: wrapped printf with a double-quoted placeholder body (agents/developer.md) -->
6. Write the PR body to a temp file (multi-line OK):
   `printf '%s' "<spec summary>\n\nTest types: <unit / regression / e2e — list
   what you added; for any type skipped, say why>\n\nCloses #<N>" >
   /tmp/pr-body-<N>.md`. Use "Part of #<N>" instead of "Closes #<N>" for all
   but the last PR on multi-PR issues.

<!-- case 2: create-pr with a double-quoted title (agents/developer.md) -->
7. **Open the PR** — this is the completion signal:
   `bash scripts/pipeline-vcs.sh create-pr <branch> "<title>" /tmp/pr-body-<N>.md`.

<!-- case 3: comment-issue with a double-quoted spec (agents/pm.md) -->
Post: `bash scripts/pipeline-vcs.sh comment-issue <N> "**PM spec:** ..."`. If
the post fails, report it in your final message and do not advance the label.

<!-- case 4: printf body to a fixed temp path (skills/pipeline/SKILL.md) -->
   - Write the body to a temp file: `printf '%s' "<body>" > /tmp/sub-issue-<i>.md`

<!-- case 5: create-issue, independent sub-task (skills/pipeline/SKILL.md) -->
     ```bash
     bash scripts/pipeline-vcs.sh create-issue "<sub-task title>" /tmp/sub-issue-<i>.md \
       --label pipeline:ready --label epic:<N>

<!-- case 6: create-issue, dependent sub-task (skills/pipeline/SKILL.md) -->
     ```bash
     bash scripts/pipeline-vcs.sh create-issue "<sub-task title>" /tmp/sub-issue-<i>.md \
       --label epic:<N>

<!-- case 7: wrapped comment-issue, quoted argument on the next line (skills/pipeline/SKILL.md) -->
   bash scripts/pipeline-vcs.sh comment-issue <N> \
     "**Planner:** decomposed into sub-issues: <list of #SUB_N>"

<!-- case 8: slug-for with a double-quoted title (skills/pipeline/SKILL.md) -->
is `bash scripts/pipeline-vcs.sh slug-for "<title>"`; prefix is `feat/` when the

<!-- case 9: create-pr --draft, verb on the line after the script name (skills/pipeline/SKILL.md) -->
after `Verify timeout:`: `Open the PR as a DRAFT: bash scripts/pipeline-vcs.sh
create-pr <branch> "<title>" <body-file> --draft`. Every developer dispatch
