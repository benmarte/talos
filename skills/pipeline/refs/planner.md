# Planner and epics (`roles.planner = true`)

Read when `talos.sh env` prints `ref=planner` or `next` answers `action=dispatch stage=planner`. The steps named here (1, 3b, 3c) are the LLM loop's, `refs/llm-loop.md`: the code driver has no planner stage.

**Step 1 sweeps.** `epic=<E> action=closed|pending|waiting` (else `pipeline:epic-children-done`, one comment; `warn reason=epic-acceptance-unsupported` = unsupported, left open). `unblocked=<N>` = `pipeline:ready` once every `Depends on:` issue is closed.

**Queue.** With the planner on, `next` gates dependencies and routes a `pipeline:confirmed` epic (the `epic` label, at least 4 `- [ ]` checklist items, or a body of at least 2000 characters) to the planner.

## Act path

Spawn `bash scripts/talos.sh prompt planner --issue <N> --title-file .talos/planner-epic-title.body --body-file .talos/planner-epic.body` (heredocs: reporter-controlled text). `done` refuses the planner role (`stop reason=unknown-role`, exit 2), so do not call it for this stage (Stage return). On `PLAN:` output:

1. For each sub-task 1..K, the body is:
   ```
   <Context from planner>

   Part of #<N>
   [Depends on: #<PREV>  <- only if the planner listed a dependency]
   ```
   Write the body to `.talos/planner-sub-issue.body` and the title to a variable, both from heredocs in the SAME command as `create-issue` (variables die between tool calls; never `.md`/`.txt`, which a project hook may refuse):
   ```bash
   mkdir -p .talos
   cat > .talos/planner-sub-issue.body <<'TALOS_<rand>'
   … the body …
   TALOS_<rand>
   read -r SUB_TITLE <<'TALOS_<rand>'
   … the sub-task title …
   TALOS_<rand>
   ```
   Every sub-issue carries `--label epic:<N>` (the `Part of #<N>` line keys the epic auto-close sweep).
   - **Independent sub-task** (no `Depends on:` in the planner output): also `pipeline:ready`, so it enters the queue at once:
     ```bash
     rc=0; bash scripts/pipeline-vcs.sh create-issue "$SUB_TITLE" .talos/planner-sub-issue.body \
       --label pipeline:ready --label epic:<N> || rc=$?
     rm -f .talos/planner-sub-issue.body; exit "$rc"
     ```
     Non-zero: report, set `pipeline:blocked`, no sub-issue recorded.
   - **Dependent sub-task** (`Depends on: <j>`): NO `pipeline:ready` (the sweep unblocks it later via the body's `Depends on: #<PREV>` line); `--label epic:<N>` only.
   - Capture each `SUB_N`; record planner-index to issue-number (fills the next `Depends on:`).
2. Label the epic: `bash scripts/pipeline-vcs.sh label-issue <N> --add pipeline:epic-decomposed --remove pipeline:confirmed`.
3. The epic is done for this run (skip 3b and 3c). Comment on it (`SUB_LIST` = the sub-issue numbers only): `bash scripts/pipeline-vcs.sh comment-issue <N> "**Planner:** decomposed into sub-issues: $SUB_LIST"` (non-zero: say so in the relay, never assert it was posted).
4. Relay `pipeline-notify.sh info "#<N>" "epic decomposed into K sub-issues" <N>`.
