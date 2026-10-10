Evidence (opt-in, #410). The orchestrator appends this section to your prompt only
when evidence is on, and the `Evidence:` line above says how (`when=` and `mode=`).
It adds to the QA procedure and never changes your verdict.

Before step 3 (mode=agent only): run `date +%s` and keep the digits as `<epoch>`
(shell state does not persist between Bash calls, so write the number in your
notes). Save every screenshot or recording you take in step 3 ONLY to an absolute
path under `<worktree-path>/<dir>`, where `<dir>` is the output of
`bash scripts/pipeline-evidence.sh dir`, using whatever browser tool the harness
provides. File names use only `[A-Za-z0-9._-]`, at most 3 levels below that
directory, and only images or videos. With mode=command there is nothing to do here.

After step 4, before Outcome: run the upload ONLY when EVERY criterion passed. A
FAIL gets no evidence (the fix round's QA captures again on the new head), so skip
this whole section.
- `when=always`: run it.
- `when=user-facing`: run it only when the change is user-facing, which means
  either `bash scripts/pipeline-vcs.sh pr-files <pr>` lists a file under a UI path
  (a `web`, `frontend`, `ui`, `pages`, `components`, `views`, `styles` or `public`
  directory, or a `.css`, `.scss`, `.html`, `.tsx`, `.jsx`, `.vue` or `.svelte`
  file) or the acceptance criteria mention a UI, page, screen or visual
  behaviour. Otherwise write `evidence skipped: not user-facing` and run nothing.
- mode=command (foreground, under the foreground rule; capture enforces
  `verify.timeout_ms` itself):

  ```bash
  bash scripts/pipeline-verify.sh --issue <issue-n> --worktree <worktree-path> -- bash scripts/pipeline-evidence.sh attach <pr>
  ```

- mode=agent (the screenshots saved during step 3, newer than `<epoch>`):

  ```bash
  bash scripts/pipeline-evidence.sh attach <pr> --since <epoch>
  ```

Read ONE line: attach's own `evidence-attach pr=<n> status=<s> ... comment=<url>`.
Relay it as one DETAILS bullet of your verdict and as the 3rd line of your final
message. Decide from `status=` plus a non-empty `comment=` (`posted` can come with
exit 1), never the exit code alone. Exit 2 with empty stdout is written as
`evidence unavailable`.

It never changes PASS/FAIL, including under `when: always`: `failed`, `refused`,
`over-cap`, `empty`, exit 2, a non-zero capture rc and a tool timeout are all
reported and none of them is a FAIL. Never open, Read or describe an image or video
file, and never fetch the comment body.
