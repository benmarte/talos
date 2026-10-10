#!/usr/bin/env bash
# pipeline-vcs.sh — VCS provider adapter for Talos.
#
# Provides a uniform verb interface over GitHub, GitLab, Azure DevOps, or a
# local markdown file (plan.md) so orchestrator and subagent prompts never
# contain provider-specific CLI calls.
#
# Usage: pipeline-vcs.sh [--dry-run] <verb> [args...]
#
# Verbs:
#   list-issues                               List open issues / work items
#               [--no-body]                   github, github-api: leave `body` out of
#                                             every item (number, title, labels
#                                             only; #449). Default output unchanged.
#   create-issue <title> <body-file> [--label l]  Create a new issue; --label
#                                             may be repeated (used by planner
#                                             to create sub-issues). Exits
#                                             non-zero if the POST fails.
#                                             Then runs assign-issue on the new
#                                             issue (messages on stderr only).
#   current-user                              Print the authenticated login (#466; github,
#                                             github-api, gitlab, azure). Exit 1 and no
#                                             output when it cannot be resolved (file
#                                             mode, no lookup), 3 when the lookup was
#                                             refused. Used by talos.sh to count only
#                                             trusted-author markers.
#   assign-issue <n>                          Assign issue <n> per issues.assignee
#                                             (#299) only when it has no assignee;
#                                             read back, and print "assign-issue:
#                                             #<n> assigned to <id>" only when the
#                                             write is confirmed. Every failure is
#                                             a stderr WARNING + exit 0. github,
#                                             github-api, gitlab, azure (not file).
#   issue-assignees <n>                       Print issue <n>'s assignee logins, one per
#                                             line (nothing when unassigned; #560).
#                                             Exit 1 on a failed read. github,
#                                             github-api, gitlab, azure; file exits 2.
#   unassign-issue <n> <login>                Take <login> off issue <n>, keeping any
#                                             other assignee (azure clears its single
#                                             field), read back; prints "unassign-issue:
#                                             #<n> unassigned <login>" (or "not assigned
#                                             to"). Exit 1 + WARNING when the login is
#                                             still there (#560).
#   list-assignees                            One JSON object {"<n>": ["login", ...]} of
#                                             the open issues that have an assignee
#                                             (#560). Exit 1 on a failed read.
#   view-issue <n>                            View issue details
#             <n> --spec                      Compact form for stage handoff (#201):
#                                             same {title, body, labels, comments}
#                                             shape, but comments is at most the one
#                                             latest comment whose body starts with
#                                             "**PM spec:**". Every comment containing
#                                             a "<!-- talos:" marker, every stage-
#                                             verdict comment (body starting with
#                                             "**Agent:**"), and any other comment
#                                             (including plain human replies -- the
#                                             spec is the contract, not the thread)
#                                             is dropped. Reuses the paginated
#                                             read-comments path -- no new fetches.
#                                             GitHub only (github/github-api parity);
#                                             gitlab, azure, and file mode fall back
#                                             to plain view-issue with a stderr note.
#             <n> --since-stage               Delta form for the PM and validator (#548):
#                                             {title, body, labels, comments,
#                                             earlier_comments}, where comments holds
#                                             the latest stage comment (a "**PM spec:**"
#                                             or "**Agent:**" comment) plus what came
#                                             after it, bare "<!-- talos:" marker
#                                             comments dropped, and earlier_comments
#                                             counts the human comments before it
#                                             (read them with read-comments). With no
#                                             stage comment yet, every human comment
#                                             is new. Same read as --spec; same
#                                             fallback on gitlab, azure and file mode.
#   comment-issue <n> <body>                  Post comment on issue <n>
#                 <n> --body-file <path|->    ...or read the body from a file, or from
#                                             stdin with "-" (heredoc; #342)
#                                             A positional <body> of exactly "-" is
#                                             refused (exit 1, nothing posted): it is
#                                             NOT stdin. Use `--body-file -` (#449).
#   close-issue <n> <body>                    Close issue with a comment
#               <n> --body-file <path|->      ...or read the comment from a file / stdin
#   label-issue <n> [--add <l>] [--remove <l>]  Add/remove labels
#   check-epic-acceptance <n>                 Scan issue <n>'s body for unticked
#                                             "- [ ] " checklist boxes. Exits 0
#                                             (no output) when none remain —
#                                             including bodies with no checkboxes
#                                             at all. Exits non-zero and prints
#                                             each unticked item's text, one per
#                                             line, when any remain. github,
#                                             github-api, gitlab (#303).
#   has-spec <n>                              Exit 0 when issue <n>'s body already
#                                             IS a usable spec — an "acceptance
#                                             criteria" heading (case-insensitive,
#                                             `#`-prefixed or bold) followed by at
#                                             least one `- [ ]`/`- [x]` item, or the
#                                             `spec:ready` label — so the orchestrator
#                                             can skip the PM stage (#199). Exit 1
#                                             otherwise. Prints nothing either way.
#                                             GitHub only (github, github-api parity).
#   slug-for <title>                          Print the `<=40`-char slug for
#                                             `fix/issue-<n>-<slug>` / `feat/issue-
#                                             <n>-<slug>`: title lowercased,
#                                             non-alphanumeric runs collapsed to a
#                                             single '-', trimmed. Provider-agnostic
#                                             (#199).
#   create-pr <branch> <title> <body-file>    Open a pull / merge request
#             [--draft]                       ...as a DRAFT (#332): GitHub
#                                             `draft: true`, glab `--draft`, az
#                                             `--draft true`; `--draft` goes
#                                             after the three positionals. File
#                                             mode stays a no-op.
#   ready-pr <n>                              Mark a draft PR ready for review
#                                             (#332): GitHub GraphQL
#                                             markPullRequestReadyForReview (the
#                                             one mutation REST lacks), `glab mr
#                                             update --ready`, `az repos pr
#                                             update --draft false`. Exit 0 only
#                                             on success; every failure (bad or
#                                             non-numeric id, setup error, file
#                                             mode) is exit 2.
#   draft-pr <n>                              Convert a PR back to a draft
#                                             (#332): GitHub GraphQL
#                                             convertPullRequestToDraft, `glab mr
#                                             update --draft`, `az repos pr
#                                             update --draft true`.
#                                             Same exit contract as ready-pr.
#   pr-is-draft <n>                           Print `draft` or `ready` (#332).
#                                             Exit 0 = draft, 1 = ready, 2 =
#                                             unverified (fetch failed, bad or
#                                             non-numeric PR id, unparseable
#                                             response, unsupported provider:
#                                             file; setup error: no
#                                             token, unknown provider, missing
#                                             CLI; --dry-run). Exit 0 only with
#                                             stdout exactly `draft`, exit 1 only
#                                             with stdout exactly `ready` (enforced
#                                             for every provider by the dispatcher);
#                                             stdout is empty on every exit 2.
#                                             Callers dispatch QA / the CI wait
#                                             only on exit 1.
#   pr-ci-runs <n>                            Print the number of `pull_request`
#                                             workflow runs of THIS PR that
#                                             executed (#332): one listing for
#                                             the head branch, keeping runs whose
#                                             pull_requests[] names this PR and
#                                             dropping `skipped` ones (a draft
#                                             push skipped by the `draft != true`
#                                             guard is not CI that ran). github
#                                             only; every other provider exits 2,
#                                             and so does any setup error, a
#                                             failed, truncated or unparseable
#                                             listing, a run that cannot be
#                                             attributed to a PR (empty
#                                             pull_requests[], e.g. a fork) or a
#                                             total at GitHub's 1000-result cap
#                                             (never a short count). Call it
#                                             while the PR is OPEN: after
#                                             `merge-pr` deletes the head branch
#                                             every run reads as unattributed.
#   view-pr <n|branch>                        View PR details
#   list-prs                                  List open PRs
#   diff-pr <n>                               Show PR diff
#          <n> --stat                         Print a `git diff --stat`-style
#                                             per-file summary (path, additions,
#                                             deletions) instead of the full diff,
#                                             so reviewer/security/QA can decide
#                                             whether they need the full diff at
#                                             all (#201). Derived from the same
#                                             paginated PR-files endpoint pr-files
#                                             (#200) uses. GitHub only
#                                             (github/github-api parity); other
#                                             providers print the full diff (flag
#                                             ignored).
#   checkout-pr <n>                           Check out PR branch locally
#   approve-pr <n> <body>                     Approve a PR with a comment
#              <n> --body-file <path|->       ...or read the comment from a file / stdin
#   label-pr <n> [--add <l>] [--remove <l>]   Add/remove labels on PR
#   pr-checks <n>                             Show CI check status: one line per
#                                             check run or commit status, "name
#                                             TAB pass|fail|pending|skipping|
#                                             cancel TAB elapsed TAB url". Exit
#                                             1 when any failed, 8 while any is
#                                             pending, else 0.
#   pr-checks-required <n>                    Exit 0 only when every check in
#                                             merge.required_checks passes on
#                                             the current head; exit 2 while
#                                             any is pending/missing, exit 1
#                                             on failure or an empty
#                                             merge.required_checks (#205).
#                                             A skipped or neutral check
#                                             is pending, not failed (#435): a
#                                             draft push leaves one until the
#                                             ready_for_review run replaces it.
#                                             It never passes, so a persistent
#                                             skip ends exit 2 at the deadline.
#              <n> --wait <seconds>           ...poll (30, 60, then 120 s steps) until not 2 or
#                                             <seconds> (digits, <= 3600, read in
#                                             base 10: 08 and 09 are valid, 0010
#                                             is 10; #449) pass;
#                                             github/github-api only (#355)
#   merge-pr <n>                              Merge the PR
#   update-branch <n>                         Update the PR's head branch by
#                                             merging its base into it
#                                             server-side (#289): GitHub
#                                             `PUT .../pulls/{n}/update-branch`
#                                             with expected_head_sha (gh and
#                                             github-api parity), GitLab
#                                             `glab mr rebase`. Exit 0 on
#                                             success; exit 1 on a head-moved
#                                             conflict (HTTP 409) or other
#                                             GitHub failure; exit 2 where
#                                             unsupported (azure, file mode) —
#                                             callers skip silently and fall
#                                             back to the developer merge-base
#                                             dispatch. Does NOT resolve
#                                             content conflicts on the PR's
#                                             own files: a 409 there means
#                                             the caller must dispatch the
#                                             developer merge-base task.
#   comment-pr <n> <body>                     Post comment on PR <n>
#              <n> --body-file <path|->       ...or read the body from a file, or from
#                                             stdin with "-". A positional <body> of
#                                             exactly "-" is refused like
#                                             comment-issue (#449).
#   find-pr <issue-n> [state]                 Find PRs for an issue (branch has
#                                             issue-<n> or title/body has #<n>).
#                                             state: open (default) | merged | all
#                                             merged: only the branch or a closing
#                                             keyword (Closes #<n>) counts (#298).
#                                             azure also matches PRs linked to the
#                                             work item. Exit 2 = find-pr is not
#                                             implemented for this provider (never
#                                             "no PR found").
#   check-pr-files <n>                        Exit 1 if the PR touches any
#                                             merge.forbidden_files pattern
#   pr-files <n>                              Print the PR's changed paths, one per
#                                             line -- no filtering, no exit-1 gate
#                                             (that's check-pr-files). Fully paginated
#                                             (#171 pattern) so PRs with >100 changed
#                                             files are never silently truncated.
#                                             Used by the Step 3e Phase 1 docs-mode
#                                             gate (#200) to decide whether the docs
#                                             stage needs to run at all. github,
#                                             github-api, gitlab (#303, MR diffs
#                                             API), azure (#304, last iteration's
#                                             changes); a failed fetch exits 1.
#                                             file mode fails open (empty stdout).
#   check-closing-keyword <n|branch> <issue>  Exit 1 if the PR body has a closing
#                                             keyword for <issue> while other PRs
#                                             for that issue are still open.
#                                             azure (#304) is link-based: the PR is
#                                             linked to work item <issue> and
#                                             another active PR is linked to it or
#                                             on an issue-<issue> branch.
#                                             Fail-open: exits 0 + stdout marker
#                                             if data cannot be fetched.
#   rerun-ci <n>                              Re-run failed CI for the PR head SHA
#   pr-head <n>                               Print the current head SHA for a PR
#   pr-mergeable <n>                          Print MERGEABLE / CONFLICTING / UNKNOWN
#                                             for the PR's mergeability with its base
#                                             (#214). Exit 0/1/2 respectively. UNKNOWN
#                                             is retried up to 4 times (GitHub computes
#                                             it lazily), sleeping a
#                                             TALOS_RETRY_SLEEP_SCALE-scaled 2s between
#                                             attempts. github/github-api parity;
#                                             gitlab/azure best-effort off their own
#                                             merge-status fields, else UNKNOWN with a
#                                             stderr note; file mode: UNKNOWN (no PR
#                                             concept). Used before dispatching QA and
#                                             before QA's CI wait, since GitHub
#                                             schedules no `pull_request` run for a
#                                             CONFLICTING PR.
#   conflict-files <n>                        Print the paths that conflict between
#                                             PR <n>'s head and origin/<base_branch>,
#                                             one per line (#256). Resolved with a
#                                             throwaway `git merge --no-commit` in a
#                                             detached temp worktree outside the
#                                             caller's own checkout -- `git status`/
#                                             `assert-sync` on the caller's checkout
#                                             are unaffected, and the temp worktree is
#                                             removed on every exit path. Exit 0 with
#                                             output when conflicting, exit 0 with no
#                                             output when clean, exit 2 when it cannot
#                                             be determined (fetch/worktree failure).
#                                             GitHub only (github/github-api parity),
#                                             backed by one shared implementation
#                                             (same pattern as has-spec/post-approval).
#                                             Used by the Step 3c mergeability gate to
#                                             decide whether a CONFLICTING PR qualifies
#                                             for pipeline-mergebase.sh's mechanical
#                                             union-merge instead of a developer
#                                             merge-base dispatch.
#   check-approval-sha <n> [--stale-list]     Exit 1 if any approval label was earned
#                                             against a non-current head SHA (stale
#                                             approvals); respects
#                                             merge.approval_waiver_paths config
#                                             (code, tests, agent instructions and
#                                             pipeline config are never waivable).
#                                             --stale-list additionally prints one
#                                             stdout line per stale role:
#                                             "stale role=<role> label=<label>"
#   record-attempt <issue-n> <stage>          Record one attempt for the given blocking
#     [--pr <pr-n> | --idempotency-key <token>]
#                                             stage on the issue. Reads prior state,
#                                             computes new per-stage count and running
#                                             total, posts a <!-- talos:attempt --> marker
#                                             comment, and prints "stage=<s> count=<k>
#                                             total=<t>" on stdout. Exits non-zero when
#                                             either ceiling would be exceeded.
#                                             --pr <pr-n>: derives the idempotency key
#                                             itself as "<stage>-<pr-head-sha>" by
#                                             resolving the PR's current head SHA
#                                             server-side (same call as the pr-head verb).
#                                             Retry-stable by construction -- the exact
#                                             same command, run again in a fresh shell/
#                                             process, always recomputes the same key as
#                                             long as the PR head has not moved, so callers
#                                             never mint a token by hand (e.g. no
#                                             $(date +%s), which re-evaluates on every
#                                             invocation and defeats dedup on retry). Fails
#                                             closed (exit 1, nothing posted) if the head
#                                             SHA cannot be resolved. Mutually exclusive
#                                             with --idempotency-key.
#                                             --idempotency-key <token>: when the most
#                                             recent marker already carries this stage and
#                                             key, does not post again -- reprints the
#                                             existing counts unchanged and exits with the
#                                             status those counts imply. token must match
#                                             [A-Za-z0-9._-]+ (exit 1 otherwise). Only
#                                             dedupes an immediate retry within the same
#                                             orchestrator turn -- it does not persist
#                                             across process restarts. Use this only when
#                                             no PR exists yet (e.g. developer/validator/pm
#                                             stages before a PR is opened); prefer --pr
#                                             whenever a PR number is available. Omitted:
#                                             unchanged back-compat behaviour (always
#                                             posts).
#   read-attempt <issue-n>                    Print stage/count/total from the most
#                                             recent attempt marker on the issue.
#                                             Exits 0 (prints "stage= count=0 total=0")
#                                             when no marker exists yet.
#   read-comments <issue-or-pr-n>              Print every comment on an issue/PR (GitHub
#                                             treats PRs as issues for this endpoint) as
#                                             {"comments": [...]}, fully paginated (no
#                                             100-comment cap). Shared reader used by both
#                                             read-attempt and post-approval's duplicate-
#                                             marker check (#172). Fail-closed: prints
#                                             nothing and exits 1 on any page failure.
#   upsert-pr-comment <pr> --marker <name> --body-file <path|->
#                                             Keep ONE marker comment on PR <pr> up to date
#                                             (#381, epic #334; github and github-api only,
#                                             gitlab, azure and file exit 2 with `not
#                                             implemented for provider '<p>'`). <name> is a
#                                             TALOS_MARKERS member without `talos:` (e.g.
#                                             spend), else exit 2; a bare `-` argument exits
#                                             2. The body (a file, or stdin with `-`) gets a
#                                             blank line and `<!-- talos:<name> -->` as its
#                                             last line. The newest comment by the
#                                             authenticated user whose last non-blank line is
#                                             that marker is PATCHed in place, else a new one
#                                             is POSTed; an identical body writes nothing.
#                                             Prints the comment URL, then `upserted pr=<n>
#                                             comment=created|updated|unchanged`. The body
#                                             reaches the API on stdin, never argv; the same
#                                             caps as approve-pr apply to the final body (over
#                                             either, an empty body, an unreadable file or a
#                                             closed stdin: exit 1). An unresolved login (GET
#                                             /user is 403 for an Actions GITHUB_TOKEN), an
#                                             unreadable comment list or a failed write is exit
#                                             1 and never a blind duplicate. Works on a merged
#                                             PR. --dry-run prints the planned calls, exit 0.
#   edit-pr-body <pr> --body-file <path|->    Replace the description of PR <pr> (#455;
#                                             github, github-api: PATCH pulls/<n>;
#                                             gitlab, azure
#                                             and file exit 2 `not implemented for
#                                             provider '<p>'`). The body comes ONLY from
#                                             a file or stdin with `-`, never argv or a
#                                             positional (exit 2); a non-numeric <pr> or
#                                             a flag with no value is exit 2. The same
#                                             character and byte caps and the unsubstituted-
#                                             placeholder guard as comment-pr apply, and an
#                                             empty body, an unreadable file or a closed
#                                             stdin is exit 1, all before any call.
#                                             Prints `edited pr=<n> body`. Journaled in the
#                                             write log. --dry-run prints the planned call.
#   mark-needs-owner <n> <text>              Park a pending owner decision on GitHub
#                    <n> --body-file <path|->  (#345, epic #333): post ONE comment on issue
#                                             or PR <n> -- <text>, a blank line, then
#                                             `<!-- talos:needs-owner -->` as the last
#                                             line (no header; a text that already ends
#                                             in that marker line is not marked twice) --
#                                             and then add the label pipeline:needs-
#                                             owner. The text may come from a file or
#                                             from stdin with "-" (a closed or terminal
#                                             stdin exits 1); a text over 65536
#                                             characters or 120000 bytes, an empty text,
#                                             a text that looks like a flag, extra
#                                             arguments and a non-numeric <n> are all
#                                             refused with exit 1 before any call.
#                                             Idempotent only while the item is still
#                                             unanswered: when the newest TRUSTED marker
#                                             comment already has the same body (marker
#                                             line and surrounding whitespace ignored)
#                                             and no trusted human reply is newer, no
#                                             second comment is posted, the label is
#                                             still ensured and the exit is 0. Once the
#                                             item is answered the same text posts a new
#                                             comment. The existing comments are read
#                                             first; a failed read is exit 1, nothing
#                                             posted. Exit 0 only when the comment (or the
#                                             existing one) AND the label both succeed;
#                                             a failed comment POST is exit 1 and no label
#                                             call is made. stdout: `marked n=<n>
#                                             comment=<posted|existing>`. Both comment
#                                             and label use the issues REST endpoints,
#                                             which serve issues and PRs alike. Works on
#                                             an issue in any state. github, github-api;
#                                             gitlab, azure and file exit 2 with
#                                             "not implemented for provider '<p>'".
#   list-needs-owner [--json] [--clear-answered]
#                                             One line per OPEN issue or PR carrying
#                                             pipeline:needs-owner, sorted by number:
#                                               needs-owner n=<n> kind=<issue|pr> answered=<yes|no> question=<text>
#                                             `question=` is ALWAYS THE LAST field and
#                                             runs to the end of the line: it is the first
#                                             non-blank line of the newest trusted marker
#                                             comment (an `**Agent:**` line and the marker
#                                             line skipped), whitespace collapsed to
#                                             single spaces, control characters removed,
#                                             at most 200 characters, so it can never
#                                             forge another field. Parse with --json (one
#                                             array of {n, kind, answered, question};
#                                             n is a number, answered is "yes" or "no")
#                                             rather than splitting lines. An item with
#                                             the label but no trusted marker comment
#                                             prints `question=(no marker comment)` and
#                                             `answered=no`. A marker comment counts only
#                                             when its last non-blank line is the marker;
#                                             with markers.verify_authors (default true)
#                                             it and every reply must be written by
#                                             markers.trusted_authors or the
#                                             authenticated identity -- an outsider's
#                                             comment neither supplies the question nor
#                                             answers it; unresolvable trust fails open
#                                             with `talos:marker-authors-unverified` on
#                                             stderr. answered=yes means a trusted
#                                             comment newer than that marker comment is
#                                             neither a Talos comment (`<!-- talos:` or a
#                                             leading `**Agent:**`) nor empty. Reads every
#                                             page of issues and comments; a failed or
#                                             unparseable fetch is exit 1 with EMPTY
#                                             stdout and nothing cleared, never an empty
#                                             list. No labelled item: exit 0, empty
#                                             stdout (`[]` with --json, so a JSON reader
#                                             always gets an array). --clear-answered removes the label
#                                             from every answered=yes item and prints
#                                             `cleared n=<n>` for each removal that
#                                             succeeded (after the listing; on stderr
#                                             with --json so stdout stays one JSON
#                                             array); a failed removal is exit 1. Without
#                                             the flag no label is changed. github,
#                                             github-api; other providers exit 2 as above.
#   check-attempt <issue-n>                   Exit 1 (and print reason) when EITHER
#                                             ceiling is already reached for the issue;
#                                             exit 0 otherwise. Does NOT record a new
#                                             attempt — use record-attempt for that.
#   assert-sync                               Assert the working tree is clean AND level
#                                             with origin/<base_branch>. Exits 0 (no
#                                             output) on success. Exits 1 with a message
#                                             on dirty tree, behind-origin, or diverged.
#                                             Dirty-tree check runs BEFORE fetch so the
#                                             working tree is never read in a mixed state.
#                                             Used as an orchestrator precondition before
#                                             dispatching non-worktree-isolated stages.
#   post-approval <pr> <role> [--body-file p] [--issue n]
#                                             Fetch head SHA from the PR, construct
#                                             the wrapped approval marker, post it as a
#                                             comment, and apply the approval label.
#                                             GitHub-only (github and github-api providers).
#                                             Roles: qa, reviewer, security, docs.
#                                             Eliminates marker format failures for any
#                                             stage that uses this verb (#146).
#                                             Duplicate-marker check (#172): before
#                                             posting, fetches every PR comment
#                                             (paginated) and skips the post (exit 0, no
#                                             comment-pr call) when an identical marker
#                                             already exists at the current head SHA --
#                                             the label is still applied defensively. A
#                                             failed comment fetch fails closed: exit 1,
#                                             nothing posted.
#                                             Self-check (#549): the verb then runs
#                                             check-approval-sha itself and prints ONE
#                                             result line ending `stamp ok`, or
#                                             `stamp FAILED (...)` with exit 1 -- no
#                                             stage runs a confirmation after it.
#                                             One pass shares its reads (#554): the PR,
#                                             its comments and the login are read once
#                                             before the writes and once after (see
#                                             "Per-pass read cache"); 7 REST calls, not 10.
#                                             --issue <n> tags the calling stage's
#                                             worktree for issue <n> (best effort; the
#                                             main checkout is never tagged).
#
# Config keys (from talos.pipeline.json via pipeline-config.sh):
#   vcs.provider          github | github-api | gitlab | azure | file   (default: github)
#   vcs.token_env         env-var name for the GitHub token (token transport;
#                         default: GITHUB_TOKEN then GH_TOKEN)
#   vcs.repo              owner/repo  (auto-detected if omitted)
#   vcs.azure.org_url     e.g. https://dev.azure.com/myorg
#   vcs.azure.project     Azure DevOps project name
#   vcs.file.source.path  path to plan.md  (default: plan.md)
#   base_branch           PR target branch
#   merge.method          squash | merge | rebase   (default: squash)
#   issues.assignee       self | <identity> | none   (default: self) -- who
#                         create-issue / assign-issue assign an issue to (#299);
#                         "" = none, with a stderr notice (#305)
#   limits.max_fix_attempts     max consecutive per-stage failures before
#                               pipeline:blocked (default: 3)
#   limits.max_total_dispatches absolute ceiling on total developer dispatches
#                               per issue — never resets (default: 8)
#   limits.max_retries          max retries per network call after a rate-limit
#                               / transient error, on top of the original try
#                               (default: 5, so up to 6 total attempts). Must be
#                               a non-negative integer — a non-numeric value is
#                               rejected with a warning and the default is used.
#                               Applies to every network verb in every adapter
#                               via the shared _with_retry helper (#173).
#                               Backoff: Retry-After header when the transport
#                               supplies one, else exponential starting at 2s,
#                               doubling each attempt — both are capped at 60s.
#                               Retried: HTTP 429 (curl paths: decided from the
#                               parsed status code, not text); GitHub 403
#                               secondary-rate-limit/abuse-detection bodies;
#                               gh/glab/az CLI errors whose stderr matches an
#                               anchored rate-limit phrase (never a bare
#                               number). Not retried: 401, 404, 422, and any
#                               other non-matching error — those fail
#                               immediately with today's behaviour.
#                               TALOS_RETRY_SLEEP_SCALE (default 1) scales every
#                               sleep and accepts decimals (e.g. 0.1); set to 0
#                               in tests for instant runs.
#
# --dry-run: print the underlying CLI command instead of running it.
#            For file mode: describe the edit without applying it.
#
# Exit behaviour:
#   Exits non-zero on real errors so the orchestrator can react.
#   File-not-found / missing CLI → descriptive stderr + exit 1.
#   Webhook-safe no-ops (create-pr / merge-pr in file mode) → exit 0 + message.
#
# Provider notes:
#   github      — ONE REST client. Transport: `gh api` when `gh` is on PATH and
#                 authenticated, else curl with GITHUB_TOKEN or GH_TOKEN.
#   github-api  — the same client pinned to the token transport (curl), for CI
#                 and containers: no `gh` needed; set GITHUB_TOKEN or GH_TOKEN.
#                 Projects v2 board updates also use the token (pipeline-status.sh).
#   gitlab  — best-effort; requires `glab` CLI authenticated.
#   azure   — best-effort; requires `az` CLI + azure-devops extension:
#               az extension add --name azure-devops
#               az devops configure --defaults organization=<org_url> project=<project>
#   file    — no VCS needed; edits a markdown checklist file (plan.md).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# cfg() (#169): dumps the config once per invocation and answers lookups
# from that cache instead of re-parsing on every call. Guarded (#169 review):
# a partial install/sync may not yet ship pipeline-cfg-cache.sh: that is fatal
# (no per-call fallback: it would hide the fail-closed exit of a broken table).
if [ -f "$SCRIPT_DIR/pipeline-cfg-cache.sh" ]; then
  . "$SCRIPT_DIR/pipeline-cfg-cache.sh"
else
  echo "talos: pipeline-cfg-cache.sh missing; reinstall Talos" >&2
  exit 1
fi

# with_lock (#180 pattern, #262 review follow-up): `_vcs_shared_conflict_files`'s
# `git worktree add`/`remove` race the same shared git-common-dir metadata
# pipeline-worktree.sh's create/remove/sweep and pipeline-mergebase.sh's own
# worktree already serialize against. Guarded the same way as
# pipeline-cfg-cache.sh above: fall back to running unlocked with a warning
# rather than failing a partial install outright.
if [ -f "$SCRIPT_DIR/pipeline-lock.sh" ]; then
  . "$SCRIPT_DIR/pipeline-lock.sh"
else
  with_lock() { shift 2; [ "${1:-}" = "--" ] && shift; "$@"; }
  echo "pipeline: lock helper missing, worktree operations are unsynchronized" >&2
fi

# ── Contract (#178): roles / labels / markers single source of truth ────────
# Makes TALOS_ROLES/TALOS_APPROVAL_LABELS/TALOS_APPROVAL_ROLES available
# script-wide. If pipeline-contract.sh is missing (partial install/sync),
# _vcs_shared_contract_env() (below, in the shared-helper block -- so test
# harnesses that `eval` only that byte range still work) is the single
# place that falls back to the pre-#178 literals instead of leaving these
# undefined; nothing here needs its own copy of that fallback.
[ -f "$SCRIPT_DIR/pipeline-contract.sh" ] && . "$SCRIPT_DIR/pipeline-contract.sh"

# ── Resolve config path for Python blocks (#116) ─────────────────────────────
# Mirrors the canonical project config in pipeline-config.sh (#526); passed as
# TALOS_CFG env var to Python blocks that need to detect config-parse failures.
_TALOS_CFG="${PIPELINE_CONFIG:-}"
if [ -z "$_TALOS_CFG" ]; then
  # The canonical project config only (#526): no name list, no precedence.
  if [ -f "talos.pipeline.json" ]; then _TALOS_CFG="talos.pipeline.json"; fi
fi

# ── Config-parse warning (#116) ───────────────────────────────────────────────
# When a config file exists but cannot be parsed, warn once here in-process.
# No sentinel file is written: there is nothing an unprivileged external process
# can pre-create to suppress this check. Each pipeline-vcs.sh invocation either
# parses the config successfully (silent) or emits exactly one warning (below).
# Direct callers of pipeline-config.sh receive silent default-fallback behaviour;
# that is the intended degradation path for non-pipeline invocations.
if [ -n "$_TALOS_CFG" ] && [ -f "$_TALOS_CFG" ]; then
  if ! python3 -I - "$_TALOS_CFG" 2>/dev/null <<'_CFG_PARSE_CHECK'
import sys, json
p = sys.argv[1]
try:
    # JSON only (#526): the config parser is json, like the loader's.
    json.load(open(p))
    sys.exit(0)
except Exception:
    sys.exit(1)
_CFG_PARSE_CHECK
  then
    printf 'pipeline-config: WARNING -- %s could not be parsed (malformed JSON); ALL configuration keys are using built-in defaults.\n' "$_TALOS_CFG" >&2
  fi
fi

# ── Arg parsing ───────────────────────────────────────────────────────────────
DRY_RUN=false
ALLOW_CLOSED=false
VERB=""
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --allow-closed) ALLOW_CLOSED=true ;;
    *)
      [ -z "$VERB" ] && VERB="$arg" || ARGS+=("$arg")
      ;;
  esac
done

if [ -z "$VERB" ]; then
  echo "Usage: pipeline-vcs.sh [--dry-run] <verb> [args...]" >&2
  exit 1
fi

# create-pr --draft (#332): a flag after the three positionals. Pulled out of
# ARGS here so every adapter sees the same positionals; _PR_DRAFT carries it.
_PR_DRAFT=false
if [ "$VERB" = "create-pr" ] && [ "${#ARGS[@]}" -gt 3 ]; then
  _cp_args=("${ARGS[@]:0:3}")
  for _cp_a in "${ARGS[@]:3}"; do
    if [ "$_cp_a" = "--draft" ]; then _PR_DRAFT=true; else _cp_args+=("$_cp_a"); fi
  done
  ARGS=("${_cp_args[@]}")
  unset _cp_args _cp_a
fi

# ── Config ────────────────────────────────────────────────────────────────────
PROVIDER="$(cfg vcs.provider)"
REPO="$(cfg vcs.repo)"
BASE_BRANCH="$(cfg base_branch)"
MERGE_METHOD="$(cfg merge.method)"
AZURE_ORG="$(cfg vcs.azure.org_url)"
AZURE_PROJECT="$(cfg vcs.azure.project)"
FILE_PATH="$(cfg vcs.file.source.path)"

# Auto-detect repo for github/gitlab if not set.
# github-api uses only git remote (no gh call) to avoid CLI dependency.
if [ -z "$REPO" ] && [ "$PROVIDER" != "file" ]; then
  if [ "$PROVIDER" = "github-api" ]; then
    REPO="$(git remote get-url origin 2>/dev/null \
      | sed 's|.*github\.com[:/]||; s|\.git$||' || echo "")"
  else
    REPO="$(gh api 'repos/{owner}/{repo}' --jq .full_name 2>/dev/null \
      || git remote get-url origin 2>/dev/null \
      | sed 's|.*github.com[:/]||; s|.*gitlab.com[:/]||; s|\.git$||' \
      || echo "")"
  fi
fi

# ── Dry-run wrapper ───────────────────────────────────────────────────────────
_run() {
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] $*"
    return 0
  fi
  "$@"
}

# ── Draft PR helpers (#332) ───────────────────────────────────────────────────
# `pr-is-draft` and `pr-ci-runs` feed gates, so they fail closed: any fetch
# failure, bad id or unparseable response is exit 2 with nothing on stdout --
# never an empty result and never "ready".

# _vcs_draft_unsupported <verb> <provider> -> exit 2, nothing on stdout.
_vcs_draft_unsupported() {
  echo "pipeline-vcs: $1: not supported for provider $2 (exit 2, unverified)" >&2
  exit 2
}

# _vcs_pr_id_numeric <id> -> 0 only for a non-empty all-digit id.
_vcs_pr_id_numeric() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# _vcs_require_pr_id <verb> <id> -> exit 1 (usage error) unless numeric.
_vcs_require_pr_id() {
  _vcs_pr_id_numeric "$2" && return 0
  echo "pipeline-vcs: $1: PR id must be numeric (got '${2:-}')" >&2
  exit 1
}

# _vcs_shared_pr_is_draft <n> <json-field> <dry-run-text> <fetch-fn>
# <fetch-fn> is called with <n> and prints the provider's PR JSON.
_vcs_shared_pr_is_draft() {
  local _n="${1:-}" _field="$2" _dry="$3" _fetch="$4" _raw _state
  if ! _vcs_pr_id_numeric "$_n"; then
    echo "pipeline-vcs: pr-is-draft: PR id must be numeric (got '$_n') -- unverified" >&2
    exit 2
  fi
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] $_dry"
    return 0
  fi
  _raw="$("$_fetch" "$_n")" || {
    echo "pipeline-vcs: pr-is-draft: could not fetch PR #$_n -- unverified" >&2
    exit 2
  }
  _state="$(printf '%s' "$_raw" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
v = d.get(sys.argv[1]) if isinstance(d, dict) else None
if v is True:
    print("draft")
elif v is False:
    print("ready")
else:
    sys.exit(2)
' "$_field")" || {
    echo "pipeline-vcs: pr-is-draft: PR #$_n response has no boolean '$_field' -- unverified" >&2
    exit 2
  }
  printf '%s\n' "$_state"
  [ "$_state" = "draft" ] && exit 0
  exit 1
}

# ── Shared: evaluate a set of required checks against their current status ────
# (#205 review follow-up) Every provider's `pr-checks-required` normalizes its
# check data down to "<name><TAB>status" lines
# (status is one of pass|fail|pending) and feeds them here on stdin, so the
# pass/fail/pending decision -- and the "empty required_checks never passes
# vacuously" rule from #195 -- lives in exactly one place.
#
# Usage: printf '<name>\t<status>\n...' | _eval_required_checks "<required checks, newline-separated>"
# Exit codes:
#   0 -- every required check reports pass on the current head
#   1 -- merge.required_checks is empty (never a vacuous pass), OR at least one
#       required check has explicitly failed
#   2 -- no required check has failed, but at least one is pending or missing
#       from the status data (still worth polling again)
# Prints a one-line summary to stderr either way.
_eval_required_checks() {
  local _required="$1"
  python3 -I -c "
import sys

required = [l.strip() for l in sys.argv[1].splitlines() if l.strip()]
if not required:
    print('pr-checks-required: merge.required_checks is empty -- refusing to '
          'vacuously pass (see #195)', file=sys.stderr)
    sys.exit(1)

status = {}
for line in sys.stdin:
    parts = line.rstrip('\n').split('\t')
    if len(parts) >= 2 and parts[0]:
        status[parts[0]] = parts[1]

failed  = [n for n in required if status.get(n) == 'fail']
pending = [n for n in required if status.get(n) != 'pass' and n not in failed]
passed  = [n for n in required if status.get(n) == 'pass']

if failed:
    print('pr-checks-required: failed: ' + ', '.join(failed), file=sys.stderr)
    sys.exit(1)
if pending:
    print('pr-checks-required: pending or missing: ' + ', '.join(pending), file=sys.stderr)
    sys.exit(2)
print('pr-checks-required: all required checks passed: ' + ', '.join(passed), file=sys.stderr)
sys.exit(0)
" "$_required"
}

# ── Retry-with-backoff (#173) ─────────────────────────────────────────────────
# Single point of truth for retry/backoff — the only place this logic lives.
# Every network-facing verb in every adapter routes through it:
#   - _gitlab:     the `glab` shadow function defined at the top of _gitlab()
#   - _azure:      the `az`   shadow function defined at the top of _azure()
#   - _github:     _gh_try, _gh_req, _gh_diff and _gh_pages, via the
#                  _gh_once single-attempt helper (gh and curl alike)
# _file has no network calls and is deliberately not wired up.
#
# Usage: _with_retry <verb-label> <cmd...>
#   Runs <cmd...> once, with its stdout and stderr fully captured (never
#   streamed live) — a retried attempt's output is entirely suppressed, only
#   the final attempt (the one that succeeds, exhausts retries, or fails
#   non-retryably) ever reaches the real stdout/stderr.
#
#   Retryability is decided by one generic check: was $_WR_RETRYABLE set by
#   the attempt, or does the captured stderr match $_RETRY_STDERR_PATTERN?
#     - curl-based *_once helpers (which already parse the real HTTP status
#       code) set $_WR_RETRYABLE=1 themselves whenever that status is 429, or
#       403 with a secondary-rate-limit/abuse-detection body — retryability
#       for these is decided from the status, never by pattern-matching the
#       printed message text.
#     - gh/glab/az shadow functions have no status code to inspect (an
#       external CLI's stderr is all there is), so they fall back to
#       $_RETRY_STDERR_PATTERN — anchored phrases only (e.g. "HTTP 429",
#       "API rate limit exceeded", "secondary rate limit", "abuse detection",
#       "rate limited"), deliberately excluding a bare "429" so an unrelated
#       error that happens to mention an issue/PR number 429 is never
#       misclassified as a rate limit (#194 review).
#   Any other non-zero exit is treated as non-retryable and returned
#   immediately with its real exit code, output, and no delay (401/404/422/etc).
#
#   A retryable attempt may set global $_WR_RETRY_AFTER (seconds) before
#   returning non-zero, to honour a Retry-After/rate-limit hint; otherwise
#   backoff is exponential: 2s, 4s, 8s, ... Both are capped at 60s — an
#   untrusted Retry-After header can never force an arbitrarily long sleep
#   (#194 security). Every sleep is scaled by $TALOS_RETRY_SLEEP_SCALE
#   (default 1; tests set 0 for instant runs) — the scale accepts decimals
#   (e.g. 0.1), computed via awk since bash arithmetic is integer-only; a
#   non-numeric scale is rejected with a warning and the default is used.
#   Total attempts = limits.max_retries (default 5, must be a non-negative
#   integer or the default is used) plus the original try, i.e. up to 6
#   tries by default. --dry-run never reaches this helper: every verb
#   returns before its first network call when $DRY_RUN = true.
_RETRY_STDERR_PATTERN='HTTP 429|API rate limit exceeded|secondary rate limit|abuse detection|rate limited|too many requests'

_with_retry() {
  local _wr_verb="$1"; shift
  local _wr_max _wr_scale _wr_attempt=0 _wr_wait _wr_out _wr_err _wr_rc _wr_err_text
  _wr_max="$(cfg limits.max_retries)"
  case "$_wr_max" in
    ''|*[!0-9]*)
      printf 'pipeline-vcs: limits.max_retries must be a non-negative integer, got %s; using default 5\n' \
        "$_wr_max" >&2
      _wr_max=5
      ;;
  esac
  _wr_scale="${TALOS_RETRY_SLEEP_SCALE:-1}"
  if ! grep -qE '^[0-9]+(\.[0-9]+)?$' <<<"$_wr_scale"; then
    printf 'pipeline-vcs: TALOS_RETRY_SLEEP_SCALE must be a non-negative number, got %s; using default 1\n' \
      "$_wr_scale" >&2
    _wr_scale=1
  fi
  while :; do
    _WR_RETRY_AFTER=""
    _WR_RETRYABLE=""
    _wr_out="$(mktemp)"
    _wr_err="$(mktemp)"
    "$@" >"$_wr_out" 2>"$_wr_err"
    _wr_rc=$?
    _wr_err_text="$(cat "$_wr_err")"

    if [ "$_wr_rc" -eq 0 ]; then
      cat "$_wr_out"
      [ -n "$_wr_err_text" ] && printf '%s\n' "$_wr_err_text" >&2
      rm -f "$_wr_out" "$_wr_err"
      return 0
    fi

    if [ -n "$_WR_RETRYABLE" ] || grep -qiE "$_RETRY_STDERR_PATTERN" <<<"$_wr_err_text"; then
      rm -f "$_wr_out" "$_wr_err"
      _wr_attempt=$((_wr_attempt + 1))
      if [ "$_wr_attempt" -gt "$_wr_max" ]; then
        printf 'pipeline-vcs: %s: rate-limited; exhausted %s retries; last error: %s\n' \
          "$_wr_verb" "$_wr_max" "$_wr_err_text" >&2
        return 1
      fi
      if [ -n "${_WR_RETRY_AFTER:-}" ] && [ "$_WR_RETRY_AFTER" -gt 0 ] 2>/dev/null; then
        _wr_wait="$_WR_RETRY_AFTER"
      else
        _wr_wait=$(( 2 ** _wr_attempt ))
      fi
      [ "$_wr_wait" -gt 60 ] && _wr_wait=60
      printf 'pipeline-vcs: %s: rate-limited, retry %s/%s in %ss\n' \
        "$_wr_verb" "$_wr_attempt" "$_wr_max" "$_wr_wait" >&2
      sleep "$(awk -v w="$_wr_wait" -v s="$_wr_scale" 'BEGIN { printf "%.4f", w * s }')"
      continue
    fi

    cat "$_wr_out"
    [ -n "$_wr_err_text" ] && printf '%s\n' "$_wr_err_text" >&2
    rm -f "$_wr_out" "$_wr_err"
    return "$_wr_rc"
  done
}

# ── Flag-value guard (#455) ──────────────────────────────────────────────────
# A value flag given as the LAST argument used to die on an unbound `$2` (a bash
# error, exit 1). `_vcs_flag_needs_value <flag> <usage>` is exit 2 with a usage
# line instead, as the other verbs' argument checks answer.
_vcs_flag_needs_value() {
  echo "pipeline-vcs: ${VERB:-${_VERB:-?}}: $1 needs a value; Usage: $2" >&2
  exit 2
}

# ── Label arg parser (shared by label-issue / label-pr) ──────────────────────
# Parses [--add <label>]... [--remove <label>]... from $@
# Outputs: ADD_LABELS (space-separated), REMOVE_LABELS (space-separated), and
# the same labels as the arrays ADD_LABEL_ARR / REMOVE_LABEL_ARR, one element per
# label, so a label with a space or a quote survives (the github arm builds its
# argv from these, never an eval'd string). --add / --remove with no value: exit 2.
_parse_label_args() {
  ADD_LABELS=""
  REMOVE_LABELS=""
  ADD_LABEL_ARR=()
  REMOVE_LABEL_ARR=()
  local _pl_usage="${VERB:-${_VERB:-label-issue}} <n> [--add <label>]... [--remove <label>]..."
  while [ $# -gt 0 ]; do
    case "$1" in
      --add|--remove)
        [ $# -ge 2 ] || _vcs_flag_needs_value "$1" "$_pl_usage"
        if [ "$1" = "--add" ]; then
          ADD_LABELS="$ADD_LABELS $2"; ADD_LABEL_ARR+=("$2")
        else
          REMOVE_LABELS="$REMOVE_LABELS $2"; REMOVE_LABEL_ARR+=("$2")
        fi
        shift 2 ;;
      *) ADD_LABELS="$ADD_LABELS $1"; ADD_LABEL_ARR+=("$1"); shift ;;
    esac
  done
  ADD_LABELS="${ADD_LABELS# }"
  REMOVE_LABELS="${REMOVE_LABELS# }"
}

# ── Epic acceptance-checkbox scan (shared by check-epic-acceptance, #168) ────
# Reads an issue body on stdin and looks for GitHub checklist lines of the
# form "- [ ] text" (an unticked box; "- [x]"/"- [X]" are ticked and ignored).
# Exits 0 and prints nothing when zero unticked boxes remain — this includes
# bodies with NO checkboxes at all, since the gate only fires on checkboxes
# that exist (option 2 in issue #168). Exits 1 and prints each unticked box's
# text, one per line, when any remain.
_epic_acceptance_scan() {
  python3 -I -c "
import re, sys
body = sys.stdin.read()
unticked = [m.group(1).strip() for m in re.finditer(r'^\s*-\s*\[\s\]\s*(.*)\$', body, re.MULTILINE)]
if unticked:
    for item in unticked:
        print(item)
    sys.exit(1)
sys.exit(0)
"
}

# ── Spec-present scan (shared by has-spec, #199) ──────────────────────────────
# Reads a view-issue-shaped JSON document ({title, body, labels, comments}) on
# stdin. Exits 0 (issue body already IS a usable spec — PM can be skipped)
# when either:
#   - the issue carries the `spec:ready` label, or
#   - the body has a heading matching "acceptance criteria" (case-insensitive,
#     `#`-prefixed e.g. "## Acceptance criteria" or bold e.g.
#     "**Acceptance criteria**", optional trailing colon) followed — before
#     the next `#`-heading, if any — by at least one `- [ ]` / `- [x]` item.
# Exits 1 (PM should still run) otherwise. Prints nothing either way.
_has_spec_scan() {
  python3 -I -c "
import json, re, sys

d = json.load(sys.stdin)
body = d.get('body') or ''
labels = [l.get('name', '') for l in (d.get('labels') or [])]
if 'spec:ready' in labels:
    sys.exit(0)

def is_heading(line):
    s = line.strip()
    if s.startswith('#'):
        s = s.lstrip('#').strip()
    elif s.startswith('**') and s.endswith('**') and len(s) > 4:
        s = s[2:-2].strip()
    else:
        return False
    return s.rstrip(':').strip().lower() == 'acceptance criteria'

lines = body.splitlines()
heading_idx = next((i for i, l in enumerate(lines) if is_heading(l)), None)
if heading_idx is None:
    sys.exit(1)

checkbox_re = re.compile(r'^\s*-\s*\[[ xX]\]\s*\S')
for line in lines[heading_idx + 1:]:
    if line.strip().startswith('#'):
        break
    if checkbox_re.match(line):
        sys.exit(0)
sys.exit(1)
"
}

# ── JSON array length (shared by list-issues/list-prs cap-warning checks) ────
# Reads a JSON document on stdin; prints its element count if it parses as a
# JSON array, else 0. Never fails the caller — malformed/non-JSON input
# degrades to "0" (no cap warning fires), which is the safe default for
# providers whose list output isn't guaranteed to be JSON (#171).
_json_array_count() {
  python3 -I -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(len(d) if isinstance(d, list) else 0)
except Exception:
    print(0)
"
}

# _json_array_len: like _json_array_count, but exits non-zero when stdin is
# not a JSON array -- for callers where "unreadable" must not read as empty
# (#319).
_json_array_len() {
  python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    d = None
if not isinstance(d, list):
    sys.exit("pipeline-vcs: expected a JSON array")
print(len(d))
'
}

# ── Cap-reached warning (shared by every provider that still caps list-issues
# /list-prs instead of paginating: gitlab, azure — github/github-api now
# paginate those fully; github's find-pr still caps at --limit, #302) ────────
# Usage: _list_cap_warn <verb> <cap> <count> <reason> <noun>
# Prints a loud stderr warning naming the exact cap when <count> == <cap>,
# since landing exactly on a request cap means more items may exist beyond
# what was fetched — truncation must never be silent (#171).
_list_cap_warn() {
  local _lcw_verb="$1" _lcw_cap="$2" _lcw_count="$3" _lcw_reason="$4" _lcw_noun="$5"
  if [ "$_lcw_count" = "$_lcw_cap" ]; then
    printf 'pipeline-vcs: %s: WARNING result capped at %s (%s) -- some %s may be missing\n' \
      "$_lcw_verb" "$_lcw_cap" "$_lcw_reason" "$_lcw_noun" >&2
  fi
}

# ── gh api --paginate multi-page merge (gitlab, azure) ───────────────────────
# `gh api --paginate <endpoint>` fetches every page of a REST list endpoint
# (following Link: rel="next" headers internally) with NO cap, but per gh's
# own --help text: "Each page is a separate JSON array or object" — pages are
# written to stdout back-to-back with no separator, not merged into one
# array. Reads that raw concatenated stdout on stdin and prints a single
# flattened JSON array containing every item from every page, in order.
_gh_paginate_merge() {
  python3 -I -c "
import json, sys
data = sys.stdin.read()
dec = json.JSONDecoder()
idx, n, items = 0, len(data), []
while idx < n:
    while idx < n and data[idx].isspace():
        idx += 1
    if idx >= n:
        break
    obj, idx = dec.raw_decode(data, idx)
    items.extend(obj) if isinstance(obj, list) else items.append(obj)
print(json.dumps(items))
"
}

# ── REST comment normaliser (shared by read-comments, github and github-api,
# #177 slice 5) ───────────────────────────────────────────────────────────
# stdin: a raw REST comments array (GitHub's "user" field per comment).
# Prints {"comments": [...]}, each comment's author normalised to
# {"login": ...} (accepting either 'user' -- the REST shape -- or 'author'
# -- gh's own GraphQL shape -- so this also tolerates being handed an
# already-normalised list) and createdAt copied from created_at/createdAt.
# Both adapters hand-duplicated this exact python block in their own
# read-comments arm before this slice; extracted here so it is defined once.
_vcs_shared_normalize_comments() {
  python3 -I -c "
import json, sys

def _login(c):
    # REST payloads carry 'user'; some fixtures/older shapes carry 'author'
    # directly (gh's own --json comments GraphQL shape) -- accept either.
    u = c.get('user')
    if isinstance(u, dict) and u.get('login'):
        return u.get('login')
    a = c.get('author')
    return a.get('login', '') if isinstance(a, dict) else ''

# An error object, a bare scalar or an unparseable page is a failed read, never
# an empty comment list (the github-api paginator rejects a non-array page the
# same way); a non-object entry is just as malformed. Fail loudly, no stdout.
try:
    raw = json.load(sys.stdin)
except ValueError:
    sys.exit('pipeline-vcs: read-comments: response is not valid JSON')
if not isinstance(raw, list):
    sys.exit('pipeline-vcs: read-comments: response is not a JSON array of comments')
if not all(isinstance(c, dict) for c in raw):
    sys.exit('pipeline-vcs: read-comments: response holds a non-object comment entry')
comments = [dict(c, author={'login': _login(c)},
                  createdAt=c.get('created_at', c.get('createdAt', ''))) for c in raw]
json.dump({'comments': comments}, sys.stdout)
"
}

# ── Compact spec-only comment filter (shared by view-issue --spec, github and
# github-api, #201) ───────────────────────────────────────────────────────────
# $1: issue metadata JSON ({"title", "body", "labels"}).
# $2: a read-comments-shaped JSON document ({"comments": [...]}), each comment
#     carrying at least a "body" field -- the exact shape both providers'
#     read-comments verb already returns, so this needs no new fetch.
# Prints a view-issue-shaped JSON document ({title, body, labels, comments})
# whose comments list holds at most one entry: the latest surviving comment
# whose body starts with "**PM spec:**". Every comment containing a
# "<!-- talos:" marker and every stage-verdict comment (body starting with
# "**Agent:**") is dropped before that scan. A plain human comment survives
# the marker/verdict filter but is still excluded from the result -- it never
# starts with "**PM spec:**" -- since the spec comment is the contract each
# stage implements against, not the discussion around it.
_vi_spec_filter() {
  python3 -I -c "
import json, sys

meta = json.loads(sys.argv[1])
comments = json.loads(sys.argv[2]).get('comments', [])
if not isinstance(comments, list):
    comments = []

def body_of(c):
    return c.get('body') or ''

def is_marker(c):
    return '<!-- talos:' in body_of(c)

def is_verdict(c):
    return body_of(c).lstrip().startswith('**Agent:**')

def is_spec(c):
    return body_of(c).lstrip().startswith('**PM spec:**')

candidates = [c for c in comments if not is_marker(c) and not is_verdict(c)]
spec_comments = [c for c in candidates if is_spec(c)]
kept = [spec_comments[-1]] if spec_comments else []

result = {
    'title': meta.get('title', ''),
    'body': meta.get('body') or '',
    'labels': meta.get('labels', []),
    'comments': kept,
}
print(json.dumps(result))
" "$1" "$2"
}

# ── Delta comment filter (view-issue --since-stage, #548) ─────────────────────
# $1: issue metadata JSON, $2: a read-comments-shaped JSON document, as for
# _vi_spec_filter. Prints {title, body, labels, comments, earlier_comments}.
# A stage comment (body starting "**PM spec:**" or "**Agent:**", the same
# prefixes _vi_spec_filter keys on) marks how far the pipeline has read; the
# latest one is the boundary. comments is the boundary comment itself (what the
# last stage found or asked) plus every non-marker comment after it; with no stage
# comment yet, every human comment. So an owner's clarification posted since the
# last stage is always there. earlier_comments counts the human comments before
# the boundary, which `read-comments` still returns.
_vi_delta_filter() {
  python3 -I -c "
import json, sys

meta = json.loads(sys.argv[1])
comments = json.loads(sys.argv[2]).get('comments', [])
if not isinstance(comments, list):
    comments = []

def body_of(c):
    return (c.get('body') or '').lstrip()

def is_stage(c):
    b = body_of(c)
    return b.startswith('**Agent:**') or b.startswith('**PM spec:**')

def is_human(c):
    return not is_stage(c) and '<!-- talos:' not in body_of(c)

cut = -1
for i, c in enumerate(comments):
    if is_stage(c):
        cut = i

print(json.dumps({
    'title': meta.get('title', ''),
    'body': meta.get('body') or '',
    'labels': meta.get('labels', []),
    'comments': [c for i, c in enumerate(comments) if i >= cut and (i == cut or is_human(c))],
    'earlier_comments': sum(1 for c in comments[:cut + 1] if is_human(c)),
}))
" "$1" "$2"
}

# ── diff --stat formatting (shared by diff-pr --stat, github and github-api,
# #201) ────────────────────────────────────────────────────────────────────────
# Reads a JSON array of {"filename", "additions", "deletions"} on stdin (the
# shape both providers' PR-files endpoint already returns -- the same data
# pr-files (#200) consumes) and prints a `git diff --stat`-style summary: one
# " <path> | +<additions> -<deletions>" line per file, then a
# "<n> files changed, <a> insertions(+), <d> deletions(-)" total line.
_diff_stat_format() {
  python3 -I -c "
import json, sys

try:
    files = json.load(sys.stdin)
except Exception:
    files = []
if not isinstance(files, list):
    files = []

lines = []
total_add = total_del = 0
for f in files:
    path = f.get('filename', '')
    if not path:
        continue
    add = int(f.get('additions', 0) or 0)
    dele = int(f.get('deletions', 0) or 0)
    total_add += add
    total_del += dele
    lines.append(f' {path} | +{add} -{dele}')

noun = 'file' if len(lines) == 1 else 'files'
lines.append(f' {len(lines)} {noun} changed, {total_add} insertions(+), {total_del} deletions(-)')
print('\n'.join(lines))
"
}

# ─────────────────────────────────────────────────────────────────────────────
# SHARED ATTEMPT/APPROVAL MARKER HELPERS (#177 slice 1)
#   Provider-independent marker-parsing logic. Each adapter owns its own fetch
#   and write; everything downstream of "already-normalised JSON in hand"
#   lives here, defined exactly once, so the adapters cannot drift on regexes,
#   ceiling math, or message wording again.
#
#   Where the two adapters previously drifted on wording (an em dash vs a
#   double hyphen), this refactor keeps the `_github` adapter's original
#   wording throughout (both read equally well; picking one avoids a second,
#   silent choice being made per call site).
# ─────────────────────────────────────────────────────────────────────────────

# _vcs_shared_read_attempt
#   stdin:  normalised comments JSON, {"comments":[{"author":{"login":...},
#           "body":...}, ...]} -- the shape the `read-comments` verb produces.
#   env:    TRUSTED_AUTHORS, TALOS_CFG -- same contract read-attempt has
#           always used. VERIFY_AUTHORS, CURRENT_USER (#187) -- effective
#           trust set is TRUSTED_AUTHORS ∪ {CURRENT_USER} when
#           VERIFY_AUTHORS is not "false" and CURRENT_USER is non-empty;
#           VERIFY_AUTHORS defaults to "true" when unset. CURRENT_USER_REFUSED
#           (#453) -- "1" when the GET /user lookup ran and was refused: only
#           TRUSTED_AUTHORS counts then, and an empty list rejects every
#           marker (fail closed) with one stderr line saying how to fix it.
#           TALOS_CONTRACT_ROLES_ENV (#178) -- KNOWN_STAGES, derived from
#           scripts/pipeline-contract.sh's TALOS_ROLES.
#   stdout: "stage=<s> count=<k> total=<t>[ key=<tok>]" (or "stage= count=0
#           total=0" when no marker exists), preceded by any
#           `talos:marker-authors-unverified` passthrough line.
#   stderr: one `talos:marker-authors-rejected authors=<comma list>` line
#           when the trust set is enforced and at least one marker was
#           skipped for having an untrusted author (#187).
#   exit:   0 normally; 1 when stdin is unparseable or the most recent
#           marker is present but corrupt/unrecognised (fail-closed --
#           corrupt markers never silently fall through to zero attempts).
_vcs_shared_read_attempt() {
  _vcs_shared_contract_env
  python3 -I -c "$(_vcs_shared_trust_py)
import json, os, re, sys

# Stage-1 permissive detector: matches any HTML comment that looks like it
# could be a talos:attempt marker.  Used to distinguish 'no marker present'
# (safe) from 'marker present but unparseable' (corrupt → fail-closed).
LOOSE_RE = re.compile(r'<!--\s*talos:attempt\b[^>]*-->')

# Stage-2 strict extractor: only matches a syntactically valid marker.
# Group 4 (key=<token>) is optional (#172 --idempotency-key); pre-existing
# markers without it continue to parse unchanged.
MARKER_RE = re.compile(
    r'<!--\s*talos:attempt\s+stage=(\S+)\s+count=(\d+)\s+total=(\d+)'
    r'(?:\s+key=([A-Za-z0-9._-]+))?\s*-->$',
    re.MULTILINE
)
# Single source of truth: scripts/pipeline-contract.sh's TALOS_ROLES,
# passed in via TALOS_CONTRACT_ROLES_ENV (#178) -- never hand-restate the
# role list here.
KNOWN_STAGES = set(os.environ.get('TALOS_CONTRACT_ROLES_ENV', '').split())

# Author trust set (#187), parsed by _vcs_shared_trust_py (one definition for
# every reader): markers.trusted_authors unioned with the authenticated user
# when markers.verify_authors is not explicitly false and that identity
# resolved. When neither is available: fail-open, once per invocation, with
# the pre-#187 warning -- unless verify_authors is explicitly false, which
# fails open silently (opt-out).
verify_authors, effective_trusted = load_trust()
author_check_active = author_check_enforced(verify_authors, effective_trusted)
warn_identity_refused('read-attempt', verify_authors, effective_trusted)
fail_open_warned = False
rejected_authors_seen = []
_config_parse_failed_ra = config_parse_failed()

try:
    data = json.load(sys.stdin)
except Exception as exc:
    print(f'pipeline-vcs: read-attempt: could not parse issue data: {exc}', file=sys.stderr)
    sys.exit(1)

raw_comments = data.get('comments', [])

# GitHub returns comments oldest-first; search newest-first for the last marker.
found = None
for c in reversed(raw_comments):
    body   = c.get('body', '')
    author = c.get('author', {}).get('login', '') if isinstance(c.get('author'), dict) else ''

    # Require the marker to appear as the last non-whitespace line of the comment
    # body, so a quoted/fenced occurrence cannot win.
    last_line = body_last_line(body)

    # INVARIANT (issue #79): last-line check is unconditional — MUST precede
    # author_check_active block. Reordering these two sections silently reopens
    # the quoted-marker bypass. Do not move the lines below past author_check_active.
    # Stage 1: does this line look at all like a talos:attempt marker?
    if not LOOSE_RE.search(last_line):
        continue  # not a marker line — skip to next comment

    # Author trust check (#187): only when verify_authors resolved a
    # non-empty effective trust set (an explicit list and/or the current
    # user).
    if author_check_active:
        if author not in effective_trusted:
            if author not in rejected_authors_seen:
                rejected_authors_seen.append(author)
            continue  # skip; keep searching older comments
    elif verify_authors:
        # No explicit list AND no resolved identity — fail open, once per
        # invocation, exactly as an unset markers.trusted_authors always has.
        if not fail_open_warned:
            print('talos:marker-authors-unverified reader=read-attempt')
            if _config_parse_failed_ra:
                print(
                    'pipeline-vcs: read-attempt: [warn] markers.trusted_authors not configured '
                    '-- config file could not be parsed (see pipeline-config warning); '
                    'any commenter\'s marker is accepted',
                    file=sys.stderr,
                )
            else:
                print(
                    'pipeline-vcs: read-attempt: [warn] markers.trusted_authors not configured '
                    '— author check skipped',
                    file=sys.stderr,
                )
            fail_open_warned = True
    # else: markers.verify_authors is explicitly false — silent fail-open,
    # no warning (#187 opt-out).

    # Stage 2: the line IS marker-like; it must parse exactly or it is corrupt.
    # Corrupt markers NEVER fall through to zero — that would grant infinite retries.
    m = MARKER_RE.match(last_line)
    if not m:
        print(
            f'pipeline-vcs: read-attempt: corrupt marker (does not parse): '
            f'{last_line!r} — fail-closed',
            file=sys.stderr,
        )
        sys.exit(1)

    stage, count_str, total_str, key_val = m.group(1), m.group(2), m.group(3), m.group(4)
    # Semantic validation: stage must be known, values non-negative, count <= total.
    if stage not in KNOWN_STAGES:
        print(f'pipeline-vcs: read-attempt: unrecognised stage \"{stage}\" in marker — fail-closed', file=sys.stderr)
        sys.exit(1)
    count_val = int(count_str)
    total_val = int(total_str)
    if count_val < 0 or total_val < 0:
        print('pipeline-vcs: read-attempt: negative value in marker — fail-closed', file=sys.stderr)
        sys.exit(1)
    if total_val < count_val:
        print('pipeline-vcs: read-attempt: total < count in marker — fail-closed', file=sys.stderr)
        sys.exit(1)
    found = (stage, count_val, total_val, key_val or '')
    break

# One machine-readable line per invocation (#187), never one per marker --
# a PR/issue with several untrusted-author markers would otherwise spam
# stderr with a near-duplicate line per marker.
if rejected_authors_seen:
    print('talos:marker-authors-rejected authors=' + ','.join(rejected_authors_seen), file=sys.stderr)

if found:
    stage, count_val, total_val, key_val = found
    if key_val:
        print(f'stage={stage} count={count_val} total={total_val} key={key_val}')
    else:
        print(f'stage={stage} count={count_val} total={total_val}')
else:
    # No marker detected at all — treat as zero attempts (deliberate, not accidental).
    print('stage= count=0 total=0')
sys.exit(0)
"
}

# _vcs_shared_contract_env (#178)
#   Sources scripts/pipeline-contract.sh (via $SCRIPT_DIR, which every real
#   invocation of this script sets at the top, and which
#   tests/test-vcs-shared-markers.sh sets by hand before `eval`-ing this
#   function range in isolation) and derives the env vars the embedded
#   python3 blocks below read: TALOS_CONTRACT_ROLES_ENV (KNOWN_STAGES) and
#   TALOS_CONTRACT_APPROVAL_ENV (APPROVAL_LABELS/VALID_ROLES, "label=role"
#   pairs). Called at the top of every shared helper that needs them --
#   defined here, in the shared-helper block, rather than only at
#   top-of-script, so it still works when only this function range is
#   loaded. Side-effect-free to call more than once per process.
_vcs_shared_contract_env() {
  if [ -f "${SCRIPT_DIR:-}/pipeline-contract.sh" ]; then
    . "$SCRIPT_DIR/pipeline-contract.sh"
  elif [ "${TALOS_ROLES+set}" != "set" ]; then
    TALOS_ROLES=(developer qa reviewer security docs validator pm orchestrator planner)
    TALOS_APPROVAL_ROLES=(qa reviewer security docs)
    TALOS_APPROVAL_LABELS=("qa:pass|" "review:approved|" "security:approved|" "docs:done|")
  fi
  TALOS_CONTRACT_ROLES_ENV="${TALOS_ROLES[*]}"
  local _cev_i _cev_label _cev_pairs=""
  for _cev_i in "${!TALOS_APPROVAL_ROLES[@]}"; do
    _cev_label="${TALOS_APPROVAL_LABELS[$_cev_i]%%|*}"
    _cev_pairs="$_cev_pairs ${_cev_label}=${TALOS_APPROVAL_ROLES[$_cev_i]}"
  done
  TALOS_CONTRACT_APPROVAL_ENV="${_cev_pairs# }"
  export TALOS_CONTRACT_ROLES_ENV TALOS_CONTRACT_APPROVAL_ENV
}

# _vcs_shared_trust_py (#453)
#   Prints the python source every marker reader runs first (read-attempt,
#   check-approval-sha, the needs-owner reader): `python3 -I -c "$(_vcs_shared_trust_py)
#   ...the reader..."`. It is the one definition of the author trust set and of
#   what a Talos-written comment looks like, so the readers cannot drift apart.
#     load_trust()           -> (verify_authors, effective_trusted): the
#                               TRUSTED_AUTHORS list (JSON array, or one login
#                               per line) plus the CURRENT_USER login, the
#                               latter only when VERIFY_AUTHORS is not false.
#                               VERIFY_AUTHORS defaults to true when unset.
#     author_check_enforced(verify, trusted) -> whether the author check runs:
#                               a non-empty set, or CURRENT_USER_REFUSED=1 (the
#                               GET /user lookup ran and was refused; see
#                               _vcs_shared_current_user), in which case only
#                               markers.trusted_authors counts and an empty
#                               list rejects every marker.
#     warn_identity_refused(reader, verify, trusted) -> the one stderr line
#                               for that empty-list case, saying how to fix it.
#     config_parse_failed()  -> True when TALOS_CFG exists but does not parse (json only, #526).
#     body_last_line(body)   -> the last non-whitespace line, stripped; a
#                               marker only counts there, so a quoted or
#                               fenced one cannot win.
#     is_talos_comment(body) -> True for a comment Talos wrote or quoted: any
#                               `<!-- talos:` marker text, or an `**Agent:**`
#                               header. Such a comment is never a human reply.
_vcs_shared_trust_py() {
  cat <<'TALOS_PY_Vt4wQ9nHc2Rz'
import json, os, pathlib, sys

def load_trust():
    raw = os.environ.get('TRUSTED_AUTHORS', '').strip()
    trusted = []
    if raw:
        try:
            parsed = json.loads(raw)
            if not isinstance(parsed, list):
                raise ValueError('not a list')
            trusted = [str(a).strip() for a in parsed if str(a).strip()]
        except Exception:
            trusted = [a.strip() for a in raw.splitlines() if a.strip()]
    verify = os.environ.get('VERIFY_AUTHORS', 'true').strip().lower() not in ('false', '0', 'no', 'off')
    current = os.environ.get('CURRENT_USER', '').strip()
    if verify and current and current not in trusted:
        trusted.append(current)
    return verify, trusted

def identity_refused():
    # CURRENT_USER_REFUSED=1: the GET /user lookup ran and was refused (an
    # Actions GITHUB_TOKEN, a GitHub App token) or answered with no login.
    return os.environ.get('CURRENT_USER_REFUSED', '') == '1'

def author_check_enforced(verify, trusted):
    # True when the author check must run: a non-empty trust set, or a refused
    # identity lookup -- that is not "no identity check configured", so it
    # trusts markers.trusted_authors ONLY and an empty list rejects everything.
    return verify and (bool(trusted) or identity_refused())

def warn_identity_refused(reader, verify, trusted):
    if verify and not trusted and identity_refused():
        print('pipeline-vcs: ' + reader + ': [warn] the authenticated-user lookup (GET /user) was refused and '
              'markers.trusted_authors is not set -- every marker is rejected (fail closed). A GitHub Actions '
              'GITHUB_TOKEN or a GitHub App token cannot call it: set markers.trusted_authors to the logins that '
              'post Talos markers (e.g. github-actions[bot]).', file=sys.stderr)

def config_parse_failed():
    # Config-parse-failed detection for the marker-authors-unverified message (#116).
    # JSON only (#526): the config parser is json, like the loader's.
    cfg = os.environ.get('TALOS_CFG', '')
    if not cfg or not pathlib.Path(cfg).exists():
        return False
    try:
        json.load(open(cfg))
    except Exception:
        return True
    return False

def body_last_line(body):
    return body.rstrip().rsplit('\n', 1)[-1].strip()

def is_talos_comment(body):
    return '<!-- talos:' in body or body.lstrip().startswith('**Agent:**')
TALOS_PY_Vt4wQ9nHc2Rz
}

# _vcs_shared_valid_login <login>
#   0 when <login> is shaped like a GitHub login: letters and digits with
#   single inner hyphens (at most 39 before any underscore), then at most one
#   `_<shortcode>` suffix (an Enterprise Managed User, e.g. `octocat_acme`),
#   then an optional `[bot]` (an app). Anything else -- empty, spaces, the raw
#   error JSON `gh api --jq` prints when GET /user is refused -- is not a login.
_vcs_shared_valid_login() {
  local _vl_re='^[A-Za-z0-9](-?[A-Za-z0-9])*(_[A-Za-z0-9]{1,39})?$' _vl_base="${1%"[bot]"}" _vl_handle
  # An Azure DevOps identity is a user principal name, `name@domain.tld` (#560):
  # `az account show --query user.name` prints one, so current-user and a claim
  # must accept it. A single @, no spaces, quotes or braces.
  local _vl_upn='^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
  if [[ "$1" =~ $_vl_upn ]] && [ "${#1}" -le 254 ]; then return 0; fi
  [[ "$_vl_base" =~ $_vl_re ]] || return 1
  _vl_handle="${_vl_base%%_*}"
  [ "${#_vl_handle}" -le 39 ]
}

# _vcs_shared_current_user <fail-open|fail-closed> <resolver-cmd> [args...]
#   Resolves and caches, once per process, the authenticated user's login
#   (#187) -- markers.verify_authors' "infer the current user as trusted"
#   half. The adapters keep owning their own fetch mechanics: _github calls this
#   as `_vcs_shared_current_user fail-open _gh_user_login` (a thin REST wrapper
#   next to the other _gh_* helpers). This
#   function owns the caching and the check of what came back (#453), and
#   tells three outcomes apart:
#     ok           the resolver exited 0 and its first line passes
#                  _vcs_shared_valid_login;
#     unavailable  it was not looked up: exit 127 (the command is not there) or
#                  exit 0 with nothing printed;
#     refused      it ran and failed: any other non-zero exit (the 403/401 of an
#                  Actions GITHUB_TOKEN or a GitHub App token), or exit 0 with a
#                  first line that is not a login (the raw error JSON `gh api
#                  --jq` prints). Never a trusted name.
#   stdout: the login for `ok`, else the empty string.
#   exit:   0 for `ok`. Otherwise by mode:
#           fail-open   0 for `unavailable`, 3 for `refused`. A reader treats
#                       `unavailable` as "identity unresolved" and degrades
#                       exactly as an unset markers.trusted_authors already
#                       does; on 3 it must trust markers.trusted_authors ONLY
#                       (an empty list rejects every marker), because a refused
#                       lookup is not the absence of an identity check.
#                       Best-effort callers (assign-issue) ignore the code.
#           fail-closed 1 for either (a write that must be made as that user,
#                       e.g. upsert-pr-comment, refuses).
#
#   Caching mirrors pipeline-cfg-cache.sh's cfg(): most call sites run
#   inside a `$(...)` command-substitution subshell, so a bare shell
#   variable set *inside* this function on a first call is invisible to a
#   second call made from a *different* subshell -- only a file on disk
#   (read/written identically by every subshell) survives across them.
#   Reuses the per-invocation cfg-cache directory (_CFG_CACHE_DIR, created
#   once at script start by pipeline-cfg-cache.sh) for that file when
#   available; the in-memory variable alone still makes repeat calls within
#   the same subshell free even when it is not. Both hold `<outcome>:<login>`.
_vcs_shared_current_user() {
  local _cu_mode="${1:-}"
  case "$_cu_mode" in
    fail-open|fail-closed) shift ;;
    *) echo "pipeline-vcs: internal error: _vcs_shared_current_user needs fail-open or fail-closed, got '$_cu_mode'" >&2; return 2 ;;
  esac
  local _cu_cache_file="" _cu_entry="" _cu_out _cu_rc
  [ -n "${_CFG_CACHE_DIR:-}" ] && _cu_cache_file="$_CFG_CACHE_DIR/current-user"
  if [ -n "${_VCS_CURRENT_USER_RESOLVED:-}" ]; then
    _cu_entry="${_VCS_CURRENT_USER_VALUE:-}"
  elif [ -n "$_cu_cache_file" ] && [ -f "$_cu_cache_file" ]; then
    _cu_entry="$(cat "$_cu_cache_file")"
  else
    _cu_out="$("$@" 2>/dev/null)"; _cu_rc=$?
    # First line, ends trimmed; inner whitespace stays so "bad login" is refused, not repaired.
    _cu_out="$(printf '%s\n' "$_cu_out" | head -1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ "$_cu_rc" -eq 127 ]; then
      _cu_entry="unavailable:"
    elif [ "$_cu_rc" -ne 0 ]; then
      _cu_entry="refused:"
    elif [ -z "$_cu_out" ]; then
      _cu_entry="unavailable:"
    elif _vcs_shared_valid_login "$_cu_out"; then
      _cu_entry="ok:$_cu_out"
    else
      _cu_entry="refused:"
    fi
    [ -n "$_cu_cache_file" ] && printf '%s' "$_cu_entry" > "$_cu_cache_file" 2>/dev/null
  fi
  _VCS_CURRENT_USER_VALUE="$_cu_entry"
  _VCS_CURRENT_USER_RESOLVED=1
  case "$_cu_entry" in
    ok:?*) printf '%s' "${_cu_entry#ok:}"; return 0 ;;
    refused:*) [ "$_cu_mode" = "fail-open" ] && return 3; return 1 ;;
    *) [ "$_cu_mode" = "fail-open" ] && return 0; return 1 ;;
  esac
}

# _vcs_shared_print_current_user <resolver-cmd> [args...]
#   The `current-user` verb (#466): print the authenticated login through the
#   cached _vcs_shared_current_user. Exit 0 with the login; 1 when no identity
#   was resolved (the lookup was not possible); 3 when it ran and was refused
#   (an Actions GITHUB_TOKEN or a GitHub App token), the same two outcomes the
#   marker readers tell apart.
_vcs_shared_print_current_user() {
  local _pc_user _pc_rc=0
  _pc_user="$(_vcs_shared_current_user fail-open "$@")" || _pc_rc=$?
  [ "$_pc_rc" -eq 0 ] || return 3
  [ -n "$_pc_user" ] || return 1
  printf '%s\n' "$_pc_user"
}

# _vcs_shared_reader_identity <verify_authors> <resolver-cmd> [args...]
#   For the readers that take a trust set (read-attempt, check-approval-sha):
#   sets _RID_USER (the login, or empty) and _RID_REFUSED (1 when the lookup
#   ran and was refused or returned something that is not a login, else
#   empty). Nothing is looked up unless <verify_authors> is "true".
_vcs_shared_reader_identity() {
  local _ri_verify="$1"; shift
  _RID_USER=""; _RID_REFUSED=""
  [ "$_ri_verify" = "true" ] || return 0
  _RID_USER="$(_vcs_shared_current_user fail-open "$@")" || _RID_REFUSED=1
  return 0
}

# ── Needs-owner label + marker verbs (#345, epic #333) ──────────────────────
# `mark-needs-owner` / `list-needs-owner`: park a pending owner decision on
# GitHub as the label pipeline:needs-owner plus a marker comment whose last
# line is `<!-- talos:needs-owner -->`, and read it back from any later
# session. The adapter supplies only its provider calls (the _gh_no_* helpers);
# the comment reader is this script's own `read-comments`.
#
# Everything read from GitHub (comment bodies, logins, the question text) is
# untrusted data. It is parsed by python3 -I from stdin or a file, never
# reaches a shell, eval, a regex built from it or a format string, and the
# only text printed is the sanitised `question` (one line, no control
# characters, at most 200 characters).
_TALOS_NEEDS_OWNER_LABEL="pipeline:needs-owner"
_TALOS_NEEDS_OWNER_LABEL_URL="pipeline%3Aneeds-owner"   # the label as a URL path segment

# _vcs_needs_owner_py <mode> <verb> [args...]   (payload on stdin)
#   render    stdin: the text. Prints the comment body: text, blank line, the
#             marker (a text already ending in the marker line is not marked
#             twice). Exit 3 when the text is empty.
#   mark-check <file>   stdin: read-comments JSON; <file>: the rendered body.
#             Prints `same` when the newest trusted marker comment has the same
#             body and is still unanswered, else `new`.
#   collect <script> <label>   stdin: a REST issues array. For each open item
#             carrying <label> it runs `bash <script> read-comments <n>`
#             (argv list, no shell) and prints one JSON object
#             {unverified, records: [{n, kind, answered, question}, ...]}
#             sorted by n; `unverified` is true when any item was read with no
#             resolved trust set. Any failure exits 1 with nothing on stdout.
#   format <text|json>   stdin: the collect object. Prints the listing.
#   answered  stdin: the collect object. Prints the n of every answered item;
#             exits 1, printing nothing, when `unverified` (#453): a listing
#             may fail open, a label removal may not.
# The trust set is _vcs_shared_trust_py's load_trust(), the one every marker
# reader uses. TRUSTED_AUTHORS, VERIFY_AUTHORS and CURRENT_USER come from env.
_vcs_needs_owner_py() {
  python3 -I -c "$(_vcs_shared_trust_py)"'
import re, subprocess, unicodedata

MARKER = "<!-- talos:needs-owner -->"
MARKER_RE = re.compile(r"^<!--\s*talos:needs-owner\s*-->$")
mode, verb = sys.argv[1], sys.argv[2]

def emit(text):
    sys.stdout.buffer.write(text.encode("utf-8", errors="replace"))

def read_stdin():
    return sys.stdin.buffer.read().decode("utf-8", errors="replace")

def die(msg):
    sys.stderr.write("pipeline-vcs: " + verb + ": " + msg + "\n")
    sys.exit(1)

def clean(text, limit):
    out = []
    for ch in text:
        cat = unicodedata.category(ch)
        if ch.isspace() or cat in ("Zs", "Zl", "Zp"):
            out.append(" ")
        elif cat[0] != "C":
            out.append(ch)
    return " ".join("".join(out).split())[:limit].strip()

def strip_marker(text):
    lines = [l.rstrip("\r") for l in text.rstrip().split("\n")]
    if lines and MARKER_RE.match(lines[-1].strip()):
        lines.pop()
    return "\n".join(lines).strip()

def body_of(c):
    b = c.get("body")
    return b if isinstance(b, str) else ""

def login_of(c):
    a = c.get("author")
    l = a.get("login") if isinstance(a, dict) else ""
    return l if isinstance(l, str) else ""

def is_reply(c):
    b = body_of(c)
    return bool(b.strip()) and not is_talos_comment(b)

def analyze(comments):
    verify, trusted = load_trust()
    active = verify and bool(trusted)
    def ok(c):
        return (not active) or login_of(c) in trusted
    res = {"marker": False, "body": "", "answered": False,
           "question": "(no marker comment)",
           "unverified": verify and not trusted, "rejected": []}
    idx = None
    for i in range(len(comments) - 1, -1, -1):
        c = comments[i]
        if not MARKER_RE.match(body_last_line(body_of(c))):
            continue
        if not ok(c):
            a = re.sub(r"[^A-Za-z0-9_.\[\]-]", "", login_of(c))
            if a not in res["rejected"]:
                res["rejected"].append(a)
            continue
        idx = i
        break
    if idx is None:
        return res
    res["marker"] = True
    res["body"] = strip_marker(body_of(comments[idx]))
    res["answered"] = any(is_reply(c) and ok(c) for c in comments[idx + 1:])
    res["question"] = "(empty marker comment)"
    for line in res["body"].split("\n"):
        s = line.strip()
        if s.startswith("**Agent:**"):
            continue
        q = clean(s, 200)
        if q:
            res["question"] = q
            break
    return res

def warn(unverified, rejected):
    if unverified:
        sys.stderr.write("talos:marker-authors-unverified reader=needs-owner\n")
        sys.stderr.write("pipeline-vcs: " + verb + ": [warn] markers.trusted_authors not configured and no authenticated identity resolved -- author check skipped\n")
    if rejected:
        sys.stderr.write("talos:marker-authors-rejected authors=" + ",".join(rejected) + "\n")

def comments_of(doc):
    cs = doc.get("comments") if isinstance(doc, dict) else None
    if not isinstance(cs, list):
        die("comments are not a list")
    return [c for c in cs if isinstance(c, dict)]

if mode == "render":
    text = strip_marker(read_stdin())
    if not text:
        sys.exit(3)
    emit(text + "\n\n" + MARKER + "\n")
elif mode == "mark-check":
    try:
        comments = comments_of(json.loads(read_stdin()))
        with open(sys.argv[3], "rb") as f:
            new_body = strip_marker(f.read().decode("utf-8", errors="replace"))
    except (ValueError, OSError):
        die("could not parse the comments")
    res = analyze(comments)
    warn(res["unverified"], res["rejected"])
    emit("same" if res["marker"] and not res["answered"] and res["body"] == new_body else "new")
elif mode == "collect":
    script, label = sys.argv[3], sys.argv[4]
    try:
        items = json.loads(read_stdin())
        if not isinstance(items, list):
            raise ValueError("not a list")
    except ValueError:
        die("could not parse the issue listing; nothing listed")
    found = {}
    for it in items:
        if not isinstance(it, dict):
            die("unexpected entry in the issue listing; nothing listed")
        n = it.get("number")
        if isinstance(n, bool) or not isinstance(n, int):
            die("an issue listing entry has no number; nothing listed")
        names = [l.get("name") for l in (it.get("labels") or []) if isinstance(l, dict)]
        if label in names and str(it.get("state", "open")).lower() != "closed":
            found[n] = "pr" if it.get("pull_request") is not None else "issue"
    records, unverified, rejected = [], False, []
    for n in sorted(found):
        r = subprocess.run(["bash", script, "read-comments", str(n)], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if r.returncode != 0:
            die("could not fetch the comments of #%d (%s); nothing listed" % (n, clean(r.stderr.decode("utf-8", errors="replace"), 200)))
        try:
            comments = comments_of(json.loads(r.stdout.decode("utf-8", errors="replace")))
        except ValueError:
            die("could not parse the comments of #%d; nothing listed" % n)
        res = analyze(comments)
        unverified = unverified or res["unverified"]
        rejected += [a for a in res["rejected"] if a not in rejected]
        records.append({"n": n, "kind": found[n], "answered": "yes" if res["answered"] else "no",
                        "question": res["question"]})
    warn(unverified, rejected)
    emit(json.dumps({"unverified": unverified, "records": records}))
else:
    try:
        listing = json.loads(read_stdin())
        records = listing["records"]
        unverified = bool(listing["unverified"])
    except (ValueError, KeyError, TypeError):
        die("could not parse the listing")
    if mode == "format" and sys.argv[3] == "json":
        emit(json.dumps(records) + "\n")
    elif mode == "format":
        for r in records:
            emit("needs-owner n=%d kind=%s answered=%s question=%s\n" % (r["n"], r["kind"], r["answered"], r["question"]))
    elif mode == "answered":
        if unverified:
            # The listing may fail open on an unresolved trust set; removing a
            # label on the strength of "any commenter answered" may not.
            die("the author trust set is unverified (no markers.trusted_authors and no authenticated identity resolved); no label removed")
        for r in records:
            if r["answered"] == "yes":
                emit("%d\n" % r["n"])
' "$@"
}

# _vcs_shared_trust_env <user-cmd> -> sets _NO_TRUSTED / _NO_VERIFY / _NO_CURRENT
# for _vcs_needs_owner_py (same lookups read-attempt does; the login resolves
# fail-open, so an unresolved one is the `unverified` state).
_vcs_shared_trust_env() {
  _NO_TRUSTED="$(cfg markers.trusted_authors)"
  _NO_VERIFY="$(cfg markers.verify_authors)"
  _NO_CURRENT=""
  [ "$_NO_VERIFY" = "true" ] && _NO_CURRENT="$(_vcs_shared_current_user fail-open "$1")"
  return 0
}

# _vcs_shared_upsert_pr_comment <pr> <marker-name> <body-file> <read-fn> <write-fn> <user-cmd> [args...]
#   `upsert-pr-comment` (#381), once for both GitHub adapters. <body-file> holds
#   the FINAL body (text, a blank line, `<!-- talos:<name> -->`), already
#   size-checked by the pre-dispatch block. <read-fn> <pr> prints the REST
#   comments array (every page) and returns non-zero on any failure;
#   <write-fn> <METHOD> <issues-relative-path> <payload-file> sends the file as
#   the request body on STDIN, inside the retried command (a retry would
#   otherwise read an already consumed stdin), and prints the response;
#   <user-cmd> [args...] prints the authenticated login.
#   Finds the newest comment by that login whose last non-blank line is the
#   marker and PATCHes it, else POSTs; an identical body makes no write.
#   Fail-closed: an unresolved login, an unreadable comment list or a failed
#   write is exit 1, and nothing is posted unless the read succeeded.
_vcs_shared_upsert_pr_comment() {
  local _uc_n="$1" _uc_name="$2" _uc_file="$3" _uc_read="$4" _uc_write="$5"; shift 5
  local _uc_marker="<!-- talos:$_uc_name -->" _uc_user _uc_raw _uc_found
  local _uc_state _uc_id _uc_url _uc_resp _uc_method _uc_path
  # The login must be one we made: fail-closed, so a lookup that fails or prints
  # something that is not a GitHub login (`gh api --jq` prints the raw error JSON
  # to stdout when the request is refused: an Actions GITHUB_TOKEN, a GitHub App
  # token) stops the verb before any write.
  if ! _uc_user="$(_vcs_shared_current_user fail-closed "$@")"; then
    echo "pipeline-vcs: upsert-pr-comment: could not resolve the authenticated user (GET /user fails for an Actions GITHUB_TOKEN or a GitHub App token); nothing posted" >&2
    exit 1
  fi
  _uc_raw="$("$_uc_read" "$_uc_n")" || {
    echo "pipeline-vcs: upsert-pr-comment: could not read the comments of #$_uc_n; nothing posted" >&2
    exit 1
  }
  _uc_found="$(printf '%s' "$_uc_raw" | python3 -I -c '
import json, sys
user, marker, path = sys.argv[1:4]
try:
    items = json.load(sys.stdin)
except ValueError:
    items = None
if not isinstance(items, list):
    sys.exit("the comments are not a JSON array")
def norm(s):
    return (s or "").replace("\r\n", "\n").rstrip()
new = norm(open(path, encoding="utf-8", errors="replace").read())
hit = None
for c in items:
    if not isinstance(c, dict):
        continue
    login = (c.get("user") or c.get("author") or {}).get("login") or ""
    body = norm(c.get("body"))
    if login.lower() == user.lower() and body.rsplit("\n", 1)[-1].strip() == marker:
        hit = c
if hit is None:
    print("created")
else:
    print("unchanged" if norm(hit.get("body")) == new else "updated",
          int(hit["id"]), hit.get("html_url") or "", sep="\t")
' "$_uc_user" "$_uc_marker" "$_uc_file")" || {
    echo "pipeline-vcs: upsert-pr-comment: could not parse the comments of #$_uc_n; nothing posted" >&2
    exit 1
  }
  IFS=$'\t' read -r _uc_state _uc_id _uc_url <<EOF
$_uc_found
EOF
  if [ "$_uc_state" != "unchanged" ]; then
    # JSON for the body, staged in a file the writer redirects to stdin: never argv.
    _TALOS_UPSERT_PAYLOAD_FILE="$(mktemp)"
    _talos_on_exit 'rm -f "$_TALOS_UPSERT_PAYLOAD_FILE"'
    python3 -I -c '
import json, sys
sys.stdout.write(json.dumps({"body": open(sys.argv[1], encoding="utf-8", errors="replace").read()}))
' "$_uc_file" > "$_TALOS_UPSERT_PAYLOAD_FILE" || {
      echo "pipeline-vcs: upsert-pr-comment: could not build the request body; nothing posted" >&2
      exit 1
    }
    if [ "$_uc_state" = "updated" ]; then
      _uc_method=PATCH; _uc_path="issues/comments/$_uc_id"
    else
      _uc_method=POST; _uc_path="issues/$_uc_n/comments"
    fi
    _uc_resp="$("$_uc_write" "$_uc_method" "$_uc_path" "$_TALOS_UPSERT_PAYLOAD_FILE")" || {
      echo "pipeline-vcs: upsert-pr-comment: $_uc_method $_uc_path failed; the comment on #$_uc_n was not changed" >&2
      exit 1
    }
    rm -f "$_TALOS_UPSERT_PAYLOAD_FILE"
    _uc_resp="$(printf '%s' "$_uc_resp" | python3 -I -c '
import json, sys
try:
    print(json.load(sys.stdin).get("html_url") or "")
except Exception:
    print("")
' 2>/dev/null)"
    [ -n "$_uc_resp" ] && _uc_url="$_uc_resp"
  fi
  [ -n "${_uc_url:-}" ] && printf '%s\n' "$_uc_url"
  printf 'upserted pr=%s comment=%s\n' "$_uc_n" "$_uc_state"
}

# _vcs_shared_mark_needs_owner <n> <text> <post-fn> <label-fn> <user-fn>
#   <post-fn> <n> <body> posts the comment, <label-fn> <n> adds the label,
#   <user-fn> prints the authenticated login. Each returns non-zero on failure.
_vcs_shared_mark_needs_owner() {
  local _mn_n="$1" _mn_text="$2" _mn_post="$3" _mn_label="$4" _mn_user="$5"
  local _mn_body _mn_comments _mn_tmp _mn_verdict _mn_how=posted
  _mn_body="$(printf '%s' "$_mn_text" | _vcs_needs_owner_py render mark-needs-owner)" || {
    echo "pipeline-vcs: mark-needs-owner: the text is empty; nothing posted" >&2
    exit 1
  }
  _mn_comments="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" read-comments "$_mn_n")" || {
    echo "pipeline-vcs: mark-needs-owner: could not read the comments of #$_mn_n; nothing posted" >&2
    exit 1
  }
  _vcs_shared_trust_env "$_mn_user"
  _mn_tmp="$(mktemp)" || exit 1
  printf '%s' "$_mn_body" > "$_mn_tmp"
  _mn_verdict="$(printf '%s' "$_mn_comments" \
    | TRUSTED_AUTHORS="$_NO_TRUSTED" VERIFY_AUTHORS="$_NO_VERIFY" CURRENT_USER="$_NO_CURRENT" \
      _vcs_needs_owner_py mark-check mark-needs-owner "$_mn_tmp")" || {
    rm -f "$_mn_tmp"
    echo "pipeline-vcs: mark-needs-owner: could not check the existing comments of #$_mn_n; nothing posted" >&2
    exit 1
  }
  rm -f "$_mn_tmp"
  if [ "$_mn_verdict" = "same" ]; then
    _mn_how=existing
  else
    "$_mn_post" "$_mn_n" "$_mn_body" || {
      echo "pipeline-vcs: mark-needs-owner: could not post the comment on #$_mn_n; label not added" >&2
      exit 1
    }
  fi
  "$_mn_label" "$_mn_n" || {
    echo "pipeline-vcs: mark-needs-owner: could not add the label $_TALOS_NEEDS_OWNER_LABEL to #$_mn_n" >&2
    exit 1
  }
  printf 'marked n=%s comment=%s\n' "$_mn_n" "$_mn_how"
}

# _vcs_shared_list_needs_owner <items-fn> <remove-fn> <user-fn> [--json] [--clear-answered]
#   <items-fn> prints the REST issues array of the open items carrying the
#   label (PRs included, marked by a pull_request key), all pages, and returns
#   non-zero on any failure; <remove-fn> <n> removes the label. Fail-closed:
#   nothing is printed or cleared unless every fetch succeeded.
_vcs_shared_list_needs_owner() {
  local _ln_items="$1" _ln_remove="$2" _ln_user="$3"; shift 3
  local _ln_json=false _ln_clear=false _ln_a _ln_raw _ln_records _ln_n _ln_rc=0
  for _ln_a in "$@"; do
    case "$_ln_a" in
      --json) _ln_json=true ;;
      --clear-answered) _ln_clear=true ;;
    esac
  done
  _ln_raw="$("$_ln_items")" || {
    echo "pipeline-vcs: list-needs-owner: could not list the open items; nothing listed" >&2
    exit 1
  }
  _vcs_shared_trust_env "$_ln_user"
  _ln_records="$(printf '%s' "$_ln_raw" \
    | TRUSTED_AUTHORS="$_NO_TRUSTED" VERIFY_AUTHORS="$_NO_VERIFY" CURRENT_USER="$_NO_CURRENT" \
      _vcs_needs_owner_py collect list-needs-owner "$SCRIPT_DIR/pipeline-vcs.sh" "$_TALOS_NEEDS_OWNER_LABEL")" || exit 1
  if [ "$_ln_json" = "true" ]; then
    printf '%s' "$_ln_records" | _vcs_needs_owner_py format list-needs-owner json || exit 1
  else
    printf '%s' "$_ln_records" | _vcs_needs_owner_py format list-needs-owner text || exit 1
  fi
  [ "$_ln_clear" = "true" ] || return 0
  local _ln_answered
  _ln_answered="$(printf '%s' "$_ln_records" | _vcs_needs_owner_py answered list-needs-owner)" || exit 1
  for _ln_n in $_ln_answered; do
    if "$_ln_remove" "$_ln_n"; then
      if [ "$_ln_json" = "true" ]; then printf 'cleared n=%s\n' "$_ln_n" >&2; else printf 'cleared n=%s\n' "$_ln_n"; fi
    else
      echo "pipeline-vcs: list-needs-owner: could not remove the label from #$_ln_n" >&2
      _ln_rc=1
    fi
  done
  [ "$_ln_rc" -eq 0 ] || exit 1
}

# _vcs_shared_assign_issue <n> <get-fn> <add-fn> <self-resolver-cmd> [args...]
#   The policy half of assign-issue (#299), shared by github, github-api,
#   gitlab and azure. Each adapter supplies only its provider calls:
#     <get-fn> <n>        print the current assignee(s), one per line (nothing
#                         when unassigned); non-zero exit = could not read
#     <add-fn> <n> <id>   add <id> as an assignee; non-zero exit = rejected
#     <self-resolver...>  print the operator's identity (issues.assignee:
#                         self), cached via _vcs_shared_current_user
#   issues.assignee (default "self"): "none" returns before any provider
#   call, so it is exactly the pre-#299 behaviour; "" (key present but
#   empty) is "none" plus a one-line stderr notice (#305); any other value
#   is the identity assigned literally. The current assignee is read first and a
#   non-empty one is never touched -- a person who picked up the card keeps
#   it. After the write the field is read back, and success is reported only
#   when the identity is actually there (GitHub silently drops
#   non-collaborators; ADO rejects identities outside the project).
#   Every failure is a stderr WARNING and return 0: an assignment must never
#   fail the stage that asked for it, and must never read as success when it
#   did not land (#147). stdout: one "assign-issue: #<n> assigned to <id>"
#   line on verified success, nothing otherwise.
_vcs_shared_assign_issue() {
  local n="$1" get_fn="$2" add_fn="$3"; shift 3
  local want want_lc
  want="$(cfg issues.assignee)"
  # Trim leading/trailing whitespace (spaces, tabs, newlines) once, up
  # front, so "  " is "none" (not a literal identity), "self " is "self",
  # and a literal identity is never passed to the provider with surrounding
  # whitespace (#321).
  want="$(printf '%s' "$want" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  want_lc="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
  # An explicit empty value means "none" (#305), never "self": clearing the
  # key is read as switching assignment off, and assigning is a visible
  # write. It is no longer silent -- one notice, then the "none" path.
  if [ -z "$want" ]; then
    echo "pipeline-vcs: assign-issue: issues.assignee is empty -- treating it as 'none' (not assigning); remove the key for 'self'" >&2
    return 0
  fi
  [ "$want_lc" = "none" ] && return 0

  case "$n" in
    ''|*[!0-9]*)
      echo "pipeline-vcs: assign-issue: WARNING -- issue number must be an integer, got '$n'; not assigned" >&2
      return 0
      ;;
  esac
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] assign-issue #$n: read the current assignee; if empty, assign '$want' and read it back"
    return 0
  fi

  local current
  if ! current="$("$get_fn" "$n" 2>/dev/null)"; then
    echo "pipeline-vcs: assign-issue: WARNING -- could not read #$n's current assignee; leaving it untouched" >&2
    return 0
  fi
  current="$(printf '%s\n' "$current" | sed '/^[[:space:]]*$/d')"
  if [ -n "$current" ]; then
    echo "pipeline-vcs: assign-issue: #$n already assigned to $(printf '%s' "$current" | paste -sd, -); preserving" >&2
    return 0
  fi

  local id="$want"
  if [ "$want_lc" = "self" ]; then
    # identity.name (#560) is what `self` means when it is set: the login this
    # operator claims issues under. Otherwise the authenticated login.
    id="$(cfg identity.name | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$id" ] || id="$(_vcs_shared_current_user fail-open "$@")"
    if [ -z "$id" ]; then
      echo "pipeline-vcs: assign-issue: WARNING -- could not resolve the operator identity (issues.assignee: self); #$n left unassigned" >&2
      return 0
    fi
  fi

  local add_err
  if ! add_err="$("$add_fn" "$n" "$id" 2>&1 >/dev/null)"; then
    echo "pipeline-vcs: assign-issue: WARNING -- could not assign #$n to '$id': $(printf '%s' "$add_err" | tail -1)" >&2
    return 0
  fi
  if "$get_fn" "$n" 2>/dev/null | grep -qixF -- "$id"; then
    echo "assign-issue: #$n assigned to $id"
  else
    echo "pipeline-vcs: assign-issue: WARNING -- '$id' is not #$n's assignee on read-back (not assignable in this project?); left unassigned" >&2
  fi
  return 0
}

# _vcs_shared_issue_assignees <n> <get-fn>
#   The `issue-assignees` verb (#560): the logins assigned to issue <n>, one
#   per line (nothing when unassigned), through the same per-provider read
#   assign-issue uses. Exit 1 on a bad number or a failed read -- a claim must
#   never read "unassigned" off a failed call.
_vcs_shared_issue_assignees() {
  local n="${1:-}" get_fn="$2" _ia_out
  case "$n" in
    ''|*[!0-9]*) echo "pipeline-vcs: issue-assignees: issue number must be an integer, got '$n'" >&2; return 1 ;;
  esac
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] issue-assignees #$n: read the assignees"
    return 0
  fi
  _ia_out="$("$get_fn" "$n")" || {
    echo "pipeline-vcs: issue-assignees: could not read #$n's assignees" >&2; return 1; }
  printf '%s\n' "$_ia_out" | sed '/^[[:space:]]*$/d'
}

# _vcs_shared_unassign_issue <n> <login> <get-fn> <remove-fn>
#   The `unassign-issue` verb (#560): take <login> off issue <n>, leaving any
#   other assignee. A login that is not assigned is left alone (no write). The
#   field is read back and success is reported only when <login> is gone. Exit
#   1, with a stderr WARNING, when the write fails or the read-back still shows
#   the login: the caller (a claim giving the issue up) must know.
#   stdout: "unassign-issue: #<n> unassigned <login>" or "... #<n> not assigned
#   to <login>".
_vcs_shared_unassign_issue() {
  local n="${1:-}" login="${2:-}" get_fn="$3" remove_fn="$4" _ua_cur _ua_err
  case "$n" in
    ''|*[!0-9]*) echo "pipeline-vcs: unassign-issue: issue number must be an integer, got '$n'" >&2; return 1 ;;
  esac
  if [ -z "$login" ]; then
    echo "pipeline-vcs: unassign-issue: usage: unassign-issue <n> <login>" >&2
    return 1
  fi
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] unassign-issue #$n: read the assignees; if '$login' is one, remove it and read it back"
    return 0
  fi
  _ua_cur="$("$get_fn" "$n" 2>/dev/null)" || {
    echo "pipeline-vcs: unassign-issue: WARNING -- could not read #$n's assignees; nothing changed" >&2; return 1; }
  if ! grep -qixF -- "$login" <<<"$_ua_cur"; then
    echo "unassign-issue: #$n not assigned to $login"
    return 0
  fi
  if ! _ua_err="$("$remove_fn" "$n" "$login" 2>&1 >/dev/null)"; then
    echo "pipeline-vcs: unassign-issue: WARNING -- could not unassign '$login' from #$n: $(printf '%s' "$_ua_err" | tail -1)" >&2
    return 1
  fi
  if "$get_fn" "$n" 2>/dev/null | grep -qixF -- "$login"; then
    echo "pipeline-vcs: unassign-issue: WARNING -- '$login' is still #$n's assignee on read-back" >&2
    return 1
  fi
  echo "unassign-issue: #$n unassigned $login"
}

# _vcs_shared_assignee_map <github|gitlab|azure>
#   The `list-assignees` verb's reducer (#560): a provider's open-issue listing
#   on stdin -> {"<n>": ["login", ...]} on stdout, assigned issues only. GitHub
#   items are `number` + assignees[].login and skip pull requests; GitLab `iid`
#   + assignees[].username; Azure `id` + fields.System.AssignedTo.uniqueName
#   (the form `current-user` prints). Exit 1 when stdin is not a JSON array.
_vcs_shared_assignee_map() {
  python3 -I -c '
import json, sys
kind = sys.argv[1]
try:
    items = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not isinstance(items, list):
    sys.exit(1)
out = {}
for i in items:
    if not isinstance(i, dict):
        continue
    if kind == "github":
        n, who = i.get("number"), [a.get("login") for a in i.get("assignees") or [] if isinstance(a, dict)]
        if "pull_request" in i:
            continue
    elif kind == "gitlab":
        n, who = i.get("iid"), [a.get("username") for a in i.get("assignees") or [] if isinstance(a, dict)]
    else:
        n = i.get("id")
        v = (i.get("fields") or {}).get("System.AssignedTo")
        who = [v.get("uniqueName")] if isinstance(v, dict) else [v] if isinstance(v, str) else []
    who = [w for w in who if isinstance(w, str) and w]
    if isinstance(n, int) and not isinstance(n, bool) and who:
        out[str(n)] = who
print(json.dumps(out))
' "$1"
}

# _vcs_issue_number_from_url <create-issue output> -- the <n> of the last
# ".../issues/<n>" URL in it (gh and glab both print the new issue's URL), or
# nothing, which _vcs_shared_assign_issue turns into a warning.
_vcs_issue_number_from_url() {
  printf '%s\n' "$1" | grep -oE '/issues/[0-9]+' | tail -1 | sed 's|.*/||'
}

# _vcs_shared_attempt_blocked <verb> <count> <total> <max-count> <max-total> <stage>
#   Prints "pipeline-vcs: <verb>: BLOCKED — ..." to stderr for each ceiling
#   that is met/exceeded (total dispatches first, then per-stage consecutive
#   attempts). Shared by check-attempt (pre-check) and record-attempt
#   (post-record check) in both adapters, so the two can no longer drift on
#   BLOCKED wording. Returns 1 if either ceiling is blocked, 0 otherwise.
_vcs_shared_attempt_blocked() {
  local verb="$1" count="$2" total="$3" max_count="$4" max_total="$5" stage="$6"
  local blocked=false
  if [ "$total" -ge "$max_total" ]; then
    echo "pipeline-vcs: ${verb}: BLOCKED — total dispatches (${total}) >= max_total_dispatches (${max_total})" >&2
    blocked=true
  fi
  if [ -n "$stage" ] && [ "$count" -ge "$max_count" ]; then
    echo "pipeline-vcs: ${verb}: BLOCKED — ${stage} consecutive attempts (${count}) >= max_fix_attempts (${max_count})" >&2
    blocked=true
  fi
  [ "$blocked" = "true" ] && return 1
  return 0
}

# _vcs_shared_record_attempt <issue-n> <stage> <post-fn> [--idempotency-key <token> | --pr <pr-n>]
#   Everything about record-attempt is provider-independent EXCEPT the actual
#   write, so this function does all of it: parses the record-attempt CLI
#   args, resolves an idempotency key (directly, or via the provider-agnostic
#   recursive `pr-head <pr-n>` call), reads prior state via the
#   provider-agnostic recursive `read-attempt` call, computes the new
#   stage/total counts, and -- unless an idempotent duplicate short-circuits
#   the write -- builds the marker body and calls `"$post_fn" <issue-n>
#   <marker-body>`, a caller-supplied function name that performs the actual
#   write and must print the created comment's URL (or the empty string on
#   failure) to stdout.
#   stdout: "stage=<s> count=<k> total=<t>" on success or idempotent replay.
#   exit:   0 if under both ceilings after recording; 1 on a bad/missing
#           argument, a failed write, or when either ceiling is now met.
_vcs_shared_record_attempt() {
  local n="$1" stage="$2" post_fn="$3"
  shift 3
  local idem_key="" idem_key_seen=false pr_n=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --idempotency-key)
        idem_key="${2:-}"
        idem_key_seen=true
        shift 2 2>/dev/null || shift "$#"
        ;;
      --pr)
        pr_n="${2:-}"
        shift 2 2>/dev/null || shift "$#"
        ;;
      *) shift ;;
    esac
  done
  if [ -n "$pr_n" ] && [ "$idem_key_seen" = "true" ]; then
    echo "pipeline-vcs: record-attempt: --pr and --idempotency-key are mutually exclusive" >&2
    return 1
  fi
  if [ -n "$pr_n" ]; then
    local pr_sha
    pr_sha="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" pr-head "$pr_n" ${REPO:+--repo "$REPO"} 2>/dev/null)" || {
      echo "pipeline-vcs: record-attempt: could not resolve head SHA for PR #$pr_n" >&2
      return 1
    }
    case "$pr_sha" in
      *[!0-9a-f]*|"")
        echo "pipeline-vcs: record-attempt: invalid SHA from pr-head: '$pr_sha'" >&2
        return 1
        ;;
    esac
    if [ "${#pr_sha}" -ne 40 ]; then
      echo "pipeline-vcs: record-attempt: SHA must be 40 hex chars, got ${#pr_sha}: '$pr_sha'" >&2
      return 1
    fi
    idem_key="${stage}-${pr_sha}"
    idem_key_seen=true
  fi
  if [ "$idem_key_seen" = "true" ]; then
    case "$idem_key" in
      ''|*[!A-Za-z0-9._-]*)
        echo "pipeline-vcs: record-attempt: --idempotency-key must match [A-Za-z0-9._-]+, got '$idem_key'" >&2
        return 1
        ;;
    esac
  fi
  local max_stage max_total
  max_stage="$(cfg limits.max_fix_attempts)"
  max_total="$(cfg limits.max_total_dispatches)"
  # Read current state (fail-closed on parse error)
  local state
  state="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" read-attempt "$n" ${REPO:+--repo "$REPO"} 2>&1)"
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "pipeline-vcs: record-attempt: read-attempt failed: $state" >&2
    return 1
  fi
  # Pass through any machine-readable talos: markers from read-attempt to our
  # own stdout, then narrow state to only the parseable stage=...count=...total=
  # line (filters out both talos: markers and any stderr warnings captured via 2>&1).
  printf '%s\n' "$state" | grep '^talos:' || true
  state="$(printf '%s\n' "$state" | grep '^stage=')"
  local prev_stage prev_count prev_total prev_key
  prev_stage="$(printf '%s' "$state" | sed 's/stage=\([^ ]*\).*/\1/')"
  prev_count="$(printf '%s' "$state" | sed 's/.*count=\([0-9]*\).*/\1/')"
  prev_total="$(printf '%s' "$state" | sed 's/.*total=\([0-9]*\).*/\1/')"
  prev_key="$(printf '%s' "$state" | sed -n 's/.*key=\([^ ]*\).*/\1/p')"
  # Idempotency dedup (#172): an immediate retry with the same stage and
  # key as the most-recent marker does not post again -- reprints the
  # existing (unincremented) counts and exits with the status those
  # counts already imply. Only covers a same-turn retry that reuses the
  # same token; it cannot detect a retry across a process restart, which
  # by definition cannot know the prior token (see README.md).
  if [ "$idem_key_seen" = "true" ] && [ "$prev_stage" = "$stage" ] && [ -n "$prev_key" ] && [ "$prev_key" = "$idem_key" ]; then
    echo "pipeline-vcs: record-attempt: duplicate --idempotency-key '$idem_key' for stage=$stage; not posting again" >&2
    printf 'stage=%s count=%d total=%d\n' "$stage" "$prev_count" "$prev_total"
    if [ "$prev_total" -ge "$max_total" ] || [ "$prev_count" -ge "$max_stage" ]; then
      return 1
    fi
    return 0
  fi
  # Compute new counts
  local new_count new_total
  new_total=$(( prev_total + 1 ))
  if [ "$prev_stage" = "$stage" ]; then
    # Same stage: increment consecutive count
    new_count=$(( prev_count + 1 ))
  else
    # Different stage: reset per-stage count to 1
    new_count=1
  fi
  # Build marker body (marker MUST be the last line of the comment).
  # key=<token> is appended only when --idempotency-key was supplied.
  local key_suffix="" marker_body
  [ "$idem_key_seen" = "true" ] && key_suffix=" key=${idem_key}"
  marker_body="$(printf 'Talos attempt record — stage=%s count=%d total=%d\n<!-- talos:attempt stage=%s count=%d total=%d%s -->' \
    "$stage" "$new_count" "$new_total" \
    "$stage" "$new_count" "$new_total" "$key_suffix")"
  # Delegate the actual write to the adapter-supplied poster function. Its
  # exit status (not stdout emptiness) is the write-succeeded signal, because
  # the two adapters disagree on what a "successful but URL-less" write looks
  # like: gh always returns a URL on success, REST can succeed without one.
  local comment_url post_rc
  comment_url="$("$post_fn" "$n" "$marker_body")"
  post_rc=$?
  if [ "$post_rc" -ne 0 ]; then
    echo "pipeline-vcs: record-attempt: failed to post attempt marker for issue #$n" >&2
    return 1
  fi
  echo "pipeline-vcs: record-attempt: marker posted at ${comment_url:-<unknown>}" >&2
  printf 'stage=%s count=%d total=%d\n' "$stage" "$new_count" "$new_total"
  # Exit non-zero if EITHER ceiling is now reached
  _vcs_shared_attempt_blocked "record-attempt" "$new_count" "$new_total" "$max_stage" "$max_total" "$stage"
}

# _vcs_shared_check_approval_marker
#   stdin:  the same PR JSON both adapters already assemble for
#           check-approval-sha: {"headRefOid", "baseRefName",
#           "labels":[{"name":...}], "comments":[...]}. Only "labels" and
#           "comments" are read here -- headRefOid/baseRefName stay with the
#           SHA/waiver comparison (_vcs_shared_check_approval_sha, #177 slice 2).
#   env:    TRUSTED_AUTHORS, TALOS_CFG -- same contract check-approval-sha
#           has always used. VERIFY_AUTHORS, CURRENT_USER (#187) -- effective
#           trust set is TRUSTED_AUTHORS ∪ {CURRENT_USER} when
#           VERIFY_AUTHORS is not "false" and CURRENT_USER is non-empty;
#           VERIFY_AUTHORS defaults to "true" when unset. TALOS_CONTRACT_
#           APPROVAL_ENV (#178) -- APPROVAL_LABELS/VALID_ROLES, derived from
#           scripts/pipeline-contract.sh's TALOS_APPROVAL_LABELS/
#           TALOS_APPROVAL_ROLES.
#   stdout: JSON {"entries": [{"label", "role", "sha", "reason"}, ...]} in
#           APPROVAL_LABELS order, restricted to labels present on the PR --
#           for each entry exactly one of "sha"/"reason" is non-null. When no
#           approval label is present at all, stdout is instead the plain
#           diagnostic message check-approval-sha has always printed for that
#           case.
#   stderr: one `talos:marker-authors-rejected authors=<comma list>` line
#           when the trust set is enforced and at least one marker (across
#           any role) was skipped for having an untrusted author (#187).
#   exit:   0 with JSON entries when at least one approval label is present;
#           3 (no error -- a legitimate short-circuit) when no approval label
#           is present, in which case the caller should relay stdout as-is
#           and exit 0; 1 when stdin is unparseable.
_vcs_shared_check_approval_marker() {
  _vcs_shared_contract_env
  python3 -I -c "$(_vcs_shared_trust_py)
import json, os, re, sys

# Single source of truth: scripts/pipeline-contract.sh's TALOS_APPROVAL_LABELS
# / TALOS_APPROVAL_ROLES, passed in via TALOS_CONTRACT_APPROVAL_ENV (#178,
# "label=role" pairs) -- never hand-restate this mapping here.
APPROVAL_LABELS = {}
for _pair in os.environ.get('TALOS_CONTRACT_APPROVAL_ENV', '').split():
    _label, _role = _pair.split('=', 1)
    APPROVAL_LABELS[_label] = _role

# Fixed valid role set -- derived from APPROVAL_LABELS values, which in turn
# come only from the contract file above, never from config or API text
# (PR #68 precedent: injected text could forge an approval marker).
# Any marker whose role is not in this set is ignored (issue #128).
VALID_ROLES = set(APPROVAL_LABELS.values())

# Strict extractor: marker must be a syntactically valid talos:approval HTML comment.
MARKER_RE = re.compile(r'<!--\s*talos:approval\s+sha=([0-9a-f]+)\s+role=(\S+?)\s*-->')

# Author trust set (#187): _vcs_shared_trust_py, the same definition
# read-attempt and the needs-owner reader use (see there for the rationale).
verify_authors, effective_trusted = load_trust()
author_check_active = author_check_enforced(verify_authors, effective_trusted)
warn_identity_refused('check-approval-sha', verify_authors, effective_trusted)
fail_open_warned = False
rejected_authors_seen = []
_config_parse_failed_cas = config_parse_failed()

try:
    data = json.load(sys.stdin)
except Exception as exc:
    print(f'pipeline-vcs: check-approval-sha: could not parse PR data: {exc}', file=sys.stderr)
    sys.exit(1)

label_names  = {lb.get('name', '') for lb in data.get('labels', [])}
raw_comments = data.get('comments', [])

# Which approval labels are present?
present = {label: role for label, role in APPROVAL_LABELS.items() if label in label_names}

if not present:
    # Inverse diagnostic (#146): when no approval labels are present but
    # talos:approval markers exist in comments, a stage likely posted the
    # marker without calling label-pr -- the mirror of the Case B diagnostic
    # shipped in #144/#142 for the other direction.
    no_label_marker_count = sum(
        1 for c in raw_comments
        if 'talos:approval sha=' in c.get('body', '')
    )
    if no_label_marker_count > 0:
        print(
            f'check-approval-sha: no approval labels present'
            f' (but {no_label_marker_count} approval marker(s) found in comments'
            f' - did a stage post a marker without applying its label?)'
        )
    else:
        print('check-approval-sha: no approval labels present')
    sys.exit(3)

# Strict extractor: marker must be a syntactically valid talos:approval HTML comment.
# Precompute once: does any comment contain near-miss marker text?
any_approval_text = any('talos:approval sha=' in c.get('body', '') for c in raw_comments)

entries = []
for label, role in present.items():
    # Find the most recent marker for this role (search comments newest-first).
    # Enforce the same last-line rule as read-attempt: the marker must be the
    # last non-whitespace line of the comment body so a quoted/fenced occurrence
    # (e.g. GitHub Quote-reply) cannot satisfy the gate.
    found_sha = None
    reason = None
    for c in reversed(raw_comments):
        body   = c.get('body', '')
        author = c.get('author', {}).get('login', '') if isinstance(c.get('author'), dict) else ''

        # INVARIANT (issue #79): last-line check is unconditional — MUST precede
        # author_check_active block. Reordering these two sections silently reopens
        # the quoted-marker bypass. Do not move the lines below past author_check_active.
        # Last-line rule: strip trailing whitespace, take final newline-split segment.
        last_line = body_last_line(body)

        m = MARKER_RE.match(last_line)
        if not m:
            continue  # marker not on last line
        marker_role = m.group(2)
        if marker_role not in VALID_ROLES:
            # Unknown role value -- log and skip so the gate falls through to
            # the existing STALE path (fail-closed). Issue #128.
            print(
                'pipeline-vcs: check-approval-sha: ignoring marker with unknown role '
                + repr(marker_role) + ' (valid: ' + ', '.join(sorted(VALID_ROLES)) + ')',
                file=sys.stderr,
            )
            continue
        if marker_role != role:
            continue  # wrong role for this label

        # Author trust check (#187): only when verify_authors resolved a
        # non-empty effective trust set (an explicit list and/or the
        # current user).
        if author_check_active:
            if author not in effective_trusted:
                if author not in rejected_authors_seen:
                    rejected_authors_seen.append(author)
                continue  # skip; keep searching older comments
        elif verify_authors:
            # No explicit list AND no resolved identity — fail open, once
            # per invocation, exactly as an unset markers.trusted_authors
            # always has.
            if not fail_open_warned:
                print('talos:marker-authors-unverified reader=check-approval-sha')
                if _config_parse_failed_cas:
                    print(
                        'pipeline-vcs: check-approval-sha: [warn] markers.trusted_authors not configured '
                        '-- config file could not be parsed (see pipeline-config warning); '
                        'any commenter\'s marker is accepted',
                        file=sys.stderr,
                    )
                else:
                    print(
                        'pipeline-vcs: check-approval-sha: [warn] markers.trusted_authors not configured '
                        '— author check skipped',
                        file=sys.stderr,
                    )
                fail_open_warned = True
        # else: markers.verify_authors is explicitly false — silent
        # fail-open, no warning (#187 opt-out).

        found_sha = m.group(1)
        break

    if not found_sha:
        # Fail-closed: missing marker means the approval predates SHA stamping —
        # treat it as stale rather than assuming it is safe.
        print(f'pipeline-vcs: check-approval-sha: {label} has no SHA marker — treating as stale', file=sys.stderr)
        if any_approval_text:
            reason = 'found talos:approval text but no valid marker -- expected <!-- talos:approval sha=<40-hex-lowercase> role=<role> --> as the last non-whitespace line'
        else:
            reason = 'no SHA marker in PR comments'
    elif not re.fullmatch(r'[0-9a-f]{40}', found_sha):
        # Reject abbreviated SHAs at parse time.  An abbreviated SHA can expand to a
        # real but wrong commit (e.g. bed2e4a expands to bed2e4ae... not bed2e4a9...).
        # Stages must post the full 40-character SHA from pipeline-vcs.sh pr-head <PR>,
        # not git rev-parse HEAD, which returns whatever commit is checked out locally.
        reason = (
            f'marker SHA {found_sha!r} is not a valid 40-character commit SHA — '
            f'the {role} stage must obtain the SHA via '
            f'pipeline-vcs.sh pr-head <PR>, not git rev-parse HEAD '
            f'(which returns whatever commit is checked out locally)'
        )
        found_sha = None

    entries.append({'label': label, 'role': role, 'sha': found_sha, 'reason': reason})

# One machine-readable line per invocation (#187), never one per marker --
# a PR with several untrusted-author markers across roles would otherwise
# spam stderr with a near-duplicate line per marker.
if rejected_authors_seen:
    print('talos:marker-authors-rejected authors=' + ','.join(rejected_authors_seen), file=sys.stderr)

json.dump({'entries': entries}, sys.stdout)
sys.exit(0)
"
}

# _vcs_shared_check_approval_sha
#   stdin:  the same PR JSON both adapters assemble for check-approval-sha
#           ({"headRefOid", "baseRefName", "labels", "comments"} -- only
#           "headRefOid" and "baseRefName" are read here; the entries below
#           already carry whatever "labels"/"comments" produced).
#   env:    MARKER_ENTRIES -- stdout of _vcs_shared_check_approval_marker
#             (rc 0 case): {"entries": [{"label","role","sha","reason"}]}.
#           WAIVER_PATHS   -- merge.approval_waiver_paths config value (JSON
#             array, newline-delimited fallback, or empty for DEFAULT_WAIVER).
#           REPO_ROOT      -- repo root for the `git diff`/`git cat-file`
#             probes below (both adapters resolve this identically via
#             `git rev-parse --show-toplevel`; it is local-repo work, not
#             GitHub-API work, so it stays here rather than per-adapter).
#           STALE_LIST     -- "true" to additionally print one greppable
#             "stale role=<role> label=<label>" stdout line per stale entry.
#   stdout: "check-approval-sha: all approval labels are current" (plus, when
#           STALE_LIST=true and there ARE stale entries, the stale-role lines
#           instead) on success paths; STALE diagnostics go to stderr.
#   exit:   0 when every approval label is current or waived; 1 on stdin
#           parse failure, bad waiver config, or any stale/non-waivable entry.
#
# Waiver rules: a SHA-mismatched approval is stale unless every file changed
# between the marker SHA and head is covered by merge.approval_waiver_paths
# (default: *.md docs/** CHANGELOG.md *.example) AND none of the hard-coded
# non-waivable paths (scripts/**, tests/**, agents/**, skills/**,
# templates/prompts/**; at any depth: .claude/{agents,skills,commands,talos,
# rules}/**, .agents/**, .agent/**, .gemini/**, .pi/**, .codex/**, and any
# AGENTS.md, CLAUDE.md, GEMINI.md, AGENTS.override.md or CLAUDE.local.md;
# plus pipeline config filenames; all casefolded) --
# checked FIRST, before the config waiver, so config can never widen a waiver
# to cover them. Files that only arrived via a base-branch sync (absent from
# the PR's own three-dot diff, #102) are excluded from consideration.
_vcs_shared_check_approval_sha() {
  python3 -I -c "
import fnmatch, json, os, subprocess, sys

# Hard-coded non-waivable: checked BEFORE the config waiver.
# The config can NEVER widen a waiver to cover these paths.
# Code (scripts/, tests/) and agent instructions (agents/, skills/,
# templates/prompts/ -- Talos's own layout, root-anchored), the runners'
# dot-directories (.claude/{agents,skills,commands,talos,rules}/, .agents/,
# .agent/, .gemini/, .pi/, .codex/ -- matched at ANY path-component boundary,
# so sub/.claude/rules/x.md counts, #431), and instruction files matched by
# basename at any depth (AGENTS.md, CLAUDE.md, GEMINI.md, AGENTS.override.md,
# CLAUDE.local.md, #428/#431) -- the instruction files are Markdown, so the
# default *.md waiver would otherwise cover them. docs/agents/ (not Talos's
# agents/) and templates/comments/** (rendered output text) stay waivable.
# Every comparison is casefolded: on a case-insensitive checkout (macOS,
# Windows) Skills/x lands in the real skills/ folder.
HARDCODED_NONWAIVABLE_PREFIXES = (
    'scripts/', 'tests/',
    'agents/', 'skills/', 'templates/prompts/',
)
HARDCODED_NONWAIVABLE_DOTDIRS = (
    '.claude/agents/', '.claude/skills/', '.claude/commands/',
    '.claude/talos/', '.claude/rules/', '.agents/',
    '.agent/', '.gemini/', '.pi/', '.codex/',
)
HARDCODED_NONWAIVABLE_EXACT    = (
    'talos.pipeline.yml', 'talos.pipeline.yaml', 'talos.pipeline.json',
    '.claude-pipeline.yaml', '.claude-pipeline.json',
    'pipeline.yaml', 'pipeline.json',
)
HARDCODED_NONWAIVABLE_BASENAMES = (
    'agents.md', 'claude.md', 'gemini.md',
    'agents.override.md', 'claude.local.md',
)

# Default waiver paths -- used when the config key is absent or unparseable.
DEFAULT_WAIVER = ['*.md', 'docs/**', 'CHANGELOG.md', '*.example']

# Validation canaries: if a waiver entry matches any of these it is too broad
# (catch-all or covers non-waivable territory) and must be rejected.
# Generated to catch both basename-level and full-path-level matches.
VALIDATION_CANARIES = [
    'scripts/core.sh',      'scripts/pipeline-vcs.sh',
    'sub/dir/scripts/x.sh',
    'tests/test-vcs.sh',    'tests/run-tests.sh',
    'sub/dir/tests/y.sh',
    'talos.pipeline.yml',   'talos.pipeline.yaml',  'talos.pipeline.json',
    '.claude-pipeline.yaml', '.claude-pipeline.json',
    'pipeline.yaml',        'pipeline.json',
    'src/arbitrary.js',     'lib/main.py', 'cmd/server.go',
    'sub/dir/arbitrary.js',
]

def is_hardcoded_nonwaivable(path):
    low = path.casefold()
    for prefix in HARDCODED_NONWAIVABLE_PREFIXES:
        if low == prefix.rstrip('/') or low.startswith(prefix):
            return True
    for prefix in HARDCODED_NONWAIVABLE_DOTDIRS:
        # '/' + low + '/' so the prefix matches at the start or after any '/'.
        if '/' + prefix in '/' + low + '/':
            return True
    if low in HARDCODED_NONWAIVABLE_EXACT:
        return True
    return os.path.basename(low) in HARDCODED_NONWAIVABLE_BASENAMES

# git diff --name-only -z: real paths, NUL-separated. Without -z git quotes
# non-ASCII, tab, newline and quote characters (core.quotePath), so
# skills/ü/SKILL.md would arrive as a quoted string and miss the prefix check.
def split_nul(out):
    return [f for f in out.split('\x00') if f]

def path_matches(path, patterns):
    base = os.path.basename(path)
    return any(fnmatch.fnmatch(base, p) or fnmatch.fnmatch(path, p) for p in patterns)

def validate_waiver_entries(entries):
    errors = []
    for entry in entries:
        for canary in VALIDATION_CANARIES:
            base = os.path.basename(canary)
            if fnmatch.fnmatch(base, entry) or fnmatch.fnmatch(canary, entry):
                errors.append(
                    f\"pipeline-vcs: ERROR: merge.approval_waiver_paths entry '{entry}'\"
                    f\" would waive '{canary}' — rejected (catch-all or covers non-waivable paths)\"
                )
                break
    return errors

# Resolve waiver paths from config (safe degradation: parse error -> defaults)
raw_waiver = os.environ.get('WAIVER_PATHS', '').strip()
if raw_waiver:
    try:
        parsed = json.loads(raw_waiver)
        if not isinstance(parsed, list):
            raise ValueError('not a list')
        waiver_entries = [str(e).strip() for e in parsed if str(e).strip()]
    except Exception:
        # Newline-delimited fallback (YAML scalar block)
        waiver_entries = [e.strip() for e in raw_waiver.splitlines() if e.strip()]
else:
    waiver_entries = DEFAULT_WAIVER

# Validate waiver config entries -- fail closed on bad config
errors = validate_waiver_entries(waiver_entries)
if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)

# An explicit entry under a non-waivable prefix (or naming a non-waivable
# file) is harmless -- is_hardcoded_nonwaivable wins -- but say so (#428).
for entry in waiver_entries:
    if is_hardcoded_nonwaivable(entry):
        print(
            f\"pipeline-vcs: check-approval-sha: note: merge.approval_waiver_paths entry '{entry}'\"
            ' ignored for agent-instruction paths',
            file=sys.stderr,
        )

# Parse PR data
try:
    data = json.load(sys.stdin)
except Exception as exc:
    print(f'pipeline-vcs: check-approval-sha: could not parse PR data: {exc}', file=sys.stderr)
    sys.exit(1)

head_sha = data.get('headRefOid', '').strip()
if not head_sha:
    print('pipeline-vcs: check-approval-sha: could not resolve head SHA', file=sys.stderr)
    sys.exit(1)

# Three-dot diff: compute the set of files the PR itself touches relative to
# origin/<base>. Files that arrived purely from a base-branch sync are absent
# from this set (they are already in the merge base). Fail-open: if base_ref_name
# is absent or the diff fails, pr_own_files = None and the filter is skipped --
# the full changed set is used (conservative / pre-fix behavior).
base_ref_name = data.get('baseRefName', '').strip()
pr_own_files = None
if base_ref_name:
    _own_root = os.environ.get('REPO_ROOT', '').strip() or None
    try:
        _pr_own = subprocess.run(
            ['git', 'diff', '--name-only', '-z', '--no-renames',
             'origin/' + base_ref_name + '...' + head_sha],
            capture_output=True, text=True,
            cwd=_own_root, timeout=30
        )
        if _pr_own.returncode == 0:
            pr_own_files = set(split_nul(_pr_own.stdout))
        # else: diff failed -- fail-open, pr_own_files stays None
    except Exception:
        pr_own_files = None  # fail-open

try:
    marker_data = json.loads(os.environ.get('MARKER_ENTRIES', '') or '{}')
except Exception:
    marker_data = {}
entries = marker_data.get('entries', [])

stale = []
for entry in entries:
    label, role = entry.get('label'), entry.get('role')
    found_sha = entry.get('sha')
    reason = entry.get('reason')

    if reason is not None:
        # Marker extraction already determined this label/role is stale
        # (no marker, unparseable marker, or an invalid-length SHA).
        stale.append((label, role, reason))
        continue

    if found_sha == head_sha:
        continue  # Approval is current

    # SHA mismatch -- check whether the delta is fully waivable
    repo_root = os.environ.get('REPO_ROOT', '').strip() or None
    try:
        # Probe whether the marker SHA actually exists in this repository before
        # attempting git diff.  git diff exits 128 for a missing SHA, which
        # produces a confusing error about an invalid revision range.  A missing
        # SHA is a different (and more serious) condition than a stale approval.
        probe = subprocess.run(
            ['git', 'cat-file', '-e', f'{found_sha}^{{commit}}'],
            capture_output=True, cwd=repo_root, timeout=10
        )
        if probe.returncode != 0:
            stale.append((label, role,
                f'marker SHA {found_sha} does not exist in this repository -- '
                f'the {role} stage posted an invalid SHA; it must re-run and '
                f're-post its marker using a SHA read from git, not reconstructed'))
            continue
        result = subprocess.run(
            ['git', 'diff', '--name-only', '-z', '--no-renames', f'{found_sha}..{head_sha}'],
            capture_output=True, text=True,
            cwd=repo_root, timeout=30
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or 'non-zero exit')
        changed = split_nul(result.stdout)
    except Exception as exc:
        # git diff failure -> treat delta as non-waivable (fail-closed)
        print(f'pipeline-vcs: check-approval-sha: git diff failed: {exc}', file=sys.stderr)
        stale.append((label, role, f'git diff failed: {exc}'))
        continue

    # Intersect with the PR's own file set to exclude base-branch-only changes.
    # A file the PR itself also touches stays in pr_own_files and is evaluated
    # normally -- fail-closed for same-file-touched-by-both (rule 2).
    # If pr_own_files is None (three-dot diff unavailable) the filter is skipped.
    if pr_own_files is not None:
        changed = [f for f in changed if f in pr_own_files]

    # First check hard-coded non-waivable paths (checked before the config waiver -- config cannot override)
    blocked = [p for p in changed if is_hardcoded_nonwaivable(p)]
    if not blocked:
        # Then check config waiver list for remaining paths
        blocked = [p for p in changed if not path_matches(p, waiver_entries)]

    if blocked:
        stale.append((label, role,
            f'non-waivable files changed since {found_sha}: ' + ', '.join(blocked[:5])))
    # else every changed file is waivable -- approval stands

if stale:
    for label, role, reason in stale:
        print(f'pipeline-vcs: check-approval-sha: STALE {label} ({role}): {reason}', file=sys.stderr)
    if os.environ.get('STALE_LIST', '') == 'true':
        for label, role, reason in stale:
            print(f'stale role={role} label={label}')
    sys.exit(1)

print('check-approval-sha: all approval labels are current')
sys.exit(0)
"
}

# _vcs_shared_check_pr_files (#177 slice 3)
#   stdin:  the PR's changed file paths, one per line. Both adapters fetch
#           this via their paginated `pr-files` mechanism (_gh_pages)
#           BEFORE calling this function, and that fetch already exits 1
#           (printing nothing) on failure -- so empty stdin here always means
#           "0 changed files", never "fetch failed". Fail-closed-on-fetch-
#           failure therefore lives at the call site, not in this function.
#   env:    CONFIGURED -- merge.forbidden_files config value (raw string).
#           REPLACE    -- merge.forbidden_files_replace config value.
#           ALLOW      -- merge.forbidden_files_allow config value.
#   stdout: a `talos:` transparency marker naming the active pattern count
#           and whether built-in defaults are in force (always), then either
#           a one-line pass confirmation or a fail banner plus one indented
#           path per offending file.
#   exit:   0 when no changed file matches an active pattern; 1 when an
#           allow-list entry is too broad for the active deny patterns
#           (fail-closed on bad config) or when >=1 forbidden file matched.
#
# _vcs_shared_forbidden_patterns
#   (#262 security-review follow-up) Single source of truth for the built-in
#   merge.forbidden_files default list -- factored out of
#   _vcs_shared_check_pr_files so pipeline-mergebase.sh's merge.union_paths
#   cross-check (exposed via the forbidden-files-patterns verb below) reuses
#   the SAME list rather than hand-duplicating it. pipeline-worktree.sh's
#   checkpoint reads it through the forbidden-files-patterns verb too (#436),
#   so there is exactly one definition.
#   env:    CONFIGURED -- merge.forbidden_files config value (raw string).
#           REPLACE    -- merge.forbidden_files_replace config value.
#   stdout: the effective forbidden-files patterns, one per line -- built-in
#           defaults unioned with CONFIGURED, unless REPLACE=true (then
#           CONFIGURED replaces the defaults wholesale).
#
# Built-in defaults — always active unless merge.forbidden_files_replace: true.
# #61 fix: merge.forbidden_files UNIONs with these defaults rather than
# replacing them wholesale, closing the silent neutering attack surface.
# .netrc and _netrc are LITERAL patterns (no glob chars); they generate
# canaries as of #76 (PR #90, commit b1d3199), so wildcard allow entries
# that match them are rejected. Deferral from issue #78 is resolved.
# #436 credential-file defaults, each matched at any depth (basename or path):
#   .npmrc, .pypirc          package-registry auth tokens
#   .git-credentials         plaintext git credential-store file
#   credentials.json, *-credentials.json, *_credentials.json
#                            cloud/service-account key files; deliberately NOT
#                            *credentials*.json, which would also refuse
#                            credentials-schema.json
#   .aws/credentials         AWS shared credentials (bare + nested: fnmatch's
#   */.aws/credentials       '*' crosses '/', so the second form is the nested one)
#   .docker/config.json      registry auth in the Docker client config
#   */.docker/config.json    (nested form, same reason)
# Every consumer matches case-insensitively (fnmatchcase on lowercased text), so
# .ENV and Credentials.JSON are caught too.
_vcs_shared_forbidden_patterns() {
  local _BUILTIN_DEFAULTS='.env
.env.*
*.pem
*.key
*.p12
*.pfx
*.secrets
secrets.*
*id_rsa*
*id_ecdsa*
*id_ed25519*
*id_dsa*
*.ppk
*.jks
*.keystore
*.pkcs12
*.kdbx
*.ovpn
.netrc
_netrc
.npmrc
.pypirc
.git-credentials
credentials.json
*-credentials.json
*_credentials.json
.aws/credentials
*/.aws/credentials
.docker/config.json
*/.docker/config.json'
  if [ -n "$CONFIGURED" ] && [ "$REPLACE" = "true" ]; then
    printf '%s\n' "$CONFIGURED"
  elif [ -n "$CONFIGURED" ]; then
    printf '%s\n%s\n' "$_BUILTIN_DEFAULTS" "$CONFIGURED"
  else
    printf '%s\n' "$_BUILTIN_DEFAULTS"
  fi
}

_vcs_shared_check_pr_files() {
  local _patterns _defaults_active
  _patterns="$(_vcs_shared_forbidden_patterns)"
  if [ -n "$CONFIGURED" ] && [ "$REPLACE" = "true" ]; then
    # Explicit opt-out: operator acknowledged they want replacement behaviour.
    echo "pipeline-vcs: WARNING: merge.forbidden_files_replace=true — built-in secret-protection defaults are SUPPRESSED; only configured patterns are active" >&2
    _defaults_active="replaced"
  else
    _defaults_active="in-force"
  fi
  # Transparency markers — always emitted on stdout so every run record is
  # auditable. Values are fixed literals or integers — never interpolated from
  # config text (guards against marker-injection via a crafted config value).
  local _pat_count
  _pat_count="$(printf '%s\n' "$_patterns" | grep -c '[^[:space:]]')" || _pat_count=0
  grep -qE '^[0-9]+$' <<<"$_pat_count" || _pat_count=0
  printf 'talos:forbidden-files-active patterns=%d defaults=%s\n' "$_pat_count" "$_defaults_active"
  [ "$_defaults_active" = "replaced" ] && \
    printf 'talos:forbidden-files-defaults-replaced patterns=%d\n' "$_pat_count"
  # merge.forbidden_files_allow — explicit exclusions, checked BEFORE the deny
  # patterns. Added 2026-08-22: the default `.env.*` correctly guards real dotenv
  # files but over-matches a committed `.env.example` template, which is the file
  # developers copy to `.env` before `docker compose up`. Without an allow list the
  # only way to permit the template is to drop `.env.*` entirely and lose protection
  # for `.env.local`, `.env.production`, etc.
  # Semantic allow-list validation: reject any entry that would exempt a canary path
  # derived from the active deny patterns. Character-stripping is whack-a-mole —
  # entries like *[!x]* or [a-z]* bypass a strip-* check; matching canaries with the
  # SAME fnmatch rule the gate uses is the only complete fix. Fail closed: any
  # validation error or unexpected exception must exit non-zero.
  if [ -n "$ALLOW" ]; then
    PATTERNS="$_patterns" ALLOW="$ALLOW" python3 -I -c "
import fnmatch, os, re, sys

patterns = [p.strip() for p in os.environ['PATTERNS'].splitlines() if p.strip()]
allow    = [a.strip() for a in os.environ.get('ALLOW','').splitlines() if a.strip()]

def pat_to_literal(pat):
    # Replace bracket expressions ([abc], [!abc]) then remaining glob chars with 'x'
    # so the result is a plain filename that the deny pattern was written to match.
    s = re.sub(r'\\[[^\\]]*\\]', 'x', pat)
    return s.replace('*', 'x').replace('?', 'x')

# Build canary paths from the active deny patterns so the check stays correct if
# defaults change. Three forms per pattern:
#   root      — bare filename         catches bare globs like * and [a-z]*
#   nested    — sub/dir/<name>        catches */* and **/*
#   prefixed  — config/<name>         catches config/* (path check, not basename)
# Build canaries from ALL deny patterns — wildcard and literal alike. Three
# forms per pattern (root, sub/dir/, config/) test allow globs along all path
# dimensions. Canaries from a LITERAL deny pattern carry a src_literal tag so
# that an allow entry which is an EXACT string match for that pattern is still
# permitted as a deliberate operator override (e.g. allowing '.env' when '.env'
# is a deny pattern). A wildcard allow entry (e.g. '*.env' or '?env') that
# happens to match a literal-pattern canary is REJECTED — it is not an explicit
# operator decision.
canaries = []  # list of (canary_path, src_literal_or_None)
for pat in patterns:
    if not re.search(r'[*?\[\]]', pat):
        # Literal deny pattern: canary IS the pattern (no glob chars to expand).
        # Tag with src_literal so exact-match overrides remain permitted.
        canaries.append((pat, pat))
        canaries.append(('sub/dir/' + pat, pat))
        canaries.append(('config/' + pat, pat))
    else:
        lit = pat_to_literal(pat)
        if not lit:
            continue
        canaries.append((lit, None))
        canaries.append(('sub/dir/' + lit, None))
        canaries.append(('config/' + lit, None))

# #64 fix: when canary generation yields an empty set (all-literal deny list),
# fall back to built-in canaries so the validator is never vacuous.
# An empty canary set must NEVER mean every allow entry is permitted.
if not canaries:
    canaries = [('x.env', None), ('sub/dir/x.env', None), ('config/x.env', None),
                ('x.pem', None), ('sub/dir/x.pem', None), ('config/x.pem', None)]

errors = []
for entry in allow:
    for canary, src_literal in canaries:
        # Exact literal override: the operator deliberately listed the guarded filename.
        if src_literal is not None and entry == src_literal:
            continue
        base = os.path.basename(canary)
        if fnmatch.fnmatchcase(base.lower(), entry.lower()) or fnmatch.fnmatchcase(canary.lower(), entry.lower()):
            errors.append(
                'pipeline-vcs: ERROR: merge.forbidden_files_allow entry \'' + entry +
                '\' would exempt \'' + canary + '\' — rejected'
            )
            break  # one error per entry is sufficient
if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
" || return 1  # Fail closed: validation error or unexpected exception must block, not pass
  fi
  PATTERNS="$_patterns" ALLOW="$ALLOW" PAT_COUNT="$_pat_count" DEFAULTS_ACTIVE="$_defaults_active" python3 -I -c "
import fnmatch, os, sys
patterns = [p.strip() for p in os.environ['PATTERNS'].splitlines() if p.strip()]
allow = [a.strip() for a in os.environ.get('ALLOW','').splitlines() if a.strip()]
pat_count = os.environ.get('PAT_COUNT', '0')
defaults_active = os.environ.get('DEFAULTS_ACTIVE', 'in-force')
bad = []
for path in (l.strip() for l in sys.stdin if l.strip()):
    base = os.path.basename(path)
    # Case-insensitive (#436): .ENV and Credentials.JSON are as secret as the lowercase forms.
    base_l, path_l = base.lower(), path.lower()
    if any(fnmatch.fnmatchcase(base_l, a.lower()) or fnmatch.fnmatchcase(path_l, a.lower()) for a in allow):
        continue
    if any(fnmatch.fnmatchcase(base_l, p.lower()) or fnmatch.fnmatchcase(path_l, p.lower()) for p in patterns):
        bad.append(path)
if bad:
    print('FORBIDDEN FILES in PR — human review required before merge:')
    for p in bad: print(f'  {p}')
    sys.exit(1)
print(f'no forbidden files [{pat_count} patterns: defaults={defaults_active}]')
"
}

# GitLab flavor (#303) shared by _vcs_shared_check_closing_keyword,
# its sibling scan and _vcs_shared_find_pr: a closing keyword from GitLab's
# default issue_closing_pattern, an optional colon, whitespace, then a
# list. GitLab closes every reference in a list after one keyword --
# `Closes #1, #2 and #3`, `Closes issues #1 #2` -- so the target reference
# may follow other references (#N, group/proj#N or an .../issues/N URL),
# each with an optional `issue(s)` word and separated by spaces, a comma or
# `and`, as in GitLab's own pattern (spaces only, so a list never spans
# lines).
# Cost bound (the scan is linear): re.search tries a match at every
# position, but a match can only start on a keyword followed (after an
# optional colon) by WHITESPACE -- GitLab requires the space too, so
# `Fixes#42` and `Closes:#42` never close. No list item or separator holds
# such a keyword -- items end in a digit and hold no whitespace, separators are
# spaces, commas and `and` -- so a list stops before the next keyword, the
# lists of two keyword starts never overlap, and every character is walked
# from at most one keyword. Within one start every piece matches a given
# text one way only: items end on (?!\d), URL segments cannot contain `/`
# (one URL never swallows the next `https://`), and the separator is
# `(?: *,)? *(?:and +)?` rather than GitLab's ambiguous ` *,? *`, which
# splits each space run two ways. As a hard backstop that does not rely on
# that argument, a list holds at most 32 references before the target and
# callers scan only the first _VCS_GITLAB_SCAN_CAP characters of a
# description, so even an adversarial body costs at most 65536 starts x 33
# items. (Before this, a keyword needed no whitespace, so every `fix` in
# `fix#1 fix#1 ...` started a match that re-walked the rest of the list:
# quadratic, 2.9 s at 24 KB.)
# Interpolated into the python regex source as a raw string: keep it free
# of single quotes. The matching host_pat pins a /-/issues/N URL to the
# project's host; when the host is unknown (vcs.repo carries none and the
# origin remote has none either, or only an ssh alias -- see _gl_repo_host)
# any host still counts, as before, since there is nothing to compare
# against.
_VCS_GITLAB_CLOSING_PREFIX='(?:clos(?:e[sd]?|ing)|fix(?:e[sd]|ing)?|resolv(?:e[sd]?|ing)|implement(?:s|ed|ing)?):?\s+(?:(?:issues? +)?(?:(?:[\w.-]+(?:/[\w.-]+)*)?#\d+(?!\d)|https?://[^\s,/]+(?:/[^\s,/]+)*?/issues/\d+(?!\d))(?: *,)? *(?:and +)?){0,32}?(?:issues? +)?'
_VCS_GITLAB_SCAN_CAP=65536

# _vcs_shared_check_closing_keyword <issue_n> <pr_number> <pr_ref> <siblings-fetch-fn> [flavor] [host]
#   (#177 slice 4) Exit 0 when safe to merge; exit 1 when the candidate PR's
#   body (read from stdin) carries a closing keyword for <issue_n> AND
#   another OPEN PR still references the same issue (an unmerged sibling
#   from a multi-PR issue). See Rule 6 in the CLI usage comment near the top
#   of this file.
#
#   stdin:  the candidate PR's raw body text.
#   args:   issue_n           -- issue number the candidate PR claims to close.
#           pr_number         -- the candidate PR's own number (excluded from
#                                 the sibling scan; falls back to pr_ref in
#                                 the diagnostic message when empty).
#           pr_ref            -- the original PR ref argument (branch name or
#                                 number) the verb was invoked with -- used
#                                 only as a diagnostic fallback label.
#           siblings-fetch-fn -- caller-supplied function name, invoked with
#                                 no arguments ONLY when a closing keyword is
#                                 present (preserves the original lazy fetch:
#                                 no sibling-list API call when there is
#                                 nothing to gate on). Must print a JSON
#                                 array of open PRs, each with number, state,
#                                 title, headRefName and body, and exit 0
#                                 when that list is complete; exit
#                                 $_VCS_SIBLINGS_CAPPED when it is only the
#                                 part below a hard cap (#319); or exit any
#                                 other non-zero on fetch failure.
#           flavor            -- optional, default "github". "gitlab" (#303)
#                                 widens the keywords to GitLab's default
#                                 issue_closing_pattern (adds closing/fixing/
#                                 resolving and implement[s|ed|ing], optional
#                                 colon), accepts a comma/"and" list after
#                                 one keyword (`Closes #1, #2 and #3` closes
#                                 all three, as on GitLab) and the URL form
#                                 to a same-project
#                                 https://<host>/<repo>/-/issues/N. Only
#                                 the first _VCS_GITLAB_SCAN_CAP characters
#                                 of each body are scanned. The github
#                                 regexes are unchanged.
#           host              -- optional, gitlab flavor only: the project's
#                                 host. When set, a /-/issues/N URL counts
#                                 only on that host; empty = any host.
#   env:    REPO -- "owner/name", scopes the #N / owner/repo#N / URL
#                    reference forms to the current repository. A missing
#                    REPO is an adapter-side "can we even ask" guard (fail
#                    open before calling this function) -- not shared logic.
#   stdout: nothing on the common paths; a `talos:closing-keyword-unverified`
#           marker when the sibling fetch fails or returns something this
#           function cannot parse (fail open), or when a capped list shows
#           no sibling (reason=siblings-capped: a sibling may sit past the
#           cap, so a human must check before merging).
#   exit:   0 safe to merge (no closing keyword, no open siblings, or a
#           fetch failure -- fail open); 1 blocked by an open sibling.
#
# NOTE (#221, filed 2026-09-08): a sibling is currently counted whenever its
# title/body mentions #<issue_n> in ANY form (Closes, Part of, an unrelated
# comment, ...). #221 wants siblings counted only when their own body has a
# closing keyword or a literal "Part of #N" -- tightening `body_pat` in the
# sibling-scan block below (or wrapping it in a `closing_or_part_of` check)
# is the entire fix. This slice intentionally leaves that behaviour
# unchanged.
# _vcs_shared_sibling_blocked <pr> <siblings> <claim> <remedy> (#304)
#   The one sibling-gate diagnostic (stderr), shared by
#   _vcs_shared_check_closing_keyword and the link-based azure gate so the
#   wording cannot drift. <siblings> is already formatted ("11 #12").
_vcs_shared_sibling_blocked() {
  echo "pipeline-vcs: check-closing-keyword: PR #$1 $3 but open sibling PR(s) still reference the same issue: #$2 — merge the siblings first, or $4" >&2
}

# A sibling fetch exits with this status when it printed only the part of
# the open-PR list below a hard cap (#319). The gate still blocks on a
# sibling it saw, but never reads "none seen" as "none open".
_VCS_SIBLINGS_CAPPED=3

# _vcs_shared_siblings_capped <pr> <issue> (#319): the capped-list outcome
# (stderr warning + fixed-literal marker), shared with the azure gate.
_vcs_shared_siblings_capped() {
  echo "pipeline-vcs: check-closing-keyword: the open-PR list hit its cap, so a sibling of #$2 may be missing -- check the open PRs by hand before merging" >&2
  echo "talos:closing-keyword-unverified pr=$1 issue=$2 reason=siblings-capped"
}

_vcs_shared_check_closing_keyword() {
  local issue_n="$1" pr_number="$2" pr_ref="$3" siblings_fetch_fn="$4" flavor="${5:-github}" host="${6:-}"
  local pr_body
  pr_body="$(cat)"

  # Check for a closing keyword for #<issue_n> in the PR body.
  # Patterns (case-insensitive):
  #   close/closes/closed/fix/fixes/fixed/resolve/resolves/resolved
  #   followed by optional whitespace and then one of:
  #     #N              — bare, implicitly current repo (unmodified)
  #     repo#N          — single-segment, no slash (unmodified)
  #     owner/repo#N    — scoped to current repo (case-insensitive)
  #     GH-N            — case-insensitive; left-guard prevents digit-prefix collision
  #     https://github.com/<owner>/<repo>/issues/N  — scoped to current repo
  local has_closing
  has_closing="$(printf '%s' "$pr_body" | python3 -I -c "
import re, sys
body = sys.stdin.read()
n    = sys.argv[1]
repo = sys.argv[2]   # owner/name — already stripped of .git suffix, passed from \$REPO
# Closing keywords (case-insensitive)
kw = r'(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)'
gitlab = sys.argv[3] == 'gitlab'
if gitlab:
    kw = r'$_VCS_GITLAB_CLOSING_PREFIX'
    body = body[:$_VCS_GITLAB_SCAN_CAP]
    host_pat = (re.escape(sys.argv[4]) + r'(?::\d+)?') if sys.argv[4] else r'[^/\s]+'
# Resolve owner and repo name for repo-scoped patterns (case-insensitive).
repo_lc = repo.lower()
if '/' in repo_lc:
    _owner_lc, _name_lc = repo_lc.split('/', 1)
else:
    _owner_lc = repo_lc; _name_lc = repo_lc
owner_esc = re.escape(_owner_lc)
name_esc  = re.escape(_name_lc)
n_esc = re.escape(n)
# Reference forms:
#   1. Hash forms — unified with boundary to prevent mid-token matches:
#      (?<!\w)(?<!/) ensures the engine cannot start a match in the middle of
#      a foreign owner/repo token (e.g. the 'repo' segment of 'other/repo#N').
#      Alternation (tried left-to-right):
#        a. owner/repo#N — must match current repo exactly (case-insensitive)
#        b. repo#N — single-segment (no slash), implicitly current-server; unscoped
#        c. #N — bare form (empty prefix)
#   2. GH-N  case-insensitive; left-guard prevents digit-prefix collision
#   3. URL — scoped to current repo (case-insensitive on owner/name)
ref_hash = (
    r'(?<!\w)(?<!/)(?:'
    + r'(?i:' + owner_esc + r'/' + name_esc + r')'   # 1a: owner/repo#N (scoped)
    + r'|[A-Za-z0-9_.-]+'                              # 1b: repo#N (single-segment)
    + r'|'                                              # 1c: bare #N (empty prefix)
    + r')#' + n_esc + r'(?!\d)'
)
ref_gh  = r'(?<![0-9])[Gg][Hh]-' + n_esc + r'(?!\d)'
ref_url = (r'https://github\.com/(?i:' + owner_esc + r'/' + name_esc + r')'
           + r'/issues/' + n_esc + r'(?!\d)')
if gitlab:
    ref_url = (r'https?://' + host_pat + r'/(?i:' + owner_esc + r'/' + name_esc + r')'
               + r'(?:/-)?/issues/' + n_esc + r'(?!\d)')
ref = r'(?:' + ref_hash + r'|' + ref_gh + r'|' + ref_url + r')'
pattern = (kw if gitlab else kw + r'\s+') + ref
if re.search(pattern, body, re.IGNORECASE):
    print('yes')
else:
    print('no')
" "$issue_n" "$REPO" "$flavor" "$host" 2>/dev/null)"

  # No closing keyword → nothing to check.
  if [ "$has_closing" != "yes" ]; then
    return 0
  fi

  # Closing keyword found. Fetch open PRs for this issue (lazily -- only now
  # that we know we need them) and filter out the current PR by number.
  local siblings_json fetch_rc=0
  siblings_json="$("$siblings_fetch_fn")" || fetch_rc=$?
  if [ -z "$siblings_json" ] || { [ "$fetch_rc" -ne 0 ] && [ "$fetch_rc" -ne "$_VCS_SIBLINGS_CAPPED" ]; }; then
    echo "pipeline-vcs: check-closing-keyword: could not fetch open PR list — skipping sibling check" >&2
    echo "talos:closing-keyword-unverified pr=${pr_number:-$pr_ref} issue=$issue_n reason=sibling-fetch-failed"
    return 0
  fi

  # Find open siblings (any PR referencing #N in branch/title/body, excluding this PR).
  local sibling_result
  sibling_result="$(printf '%s' "$siblings_json" | python3 -I -c "
import json, re, sys
n    = sys.argv[1]
self = sys.argv[2]
repo = sys.argv[3]   # owner/name — passed from \$REPO, same as has_closing block
# Resolve repo components for scoped matching (case-insensitive).
repo_lc = repo.lower()
if '/' in repo_lc:
    _owner_lc, _name_lc = repo_lc.split('/', 1)
else:
    _owner_lc = repo_lc; _name_lc = repo_lc
owner_esc = re.escape(_owner_lc)
name_esc  = re.escape(_name_lc)
n_esc = re.escape(n)
# Four-branch pattern for sibling body matching (#113: added GH-N and URL forms):
#   Branch 1: own-repo qualified form — owner/repo#N (current repo only, case-insensitive)
#   Branch 2: bare #N — not preceded by a word char or slash
#     (?<!/) excludes foreign repo#N suffixes; (?<!\w) excludes alphanumeric prefixes
#   Branch 3: GH-N (case-insensitive) — same boundary guards as has_closing
#   Branch 4: https://github.com/<owner>/<repo>/issues/N (scoped to current repo)
own_repo_pat = r'(?<!\w)(?i:' + owner_esc + r'/' + name_esc + r')#' + n_esc + r'(?!\d)'
bare_pat      = r'(?<!\w)(?<!/)#' + n_esc + r'(?!\d)'
gh_pat        = r'(?<![0-9])[Gg][Hh]-' + n_esc + r'(?!\d)'
url_pat       = (r'https://github\.com/(?i:' + owner_esc + r'/' + name_esc + r')'
                 + r'/issues/' + n_esc + r'(?!\d)')
gitlab = sys.argv[4] == 'gitlab'
cap = $_VCS_GITLAB_SCAN_CAP if gitlab else None
if gitlab:
    host_pat = (re.escape(sys.argv[5]) + r'(?::\d+)?') if sys.argv[5] else r'[^/\s]+'
    url_pat = (r'https?://' + host_pat + r'/(?i:' + owner_esc + r'/' + name_esc + r')'
               + r'(?:/-)?/issues/' + n_esc + r'(?!\d)')
ref_pat = r'(?:' + own_repo_pat + r'|' + bare_pat + r'|' + gh_pat + r'|' + url_pat + r')'
# #221: a sibling counts only when one of the four reference forms above is
# introduced by a real closing keyword (close/closes/closed/fix/fixes/fixed/
# resolve/resolves/resolved, optionally followed by a colon) or by a
# Part of #N line -- a bare prose mention (See #42, Related to #42,
# owned by #42) must NOT count as a sibling.
kw_prefix     = r'(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s*'
if gitlab:
    kw_prefix = r'$_VCS_GITLAB_CLOSING_PREFIX'
partof_prefix = r'\bpart\s+of\s+'
body_pat = r'(?:' + kw_prefix + r'|' + partof_prefix + r')' + ref_pat
try: prs = json.load(sys.stdin)
except Exception: prs = []
siblings = []
for pr in prs:
    if str(pr.get('number','')) == self:
        continue
    ref = pr.get('headRefName','')
    hay = (pr.get('title','') + ' ' + (pr.get('body','') or ''))[:cap]
    branch_match = bool(re.search(r'(?:^|/)issue-' + n_esc + r'(?:-|$)', ref))
    body_match   = bool(re.search(body_pat, hay, re.IGNORECASE))
    if branch_match or body_match:
        siblings.append(str(pr.get('number','')))
if siblings:
    print('blocked:' + ','.join(siblings))
else:
    print('ok')
" "$issue_n" "${pr_number:-}" "$REPO" "$flavor" "$host" 2>/dev/null)"

  case "$sibling_result" in
    ok)
      [ "$fetch_rc" -eq "$_VCS_SIBLINGS_CAPPED" ] && _vcs_shared_siblings_capped "${pr_number:-$pr_ref}" "$issue_n"
      return 0
      ;;
    blocked:*)
      local sibling_list="${sibling_result#blocked:}"
      _vcs_shared_sibling_blocked "${pr_number:-$pr_ref}" "${sibling_list/,/ #}" \
        "carries 'Closes #${issue_n}'" "change this PR body to 'Part of #${issue_n}'"
      return 1
      ;;
    *)
      # Unexpected output from python3 — fail open.
      echo "pipeline-vcs: check-closing-keyword: unexpected sibling-check output — skipping" >&2
      echo "talos:closing-keyword-unverified pr=${pr_number:-$pr_ref} issue=$issue_n reason=sibling-check-failed"
      return 0
      ;;
  esac
}

# _vcs_shared_find_pr <issue_n>
#   (#177 slice 4) The issue-reference matching. State filtering (open/closed/
#   merged/all) is NOT shared: the GitHub REST list-PRs endpoint has no
#   `merged` state -- the GitHub adapter maps merged to state=closed plus an application-side
#   merged_at check, and normalises `state` to OPEN/CLOSED/MERGED and
#   `headRefName` (from `head.ref`) before calling this function. That
#   normalisation is genuinely provider-specific, so it stays in the
#   adapter; this function does only the part both sides agreed on anyway.
#   stdin:  a JSON array of PR objects, each already normalised by the
#           caller to {number, state, title, headRefName, body}.
#   args:   issue_n -- the issue number to match branches/bodies against.
#           state   -- the requested state (default open). For `merged` (#298)
#                      the body/title match is STRICT: only a closing keyword
#                      (close[sd]?|fix(e[sd])?|resolve[sd]?, optional `:`)
#                      directly before a reference to THIS repo's #N counts:
#                      bare #N always; GH-N, <repo>#N and an
#                      http(s)://<host>/<repo>[/-]/issues/N URL only when
#                      `repo` is known, <repo> compared case-insensitively.
#                      Another repo's `Closes other/repo#N` must not close
#                      ours, and a bare mention (`Depends on #N`, `Part of
#                      #N`) must not count at all, or the Step 1 heal closes
#                      the parent epic and unfinished dependencies. Other
#                      states keep the loose bare-#N match (adopt-orphaned-PR).
#           repo    -- optional current repo, "owner/name" (GitLab:
#                      "group[/sub]/project"). Empty or not of that shape
#                      means no identity to compare: fail closed and accept
#                      only a bare #N after the keyword.
#           flavor  -- optional, default "github". "gitlab" (#303) widens
#                      the merged-state keywords to GitLab's default
#                      issue_closing_pattern (closing/fixing/resolving,
#                      implement[s|ed|ing]) and accepts a comma/"and"
#                      list after one keyword, scanning only the first
#                      _VCS_GITLAB_SCAN_CAP characters; github is unchanged.
#           host    -- optional, gitlab flavor only: the project's host; a
#                      /-/issues/N URL then counts only on that host.
#   stdout: one JSON object per matching PR: {number, state, title, headRefName}.
_vcs_shared_find_pr() {
  local n="$1" state="${2:-open}" repo="${3:-}" flavor="${4:-github}" host="${5:-}"
  python3 -I -c "
import json, re, sys
n, state, repo = sys.argv[1], sys.argv[2], sys.argv[3]
n_esc = re.escape(n)
cap = None   # gitlab merged: scan only the first _VCS_GITLAB_SCAN_CAP chars
if state == 'merged':
    kw   = r'(?<![\w-])(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s*'
    host_pat = r'[^/\s]+'
    if sys.argv[4] == 'gitlab':
        cap = $_VCS_GITLAB_SCAN_CAP
        host_pat = (re.escape(sys.argv[5]) + r'(?::\d+)?') if sys.argv[5] else r'[^/\s]+'
        kw = r'(?<![\w-])' + r'$_VCS_GITLAB_CLOSING_PREFIX'
    refs = [r'(?<![\w/])#' + n_esc]
    if re.fullmatch(r'[\w.-]+(?:/[\w.-]+)+', repo):
        r_esc = re.escape(repo)
        refs += [r'(?<!\d)GH-' + n_esc,
                 r'(?<![\w/])' + r_esc + r'#' + n_esc,
                 r'https?://' + host_pat + r'/' + r_esc + r'(?:/-)?/issues/' + n_esc]
    body_re = re.compile(kw + r'(?:' + '|'.join(refs) + r')(?!\d)', re.IGNORECASE)
else:
    body_re = re.compile(r'#' + n_esc + r'(?!\d)')
try: prs = json.load(sys.stdin)
except Exception: prs = []
for pr in prs:
    ref = pr.get('headRefName','')
    hay = (pr.get('title','') + ' ' + (pr.get('body','') or ''))[:cap]
    branch_match = bool(re.search(r'(?:^|/)issue-' + n_esc + r'(?:-|$)', ref))
    body_match   = bool(body_re.search(hay))
    if branch_match or body_match:
        print(json.dumps({k: pr.get(k) for k in ('number','state','title','headRefName')}))
" "$n" "$state" "$repo" "$flavor" "$host"
}

# _vcs_shared_pr_mergeable <status-fetch-fn>
#   (#177 slice 4) The retry/backoff loop and MERGEABLE/CONFLICTING/UNKNOWN
#   exit-code contract.
#   <status-fetch-fn> is a caller-supplied function name, invoked with no
#   arguments on every attempt; it must print exactly one of MERGEABLE /
#   CONFLICTING / UNKNOWN (anything else is treated as "still computing" and
#   retried) -- translating the provider's native mergeable representation
#   (gh: MERGEABLE/CONFLICTING/UNKNOWN directly via `--json mergeable -q
#   .mergeable`; REST: true/false/null via `.mergeable`) is the adapter's
#   job. Retries up to 4 times, sleeping a TALOS_RETRY_SLEEP_SCALE-scaled 2s
#   between attempts -- same scale/default/validation as _with_retry, but
#   this is a value-based poll (GitHub computes mergeability lazily), not a
#   rate-limit retry, so it does not route through _with_retry itself.
#   stdout: exactly one of MERGEABLE / CONFLICTING / UNKNOWN.
#   exit:   0 MERGEABLE, 1 CONFLICTING, 2 UNKNOWN (still unresolved after retries).
_vcs_shared_pr_mergeable() {
  local status_fetch_fn="$1"
  local scale
  scale="${TALOS_RETRY_SLEEP_SCALE:-1}"
  if ! grep -qE '^[0-9]+(\.[0-9]+)?$' <<<"$scale"; then
    scale=1
  fi
  local attempt=0 pm_status
  while :; do
    pm_status="$("$status_fetch_fn")"
    case "$pm_status" in
      MERGEABLE)   echo MERGEABLE;   return 0 ;;
      CONFLICTING) echo CONFLICTING; return 1 ;;
    esac
    attempt=$((attempt + 1))
    [ "$attempt" -gt 4 ] && break
    sleep "$(awk -v s="$scale" 'BEGIN { printf "%.4f", 2 * s }')"
  done
  echo UNKNOWN
  return 2
}

# _vcs_shared_conflict_files <pr-number> <base-branch>
#   (#256) Provider-agnostic conflict detection for the Step 3c mergeability
#   gate: is a CONFLICTING PR's only conflict something mechanical (e.g.
#   CHANGELOG.md) that pipeline-mergebase.sh can resolve without a developer
#   dispatch? <pr-number>'s head is fetched via GitHub's own
#   `refs/pull/<n>/head` ref -- a plain git ref exposed for every PR
#   regardless of gh-CLI vs REST auth, so this needs no adapter-specific API
#   call; `_github` calls this directly with just the PR number and its
#   resolved base branch.
#
#   The actual merge attempt runs in a throwaway DETACHED worktree created
#   OUTSIDE the caller's own checkout (mktemp -d under ${TMPDIR:-/tmp}) --
#   `git status`/`assert-sync` on the caller's checkout are provably
#   unaffected (no branch is created, no ref in the caller's checkout
#   moves). The temp worktree is removed on every return path below,
#   including the error paths -- there is exactly one cleanup call site,
#   reached by falling through rather than by an EXIT trap (this runs as a
#   plain function inside the caller's own process/subshell, not a
#   standalone script, so an EXIT trap here would fire at the wrong time --
#   see pipeline-worktree.sh's identical fall-through-cleanup convention).
#   Both `git worktree add` and the cleanup `git worktree remove` are
#   serialized with `with_lock` (same resource key/timeout pipeline-
#   worktree.sh's create/remove/sweep and pipeline-mergebase.sh's own
#   worktree use, #180/#262) -- they mutate the same shared git-common-dir
#   metadata a concurrent stage may be touching under issues.max_parallel > 1.
#
#   stdout: one conflicting path per line (git diff --diff-filter=U against
#           the aborted merge attempt); nothing when the merge is clean.
#   exit:   0 -- merge attempt completed (0 or more conflicts printed).
#           2 -- could not determine: missing args, fetch failure, or the
#               merge/worktree machinery itself failed for a reason other
#               than a content conflict.
_vcs_shared_conflict_files() {
  local pr_n="$1" base="$2"
  if [ -z "$pr_n" ] || [ -z "$base" ]; then
    echo "pipeline-vcs: conflict-files: missing PR number or base branch" >&2
    return 2
  fi

  if ! git fetch -q origin "$base" 2>/dev/null; then
    echo "pipeline-vcs: conflict-files: git fetch origin $base failed" >&2
    return 2
  fi
  if ! git rev-parse -q --verify "origin/$base" >/dev/null 2>&1; then
    echo "pipeline-vcs: conflict-files: origin/$base does not resolve after fetch" >&2
    return 2
  fi
  if ! git fetch -q origin "refs/pull/$pr_n/head" 2>/dev/null; then
    echo "pipeline-vcs: conflict-files: git fetch origin refs/pull/$pr_n/head failed" >&2
    return 2
  fi
  local pr_head
  pr_head="$(git rev-parse -q --verify FETCH_HEAD 2>/dev/null)"
  if [ -z "$pr_head" ]; then
    echo "pipeline-vcs: conflict-files: could not resolve PR #$pr_n head" >&2
    return 2
  fi

  local tmpdir
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/talos-conflict-files.XXXXXX" 2>/dev/null)"
  if [ -z "$tmpdir" ]; then
    echo "pipeline-vcs: conflict-files: mktemp failed" >&2
    return 2
  fi

  # Locked the same way pipeline-worktree.sh's create/remove/sweep and
  # pipeline-mergebase.sh's own worktree add serialize against: `git
  # worktree add`/`remove` mutate the same shared git-common-dir metadata,
  # and this repo may be running other worktree-mutating stages
  # concurrently (issues.max_parallel > 1, #180).
  local _cf_lock_resource
  _cf_lock_resource="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/talos-worktree"

  local rc_out=2 paths=""
  if with_lock "$_cf_lock_resource" 10 -- \
      git worktree add -q --detach "$tmpdir" "$pr_head" >/dev/null 2>&1; then
    git -C "$tmpdir" -c user.email=talos@local -c user.name=talos-conflict-files \
      merge --no-commit --no-ff "origin/$base" >/dev/null 2>&1
    local merge_rc=$?
    case "$merge_rc" in
      0) rc_out=0 ;;
      1)
        paths="$(git -C "$tmpdir" diff --name-only --diff-filter=U 2>/dev/null)"
        rc_out=0
        ;;
      *)
        echo "pipeline-vcs: conflict-files: merge attempt exited $merge_rc" >&2
        rc_out=2
        ;;
    esac
  else
    echo "pipeline-vcs: conflict-files: could not create temp worktree for PR #$pr_n head" >&2
    rc_out=2
  fi

  # Single cleanup call site (see header comment) -- reached on every path above.
  with_lock "$_cf_lock_resource" 10 -- git worktree remove --force "$tmpdir" >/dev/null 2>&1
  rm -rf "$tmpdir" 2>/dev/null

  [ -n "$paths" ] && printf '%s\n' "$paths"
  return "$rc_out"
}

# ─────────────────────────────────────────────────────────────────────────────
# GITHUB CLIENT  (one REST client behind the `github` and `github-api` providers)
#   Transport: `gh api` when the gh CLI is on PATH and authenticated (it owns
#     auth and enterprise hosts), else curl with GITHUB_TOKEN / GH_TOKEN
#     (vcs.token_env names another variable); `github-api` pins curl. Both hand
#     the layers above the same status, headers and body, so retry, pagination
#     and error handling are written once. The token is never logged.
# ─────────────────────────────────────────────────────────────────────────────
_GH_ROOT="https://api.github.com"
_GH_JSON="application/vnd.github+json"
_GH_DIFF="application/vnd.github.v3.diff"
_GH_XPORT=""   # gh | curl, set by _gh_init
_GH_TOKEN=""   # token transport only
_GH_API=""     # repos/<owner>/<name>, relative to the API root
_GH_STATUS=""  # HTTP status of the last _gh_once

# _gh_init -- set the repo path and, unless --dry-run (which makes no call),
# pick the transport: once per process. Exits 1 when neither transport is
# usable. Call it from the main shell, never from a command substitution (the
# choice would not survive the subshell).
_gh_init() {
  [ -n "$_GH_API" ] && return 0
  _gh_cache_dir >/dev/null || :   # resolve the pass cache here, in the main shell, so the answer is kept
  local _env _tok=""
  if [ -n "$REPO" ]; then
    _GH_API="repos/$REPO"
  else
    _GH_API='repos/{owner}/{repo}'   # gh fills the placeholders from the checkout
  fi
  [ "$DRY_RUN" = "true" ] && return 0
  _env="$(cfg vcs.token_env)"
  [ -n "$_env" ] && _tok="${!_env:-}"
  [ -z "$_tok" ] && _tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ "$PROVIDER" != "github-api" ] && command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    _GH_XPORT=gh
  elif [ -n "$_tok" ]; then
    _GH_XPORT=curl
    _GH_TOKEN="$_tok"
  else
    echo "github: no authenticated gh CLI and GITHUB_TOKEN or GH_TOKEN required" >&2
    exit 1
  fi
  if [ "$_GH_XPORT" = curl ] && [ -z "$REPO" ]; then
    echo "github: cannot determine the repository (set vcs.repo)" >&2
    exit 1
  fi
}

# _gh_http <METHOD> <path> <accept> <hdr-file> [<payload-file>] -- one HTTP
# exchange on the chosen transport. Prints the body, then "\n<status>" (what
# `curl -w '\n%{http_code}'` gives); the response headers go to <hdr-file>.
# Returns non-zero, with the transport's own stderr, when no response arrived.
_gh_http() {
  local _m="$1" _p="$2" _acc="$3" _hdr="$4" _data="${5:-}" _raw _r=0 _crlf=$'\r\n'
  if [ "$_GH_XPORT" = gh ]; then
    # The trailing x keeps $(...) from eating the newlines that end an empty body.
    _raw="$(gh api -i -X "$_m" -H "Accept: $_acc" ${_data:+-H "Content-Type: application/json" --input "$_data"} "$_p" 2>"$_hdr.err"; _r=$?; printf x; exit "$_r")" || _r=$?
    _raw="${_raw%x}"
    case "$_raw" in
      HTTP/*) ;;
      *) cat "$_hdr.err" >&2; rm -f "$_hdr.err"; return "${_r:-1}" ;;
    esac
    rm -f "$_hdr.err"
    printf '%s\n' "${_raw%%"$_crlf$_crlf"*}" > "$_hdr"
    local _line="${_raw%%$'\n'*}"
    _line="${_line#* }"
    printf '%s\n%s' "${_raw#*"$_crlf$_crlf"}" "${_line%% *}"
    return 0
  fi
  local _args=(-sS -w "\n%{http_code}" -D "$_hdr" -X "$_m"
    -H "Authorization: Bearer $_GH_TOKEN" -H "Accept: $_acc" -H "X-GitHub-Api-Version: 2022-11-28")
  if [ -n "$_data" ]; then
    curl "${_args[@]}" -H "Content-Type: application/json" --data-binary @- "$_GH_ROOT/$_p" < "$_data"
  else
    curl "${_args[@]}" "$_GH_ROOT/$_p"
  fi
}

# ── Per-pass read cache (#554) ───────────────────────────────────────────────
# One approval is five verbs (pr-head, read-comments, comment-pr, label-pr,
# check-approval-sha), each its own process, and each used to read the same PR,
# its comments and the caller's login again. A pass that wants them shared makes
# a directory, writes its own pid to <dir>/owner and exports TALOS_PASS_CACHE
# (post-approval does); the verbs below it then read through that directory.
#   - Only successes are stored: a failed read is read again, never replayed.
#   - Any write through the client (_gh_once with a method other than GET)
#     empties the directory, so a read after a write is always live. The login
#     (`user`) survives: a write cannot change who the token belongs to.
#   - Comments are stored against the head SHA of the PR object cached beside
#     them (comments-<n>-<sha>), and read only while that PR object is still
#     the one cached: a new head never reads the old head's comments.
#   - The directory is honoured only for a process under the pass that owns it
#     (<dir>/owner is an ancestor of this process), so a stale exported variable
#     in someone's shell, or a directory left by a dead pass, caches nothing.
#     (This is hygiene, not a boundary: a caller that can plant a directory can
#     already post markers with the token it holds.)
#   - A standalone verb has no pass, so no cache: behaviour is unchanged.
_GH_CACHE=""   # unset = not resolved yet; "-" = off; else the directory

# _gh_cache_dir -- prints the pass directory and returns 0, or returns 1 (and
# prints nothing) when this process has none. Memoised for the process.
_gh_cache_dir() {
  local _cd="${TALOS_PASS_CACHE:-}" _own _p="$$" _i=0
  if [ -z "$_GH_CACHE" ]; then
    _GH_CACHE="-"
    if [ -n "$_cd" ] && [ -d "$_cd" ] && [ -O "$_cd" ] && [ ! -L "$_cd" ] && [ "$DRY_RUN" != "true" ]; then
      _own="$(cat "$_cd/owner" 2>/dev/null)"
      case "$_own" in
        ''|*[!0-9]*) ;;
        *)
          while [ "$_i" -lt 12 ] && [ -n "$_p" ] && [ "$_p" -gt 1 ] 2>/dev/null; do
            if [ "$_p" = "$_own" ]; then _GH_CACHE="$_cd"; break; fi
            _p="$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d '[:space:]')"
            _i=$((_i + 1))
          done ;;
      esac
    fi
  fi
  [ "$_GH_CACHE" != "-" ] || return 1
  printf '%s' "$_GH_CACHE"
}
# _gh_cache_get <key> -- the stored body, else return 1.
_gh_cache_get() {
  local _cd
  _cd="$(_gh_cache_dir)" || return 1
  [ -s "$_cd/$1" ] || return 1
  cat "$_cd/$1"
}
# _gh_cache_put <key> -- stdin: the body to store (a no-op without a pass).
_gh_cache_put() {
  local _cd _t
  _cd="$(_gh_cache_dir)" && _t="$(mktemp "$_cd/.put.XXXXXX" 2>/dev/null)" || { cat >/dev/null; return 0; }
  cat > "$_t" && mv "$_t" "$_cd/$1" || rm -f "$_t"
}
# _gh_cache_clear -- a write happened: forget everything but the login.
_gh_cache_clear() {
  local _cd _f
  _cd="$(_gh_cache_dir)" || return 0
  for _f in "$_cd"/*; do
    [ -e "$_f" ] || continue
    [ "${_f##*/}" = owner ] || [ "${_f##*/}" = user ] || rm -f "$_f"
  done
}
# _gh_pull_cached <n> -- the pull request as REST prints it, from the pass cache
# when it holds one. Non-zero, nothing stored, when the read fails.
_gh_pull_cached() {
  local _pc
  if _pc="$(_gh_cache_get "pr-$1")"; then printf '%s' "$_pc"; return 0; fi
  _pc="$(_gh_try GET "$_GH_API/pulls/$1")" || return 1
  [ -n "$_pc" ] && printf '%s' "$_pc" | _gh_cache_put "pr-$1"
  printf '%s' "$_pc"
}

# _gh_once <METHOD> <path> <accept> <payload-file|""> [<next-file>] -- one
# attempt, shaped for _with_retry: the body on success; on a rate limit it sets
# $_WR_RETRYABLE (from the status, never message text) and $_WR_RETRY_AFTER.
# With <next-file> it writes the next page's Link (empty if none) there: a
# file, since a global would not survive _with_retry's command substitution.
_gh_once() {
  local _m="$1" _p="$2" _acc="$3" _data="${4:-}" _next_file="${5:-}"
  local _hdr _full _status _body _rc=0 _reset
  [ "$_m" = GET ] || _gh_cache_clear
  _hdr="$(mktemp)"
  _full="$(_gh_http "$_m" "$_p" "$_acc" "$_hdr" "$_data")" || {
    _rc=$?
    printf 'github: %s failed (exit %s) on %s\n' "$_GH_XPORT" "$_rc" "$VERB" >&2
    rm -f "$_hdr"
    return 1
  }
  _status="${_full##*$'\n'}"
  _body="${_full%$'\n'*}"
  _GH_STATUS="$_status"
  [ -n "$_next_file" ] && grep -i '^link:' "$_hdr" \
    | grep -o '<[^>]*>; rel="next"' \
    | sed 's/<\([^>]*\)>; rel="next"/\1/' > "$_next_file"
  if [ "${_status:-0}" -ge 300 ] 2>/dev/null; then
    if [ "$_status" = "429" ] || { [ "$_status" = "403" ] && grep -qiE 'secondary rate limit|abuse detection' <<<"$_body"; }; then
      _WR_RETRYABLE=1
      _WR_RETRY_AFTER="$(grep -i '^retry-after:' "$_hdr" 2>/dev/null | head -1 | sed 's/[^0-9]*//g' | tr -d '[:space:]')"
      _reset="$(grep -i '^x-ratelimit-reset:' "$_hdr" 2>/dev/null | sed 's/[^0-9]*//g' | tr -d '[:space:]')"
      printf 'github: HTTP %s on %s (rate-limited%s)\n' "$_status" "$VERB" "${_reset:+; reset at $_reset}" >&2
    elif [ -n "$_next_file" ]; then
      printf 'github: HTTP %s fetching page: %s\n' "$_status" "$_p" >&2
    else
      printf 'github: HTTP %s on %s\n' "$_status" "$VERB" >&2
    fi
    rm -f "$_hdr"
    return 1
  fi
  rm -f "$_hdr"
  printf '%s' "$_body"
}

# _gh_try <METHOD> <path> [<json-payload>] -- _gh_once under _with_retry. Prints
# the body; returns 1 on failure (a best-effort caller can carry on). A payload
# is staged in a file and reaches the transport on stdin, never as an argument:
# argv caps one string at 128 KiB on Linux, which an escaped body can exceed.
_gh_try() {
  local _m="$1" _p="$2" _f="" _rc=0
  if [ $# -ge 3 ]; then
    _f="$(mktemp)" || return 1
    printf '%s' "$3" > "$_f" || { rm -f "$_f"; return 1; }
  fi
  _with_retry "$VERB" _gh_once "$_m" "$_p" "$_GH_JSON" "$_f" || _rc=$?
  [ -n "$_f" ] && rm -f "$_f"
  return "$_rc"
}

# _gh_req <METHOD> <path> [<json-payload>] -- _gh_try that exits 1 on failure.
_gh_req() {
  local _body
  _body="$(_gh_try "$@")" || exit 1
  printf '%s' "$_body"
}

# _gh_diff <path> -- the unified diff of a pull request.
_gh_diff() {
  local _body
  _body="$(_with_retry "$VERB" _gh_once GET "$1" "$_GH_DIFF" "")" || exit 1
  printf '%s\n' "$_body"
}

# _gh_rel_path <url> -- when <url> is on the API origin (https, same host and
# port) prints its path and query relative to the root, else prints the refused
# scheme://host:port and returns 1. Parsed with urllib.parse (#320); userinfo,
# backslashes, whitespace and control characters are refused outright, so curl
# cannot read a different host out of the same string.
_gh_rel_path() {
  python3 -I -c '
import sys
from urllib.parse import urlsplit

def origin(url):
    p = urlsplit(url)
    scheme = p.scheme.lower()
    port = p.port if p.port is not None else {"https": 443, "http": 80}.get(scheme)
    return p, (scheme, p.hostname or "", port)

try:
    p, got = origin(sys.argv[2])
except ValueError:
    print("<unparseable URL>")
    sys.exit(1)
odd = any(ord(c) <= 0x20 or c in "\\\x7f" for c in sys.argv[2])
if odd or p.username is not None or got[0] != "https" or got != origin(sys.argv[1])[1]:
    host = "".join(c for c in got[1] if c.isprintable() and c not in " \\") or "<no host>"
    port = "" if got[2] is None else ":%s" % got[2]
    print("%s://%s%s" % (got[0] or "<no scheme>", host, port))
    sys.exit(1)
print(p.path.lstrip("/") + ("?" + p.query if p.query else ""))
' "$_GH_ROOT" "$1"
}

# _gh_pages <path> [<max-pages> <noun> [<key>]] -- every page of a REST list
# endpoint, following Link: rel="next". Prints one JSON array; with <key> each
# page is an object whose list sits under <key> (check runs, workflow runs) and
# the result is {"total_count": N, "<key>": [...]}. <max-pages> stops there and
# warns on stderr (#302: a truncated lookup must never look like an empty one).
# Returns 1 with NOTHING on stdout on any failed or wrong-shaped page (#319), so
# callers read non-zero as "no usable data". Next links are pinned to the API
# origin before a request carries a token (#320).
_gh_pages() {
  local _gp_path="$1" _gp_max="${2:-}" _gp_noun="${3:-items}" _gp_key="${4:-}"
  local _gp_all _gp_body _gp_next_file _gp_pages=0 _gp_url _gp_ref
  _gp_all="[]"
  [ -n "$_gp_key" ] && _gp_all="{\"$_gp_key\": []}"
  _gp_next_file="$(mktemp)"
  while [ -n "$_gp_path" ]; do
    : > "$_gp_next_file"
    if ! _gp_body="$(_with_retry "$VERB" _gh_once GET "$_gp_path" "$_GH_JSON" "" "$_gp_next_file")"; then
      rm -f "$_gp_next_file"
      return 1
    fi
    # Both go in on stdin -- the merged result on the first line (json.dump
    # writes no newline), then the page -- because an env var this size hits
    # E2BIG (128 KB per string on Linux).
    _gp_all="$(printf '%s\n%s' "$_gp_all" "$_gp_body" | KEY="$_gp_key" URL="$_gp_path" python3 -I -c "
import json, os, sys
prev, _, page = sys.stdin.read().partition('\n')
prev = json.loads(prev)
key = os.environ['KEY']
try:
    page = json.loads(page)
except ValueError:
    page = None
if key:
    if not isinstance(page, dict) or not isinstance(page.get(key), list):
        sys.exit('github: page is not a JSON object with a ' + key + ' list: ' + os.environ['URL'])
    prev[key].extend(page[key])
    prev.setdefault('total_count', page.get('total_count'))
else:
    if not isinstance(page, list):
        sys.exit('github: page is not a JSON array: ' + os.environ['URL'])
    prev.extend(page)
json.dump(prev, sys.stdout)
")" || { rm -f "$_gp_next_file"; return 1; }
    _gp_url="$(cat "$_gp_next_file")"
    _gp_path=""
    _gp_pages=$((_gp_pages + 1))
    if [ -n "$_gp_url" ]; then
      if [ -n "$_gp_max" ] && [ "$_gp_pages" -ge "$_gp_max" ]; then
        printf 'pipeline-vcs: %s: WARNING result capped at %s pages (github page cap) -- some %s may be missing\n' \
          "$VERB" "$_gp_max" "$_gp_noun" >&2
        break
      fi
      if ! _gp_ref="$(_gh_rel_path "$_gp_url")"; then
        printf 'github: %s: refusing to follow pagination link to %s (not the API origin); no token sent\n' \
          "$VERB" "$_gp_ref" >&2
        rm -f "$_gp_next_file"
        return 1
      fi
      _gp_path="$_gp_ref"
    fi
  done
  rm -f "$_gp_next_file"
  printf '%s' "$_gp_all"
}

# _gh_comments <issue-or-pr-n> -- every comment as a JSON array.
_gh_comments() { _gh_pages "$_GH_API/issues/$1/comments?per_page=100"; }

# _gh_user_login -- resolver for _vcs_shared_current_user (#187): GET /user, print
# .login. Non-zero when the request fails (403 for an Actions GITHUB_TOKEN or a
# GitHub App token, a rate limit) or the login is missing, null, empty or not a
# string: that is "refused" (#453, #455) and the marker readers then trust only
# markers.trusted_authors. One attempt, no exit: a failure is a state.
_gh_user_login() {
  local _ul_body _ul_login
  if _ul_login="$(_gh_cache_get user)"; then printf '%s\n' "$_ul_login"; return 0; fi
  _ul_body="$(_gh_once GET user "$_GH_JSON" "" 2>/dev/null)" || return 1
  _ul_login="$(printf '%s' "$_ul_body" | python3 -I -c "
import json, sys
try:
    login = json.load(sys.stdin).get('login')
except Exception:
    sys.exit(1)
if not isinstance(login, str) or not login.strip():
    sys.exit(1)
print(login)
" 2>/dev/null)" || return 1
  printf '%s\n' "$_ul_login" | _gh_cache_put user
  printf '%s\n' "$_ul_login"
}


# _gh_num <verb> <kind> <value> -- exit 1 unless <value> is a plain number: it
# becomes a URL path segment, so nothing else may reach a request.
_gh_num() {
  case "$3" in
    ''|*[!0-9]*) echo "pipeline-vcs: $1: $2 number must be numeric (got '$3')" >&2; exit 1 ;;
  esac
}

# _gh_urlenc <text> [<safe-chars>] -- percent-encode <text> for a URL path or
# query value (default: everything but unreserved characters).
_gh_urlenc() {
  python3 -I -c 'import sys; from urllib.parse import quote; sys.stdout.write(quote(sys.argv[1], safe=sys.argv[2]))' "$1" "${2:-}"
}

# _gh_field <dotted.path> -- stdin: JSON. Prints that field (empty when it is
# absent or null); non-zero when stdin is not JSON.
_gh_field() {
  python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
for k in sys.argv[1].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)' "$1"
}

# _gh_body_json -- stdin: text. Prints {"body": <text>}; the body never rides on
# argv (#455).
_gh_body_json() {
  python3 -I -c '
import json, sys
sys.stdout.write(json.dumps({"body": sys.stdin.buffer.read().decode("utf-8", errors="replace")}))'
}

# _gh_pr_num <ref> -- prints the PR number for a number or a branch name (the
# open PR for that head, else the newest PR of any state). Non-zero when none.
_gh_pr_num() {
  case "$1" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  local _head="$1" _st _raw _n
  case "$_head" in *:*) ;; *) _head="${REPO%%/*}:$_head" ;; esac
  _head="$(_gh_urlenc "$_head" ':/')"
  for _st in open all; do
    _raw="$(_gh_try GET "$_GH_API/pulls?state=$_st&head=$_head&per_page=1")" || return 1
    _n="$(printf '%s' "$_raw" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
print(d[0]["number"] if isinstance(d, list) and d else "")')" || return 1
    [ -n "$_n" ] && { printf '%s' "$_n"; return 0; }
  done
  return 1
}

# _gh_pull <number|branch> -- the pull request, as REST prints it. Exits 1 when
# it cannot be read.
_gh_pull() {
  local _n
  _n="$(_gh_pr_num "$1")" || { echo "pipeline-vcs: $VERB: no pull request found for '$1'" >&2; exit 1; }
  _gh_req GET "$_GH_API/pulls/$_n"
}

# _gh_comments_obj <n> -- {"comments": [...]} for an issue or PR: every comment,
# each with author.login and createdAt next to the REST fields. Non-zero when
# any page fails.
_gh_comments_obj() {
  local _raw _ck="" _sha _obj
  # In a pass (#554) the comments are stored against the cached PR's head SHA.
  _sha="$(_gh_cache_get "pr-$1" | _gh_field head.sha 2>/dev/null)"
  [ -z "$_sha" ] || _ck="comments-$1-$_sha"
  if [ -n "$_ck" ] && _obj="$(_gh_cache_get "$_ck")"; then printf '%s' "$_obj"; return 0; fi
  _raw="$(_gh_comments "$1")" || return 1
  [ -n "$_raw" ] || return 1
  _obj="$(printf '%s' "$_raw" | _vcs_shared_normalize_comments)" || return 1
  [ -z "$_ck" ] || printf '%s' "$_obj" | _gh_cache_put "$_ck"
  printf '%s' "$_obj"
}

# _gh_marker_data <pr> -- {"headRefOid", "baseRefName", "labels", "comments"} for
# the approval-marker readers, from two REST reads (the PR, every comment).
# Non-zero, nothing on stdout, when either fails.
_gh_marker_data() {
  local _pr _cm
  _pr="$(_gh_pull_cached "$1")" || return 1
  _cm="$(_gh_comments_obj "$1")" || return 1
  [ -n "$_pr" ] || return 1
  printf '%s\n%s' "$_cm" "$_pr" | python3 -I -c '
import json, sys
head, _, pr = sys.stdin.read().partition("\n")
pr = json.loads(pr)
json.dump({"headRefOid": (pr.get("head") or {}).get("sha", ""),
           "baseRefName": (pr.get("base") or {}).get("ref", ""),
           "labels": [{"name": l.get("name", "")} for l in pr.get("labels") or []],
           "comments": json.loads(head)["comments"]}, sys.stdout)'
}

# _gh_check_table <pr> [<required names>] -- one "name TAB state TAB elapsed TAB
# url" line per check on the PR's head commit: its check runs plus its legacy
# commit statuses. State is pass | fail | pending | skipping | cancel. The
# commit-status read is skipped when <required names> (newline separated) are
# all check runs already. Non-zero when a read fails.
_gh_check_table() {
  local _sha _runs _stat='{"statuses":[]}' _tbl _name
  _sha="$(_gh_try GET "$_GH_API/pulls/$1" | _gh_field head.sha)" || return 1
  [ -n "$_sha" ] || return 1
  _runs="$(_gh_pages "$_GH_API/commits/$_sha/check-runs?per_page=100" "" "check runs" check_runs)" || return 1
  _tbl="$(printf '%s\n%s' "$_runs" "$_stat" | _gh_check_table_py)"
  local _need=0
  if [ -z "${2:-}" ]; then
    _need=1
  else
    while IFS= read -r _name; do
      [ -n "$_name" ] || continue
      printf '%s\n' "$_tbl" | cut -f1 | grep -qxF -- "$_name" || _need=1
    done <<<"$2"
  fi
  if [ "$_need" = 1 ]; then
    _stat="$(_gh_try GET "$_GH_API/commits/$_sha/status")" || return 1
    _tbl="$(printf '%s\n%s' "$_runs" "$_stat" | _gh_check_table_py)"
  fi
  printf '%s\n' "$_tbl"
}
_gh_check_table_py() {
  python3 -I -c '
import json, sys
from datetime import datetime
runs, _, stat = sys.stdin.read().partition("\n")
runs = json.loads(runs).get("check_runs") or []
try:
    stat = json.loads(stat).get("statuses") or []
except ValueError:
    stat = []

def secs(a, b):
    try:
        f = "%Y-%m-%dT%H:%M:%SZ"
        return max(0, int((datetime.strptime(b, f) - datetime.strptime(a, f)).total_seconds()))
    except Exception:
        return 0

def fmt(s):
    h, rest = divmod(s, 3600)
    m, sec = divmod(rest, 60)
    return (str(h) + "h" if h else "") + (str(m) + "m" if h or m else "") + str(sec) + "s" if s else "0"

for c in runs:
    if not c.get("name"):
        continue
    if c.get("status") != "completed":
        state = "pending"
    else:
        state = {"success": "pass", "skipped": "skipping", "neutral": "skipping",
                 "cancelled": "cancel"}.get(c.get("conclusion"), "fail")
    print("\t".join([c["name"], state, fmt(secs(c.get("started_at") or "", c.get("completed_at") or "")),
                     c.get("html_url") or c.get("details_url") or ""]))
for s in stat:
    if s.get("context"):
        state = {"success": "pass", "pending": "pending"}.get(s.get("state"), "fail")
        print("\t".join([s["context"], state, "0", s.get("target_url") or ""]))
'
}

# Provider calls for _vcs_shared_assign_issue (#299). _gh_try, not _gh_req:
# _gh_req exits the whole script on failure, and a failed assignment must
# never fail the verb that asked for it.
_gh_assignees_get() {
  local _ag_body
  _ag_body="$(_gh_try GET "$_GH_API/issues/$1")" || return 1
  printf '%s' "$_ag_body" | python3 -I -c "
import json, sys
for a in json.load(sys.stdin).get('assignees') or []:
    print(a.get('login', ''))
"
}
# POST .../assignees ADDS to the list (PATCH .../issues/{n} would replace it).
_gh_assignee_add() {
  local _aa_payload
  _aa_payload="$(python3 -I -c "import json, sys; print(json.dumps({'assignees': [sys.argv[1]]}))" "$2")"
  _gh_try POST "$_GH_API/issues/$1/assignees" "$_aa_payload"
}
# DELETE .../assignees takes one login off and keeps the others.
_gh_assignee_remove() {
  local _ar_payload
  _ar_payload="$(python3 -I -c "import json, sys; print(json.dumps({'assignees': [sys.argv[1]]}))" "$2")"
  _gh_try DELETE "$_GH_API/issues/$1/assignees" "$_ar_payload" >/dev/null
}

# Provider calls for the needs-owner verbs (#345). _gh_try (not _gh_req) so a
# failure returns to the shared helper, which owns the exit code. The issues
# endpoints serve issues and PRs alike.
_gh_no_items() { _gh_pages "$_GH_API/issues?state=open&labels=$_TALOS_NEEDS_OWNER_LABEL_URL&per_page=100"; }
_gh_no_post_comment() {
  local _np_payload
  _np_payload="$(printf '%s' "$2" | _gh_body_json)" || return 1
  _gh_try POST "$_GH_API/issues/$1/comments" "$_np_payload" >/dev/null
}
_gh_no_label_add() {
  _gh_try POST "$_GH_API/issues/$1/labels" "{\"labels\":[\"$_TALOS_NEEDS_OWNER_LABEL\"]}" >/dev/null
}
_gh_no_label_remove() {
  _gh_try DELETE "$_GH_API/issues/$1/labels/$_TALOS_NEEDS_OWNER_LABEL_URL" >/dev/null
}

# Provider calls for upsert-pr-comment (#381). The body is already in a file,
# which reaches the transport on stdin; the shared helper owns the exit code.
_gh_upc_read() { _gh_comments "$1"; }
_gh_upc_write() { _with_retry "$VERB" _gh_once "$1" "$_GH_API/$2" "$_GH_JSON" "$3"; }

# _gh_label_edit <issue|pr> <n> -- label-issue / label-pr (#455). The labels
# come from _parse_label_args' arrays: each is one JSON string or one URL path
# segment, never re-parsed by a shell. Additions are one POST and removals one
# DELETE each, so a concurrent label change is never overwritten; removing a
# label the item does not carry is not an error.
_gh_label_edit() {
  local _le_kind="$1" _le_n="$2" _le_lbl _le_err _le_rc _le_payload
  _gh_num "$VERB" "$_le_kind" "$_le_n"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] POST $_GH_API/issues/$_le_n/labels labels=${ADD_LABELS:-<none>}; DELETE $_GH_API/issues/$_le_n/labels/<label> for: ${REMOVE_LABELS:-<none>}"
    return 0
  fi
  if [ "${#ADD_LABEL_ARR[@]}" -gt 0 ]; then
    _le_payload="$(python3 -I -c 'import json, sys; print(json.dumps({"labels": sys.argv[1:]}))' "${ADD_LABEL_ARR[@]}")"
    _gh_req POST "$_GH_API/issues/$_le_n/labels" "$_le_payload" >/dev/null || exit 1
  fi
  for _le_lbl in ${REMOVE_LABEL_ARR[@]+"${REMOVE_LABEL_ARR[@]}"}; do
    _le_err="$(mktemp)"
    _le_rc=0
    _gh_try DELETE "$_GH_API/issues/$_le_n/labels/$(_gh_urlenc "$_le_lbl")" >/dev/null 2>"$_le_err" || _le_rc=$?
    if [ "$_le_rc" -ne 0 ] && [ "$_GH_STATUS" != "404" ]; then
      cat "$_le_err" >&2
      rm -f "$_le_err"
      exit 1
    fi
    rm -f "$_le_err"
  done
  if [ "$_le_kind" = PR ]; then
    echo "Labels updated on PR #$_le_n"
  else
    echo "Labels updated on issue #$_le_n"
  fi
}

# _gh_comment_state_gate <issue|PR> <n> -- the closed-target check before a
# comment (comment-issue, comment-pr). Sets _GH_UNVERIFIED=true when the state
# could not be read (the comment goes ahead, flagged); exits 1 on a closed
# issue, or a PR closed without merging, unless --allow-closed.
_gh_comment_state_gate() {
  local _cs_kind="$1" _cs_n="$2" _cs_raw _cs_state _cs_merged _cs_path=issues
  _GH_UNVERIFIED=false
  [ "$ALLOW_CLOSED" = "true" ] && return 0
  [ "$_cs_kind" = PR ] && _cs_path=pulls
  if [ "$_cs_kind" = PR ]; then
    _cs_raw="$(_gh_pull_cached "$_cs_n" 2>/dev/null)" || _cs_raw=""
  else
    _cs_raw="$(_gh_try GET "$_GH_API/$_cs_path/$_cs_n" 2>/dev/null)" || _cs_raw=""
  fi
  if [ -z "$_cs_raw" ]; then
    echo "pipeline-vcs: warning: could not determine state of $_cs_kind #$_cs_n — proceeding" >&2
    _GH_UNVERIFIED=true
    return 0
  fi
  _cs_state="$(printf '%s' "$_cs_raw" | _gh_field state)"
  _cs_merged="$(printf '%s' "$_cs_raw" | _gh_field merged_at)"
  if [ "$_cs_state" = "closed" ] && [ -z "$_cs_merged" ]; then
    if [ "$_cs_kind" = PR ]; then
      echo "pipeline-vcs: comment-pr: PR #$_cs_n is CLOSED (not merged) — use --allow-closed to override" >&2
    else
      echo "pipeline-vcs: comment-issue: issue #$_cs_n is CLOSED (use --allow-closed to override)" >&2
    fi
    exit 1
  fi
}

# _gh_post_comment <n> <body> -- POST the comment and print its URL; exits 1 on failure.
_gh_post_comment() {
  local _pc_resp
  _pc_resp="$(_gh_req POST "$_GH_API/issues/$1/comments" "$(printf '%s' "$2" | _gh_body_json)")" || exit 1
  printf '%s' "$_pc_resp" | _gh_field html_url
}

# ─────────────────────────────────────────────────────────────────────────────
# GITHUB ADAPTER  (providers `github` and `github-api`)
# ─────────────────────────────────────────────────────────────────────────────
_github() {
  _gh_init
  local verb="$1"; shift
  case "$verb" in
    assign-issue)
      _vcs_shared_assign_issue "${1:-}" _gh_assignees_get _gh_assignee_add _gh_user_login
      ;;
    current-user)
      _vcs_shared_print_current_user _gh_user_login
      exit $?
      ;;
    issue-assignees)
      _vcs_shared_issue_assignees "${1:-}" _gh_assignees_get || exit 1
      ;;
    unassign-issue)
      _vcs_shared_unassign_issue "${1:-}" "${2:-}" _gh_assignees_get _gh_assignee_remove || exit 1
      ;;
    list-assignees)
      # One paginated request, the list-issues endpoint (#560).
      local _la_raw
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/issues?state=open&per_page=100 (paginated; assignees per issue)"; return 0; }
      _la_raw="$(_gh_pages "$_GH_API/issues?state=open&per_page=100")" || exit 1
      printf '%s' "$_la_raw" | _vcs_shared_assignee_map github || exit 1
      ;;
    upsert-pr-comment)
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/issues/$1/comments?per_page=100 (paginated; newest own comment ending in <!-- talos:$2 -->); then PATCH $_GH_API/issues/comments/<id> (body on stdin), or POST $_GH_API/issues/$1/comments when there is none; no write when the body is unchanged"; return 0; }
      _vcs_shared_upsert_pr_comment "${1:-}" "${2:-}" "${3:-}" _gh_upc_read _gh_upc_write _gh_user_login
      ;;
    mark-needs-owner)
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/issues/$1/comments (read-comments); unless the newest trusted marker comment already has this body and is unanswered: POST $_GH_API/issues/$1/comments; POST $_GH_API/issues/$1/labels ($_TALOS_NEEDS_OWNER_LABEL)"; return 0; }
      _vcs_shared_mark_needs_owner "${1:-}" "${2-}" _gh_no_post_comment _gh_no_label_add _gh_user_login
      ;;
    list-needs-owner)
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] GET $_GH_API/issues?state=open&labels=$_TALOS_NEEDS_OWNER_LABEL_URL&per_page=100 (paginated); read-comments per item"
        case " $* " in
          *" --clear-answered "*) echo "[dry-run] for each answered item: DELETE $_GH_API/issues/<n>/labels/$_TALOS_NEEDS_OWNER_LABEL_URL" ;;
        esac
        return 0
      fi
      _vcs_shared_list_needs_owner _gh_no_items _gh_no_label_remove _gh_user_login "$@"
      ;;
    list-issues)
      # The REST issues endpoint returns pull requests too (they carry a
      # `pull_request` key): drop them. --no-body (#449) leaves `body` out of
      # every item, for callers that only need number/title/labels.
      local _li_nobody=0 _li_raw
      [ "${1:-}" = "--no-body" ] && _li_nobody=1
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/issues?state=open&per_page=100 (paginated via Link headers until exhausted)"; return 0; }
      _li_raw="$(_gh_pages "$_GH_API/issues?state=open&per_page=100")" || exit 1
      printf '%s' "$_li_raw" | NO_BODY="$_li_nobody" python3 -I -c "
import json, os, sys
items = json.load(sys.stdin)
out = [{'number': i.get('number'), 'title': i.get('title', ''),
        'labels': [{'name': l.get('name')} for l in (i.get('labels') or [])],
        'body': i.get('body') or ''}
       for i in items if 'pull_request' not in i]
if os.environ.get('NO_BODY') == '1':
    for i in out:
        del i['body']
print(json.dumps(out))
"
      ;;
    view-issue)
      local _vi_n="${1:-}" _vi_spec=false _vi_since=false _vi_issue _vi_comments _vi_meta
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --spec) _vi_spec=true ;;
          --since-stage) _vi_since=true ;;
        esac
        shift
      done
      _gh_num "$verb" issue "$_vi_n"
      if [ "$DRY_RUN" = "true" ]; then
        if [ "$_vi_spec" = "true" ]; then
          echo "[dry-run] GET $_GH_API/issues/$_vi_n; read-comments $_vi_n (filter to latest **PM spec:** comment, dropping talos: markers and **Agent:** verdicts)"
        elif [ "$_vi_since" = "true" ]; then
          echo "[dry-run] GET $_GH_API/issues/$_vi_n; read-comments $_vi_n (keep the latest **PM spec:** / **Agent:** comment and the comments after it)"
        else
          echo "[dry-run] GET $_GH_API/issues/$_vi_n; GET $_GH_API/issues/$_vi_n/comments (paginated)"
        fi
        return 0
      fi
      _vi_issue="$(_gh_req GET "$_GH_API/issues/$_vi_n")" || exit 1
      if [ "$_vi_spec" = "true" ] || [ "$_vi_since" = "true" ]; then
        _vi_comments="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" read-comments "$_vi_n" ${REPO:+--repo "$REPO"})" || exit 1
        _vi_meta="$(printf '%s' "$_vi_issue" | python3 -I -c "
import json, sys
d = json.load(sys.stdin)
print(json.dumps({'title': d.get('title', ''), 'body': d.get('body') or '',
                  'labels': [{'name': l['name']} for l in d.get('labels', [])]}))
")"
        if [ "$_vi_spec" = "true" ]; then
          _vi_spec_filter "$_vi_meta" "$_vi_comments"
        else
          _vi_delta_filter "$_vi_meta" "$_vi_comments"
        fi
        return
      fi
      _vi_comments="$(_gh_comments_obj "$_vi_n")" || exit 1
      printf '%s\n%s' "$_vi_comments" "$_vi_issue" | python3 -I -c "
import json, sys
head, _, issue = sys.stdin.read().partition('\n')
d = json.loads(issue)
print(json.dumps({
    'title': d.get('title', ''),
    'body': d.get('body') or '',
    'labels': [{'name': l['name']} for l in d.get('labels', [])],
    'comments': [dict(c, url=c.get('html_url', '')) for c in json.loads(head)['comments']]}))
"
      ;;
    comment-issue)
      local n="$1" body="$2"
      _gh_num "$verb" issue "$n"
      if [ "$DRY_RUN" = "true" ]; then
        if [ "$ALLOW_CLOSED" = "true" ]; then
          echo "[dry-run] POST $_GH_API/issues/$n/comments body=$body (--allow-closed; URL on stdout)"
        else
          echo "[dry-run] GET $_GH_API/issues/$n (state check); POST $_GH_API/issues/$n/comments body=$body (URL on stdout)"
        fi
        return 0
      fi
      _gh_comment_state_gate issue "$n"
      _gh_post_comment "$n" "$body"
      if [ "$_GH_UNVERIFIED" = "true" ]; then
        echo "talos:comment-state-unverified target=issue#$n reason=state-check-failed"
      fi
      ;;
    close-issue)
      local n="$1" body="${2:-resolved}"
      _gh_num "$verb" issue "$n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] POST $_GH_API/issues/$n/comments body=$body; PATCH $_GH_API/issues/$n state=closed"; return 0; }
      _gh_post_comment "$n" "$body" >/dev/null
      _gh_req PATCH "$_GH_API/issues/$n" '{"state":"closed"}' >/dev/null || exit 1
      echo "Closed issue #$n"
      ;;
    label-issue)
      local n="$1"; shift
      _parse_label_args "$@"
      _gh_label_edit issue "$n"
      ;;
    check-epic-acceptance)
      # Fetches the epic's body and delegates to the shared checklist scan.
      local n="${1:-}" _cea_issue
      [ -z "$n" ] && { echo "pipeline-vcs: check-epic-acceptance: missing issue number" >&2; exit 1; }
      _gh_num "$verb" issue "$n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/issues/$n | scan for unticked '- [ ]' checklist lines"; return 0; }
      _cea_issue="$(_gh_req GET "$_GH_API/issues/$n")" || exit 1
      printf '%s' "$_cea_issue" | _gh_field body | _epic_acceptance_scan
      ;;
    create-issue)
      local title="$1" body_file="$2"; shift 2
      local label_args=() _ci_resp _ci_payload
      while [ $# -gt 0 ]; do
        case "$1" in
          --label) [ $# -ge 2 ] || _vcs_flag_needs_value --label "create-issue <title> <body-file> [--label <label>]..."; label_args+=("$2"); shift 2 ;;
          *) shift ;;
        esac
      done
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] POST $_GH_API/issues title=$title labels=${label_args[*]:-<none>}"; return 0; }
      [ -r "$body_file" ] || { echo "pipeline-vcs: create-issue: cannot read '$body_file'" >&2; exit 1; }
      _ci_payload="$(python3 -I -c 'import json, sys; print(json.dumps({"title": sys.argv[1], "body": sys.stdin.read(), "labels": sys.argv[2:]}))' \
        "$title" ${label_args[@]+"${label_args[@]}"} < "$body_file")"
      _ci_resp="$(_gh_req POST "$_GH_API/issues" "$_ci_payload")" || exit 1
      printf '%s' "$_ci_resp" | python3 -I -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('html_url') or d.get('url') or d.get('number', ''))
"
      # Assign the new issue (#299) -- stdout stays the URL alone.
      _vcs_shared_assign_issue "$(printf '%s' "$_ci_resp" | _gh_field number 2>/dev/null)" \
        _gh_assignees_get _gh_assignee_add _gh_user_login >&2
      ;;
    create-pr)
      local branch="$1" title="$2" body_file="$3" _cp_draft=false _cp_payload
      [ "$_PR_DRAFT" = "true" ] && _cp_draft=true
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] POST $_GH_API/pulls head=$branch base=${BASE_BRANCH:-<default branch>} title=$title draft=$_cp_draft"; return 0; }
      [ -r "$body_file" ] || { echo "pipeline-vcs: create-pr: cannot read '$body_file'" >&2; exit 1; }
      if [ -z "$BASE_BRANCH" ]; then
        BASE_BRANCH="$(_gh_req GET "$_GH_API" | _gh_field default_branch)"
        [ -n "$BASE_BRANCH" ] || { echo "pipeline-vcs: create-pr: could not resolve the default branch" >&2; exit 1; }
      fi
      _cp_payload="$(python3 -I -c 'import json, sys
print(json.dumps({"title": sys.argv[1], "head": sys.argv[2], "base": sys.argv[3],
                  "draft": sys.argv[4] == "true", "body": sys.stdin.read()}))' \
        "$title" "$branch" "$BASE_BRANCH" "$_cp_draft" < "$body_file")"
      # (#549) One line, `PR #<n> <url>`: the caller needs no view-pr to learn
      # either. The number is the API's own, else the URL's tail; an answer with
      # neither is a failure, never a guessed PR.
      _gh_req POST "$_GH_API/pulls" "$_cp_payload" | python3 -I -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
url = d.get("html_url") if isinstance(d.get("html_url"), str) else ""
num = d.get("number")
if not isinstance(num, int) or isinstance(num, bool):
    m = re.search(r"/pull/([0-9]+)$", url)
    num = int(m.group(1)) if m else None
if not url or num is None:
    sys.stderr.write("pipeline-vcs: create-pr: the API answer carries no PR number or URL\n")
    sys.exit(1)
print("PR #%d %s" % (num, url))' || exit 1
      ;;
    ready-pr|draft-pr)
      # (#332) GraphQL is the one thing REST cannot do here: a PR's draft state
      # is only writable through a mutation on its node id.
      local _rd_n="${1:-}" _rd_mut=markPullRequestReadyForReview _rd_msg="is ready for review" _rd_node _rd_resp _rd_q
      _vcs_require_pr_id "$verb" "$_rd_n"
      [ "$verb" = "draft-pr" ] && { _rd_mut=convertPullRequestToDraft; _rd_msg="is a draft again"; }
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/pulls/$_rd_n (node id); POST graphql $_rd_mut"; return 0; }
      _rd_node="$(_gh_req GET "$_GH_API/pulls/$_rd_n" | _gh_field node_id)"
      [ -n "$_rd_node" ] || { echo "pipeline-vcs: $verb: could not read PR #$_rd_n" >&2; exit 1; }
      _rd_q="mutation(\$id: ID!) { $_rd_mut(input: {pullRequestId: \$id}) { pullRequest { isDraft } } }"
      _rd_resp="$(_gh_req POST graphql "$(python3 -I -c '
import json, sys
print(json.dumps({"query": sys.argv[1], "variables": {"id": sys.argv[2]}}))' "$_rd_q" "$_rd_node")")" || exit 1
      printf '%s' "$_rd_resp" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(1 if d.get("errors") or not d.get("data") else 0)' \
        || { echo "pipeline-vcs: $verb: GitHub refused the change for PR #$_rd_n" >&2; exit 1; }
      echo "PR #$_rd_n $_rd_msg"
      ;;
    pr-is-draft)
      # (#332) Fail closed: see _vcs_shared_pr_is_draft.
      _github_fetch_draft() { _gh_try GET "$_GH_API/pulls/$1"; }
      _vcs_shared_pr_is_draft "${1:-}" draft "GET $_GH_API/pulls/${1:-} (.draft)" _github_fetch_draft
      ;;
    pr-ci-runs)
      # (#332) Number of `pull_request` workflow runs that executed for THIS PR:
      # the listed runs for its head branch whose pull_requests[] names this PR
      # (a reused branch name must not inflate it), minus `skipped` ones (a push
      # to a draft PR creates a run whose jobs the `draft != true` guard skips).
      # One paginated listing, so the count is one snapshot. Fail closed (exit
      # 2, never a short count) on a run with no pull_requests[] (a fork's), a
      # listing shorter than its total_count, or GitHub's 1000-result search cap.
      local _cr_n="${1:-}" _cr_head _cr_listing
      if ! _vcs_pr_id_numeric "$_cr_n"; then
        echo "pipeline-vcs: pr-ci-runs: PR id must be numeric (got '$_cr_n') -- unverified" >&2
        exit 2
      fi
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/pulls/$_cr_n (head branch); GET $_GH_API/actions/runs?event=pull_request&branch=<head>&per_page=100 (paginated)"; return 0; }
      _cr_head="$(_gh_try GET "$_GH_API/pulls/$_cr_n")" || {
        echo "pipeline-vcs: pr-ci-runs: could not fetch PR #$_cr_n -- unverified" >&2
        exit 2
      }
      _cr_head="$(printf '%s' "$_cr_head" | _gh_field head.ref)"
      [ -n "$_cr_head" ] || {
        echo "pipeline-vcs: pr-ci-runs: PR #$_cr_n has no head branch -- unverified" >&2
        exit 2
      }
      _cr_listing="$(_gh_pages "$_GH_API/actions/runs?event=pull_request&branch=$(_gh_urlenc "$_cr_head")&per_page=100" "" "workflow runs" workflow_runs)" || {
        echo "pipeline-vcs: pr-ci-runs: could not list workflow runs for PR #$_cr_n -- unverified" >&2
        exit 2
      }
      printf '%s' "$_cr_listing" | PR_N="$_cr_n" python3 -I -c '
import json, os, sys
n = int(os.environ["PR_N"])
page = json.load(sys.stdin)
total = page.get("total_count")
if type(total) is not int or total < 0 or total >= 1000:
    sys.exit(2)
runs = page["workflow_runs"]
if len(runs) != total:
    sys.exit(2)
count = 0
for run in runs:
    if not isinstance(run, dict):
        sys.exit(2)
    prs = run.get("pull_requests")
    if not isinstance(prs, list) or not prs:
        sys.exit(2)
    nums = []
    for p in prs:
        num = p.get("number") if isinstance(p, dict) else None
        if type(num) is not int:
            sys.exit(2)
        nums.append(num)
    if n in nums and run.get("conclusion") != "skipped":
        count += 1
print(count)
' || {
        echo "pipeline-vcs: pr-ci-runs: workflow runs for PR #$_cr_n are malformed, truncated, cannot be attributed to a PR, or are at GitHub's 1000-result cap -- unverified" >&2
        exit 2
      }
      ;;
    view-pr)
      local _vp_ref="${1:-}" _vp_pr
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/pulls/$_vp_ref"; return 0; }
      _vp_pr="$(_gh_pull "$_vp_ref")" || exit 1
      printf '%s' "$_vp_pr" | python3 -I -c "
import json, sys
d = json.load(sys.stdin)
print(json.dumps({'number': d.get('number'), 'title': d.get('title', ''),
                  'headRefName': (d.get('head') or {}).get('ref', ''),
                  'labels': [{'name': l['name']} for l in d.get('labels', [])],
                  'url': d.get('html_url', ''), 'body': d.get('body') or ''}))
"
      ;;
    list-prs)
      # Lane scoping: only PRs targeting THIS config's base_branch, with baseRefName
      # so callers can verify. A repo-wide list let one lane adopt and merge another
      # lane's in-flight PR into the wrong base.
      local _lp_endpoint="$_GH_API/pulls?state=open&per_page=100" _lp_raw
      [ -n "$BASE_BRANCH" ] && _lp_endpoint="${_lp_endpoint}&base=${BASE_BRANCH}"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_lp_endpoint (paginated via Link headers until exhausted)"; return 0; }
      _lp_raw="$(_gh_pages "$_lp_endpoint")" || exit 1
      printf '%s' "$_lp_raw" | python3 -I -c "
import json, sys
items = json.load(sys.stdin)
def cross(i):
    # A fork PR (#346): head and base repos differ; a deleted fork has no head repo.
    h = ((i.get('head') or {}).get('repo') or {}).get('full_name')
    return h is None or h != ((i.get('base') or {}).get('repo') or {}).get('full_name')
print(json.dumps([{'number': i.get('number'), 'title': i.get('title', ''),
                   'headRefName': (i.get('head') or {}).get('ref', ''),
                   'baseRefName': (i.get('base') or {}).get('ref', ''),
                   'labels': [{'name': l.get('name')} for l in (i.get('labels') or [])],
                   'isCrossRepository': cross(i)}
                  for i in items]))
"
      ;;
    diff-pr)
      local _dp_n="${1:-}" _dp_stat=false _dp_raw
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --stat) _dp_stat=true ;;
        esac
        shift
      done
      _gh_num "$verb" PR "$_dp_n"
      if [ "$DRY_RUN" = "true" ]; then
        if [ "$_dp_stat" = "true" ]; then
          echo "[dry-run] GET $_GH_API/pulls/$_dp_n/files?per_page=100 (paginated) | git-diff-stat-style summary"
        else
          echo "[dry-run] GET $_GH_API/pulls/$_dp_n (Accept: $_GH_DIFF)"
        fi
        return 0
      fi
      if [ "$_dp_stat" = "true" ]; then
        # Derived from the same paginated pr-files (#200) endpoint -- no new
        # fetch pattern, just additions/deletions instead of just paths.
        _dp_raw="$(_gh_pages "$_GH_API/pulls/$_dp_n/files?per_page=100")" || exit 1
        printf '%s' "$_dp_raw" | _diff_stat_format
        return
      fi
      _gh_diff "$_GH_API/pulls/$_dp_n"
      ;;
    checkout-pr)
      # A git operation, so gh's own helper wins when it is the transport (it
      # wires up fork remotes and upstream tracking); with a token only, fetch
      # GitHub's pull ref into a branch of the PR's head name.
      local _co_n="${1:-}" _co_branch
      _gh_num "$verb" PR "$_co_n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] gh pr checkout $_co_n (token only: GET $_GH_API/pulls/$_co_n; git fetch origin refs/pull/$_co_n/head:<head ref>; git checkout <head ref>)"; return 0; }
      if [ "$_GH_XPORT" = gh ]; then
        gh pr checkout "$_co_n" ${REPO:+--repo "$REPO"}
        return
      fi
      _co_branch="$(_gh_req GET "$_GH_API/pulls/$_co_n" | _gh_field head.ref)"
      [ -n "$_co_branch" ] || { echo "pipeline-vcs: checkout-pr: could not resolve head ref for PR #$_co_n" >&2; exit 1; }
      git fetch origin "refs/pull/$_co_n/head:$_co_branch" && git checkout "$_co_branch"
      ;;
    approve-pr)
      local n="${1:-}" _ap_body="${2:-approved}"
      _gh_num "$verb" PR "$n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] POST $_GH_API/pulls/$n/reviews event=APPROVE body=$_ap_body"; return 0; }
      _gh_req POST "$_GH_API/pulls/$n/reviews" "$(printf '%s' "$_ap_body" | python3 -I -c '
import json, sys
print(json.dumps({"body": sys.stdin.read(), "event": "APPROVE"}))')" >/dev/null || exit 1
      echo "Approved PR #$n"
      ;;
    label-pr)
      local n="$1"; shift
      _parse_label_args "$@"
      _gh_label_edit PR "$n"
      ;;
    pr-checks)
      # The table `gh pr checks` printed: name, state, elapsed, link. Exit 1 when
      # any check failed, 8 while any is pending, else 0.
      local _pk_n="${1:-}" _pk_tbl
      _gh_num "$verb" PR "$_pk_n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/pulls/$_pk_n; GET $_GH_API/commits/<sha>/check-runs; GET $_GH_API/commits/<sha>/status"; return 0; }
      _pk_tbl="$(_gh_check_table "$_pk_n")" || exit 1
      [ -n "$_pk_tbl" ] && printf '%s\n' "$_pk_tbl"
      printf '%s\n' "$_pk_tbl" | cut -f2 | grep -qxE 'fail|cancel' && return 1
      printf '%s\n' "$_pk_tbl" | cut -f2 | grep -qxE 'pending' && return 8
      return 0
      ;;
    pr-checks-required)
      # Scoped to merge.required_checks (#205): an unrelated optional check stuck
      # pending must not burn the wait, and a required check GitHub has not
      # scheduled yet is pending, never an absent "pass". A read that fails reads
      # as "nothing reported": exit 2, never a pass.
      local _n="${1:-}" _required _tbl
      _gh_num "$verb" PR "$_n"
      _required="$(cfg merge.required_checks)"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/pulls/$_n; GET $_GH_API/commits/<sha>/check-runs; evaluate against merge.required_checks"; return 0; }
      # Empty config never passes vacuously and needs no CI data to say so.
      [ -z "$_required" ] && { printf '' | _eval_required_checks "$_required"; return; }
      _tbl="$(_gh_check_table "$_n" "$_required")" || _tbl=""
      printf '%s\n' "$_tbl" | awk -F'\t' 'NF >= 2 { s = ($2 == "pass") ? "pass" : (($2 == "pending" || $2 == "skipping") ? "pending" : "fail"); print $1 "\t" s }' \
        | _eval_required_checks "$_required"
      ;;
    merge-pr)
      local n="${1:-}" _mm=merge _mp_pr _mp_ref _mp_same
      _gh_num "$verb" PR "$n"
      case "$MERGE_METHOD" in squash) _mm=squash ;; rebase) _mm=rebase ;; esac
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/pulls/$n; PUT $_GH_API/pulls/$n/merge merge_method=$_mm; DELETE the head branch ref"; return 0; }
      _mp_pr="$(_gh_req GET "$_GH_API/pulls/$n")" || exit 1
      _gh_req PUT "$_GH_API/pulls/$n/merge" "{\"merge_method\": \"$_mm\"}" >/dev/null || exit 1
      # --delete-branch: the merge endpoint does not delete it. A fork's branch is not ours to delete.
      _mp_ref="$(printf '%s' "$_mp_pr" | _gh_field head.ref)"
      _mp_same="$(printf '%s' "$_mp_pr" | python3 -I -c "
import json, sys
d = json.load(sys.stdin)
print('yes' if ((d.get('head') or {}).get('repo') or {}).get('full_name') == ((d.get('base') or {}).get('repo') or {}).get('full_name') else 'no')")"
      if [ -n "$_mp_ref" ] && [ "$_mp_same" = yes ]; then
        _gh_try DELETE "$_GH_API/git/refs/heads/$(_gh_urlenc "$_mp_ref" /)" >/dev/null \
          || echo "pipeline-vcs: merge-pr: PR #$n merged, but its branch '$_mp_ref' could not be deleted" >&2
      fi
      echo "Merged PR #$n"
      ;;
    comment-pr)
      # PRs are issues for commenting purposes on GitHub
      local n="$1" body="$2"
      _gh_num "$verb" PR "$n"
      if [ "$DRY_RUN" = "true" ]; then
        if [ "$ALLOW_CLOSED" = "true" ]; then
          echo "[dry-run] POST $_GH_API/issues/$n/comments body=$body (--allow-closed; URL on stdout)"
        else
          echo "[dry-run] GET $_GH_API/pulls/$n (state check); POST $_GH_API/issues/$n/comments body=$body (URL on stdout)"
        fi
        return 0
      fi
      _gh_comment_state_gate PR "$n"
      _gh_post_comment "$n" "$body"
      if [ "$_GH_UNVERIFIED" = "true" ]; then
        echo "talos:comment-state-unverified target=pr#$n reason=state-check-failed"
      fi
      ;;
    edit-pr-body)
      # Replace the PR's description (#455). ARGS is `<n> <body>` here: the
      # pre-dispatch block validated the flags, the caps and the placeholders.
      local n="${1:-}" _eb_payload
      _gh_num "$verb" PR "$n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] PATCH $_GH_API/pulls/$n (body on stdin)"; return 0; }
      _eb_payload="$(printf '%s' "$2" | _gh_body_json)" \
        || { echo "pipeline-vcs: edit-pr-body: could not build the request body; nothing changed" >&2; exit 1; }
      _gh_req PATCH "$_GH_API/pulls/$n" "$_eb_payload" >/dev/null || exit 1
      echo "edited pr=$n body"
      ;;
    find-pr)
      # Issue-reference matching is _vcs_shared_find_pr. REST has no state=merged,
      # so this arm maps the state and hands over a {number, state, title,
      # headRefName, body} list. state=closed also returns unmerged PRs, so the
      # list is paginated (#302), up to _fp_max_pages with a warning at the cap.
      local n="$1" state="${2:-open}" _fp_max_pages=10 _fp_state _fp_raw
      case "$state" in
        merged) _fp_state=closed ;;   # merged PRs are closed with merged_at set
        *)      _fp_state="$state" ;;
      esac
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/pulls?state=$_fp_state&per_page=100 (paginated via Link headers, up to $_fp_max_pages pages) | filter issue-$n / #$n"; return 0; }
      _fp_raw="$(_gh_pages "$_GH_API/pulls?state=$_fp_state&per_page=100" "$_fp_max_pages" PRs)" || exit 1
      printf '%s' "$_fp_raw" | STATE_FILTER="$state" python3 -I -c "
import json, sys, os
state_filter = os.environ.get('STATE_FILTER', 'open')
try: prs = json.load(sys.stdin)
except Exception: prs = []
out = []
for pr in prs:
    if state_filter == 'merged' and not pr.get('merged_at'):
        continue
    if pr.get('merged_at'):
        out_state = 'MERGED'
    elif (pr.get('state') or '').upper() == 'OPEN':
        out_state = 'OPEN'
    else:
        out_state = 'CLOSED'
    out.append({'number': pr.get('number'), 'state': out_state,
                'title': pr.get('title', ''),
                'headRefName': (pr.get('head') or {}).get('ref', ''),
                'body': pr.get('body') or ''})
json.dump(out, sys.stdout)
" | _vcs_shared_find_pr "$n" "$state" "$REPO"
      ;;
    check-pr-files|pr-files)
      # Every page (#171, #211): a >100-file PR is never silently truncated, and
      # a failed page exits non-zero with no partial output -- the fail-closed
      # behaviour the forbidden-files gate's stdin contract relies on.
      # check-pr-files hands the paths to _vcs_shared_check_pr_files (#177
      # slice 3); pr-files prints them.
      local n="${1:-}" _pf_raw
      _gh_num "$verb" PR "$n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/pulls/$n/files?per_page=100 (paginated via Link headers until exhausted) | print .filename, one per line"; return 0; }
      _pf_raw="$(_gh_pages "$_GH_API/pulls/$n/files?per_page=100")" || exit 1
      if [ "$verb" = "pr-files" ]; then
        printf '%s' "$_pf_raw" | _gh_paths
      else
        printf '%s' "$_pf_raw" | _gh_paths \
          | CONFIGURED="$(cfg merge.forbidden_files)" REPLACE="$(cfg merge.forbidden_files_replace)" ALLOW="$(cfg merge.forbidden_files_allow)" _vcs_shared_check_pr_files
      fi
      ;;
    rerun-ci)
      local n="${1:-}" _rr_sha _rr_runs _rr_ids _rr_id
      _gh_num "$verb" PR "$n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/pulls/$n (head SHA); GET $_GH_API/actions/runs?head_sha=<sha>; POST $_GH_API/actions/runs/<id>/rerun-failed-jobs for each failed run"; return 0; }
      _rr_sha="$(_gh_req GET "$_GH_API/pulls/$n" | _gh_field head.sha)"
      [ -n "$_rr_sha" ] || { echo "pipeline-vcs: could not resolve head SHA for PR #$n" >&2; exit 1; }
      _rr_runs="$(_gh_pages "$_GH_API/actions/runs?head_sha=$_rr_sha&per_page=100" "" "workflow runs" workflow_runs)" || exit 1
      _rr_ids="$(printf '%s' "$_rr_runs" | python3 -I -c "
import json, sys
for r in json.load(sys.stdin)['workflow_runs']:
    if r.get('conclusion') in ('failure', 'timed_out', 'cancelled'):
        print(r['id'])")"
      if [ -z "$_rr_ids" ]; then
        echo "rerun-ci: no failed runs found for PR #$n ($_rr_sha)"
        return 0
      fi
      while IFS= read -r _rr_id; do
        [ -n "$_rr_id" ] && { _gh_req POST "$_GH_API/actions/runs/$_rr_id/rerun-failed-jobs" '{}' >/dev/null || exit 1; }
      done <<< "$_rr_ids"
      echo "rerun-ci: re-ran failed runs for PR #$n ($_rr_sha)"
      ;;
    update-branch)
      # update-branch <n> (#289): merge the base into the PR's head SERVER-SIDE
      # (PUT pulls/{n}/update-branch with expected_head_sha). Exit 0 on success,
      # 1 on a head-moved conflict (409) or any other failure; the caller
      # re-checks pr-mergeable and falls back to a developer merge-base task.
      local _ub_n="${1:-}" _ub_sha
      _gh_num "$verb" PR "$_ub_n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/pulls/$_ub_n (head SHA); PUT $_GH_API/pulls/$_ub_n/update-branch expected_head_sha=<sha>"; return 0; }
      _ub_sha="$(_gh_try GET "$_GH_API/pulls/$_ub_n" 2>/dev/null | _gh_field head.sha)"
      [ -n "$_ub_sha" ] || { echo "pipeline-vcs: update-branch: could not resolve head SHA for PR #$_ub_n" >&2; exit 1; }
      _gh_try PUT "$_GH_API/pulls/$_ub_n/update-branch" "{\"expected_head_sha\":\"$_ub_sha\"}" >/dev/null 2>&1 || {
        echo "pipeline-vcs: update-branch: GitHub refused the branch update for PR #$_ub_n (head moved, or conflicts unresolved server-side)" >&2
        exit 1
      }
      echo "update-branch: PR #$_ub_n branch updated with its base"
      ;;
    check-closing-keyword)
      # check-closing-keyword <pr_branch_or_number> <issue_N>: exit 1 only when the
      # PR body closes <issue_N> AND other PRs for it are still open (the final
      # PR of a multi-PR issue finds its siblings merged and passes). FAIL-OPEN:
      # an unreadable PR or sibling list prints a machine-readable marker (a fixed
      # literal, never API text) and exits 0. The regex, sibling scan and message
      # are _vcs_shared_check_closing_keyword; this arm is fetch -> call.
      local pr_ref="${1:-}" issue_n="${2:-}" _cc_num _cc_raw _cc_body
      [ -z "$pr_ref" ]  && { echo "pipeline-vcs: check-closing-keyword: missing PR ref"     >&2; exit 1; }
      [ -z "$issue_n" ] && { echo "pipeline-vcs: check-closing-keyword: missing issue number" >&2; exit 1; }
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] check-closing-keyword $pr_ref $issue_n: GET $_GH_API/pulls/$pr_ref (body, closing keyword), then GET $_GH_API/pulls?state=open&per_page=100 (siblings)"; return 0; }
      # Repo-scope guard: with $REPO unresolved the URL/owner#N forms cannot be
      # scoped to this repository -- fail open with a fixed-literal marker.
      if [ -z "$REPO" ]; then
        echo "talos:closing-keyword-unverified pr=$pr_ref issue=$issue_n reason=repo-unresolved"
        return 0
      fi
      if _cc_num="$(_gh_pr_num "$pr_ref" 2>/dev/null)" \
          && _cc_raw="$(_gh_try GET "$_GH_API/pulls/$_cc_num" 2>/dev/null)" && [ -n "$_cc_raw" ]; then
        :
      else
        echo "pipeline-vcs: check-closing-keyword: could not fetch PR '$pr_ref' — skipping check" >&2
        echo "talos:closing-keyword-unverified pr=$pr_ref issue=$issue_n reason=pr-fetch-failed"
        return 0
      fi
      _cc_body="$(printf '%s' "$_cc_raw" | _gh_field body)"

      # Lazily fetches and normalises the open-PR list -- only invoked by the
      # shared function when a closing keyword is actually present. Every page
      # up to _max (#319): a sibling past the first 100 still counts. A list
      # that fills all _max pages is capped only if one probe past the cap finds
      # more PRs.
      _github_fetch_closing_siblings() {
        local _open_prs_raw _probe _max=100 _capped=0
        _open_prs_raw="$(_gh_pages "$_GH_API/pulls?state=open&per_page=100" "$_max" PRs)" || return 1
        [ -z "$_open_prs_raw" ] && return 1
        if [ "$(printf '%s' "$_open_prs_raw" | _json_array_len)" = "$((_max * 100))" ]; then
          _probe="$(_gh_try GET "$_GH_API/pulls?state=open&per_page=100&page=$((_max + 1))")" || return 1
          _probe="$(printf '%s' "$_probe" | _json_array_len)" || return 1
          [ "$_probe" = 0 ] || _capped=1
        fi
        printf '%s' "$_open_prs_raw" | python3 -I -c "
import json, sys
prs = json.load(sys.stdin)
if not isinstance(prs, list):
    prs = []
json.dump([dict(p, headRefName=(p.get('head') or {}).get('ref', '')) for p in prs], sys.stdout)
" || return 1
        [ "$_capped" = 0 ] || return "$_VCS_SIBLINGS_CAPPED"
      }

      printf '%s' "$_cc_body" | REPO="$REPO" \
        _vcs_shared_check_closing_keyword "$issue_n" "$_cc_num" "$pr_ref" _github_fetch_closing_siblings
      exit $?
      ;;
    pr-head)
      # pr-head <n> -- print the current head SHA for a PR (fail-closed: exits 1 if unresolvable)
      local n="${1:-}" sha
      _gh_num "$verb" PR "$n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/pulls/$n (.head.sha)"; return 0; }
      sha="$(_gh_pull_cached "$n" | _gh_field head.sha)"
      [ -z "$sha" ] && { echo "pipeline-vcs: pr-head: could not resolve head SHA for PR #$n" >&2; exit 1; }
      printf '%s\n' "$sha"
      ;;
    pr-mergeable)
      # pr-mergeable <n> (#214): REST `mergeable` is true/false/null (null = not
      # computed yet) -> MERGEABLE / CONFLICTING / UNKNOWN; _vcs_shared_pr_mergeable
      # owns the retry loop and exit codes. Re-fetched per attempt (computed lazily).
      local n="${1:-}"
      _gh_num "$verb" PR "$n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/pulls/$n (.mergeable)"; return 0; }
      _github_fetch_mergeable() {
        case "$(_gh_req GET "$_GH_API/pulls/$n" | _gh_field mergeable)" in
          True)  echo MERGEABLE ;;
          False) echo CONFLICTING ;;
          *)     echo UNKNOWN ;;
        esac
      }
      _vcs_shared_pr_mergeable _github_fetch_mergeable
      exit $?
      ;;

    # ── Attempt counting ─────────────────────────────────────────────────────

    read-comments)
      # read-comments <issue-or-pr-n>: every comment as {"comments": [...]}, all
      # pages (PRs are issues here). The shared reader behind read-attempt and
      # post-approval's duplicate check (#172). Fail-closed: nothing on stdout and
      # exit 1 on any page failure.
      local n="${1:-}"
      [ -z "$n" ] && { echo "pipeline-vcs: read-comments: missing issue/PR number" >&2; exit 1; }
      _gh_num "$verb" issue "$n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] GET $_GH_API/issues/$n/comments?per_page=100 (paginated)"; return 0; }
      _gh_comments_obj "$n" || { echo "pipeline-vcs: read-comments: could not fetch issue #$n data" >&2; exit 1; }
      ;;

    read-attempt)
      # read-attempt <issue-n>
      # Print "stage=<s> count=<k> total=<t>" from the most-recent attempt
      # marker on the issue. Prints "stage= count=0 total=0" when no marker
      # exists (new issue). Exits 0 always (read-only query).
      local n="${1:-}" issue_data trusted_authors verify_authors
      [ -z "$n" ] && { echo "pipeline-vcs: read-attempt: missing issue number" >&2; exit 1; }
      _gh_num "$verb" issue "$n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] read-attempt $n: GET $_GH_API/issues/$n/comments (paginated) and extract the last talos:attempt marker"; return 0; }
      issue_data="$(_gh_comments_obj "$n")" || { echo "pipeline-vcs: read-attempt: could not fetch issue #$n data" >&2; exit 1; }
      trusted_authors="$(cfg markers.trusted_authors)"
      verify_authors="$(cfg markers.verify_authors)"
      _vcs_shared_reader_identity "$verify_authors" _gh_user_login
      printf '%s' "$issue_data" | TRUSTED_AUTHORS="$trusted_authors" VERIFY_AUTHORS="$verify_authors" CURRENT_USER="$_RID_USER" CURRENT_USER_REFUSED="$_RID_REFUSED" TALOS_CFG="$_TALOS_CFG" _vcs_shared_read_attempt
      ;;

    check-attempt)
      # check-attempt <issue-n>
      # Exit 1 (with reason) when EITHER ceiling is already reached for the
      # issue.  Does NOT record a new attempt -- callers do that with
      # record-attempt.  Reads limits.max_fix_attempts and
      # limits.max_total_dispatches from config.
      local n="${1:-}"
      [ -z "$n" ] && { echo "pipeline-vcs: check-attempt: missing issue number" >&2; exit 1; }
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] check-attempt $n: compare current attempt state against configured ceilings"; return 0; }
      local max_stage max_total
      max_stage="$(cfg limits.max_fix_attempts)"
      max_total="$(cfg limits.max_total_dispatches)"
      local state
      state="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" read-attempt "$n" ${REPO:+--repo "$REPO"} 2>&1)"
      local rc=$?
      if [ $rc -ne 0 ]; then
        echo "pipeline-vcs: check-attempt: read-attempt failed: $state" >&2
        exit 1
      fi
      # Pass through any machine-readable talos: markers from read-attempt to our
      # own stdout, then narrow state to only the parseable stage=...count=...total=
      # line (filters out both talos: markers and any stderr warnings captured via 2>&1).
      printf '%s\n' "$state" | grep '^talos:' || true
      state="$(printf '%s\n' "$state" | grep '^stage=')"
      local cur_stage cur_count cur_total
      cur_stage="$(printf '%s' "$state" | sed 's/stage=\([^ ]*\).*/\1/')"
      cur_count="$(printf '%s' "$state" | sed 's/.*count=\([0-9]*\).*/\1/')"
      cur_total="$(printf '%s' "$state" | sed 's/.*total=\([0-9]*\).*/\1/')"
      if ! _vcs_shared_attempt_blocked "check-attempt" "$cur_count" "$cur_total" "$max_stage" "$max_total" "$cur_stage"; then
        exit 1
      fi
      echo "pipeline-vcs: check-attempt: ok (stage=$cur_stage count=$cur_count total=$cur_total; max_stage=$max_stage max_total=$max_total)"
      exit 0
      ;;

    record-attempt)
      # record-attempt <issue-n> <stage> [--pr <pr-n> | --idempotency-key <token>]:
      # see _vcs_shared_record_attempt.
      local n="${1:-}" stage="${2:-}"
      [ -z "$n" ]     && { echo "pipeline-vcs: record-attempt: missing issue number" >&2; exit 1; }
      [ -z "$stage" ] && { echo "pipeline-vcs: record-attempt: missing stage argument" >&2; exit 1; }
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] record-attempt $n $stage: read prior state, post <!-- talos:attempt stage=$stage ... --> marker"; return 0; }
      # The write: POST the marker comment and print its URL (it may
      # legitimately be empty); non-zero only when the write itself failed.
      _github_post_attempt_marker() {
        local _resp
        _resp="$(_gh_try POST "$_GH_API/issues/$1/comments" "$(printf '%s' "$2" | _gh_body_json)")" || return 1
        [ -n "$_resp" ] || return 1
        printf '%s' "$_resp" | _gh_field html_url 2>/dev/null
        return 0
      }
      shift 2 2>/dev/null || shift "$#"
      _vcs_shared_record_attempt "$n" "$stage" _github_post_attempt_marker "$@"
      ;;

    check-approval-sha)
      # check-approval-sha <n> [--stale-list]: every approval label must have been
      # earned at the current head SHA (waivers: merge.approval_waiver_paths; code,
      # tests, agent instructions and pipeline config are never waivable).
      # Fail-closed. Marker extraction and the SHA/waiver logic are
      # _vcs_shared_check_approval_marker / _vcs_shared_check_approval_sha; this
      # arm is fetch (the PR, every comment) -> call.
      local n="${1:-}"; shift
      local stale_list_flag="false"
      if [ "${1:-}" = "--stale-list" ]; then
        stale_list_flag="true"
      fi
      _gh_num "$verb" PR "$n"
      [ "$DRY_RUN" = "true" ] && { echo "[dry-run] check-approval-sha $n: verify all approval labels match current head SHA"; return 0; }
      local pr_data
      pr_data="$(_gh_marker_data "$n")" || pr_data=""
      if [ -z "$pr_data" ]; then
        echo "pipeline-vcs: check-approval-sha: could not fetch PR #$n data" >&2
        exit 1
      fi
      local trusted_authors_cas verify_authors_cas
      trusted_authors_cas="$(cfg markers.trusted_authors)"
      verify_authors_cas="$(cfg markers.verify_authors)"
      _vcs_shared_reader_identity "$verify_authors_cas" _gh_user_login
      local marker_out marker_rc marker_json
      marker_out="$(printf '%s' "$pr_data" | TRUSTED_AUTHORS="$trusted_authors_cas" VERIFY_AUTHORS="$verify_authors_cas" CURRENT_USER="$_RID_USER" CURRENT_USER_REFUSED="$_RID_REFUSED" TALOS_CFG="$_TALOS_CFG" _vcs_shared_check_approval_marker)"
      marker_rc=$?
      if [ "$marker_rc" -eq 1 ]; then
        exit 1
      fi
      if [ "$marker_rc" -eq 3 ]; then
        # No approval labels present: marker_out IS the diagnostic message.
        printf '%s\n' "$marker_out"
        exit 0
      fi
      # marker_rc == 0: marker_out is zero or more machine-readable
      # `talos:...` passthrough lines followed by exactly one JSON payload
      # line -- relay the former to our own stdout (same convention
      # read-attempt/check-attempt use) and keep the latter for the waiver
      # comparison below.
      printf '%s\n' "$marker_out" | grep '^talos:' || true
      marker_json="$(printf '%s\n' "$marker_out" | grep -v '^talos:')"
      local waiver_paths repo_root
      waiver_paths="$(cfg merge.approval_waiver_paths)"
      repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
      printf '%s' "$pr_data" \
        | WAIVER_PATHS="$waiver_paths" REPO_ROOT="${repo_root:-}" MARKER_ENTRIES="$marker_json" STALE_LIST="$stale_list_flag" _vcs_shared_check_approval_sha
      exit $?
      ;;
    *) echo "pipeline-vcs: unknown verb: $verb" >&2; exit 1 ;;
  esac
}

# _gh_paths -- stdin: a JSON array of changed files. Prints each .filename.
_gh_paths() {
  python3 -I -c "
import json, sys
for f in json.load(sys.stdin):
    path = f.get('filename', '')
    if path:
        print(path)
"
}

# ─────────────────────────────────────────────────────────────────────────────
# GITLAB ADAPTER  (best-effort — requires glab authenticated)
# ─────────────────────────────────────────────────────────────────────────────
_gitlab() {
  if ! command -v glab >/dev/null 2>&1; then
    echo "pipeline-vcs: 'glab' not found. Install from https://gitlab.com/gitlab-org/cli" >&2
    exit 1
  fi

  # Shadow `glab` for the same reason _github shadows `gh` (#173): a single
  # point of truth covering every call site below with zero edits. Defined
  # after the command-v check above so that pre-flight probe still resolves
  # the real binary. glab's rate-limit behaviour is not covered by a repo
  # test fixture today — GitLab returns HTTP 429 with a plain-text/JSON body
  # depending on endpoint; glab CLI surfaces this on stderr typically
  # containing "429" or "too many requests". Match both, best-effort; revisit
  # if a real glab rate-limit stderr sample becomes available.
  glab() { _with_retry "$VERB" command glab "$@"; }

  local verb="$1"; shift
  local RARG=""
  [ -n "$REPO" ] && RARG="-R $REPO"

  # _gl_label_update <issue|mr> <n> -- label-issue / label-pr (#455). Labels come
  # from _parse_label_args' arrays and go to glab as an argv array, never an eval'd
  # string: a label with a quote, `$(`, a space or a leading dash is one argument.
  _gl_label_update() {
    local _glu_args=(glab "$1" update "$2") _glu_lbl
    for _glu_lbl in ${ADD_LABEL_ARR[@]+"${ADD_LABEL_ARR[@]}"}; do _glu_args+=(--label "$_glu_lbl"); done
    for _glu_lbl in ${REMOVE_LABEL_ARR[@]+"${REMOVE_LABEL_ARR[@]}"}; do _glu_args+=(--unlabel "$_glu_lbl"); done
    [ -n "$REPO" ] && _glu_args+=(-R "$REPO")
    _run "${_glu_args[@]}"
  }

  # Provider calls for _vcs_shared_assign_issue (#299). Flags and output
  # shapes checked against upstream glab source in #305: `-F/--output json`
  # prints the client-go Issue, whose `assignees` is [{username, ...}];
  # update's "+" prefix goes to ToAdd and keeps the current assignees;
  # `glab api user` is GET /user, which returns `username`.
  _gl_assignees_get() {
    local _ag_json
    _ag_json="$(glab issue view "$1" --output json $RARG)" || return 1
    printf '%s' "$_ag_json" | python3 -I -c "
import json, sys
for a in json.load(sys.stdin).get('assignees') or []:
    print(a.get('username', ''))
"
  }
  # glab's "+" prefix ADDS to the assignee list instead of replacing it.
  _gl_assignee_add() {
    glab issue update "$1" --assignee "+$2" $RARG
  }
  # "!" removes one assignee and keeps the others (#560).
  _gl_assignee_remove() {
    glab issue update "$1" --assignee "!$2" $RARG
  }
  _gl_current_user() {
    glab api user | python3 -I -c "import json, sys; print(json.load(sys.stdin).get('username', ''))"
  }

  # <remote-or-path> -> "<host><TAB><group/sub/project>" (#303). With
  # vcs.repo unset on a self-hosted instance the auto-detect leaves REPO as
  # the whole remote (https://host/g/p.git, ssh://git@host:22/g/p.git or
  # git@host:g/p.git); strip the scheme, user, host, port and .git so REST
  # paths and reference matching see the bare project path. A plain
  # "group/project" has no host.
  _gl_split_repo() {
    python3 -I -c '
import re, sys
r, host = sys.argv[1].strip(), ""
m = re.match(r"^[A-Za-z][\w+.-]*://(?:[^@/]*@)?([^/:]*)(?::\d*)?(?:/(.*))?$", r)
if m:
    host, path = m.group(1), m.group(2) or ""
elif re.match(r"^(?:[^@/:]+@)?[^/:]+:", r):
    left, path = r.split(":", 1)
    host = left.rsplit("@", 1)[-1]
else:
    path = r
path = path.strip("/")
if path.endswith(".git"):
    path = path[:-4]
print(host.lower() + "\t" + path)
' "$1"
  }
  _gl_repo_path() { _gl_split_repo "$REPO" | cut -f2; }
  # The project's host: from REPO when it carries one, else from the origin
  # remote; empty when neither does (callers then accept any host). A host
  # without a dot is an ssh alias (`git@gitlab-work:g/p.git` via
  # ~/.ssh/config), not the name in the project's https issue URLs, so it
  # counts as unknown too rather than rejecting every valid URL.
  _gl_repo_host() {
    local _h
    _h="$(_gl_split_repo "$REPO" | cut -f1)"
    [ -n "$_h" ] || _h="$(_gl_split_repo "$(git remote get-url origin 2>/dev/null)" | cut -f1)"
    case "$_h" in *.*) printf '%s' "$_h" ;; esac
  }
  # REST project reference for `glab api` (#303), which takes no -R flag:
  # the URL-encoded project path (GitLab accepts it wherever :id goes), or
  # glab's own :id placeholder for the current directory's project.
  _gl_api_project() {
    local _p
    _p="$(_gl_repo_path)"
    if [ -n "$_p" ]; then
      python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$_p"
    else
      echo ":id"
    fi
  }
  # MR iids are interpolated into REST paths -- accept digits only.
  _gl_require_iid() {
    case "$2" in
      ''|*[!0-9]*) echo "pipeline-vcs: $1: expected a numeric MR iid, got '$2'" >&2; return 1 ;;
    esac
  }
  # glab MR list JSON on stdin -> the shared {number,state,title,
  # headRefName,body} PR shape (find-pr, check-closing-keyword).
  _gl_mrs_to_prs() {
    python3 -I -c '
import json, sys
try: mrs = json.load(sys.stdin)
except Exception: mrs = []
json.dump([{"number": m.get("iid"),
            "state": {"opened": "OPEN", "merged": "MERGED"}.get(m.get("state", ""), "CLOSED"),
            "title": m.get("title", ""),
            "headRefName": m.get("source_branch") or m.get("sourceBranch") or "",
            "body": m.get("description") or ""} for m in mrs], sys.stdout)
'
  }
  # MR <iid>'s changed paths, one per line (#303): new_path covers added,
  # modified and renamed files. GET /projects/:id/merge_requests/:iid/diffs,
  # every page. Returns non-zero with no stdout on an API failure or an
  # empty/unparseable response -- never a short or empty "no files" list.
  # GitLab itself truncates MRs above its instance diff limits.
  _gl_pr_files() {
    local _raw
    _raw="$(glab api --paginate "projects/$(_gl_api_project)/merge_requests/$1/diffs?per_page=100")" || return 1
    [ -n "$_raw" ] || return 1
    # Strict parse: an entry without new_path (e.g. an error object) is a
    # failure, not an MR with no files -- raises before anything is printed.
    printf '%s' "$_raw" | _gh_paginate_merge | python3 -I -c '
import json, sys
paths = [d["new_path"] for d in json.load(sys.stdin)]
for p in paths:
    print(p)
' 2>/dev/null
  }

  case "$verb" in
    assign-issue)
      _vcs_shared_assign_issue "${1:-}" _gl_assignees_get _gl_assignee_add _gl_current_user
      ;;
    current-user)
      _vcs_shared_print_current_user _gl_current_user
      exit $?
      ;;
    issue-assignees)
      _vcs_shared_issue_assignees "${1:-}" _gl_assignees_get || exit 1
      ;;
    unassign-issue)
      _vcs_shared_unassign_issue "${1:-}" "${2:-}" _gl_assignees_get _gl_assignee_remove || exit 1
      ;;
    list-assignees)
      # Capped at glab's per-page ceiling, like list-issues (#560).
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] glab issue list --state opened --per-page 100 --output json $RARG (assignees per issue)"
        return 0
      fi
      local _la_raw
      _la_raw="$(glab issue list --state opened --per-page 100 --output json $RARG)" || exit 1
      printf '%s' "$_la_raw" | _vcs_shared_assignee_map gitlab || exit 1
      ;;
    list-issues)
      # glab's default page size is well under 100; --per-page raises it to
      # GitLab's own per-page ceiling. glab has no built-in "fetch every
      # page" flag, so unlike github/github-api this stays capped — warn
      # loudly naming the cap whenever a result lands exactly on it, so
      # truncation is never silent (#171).
      local _gli_cap=100
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] glab issue list --state opened --per-page $_gli_cap $RARG $*"
        return 0
      fi
      local _gli_out
      _gli_out="$(glab issue list --state opened --per-page "$_gli_cap" $RARG "$@")" || exit 1
      local _gli_count
      _gli_count="$(printf '%s' "$_gli_out" | _json_array_count)"
      _list_cap_warn list-issues "$_gli_cap" "$_gli_count" "glab --per-page ceiling" issues
      printf '%s\n' "$_gli_out"
      ;;
    view-issue)
      # --spec (#201) is a GitHub-only compact form; fall back to the plain
      # full view rather than silently ignoring the flag.
      for _vi_a in "$@"; do
        case "$_vi_a" in --spec|--since-stage) echo "pipeline-vcs: view-issue $_vi_a: not implemented for provider 'gitlab' -- falling back to full view-issue" >&2 ;; esac
      done
      _run glab issue view "$1" $RARG
      ;;
    comment-issue)
      local n="$1" body="$2"
      _run glab issue note "$n" --message "$body" $RARG
      ;;
    close-issue)
      local n="$1" body="$2"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] glab issue note $n --message <body> && glab issue close $n $RARG"
      else
        glab issue note "$n" --message "$body" $RARG
        glab issue close "$n" $RARG
      fi
      ;;
    label-issue)
      local n="$1"; shift
      _parse_label_args "$@"
      _gl_label_update issue "$n"
      ;;
    create-issue)
      local title="$1" body_file="$2"; shift 2
      local label_args=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --label) [ $# -ge 2 ] || _vcs_flag_needs_value --label "create-issue <title> <body-file> [--label <label>]..."; label_args+=("--label" "$2"); shift 2 ;;
          *) shift ;;
        esac
      done
      if [ "$DRY_RUN" = "true" ]; then
        _run glab issue create --title "$title" \
          --description "$(cat "$body_file")" \
          "${label_args[@]+"${label_args[@]}"}" $RARG
        return 0
      fi
      local _ci_url
      _ci_url="$(glab issue create --title "$title" \
        --description "$(cat "$body_file")" \
        "${label_args[@]+"${label_args[@]}"}" $RARG)" || return
      [ -n "$_ci_url" ] && printf '%s\n' "$_ci_url"
      # Assign the new issue (#299) -- stdout stays glab's own output.
      _vcs_shared_assign_issue "$(_vcs_issue_number_from_url "$_ci_url")" \
        _gl_assignees_get _gl_assignee_add _gl_current_user >&2
      ;;
    create-pr)
      local branch="$1" title="$2" body_file="$3"
      [ -z "$BASE_BRANCH" ] && BASE_BRANCH="$(glab repo view --format='%{default_branch}' 2>/dev/null || echo main)"
      local _draft_arg=""; [ "$_PR_DRAFT" = "true" ] && _draft_arg="--draft"
      _run glab mr create --head "$branch" --target-branch "$BASE_BRANCH" \
        --title "$title" --description "$(cat "$body_file")" $RARG $_draft_arg
      ;;
    ready-pr|draft-pr)
      # (#332) `glab mr update <n> --ready|--draft`.
      local _rd_n="${1:-}" _rd_flag="--ready"
      _vcs_require_pr_id "$VERB" "$_rd_n"
      [ "$VERB" = "draft-pr" ] && _rd_flag="--draft"
      _run glab mr update "$_rd_n" "$_rd_flag" $RARG
      ;;
    pr-is-draft)
      # (#332) glab's MR JSON carries a boolean `draft`. Fail closed.
      _gitlab_fetch_draft() {
        glab mr view "$1" --output json $RARG
      }
      _vcs_shared_pr_is_draft "${1:-}" draft \
        "glab mr view ${1:-} --output json $RARG" _gitlab_fetch_draft
      ;;
    pr-ci-runs)
      _vcs_draft_unsupported pr-ci-runs gitlab
      ;;
    view-pr)
      _run glab mr view "$1" $RARG
      ;;
    list-prs)
      # Same reasoning as list-issues above: raise the page size and warn
      # loudly if a result lands exactly on the cap (#171).
      local _glp_cap=100
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] glab mr list --state opened --per-page $_glp_cap $RARG"
        return 0
      fi
      local _glp_out
      _glp_out="$(glab mr list --state opened --per-page "$_glp_cap" $RARG)" || exit 1
      local _glp_count
      _glp_count="$(printf '%s' "$_glp_out" | _json_array_count)"
      _list_cap_warn list-prs "$_glp_cap" "$_glp_count" "glab --per-page ceiling" PRs
      printf '%s\n' "$_glp_out"
      ;;
    diff-pr)
      _run glab mr diff "$1" $RARG
      ;;
    checkout-pr)
      _run glab mr checkout "$1" $RARG
      ;;
    approve-pr)
      local n="$1" body="${2:-}"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] glab mr approve $n $RARG  # note: body not posted separately on approve"
      else
        glab mr approve "$n" $RARG
        # glab mr approve has no --body; post comment separately if body given
        [ -n "$body" ] && glab mr note "$n" --message "$body" $RARG
      fi
      ;;
    label-pr)
      local n="$1"; shift
      _parse_label_args "$@"
      _gl_label_update mr "$n"
      ;;
    pr-checks)
      _run glab mr ci status "$1" $RARG
      ;;
    merge-pr)
      _run glab mr merge "$1" $RARG
      ;;
    update-branch)
      # update-branch <n> (#289) — GitLab's equivalent of the server-side base
      # update: `glab mr rebase <iid>` rebases the MR onto its target branch.
      # Exit non-zero on failure; caller re-checks pr-mergeable.
      _run glab mr rebase "$1" $RARG
      ;;
    comment-pr)
      local n="$1" body="$2"
      _run glab mr note "$n" --message "$body" $RARG
      ;;
    pr-mergeable)
      # pr-mergeable <n> (#214) — best-effort: `glab mr view --output json`
      # exposes GitLab's own merge_status field (can_be_merged /
      # cannot_be_merged / unchecked / checking / ...). Only the two
      # conclusive values are trusted; anything else (including a fetch
      # failure) is reported as UNKNOWN with a stderr note, same contract as
      # the GitHub providers but without their lazy-computation retry loop
      # (GitLab does not need one for this field).
      local n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] glab mr view $n --output json $RARG  # .merge_status"
        return 0
      fi
      local _pm_json _pm_status
      _pm_json="$(glab mr view "$n" --output json $RARG 2>/dev/null)"
      _pm_status="$(printf '%s' "$_pm_json" | python3 -I -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get('merge_status') or d.get('detailed_merge_status') or '')
" 2>/dev/null)"
      case "$_pm_status" in
        can_be_merged|mergeable)     echo MERGEABLE;   exit 0 ;;
        cannot_be_merged|conflict)   echo CONFLICTING; exit 1 ;;
        *)
          echo "pipeline-vcs: pr-mergeable: gitlab merge_status '$_pm_status' not conclusive — reporting UNKNOWN" >&2
          echo UNKNOWN
          exit 2
          ;;
      esac
      ;;
    find-pr)
      # find-pr <issue-n> [open|merged|closed|all] (#298). glab selects the
      # state with a flag (default = opened); normalise GitLab MR fields to
      # the shared {number,state,title,headRefName,body} shape and reuse the
      # github matcher, so `merged` counts only the branch convention or a
      # closing keyword -- GitLab uses the same Closes #N syntax.
      local n="$1" state="${2:-open}" _glfp_flag=""
      case "$state" in
        merged) _glfp_flag="--merged" ;;
        closed) _glfp_flag="--closed" ;;
        all)    _glfp_flag="--all" ;;
      esac
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] glab mr list $_glfp_flag --per-page 100 --output json $RARG | filter issue-$n / #$n"
        return 0
      fi
      local _glfp_out
      _glfp_out="$(glab mr list $_glfp_flag --per-page 100 --output json $RARG)" || {
        echo "pipeline-vcs: find-pr: glab mr list failed" >&2; exit 1; }
      _list_cap_warn find-pr 100 "$(printf '%s' "$_glfp_out" | _json_array_count)" "glab --per-page ceiling" MRs
      printf '%s' "$_glfp_out" | _gl_mrs_to_prs | _vcs_shared_find_pr "$n" "$state" "$(_gl_repo_path)" gitlab "$(_gl_repo_host)"
      ;;
    pr-files)
      # pr-files <iid> (#303) -- same contract as github: one changed path
      # per line; a failed or empty fetch exits 1 with no stdout.
      local n="${1:-}"
      _gl_require_iid pr-files "$n" || exit 1
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] glab api --paginate projects/$(_gl_api_project)/merge_requests/$n/diffs?per_page=100"
        return 0
      fi
      _gl_pr_files "$n" || { echo "pipeline-vcs: pr-files: could not fetch the changed files of MR !$n" >&2; exit 1; }
      ;;
    check-pr-files)
      # Forbidden-files merge gate (#303): pr-files output through the same
      # shared matcher github uses. Fails closed on any fetch failure.
      local n="${1:-}"
      _gl_require_iid check-pr-files "$n" || exit 1
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] pr-files $n | match against forbidden patterns"
        return 0
      fi
      local _glcpf_paths
      _glcpf_paths="$(_gl_pr_files "$n")" || {
        echo "pipeline-vcs: check-pr-files: could not fetch the changed files of MR !$n -- failing closed, do not merge" >&2
        exit 1; }
      printf '%s\n' "$_glcpf_paths" | CONFIGURED="$(cfg merge.forbidden_files)" REPLACE="$(cfg merge.forbidden_files_replace)" ALLOW="$(cfg merge.forbidden_files_allow)" _vcs_shared_check_pr_files
      ;;
    check-closing-keyword)
      # check-closing-keyword <iid|branch> <issue_N> (#303) -- github
      # semantics via _vcs_shared_check_closing_keyword: exit 1 when the MR
      # description closes #N while another opened MR references N. A
      # fetch failure fails open with the talos:closing-keyword-unverified
      # marker (fixed-literal reason), exactly as on github.
      local pr_ref="${1:-}" issue_n="${2:-}"
      [ -z "$pr_ref" ]  && { echo "pipeline-vcs: check-closing-keyword: missing MR ref"       >&2; exit 1; }
      [ -z "$issue_n" ] && { echo "pipeline-vcs: check-closing-keyword: missing issue number" >&2; exit 1; }
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] check-closing-keyword $pr_ref $issue_n: glab mr view (description), then glab mr list --output json"
        return 0
      fi
      # The bare project path scopes the reference forms, never a URL.
      local _glck_repo _glck_json _glck_number _glck_body
      _glck_repo="$(_gl_repo_path)"
      if [ -z "$_glck_repo" ]; then
        echo "talos:closing-keyword-unverified pr=$pr_ref issue=$issue_n reason=repo-unresolved"
        return 0
      fi
      _glck_json="$(glab mr view "$pr_ref" --output json $RARG 2>/dev/null)"
      _glck_number="$(printf '%s' "$_glck_json" | python3 -I -c "import json,sys; print(json.load(sys.stdin).get('iid',''))" 2>/dev/null)"
      if [ -z "$_glck_number" ]; then
        echo "pipeline-vcs: check-closing-keyword: could not fetch MR '$pr_ref' — skipping check" >&2
        echo "talos:closing-keyword-unverified pr=$pr_ref issue=$issue_n reason=pr-fetch-failed"
        return 0
      fi
      _glck_body="$(printf '%s' "$_glck_json" | python3 -I -c "import json,sys; print(json.load(sys.stdin).get('description') or '')")"
      # Opened MRs only, every page (#319: `glab mr list` stopped at 100).
      # Non-zero on failure.
      _gl_fetch_closing_siblings() {
        local _out
        _out="$(glab api --paginate "projects/$(_gl_api_project)/merge_requests?state=opened&per_page=100")" || return 1
        [ -n "$_out" ] || return 1
        printf '%s' "$_out" | _gh_paginate_merge | _gl_mrs_to_prs
      }
      printf '%s' "$_glck_body" | REPO="$_glck_repo" \
        _vcs_shared_check_closing_keyword "$issue_n" "$_glck_number" "$pr_ref" _gl_fetch_closing_siblings gitlab "$(_gl_repo_host)"
      exit $?
      ;;
    check-epic-acceptance)
      # check-epic-acceptance <N> (#303): the issue description through the
      # shared unticked-box scan. A failed fetch, or a response without a
      # description field, exits 1 so the epic sweep never closes the epic.
      local n="${1:-}"
      [ -z "$n" ] && { echo "pipeline-vcs: check-epic-acceptance: missing issue number" >&2; exit 1; }
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] glab issue view $n --output json $RARG | .description | scan for unticked '- [ ]' checklist lines"
        return 0
      fi
      local _glcea_json _glcea_body
      _glcea_json="$(glab issue view "$n" --output json $RARG)" || exit 1
      _glcea_body="$(printf '%s' "$_glcea_json" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
if not isinstance(d, dict) or "description" not in d:
    sys.exit(1)
print(d["description"] or "")
' 2>/dev/null)" || {
        echo "pipeline-vcs: check-epic-acceptance: could not read the description of issue #$n -- not closing" >&2
        exit 1; }
      printf '%s' "$_glcea_body" | _epic_acceptance_scan
      ;;
    rerun-ci)
      # rerun-ci <iid> (#303): retry the failed/canceled jobs of the MR's
      # head pipeline -- GET /projects/:id/merge_requests/:iid (.head_pipeline)
      # then POST /projects/:id/pipelines/:pipeline_id/retry. Any failure,
      # including an MR with no pipeline, exits 1.
      local n="${1:-}"
      _gl_require_iid rerun-ci "$n" || exit 1
      local _glrc_proj
      _glrc_proj="$(_gl_api_project)"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] glab api --method POST projects/$_glrc_proj/pipelines/<head pipeline of MR !$n>/retry"
        return 0
      fi
      local _glrc_pid
      _glrc_pid="$(glab api "projects/$_glrc_proj/merge_requests/$n" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
p = d.get("head_pipeline") or d.get("pipeline") or {}
print(p.get("id") or "")
' 2>/dev/null)"
      case "$_glrc_pid" in
        ''|*[!0-9]*) echo "pipeline-vcs: rerun-ci: could not resolve a head pipeline for MR !$n" >&2; exit 1 ;;
      esac
      glab api --method POST "projects/$_glrc_proj/pipelines/$_glrc_pid/retry" >/dev/null || {
        echo "pipeline-vcs: rerun-ci: retry of pipeline $_glrc_pid failed" >&2; exit 1; }
      echo "rerun-ci: retried pipeline $_glrc_pid for MR !$n"
      ;;
    pr-checks-required)
      # Not implemented for gitlab yet. This verb gates a CI-wait
      # loop that trusts exit 0 as "every required check passed" -- failing
      # open here would let that loop treat unimplemented CI status as a
      # vacuous pass. Fail closed instead (#205).
      echo "pipeline-vcs: pr-checks-required not implemented for gitlab -- falls back to failing closed, not a vacuous pass" >&2
      return 1
      ;;
    *) echo "pipeline-vcs: unknown verb: $verb" >&2; exit 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# AZURE DEVOPS ADAPTER  (best-effort)
#   Prerequisites:
#     az extension add --name azure-devops
#     az devops configure --defaults organization=<org_url> project=<project>
#   Or set vcs.azure.org_url + vcs.azure.project in talos.pipeline.json
# ─────────────────────────────────────────────────────────────────────────────
# Post a comment to an Azure DevOps work item. `az boards work-item comment add`
# does not exist in the azure-devops extension, so use the REST comments endpoint
# via `az rest` (needs an absolute org URL + project name).
_azure_post_comment() {
  local n="$1" body="$2"
  # Work-item comments render HTML (unlike PR threads) — convert markdown bodies.
  body="$(_md_to_html "$body")"
  local base_org="$AZURE_ORG" proj="$AZURE_PROJECT"
  [ -z "$base_org" ] && base_org="$(az devops configure --list 2>/dev/null | awk -F'= *' '/^organization/{print $2}' | tr -d '[:space:]')"
  [ -z "$proj" ]     && proj="$(az devops configure --list 2>/dev/null | awk -F'= *' '/^project/{print $2}' | tr -d '[:space:]')"
  if [ -z "$base_org" ] || [ -z "$proj" ]; then
    echo "pipeline-vcs: azure comment needs an org URL + project — set vcs.azure.org_url and vcs.azure.project" >&2
    return 1
  fi
  base_org="${base_org%/}"
  local url="$base_org/$proj/_apis/wit/workItems/$n/comments?api-version=7.1-preview.3"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] az rest --method post --url $url --body {\"text\":$body}"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  python3 -I -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"text": sys.argv[2]}))' "$tmp" "$body"
  az rest --method post --url "$url" \
    --resource "499b84ac-1321-427f-aa17-267ca6975798" \
    --headers "Content-Type=application/json" --body "@$tmp" >/dev/null
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# Echo the ADO organization URL without a trailing "/": vcs.azure.org_url,
# else `az devops configure`'s default. Returns non-zero when neither is set.
_azure_org() {
  local base_org="$AZURE_ORG"
  [ -z "$base_org" ] && base_org="$(az devops configure --list 2>/dev/null | awk -F'= *' '/^organization/{print $2}' | tr -d '[:space:]')"
  [ -z "$base_org" ] && return 1
  echo "${base_org%/}"
}

# Echo the ADO Git REST base URL ({org}/{project}/_apis/git/repositories/{repo}).
# Returns non-zero if org/project/repo can't be resolved. Used by the PR verbs
# that az has no command for (labels, comment threads) — reached via `az rest`.
_azure_git_base() {
  local base_org proj="$AZURE_PROJECT" repo="$REPO"
  [ -z "$proj" ]     && proj="$(az devops configure --list 2>/dev/null | awk -F'= *' '/^project/{print $2}' | tr -d '[:space:]')"
  [ -z "$repo" ] && return 1
  base_org="$(_azure_org)" || return 1
  [ -z "$proj" ] && return 1
  echo "$base_org/$proj/_apis/git/repositories/$repo"
}
ADO_RESOURCE="499b84ac-1321-427f-aa17-267ca6975798"  # Azure DevOps AAD app id (az rest --resource)

# Convert a markdown string to HTML for Azure DevOps HTML-rendered fields.
# ADO work-item Description and work-item comments render HTML, NOT markdown, so
# GitHub-flavored markdown bodies (e.g. planner-generated sub-issues) would
# otherwise show raw '#', '**', '- [ ]' text. PR comment threads DO render
# markdown, so this is applied only to work-item Description + comments, never PR
# threads. Passes the body through unchanged when it already looks like HTML.
# Prefers pandoc, then the python `markdown` lib, then a self-contained fallback
# (python3 is already a hard dependency of this adapter).
_md_to_html() {
  local md="$1"
  [ -z "$md" ] && { printf ''; return 0; }
  # Already HTML? (first non-space char is '<') — pass through untouched.
  case "$(printf '%s' "$md" | sed -e 's/^[[:space:]]*//')" in
    '<'*) printf '%s' "$md"; return 0 ;;
  esac
  if command -v pandoc >/dev/null 2>&1; then
    printf '%s' "$md" | pandoc -f gfm -t html 2>/dev/null && return 0
  fi
  python3 -I - "$md" <<'PYEOF'
import sys, html, re
src = sys.argv[1]
try:
    import markdown  # best fidelity when the lib is installed
    sys.stdout.write(markdown.markdown(src, extensions=['tables', 'fenced_code', 'sane_lists']))
    sys.exit(0)
except Exception:
    pass

def inline(text):
    text = html.escape(text, quote=False)
    codes = []
    def stash(m):
        codes.append(m.group(1)); return "\x00%d\x00" % (len(codes) - 1)
    text = re.sub(r'`([^`]+)`', stash, text)
    text = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', r'<a href="\2">\1</a>', text)
    text = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', text)
    text = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', r'<em>\1</em>', text)
    text = re.sub(r'(?<!\w)_([^_]+)_(?!\w)', r'<em>\1</em>', text)
    text = re.sub(r'\x00(\d+)\x00', lambda m: "<code>%s</code>" % codes[int(m.group(1))], text)
    return text

def cells(s):
    s = re.sub(r'^\|', '', s.strip()); s = re.sub(r'\|$', '', s)
    return [c.strip() for c in s.split('|')]

def is_sep(s):
    return bool(re.match(r'^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)+\|?\s*$', s))

lines = src.replace('\r\n', '\n').split('\n')
out = []; i = 0; n = len(lines)
while i < n:
    line = lines[i]
    if re.match(r'^\s*```', line):
        i += 1; buf = []
        while i < n and not re.match(r'^\s*```\s*$', lines[i]):
            buf.append(html.escape(lines[i], quote=False)); i += 1
        i += 1
        out.append('<pre><code>' + '\n'.join(buf) + '</code></pre>'); continue
    m = re.match(r'^(#{1,6})\s+(.*)$', line)
    if m:
        lv = len(m.group(1))
        out.append('<h%d>%s</h%d>' % (lv, inline(m.group(2).strip()), lv)); i += 1; continue
    if '|' in line and i + 1 < n and is_sep(lines[i + 1]):
        header = cells(line); i += 2; rows = []
        while i < n and '|' in lines[i] and lines[i].strip():
            rows.append(cells(lines[i])); i += 1
        t = ['<table border="1" cellpadding="6" cellspacing="0">']
        t.append('<tr>' + ''.join('<th>%s</th>' % inline(c) for c in header) + '</tr>')
        for r in rows:
            t.append('<tr>' + ''.join('<td>%s</td>' % inline(c) for c in r) + '</tr>')
        t.append('</table>'); out.append('\n'.join(t)); continue
    if re.match(r'^\s*[-*+]\s+', line):
        items = []
        while i < n and re.match(r'^\s*[-*+]\s+', lines[i]):
            it = re.sub(r'^\s*[-*+]\s+', '', lines[i])
            it = re.sub(r'^\[( |x|X)\]\s*', lambda mm: '☐ ' if mm.group(1) == ' ' else '☑ ', it)
            items.append('<li>%s</li>' % inline(it)); i += 1
        out.append('<ul>' + ''.join(items) + '</ul>'); continue
    if re.match(r'^\s*\d+\.\s+', line):
        items = []
        while i < n and re.match(r'^\s*\d+\.\s+', lines[i]):
            it = re.sub(r'^\s*\d+\.\s+', '', lines[i]); items.append('<li>%s</li>' % inline(it)); i += 1
        out.append('<ol>' + ''.join(items) + '</ol>'); continue
    if line.strip() == '':
        i += 1; continue
    buf = [line]; i += 1
    while i < n and lines[i].strip() != '' and not re.match(r'^\s*(#{1,6}\s|```|[-*+]\s|\d+\.\s)', lines[i]):
        buf.append(lines[i]); i += 1
    out.append('<p>' + inline(' '.join(b.strip() for b in buf)) + '</p>')
sys.stdout.write('\n'.join(out))
PYEOF
}

# Untrusted ADO text (work-item HTML, branch names) is cut to this many
# characters before any regex runs over it (#304), as gitlab does.
_VCS_AZURE_SCAN_CAP=65536

# _ado_description_text (#304)
#   stdin:  an `az boards work-item show` JSON document.
#   stdout: its System.Description (HTML) as text, one non-empty stripped
#           line each, every checkbox rewritten as a `- [ ] ` / `- [x] ` line
#           for _epic_acceptance_scan: an <input type="checkbox"> (ticked
#           only by a `checked` attribute of its own, never by a value such
#           as value="checked"), U+2610 (unticked), U+2611/U+2612 (ticked),
#           and a line starting with [ ] or [x], e.g. <li>[ ] text</li>. A
#           box's text is the rest of its line or list item, on either side
#           of the box; on a line with several boxes each takes the text
#           after it, or the text before it when the line ends in a box.
#   exit:   0; 1 when the document is not a work item (no `fields` object);
#           3, printing nothing, when the description is longer than
#           _VCS_AZURE_SCAN_CAP (checked before any regex runs).
#   A missing System.Description is an empty one: ADO omits empty fields.
#   Linear: a tag match starts only at `<` and its [^<>]* stops at the next
#   `<`, and the lookahead after the name stops name/attribute backtracking;
#   an attribute match starts only at a name, and a quoted value stops at
#   the next matching quote; blank lines are dropped so the scan's leading
#   \s* never spans lines.
_ado_description_text() {
  python3 -I -c '
import html, json, re, sys
cap = int(sys.argv[1])
d = json.load(sys.stdin)
fields = d.get("fields") if isinstance(d, dict) else None
if not isinstance(fields, dict):
    sys.exit(1)
src = fields.get("System.Description") or ""
if not isinstance(src, str):
    sys.exit(1)
if len(src) > cap:
    sys.exit(3)
OPEN, DONE = "", ""   # in-line box markers (private use)
src = src.replace(OPEN, "").replace(DONE, "")
BLOCK = {"p", "div", "br", "li", "ul", "ol", "tr", "table", "blockquote", "pre",
         "h1", "h2", "h3", "h4", "h5", "h6"}
ATTR = re.compile(r"([^\s\"\x27<>/=]+)(?:\s*=\s*(\"[^\"]*\"|\x27[^\x27]*\x27|[^\s\"\x27<>=`]+))?")
def tag(m):
    name = m.group(2).lower()
    if name == "input" and not m.group(1):
        attrs = {}
        for a in ATTR.finditer(m.group(3)):
            attrs.setdefault(a.group(1).lower(), (a.group(2) or "").strip("\"\x27"))
        if attrs.get("type", "").lower() == "checkbox":
            return DONE if "checked" in attrs else OPEN
        return ""
    return "\n" if name in BLOCK else ""
text = re.sub(r"<(/?)([A-Za-z][A-Za-z0-9]*)(?![A-Za-z0-9])([^<>]*)>", tag, src)
text = html.unescape(text)
text = text.replace("☐", OPEN).replace("☑", DONE).replace("☒", DONE)
MARK = re.compile("([" + OPEN + DONE + "])")
lines = []
for line in text.splitlines():
    parts = MARK.split(line)
    segs, marks = parts[0::2], parts[1::2]
    if not marks:
        line = line.strip()
        if re.match(r"\[(?:\s|x|X)\]", line):
            line = "- " + line
        if line:
            lines.append(line)
        continue
    if len(marks) == 1:
        texts = [segs[0] + " " + segs[1]]
    elif segs[-1].strip():
        texts = segs[1:]
    else:
        texts = segs[:-1]
    for mark, t in zip(marks, texts):
        t = " ".join(t.split()) or "(checkbox without text)"
        lines.append(("- [ ] " if mark == OPEN else "- [x] ") + t)
print("\n".join(lines))
' "$_VCS_AZURE_SCAN_CAP"
}

_azure() {
  if ! command -v az >/dev/null 2>&1; then
    echo "pipeline-vcs: 'az' (Azure CLI) not found. Install from https://aka.ms/installazurecli" >&2
    exit 1
  fi

  # Check for azure-devops extension
  if ! az extension list --query "[?name=='azure-devops']" -o tsv 2>/dev/null | grep -q azure-devops; then
    echo "pipeline-vcs: azure-devops extension missing. Run: az extension add --name azure-devops" >&2
    exit 1
  fi

  # Shadow `az` for the same reason _github shadows `gh` (#173): a single
  # point of truth covering every call site below with zero edits. Defined
  # after the command-v / extension pre-flight checks above so those still
  # resolve the real binary. Azure DevOps REST throttling returns HTTP 429
  # or 503 with a "TF400733"/"rate limit" style message; the `az` CLI
  # surfaces this on stderr, typically containing "429" or "rate limit". No
  # repo test fixture reproduces az's real throttling body today — best
  # effort, revisit if a real sample becomes available.
  az() { _with_retry "$VERB" command az "$@"; }

  local ORG_ARG="" PROJ_ARG=""
  [ -n "$AZURE_ORG" ]     && ORG_ARG="--org $AZURE_ORG"
  [ -n "$AZURE_PROJECT" ] && PROJ_ARG="--project $AZURE_PROJECT"

  # Provider calls for _vcs_shared_assign_issue (#299). ADO has a single
  # System.AssignedTo; print both its uniqueName and displayName so the
  # read-back matches whichever form issues.assignee was given in. Older
  # az/ADO versions return the field as a "Name <upn>" string instead.
  _az_assignee_get() {
    local _ag_json
    _ag_json="$(az boards work-item show --id "$1" $ORG_ARG --output json)" || return 1
    printf '%s' "$_ag_json" | python3 -I -c "
import json, re, sys
v = (json.load(sys.stdin).get('fields') or {}).get('System.AssignedTo')
if isinstance(v, dict):
    for k in ('uniqueName', 'displayName'):
        if v.get(k):
            print(v[k])
elif v:
    print(v)
    m = re.search(r'<([^>]+)>', v)
    if m:
        print(m.group(1))
"
  }
  _az_assignee_set() {
    az boards work-item update --id "$1" --assigned-to "$2" $ORG_ARG --output none
  }
  # The work item's assignee as its unique name only (#560): the form
  # `current-user` prints, so a claim compares one name per person.
  _az_assignee_login() {
    local _al_json
    _al_json="$(az boards work-item show --id "$1" $ORG_ARG --output json)" || return 1
    printf '%s' "$_al_json" | python3 -I -c "
import json, re, sys
v = (json.load(sys.stdin).get('fields') or {}).get('System.AssignedTo')
if isinstance(v, dict):
    if v.get('uniqueName'):
        print(v['uniqueName'])
elif v:
    m = re.search(r'<([^>]+)>', v)
    print(m.group(1) if m else v)
"
  }
  # An empty --assigned-to clears the field (#560).
  _az_assignee_clear() {
    az boards work-item update --id "$1" --assigned-to "" $ORG_ARG --output none
  }

  # PR and work-item ids go into REST paths and az --id: digits only (#304).
  _az_require_id() {
    case "$2" in
      ''|*[!0-9]*) echo "pipeline-vcs: $1: expected a numeric id, got '$2'" >&2; return 1 ;;
    esac
  }
  # PR <id>'s policy evaluation records, a JSON array (rerun-ci, #304):
  # `az repos pr policy list --id <id>`, which calls GET _apis/policy/
  # evaluations?artifactId=vstfs:///CodeReview/CodeReviewId/<projectId>/<id>
  # without includeNotApplicable, so a policy that does not apply to the PR
  # has no record (rerun-ci only re-queues failed builds, so it needs none).
  # Returns non-zero with no stdout when the fetch fails or the response is
  # not a list of objects.
  _az_pr_policies() {
    local _azpp_json
    _azpp_json="$(az repos pr policy list --id "$1" $ORG_ARG --output json)" || {
      echo "pipeline-vcs: $VERB: could not list the policies of PR #$1" >&2; return 1; }
    printf '%s' "$_azpp_json" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
if not isinstance(d, list) or not all(isinstance(r, dict) for r in d):
    sys.exit(1)
' 2>/dev/null || {
      echo "pipeline-vcs: $VERB: could not parse the policies of PR #$1" >&2; return 1; }
    printf '%s' "$_azpp_json"
  }
  # PR <id>'s policy evaluations for pr-checks-required (#328), printed as
  # {"source": <the PR's lastMergeSourceCommit id, or "">, "records": [...]}.
  # `az repos pr policy list` has no includeNotApplicable flag, so this is
  # the REST call (Policy - Evaluations - List, api-version 7.1-preview.1):
  # GET {org}/{projectId}/_apis/policy/evaluations?artifactId=vstfs:///
  # CodeReview/CodeReviewId/{projectId}/{id}&includeNotApplicable=true,
  # with the project id taken from `az repos pr show` (repository.project.
  # id), as az builds it. One $top=1000 page: a full page may be truncated,
  # so it fails like an unparseable one. Returns non-zero with no stdout on
  # any fetch or parse failure, before any REST call when the project id
  # is not a GUID.
  _az_pr_evaluations() {
    local _azpe_org _azpe_pr _azpe_meta _azpe_proj _azpe_raw
    _azpe_org="$(_azure_org)" || {
      echo "pipeline-vcs: $VERB: needs the organization (vcs.azure.org_url)" >&2; return 1; }
    _azpe_pr="$(az repos pr show --id "$1" $ORG_ARG --output json)" || {
      echo "pipeline-vcs: $VERB: could not read PR #$1" >&2; return 1; }
    # "<projectId> <sourceCommit>"; the commit may be empty.
    _azpe_meta="$(printf '%s' "$_azpe_pr" | python3 -I -c '
import json, re, sys
d = json.load(sys.stdin)
proj = ((d.get("repository") or {}).get("project") or {}).get("id")
src = (d.get("lastMergeSourceCommit") or {}).get("commitId") or ""
if not isinstance(proj, str) or not re.fullmatch(r"[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", proj):
    sys.exit(1)
if not isinstance(src, str) or not re.fullmatch(r"(?:[0-9a-fA-F]{40})?", src):
    sys.exit(1)
print(proj + " " + src)
' 2>/dev/null)" || {
      echo "pipeline-vcs: $VERB: could not read the project id of PR #$1" >&2; return 1; }
    _azpe_proj="${_azpe_meta%% *}"
    _azpe_raw="$(az rest --method get --resource "$ADO_RESOURCE" \
      --url "$_azpe_org/$_azpe_proj/_apis/policy/evaluations?artifactId=vstfs%3A%2F%2F%2FCodeReview%2FCodeReviewId%2F$_azpe_proj%2F$1&includeNotApplicable=true&\$top=1000&api-version=7.1-preview.1")" || {
      echo "pipeline-vcs: $VERB: could not list the policies of PR #$1" >&2; return 1; }
    printf '%s' "$_azpe_raw" | python3 -I -c '
import json, sys
v = json.load(sys.stdin)["value"]
if not isinstance(v, list) or not all(isinstance(r, dict) for r in v) or len(v) >= 1000:
    sys.exit(1)
print(json.dumps({"source": sys.argv[1], "records": v}))
' "${_azpe_meta#* }" 2>/dev/null || {
      echo "pipeline-vcs: $VERB: could not parse the policies of PR #$1 (not a list of evaluations, or a full page of 1000 that may be truncated)" >&2
      return 1; }
  }
  # stdin: `work-item show --expand relations` JSON. Prints the id of each
  # linked PR, one per line; links look like
  # vstfs:///Git/PullRequestId/<project>%2F<repo>%2F<pr-id>. Exits 1 on
  # JSON that does not parse; a non-numeric id is dropped.
  _az_linked_pr_ids() {
    python3 -I -c '
import json, sys
for r in json.load(sys.stdin).get("relations") or []:
    url = r.get("url", "")
    if r.get("rel") == "ArtifactLink" and url.startswith("vstfs:///Git/PullRequestId/"):
        pid = url.replace("%2F", "/").replace("%2f", "/").rsplit("/", 1)[-1]
        if pid.isdigit():
            print(pid)
' 2>/dev/null
  }
  # PR <id>'s changed paths, one per line without ADO's leading "/" (#304):
  # the last iteration's changes against the common commit ($compareTo
  # defaults to 0), every $top/$skip page. REST, api-version 7.1:
  # GET .../pullRequests/{id}/iterations, then
  # GET .../pullRequests/{id}/iterations/{last}/changes. Returns non-zero
  # with no stdout on any fetch or parse failure -- never a short list.
  _az_pr_files() {
    local _gb _raw _it _page _next _skip=0 _paths=""
    _gb="$(_azure_git_base)" || {
      echo "pipeline-vcs: $VERB: needs org/project/repo (vcs.azure.org_url, vcs.azure.project, vcs.repo)" >&2
      return 1; }
    _raw="$(az rest --method get --url "$_gb/pullRequests/$1/iterations?api-version=7.1" --resource "$ADO_RESOURCE")" || return 1
    _it="$(printf '%s' "$_raw" | python3 -I -c '
import json, sys
print(max(int(i["id"]) for i in json.load(sys.stdin)["value"]))
' 2>/dev/null)" || return 1
    while :; do
      _raw="$(az rest --method get --resource "$ADO_RESOURCE" \
        --url "$_gb/pullRequests/$1/iterations/$_it/changes?\$top=2000&\$skip=$_skip&api-version=7.1")" || return 1
      # First line: nextSkip (0 on the last page); then one path per line.
      _page="$(printf '%s' "$_raw" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
print(int(d.get("nextSkip") or 0))
for c in d["changeEntries"]:
    item = c["item"]
    if not item.get("isFolder"):
        p = item["path"]
        print(p[1:] if p.startswith("/") else p)
' 2>/dev/null)" || return 1
      _next="${_page%%$'\n'*}"
      [ "$_page" = "$_next" ] || _paths="$_paths${_page#*$'\n'}"$'\n'
      [ "$_next" -gt "$_skip" ] || break
      _skip="$_next"
    done
    printf '%s' "$_paths"
  }
  # Active sibling PRs of PR <self> for work item <n> (#304): PRs linked to
  # the work item plus PRs on an issue-<n> branch, space-separated, <self>
  # excluded. Returns non-zero on any fetch or parse failure, and
  # $_VCS_SIBLINGS_CAPPED (with the siblings it did see) when the active-PR
  # list is still full after _max pages and a probe finds more (#319).
  _az_closing_siblings() {
    local _self="$1" _n="$2" _wi _ids _id _pr _linked="" _active _ra=""
    local _page _len _raw="" _top=1000 _max=10 _pages=0 _capped=0
    [ -n "$REPO" ] && _ra="--repository $REPO"
    _wi="$(az boards work-item show --id "$_n" --expand relations $ORG_ARG --output json)" || return 1
    _ids="$(printf '%s' "$_wi" | _az_linked_pr_ids)" || return 1
    for _id in $_ids; do
      [ "$_id" = "$_self" ] && continue
      _pr="$(az repos pr show --id "$_id" $ORG_ARG --output json)" || return 1
      _linked="${_linked:+$_linked,}$_pr"
    done
    # Every --top/--skip page until a short one (#319: one --top 1000 call
    # missed a sibling past the first 1000). After _max full pages, one
    # --top 1 probe tells a capped list from one that is exactly full.
    while :; do
      _page="$(az repos pr list --status active --top "$_top" --skip "$((_pages * _top))" \
        $ORG_ARG $PROJ_ARG $_ra --output json)" || return 1
      _raw="$_raw$_page"
      _pages=$((_pages + 1))
      _len="$(printf '%s' "$_page" | _json_array_len)" || return 1
      [ "$_len" = "$_top" ] && [ "$_pages" -lt "$_max" ] || break
    done
    if [ "$_len" = "$_top" ]; then
      _page="$(az repos pr list --status active --top 1 --skip "$((_pages * _top))" \
        $ORG_ARG $PROJ_ARG $_ra --output json)" || return 1
      _len="$(printf '%s' "$_page" | _json_array_len)" || return 1
      [ "$_len" = 0 ] || _capped=1
    fi
    _active="$(printf '%s' "$_raw" | _gh_paginate_merge 2>/dev/null)" || return 1
    printf '[[%s],%s]' "$_linked" "$_active" | python3 -I -c '
import json, re, sys
me, n, cap = sys.argv[1], sys.argv[2], int(sys.argv[3])
linked, active = json.load(sys.stdin)
ids = {int(p["pullRequestId"]) for p in linked if p.get("status") == "active"}
branch = re.compile(r"(?:^|/)issue-" + n + r"(?:-|$)")
ids |= {int(p["pullRequestId"]) for p in active if branch.search((p.get("sourceRefName") or "")[:cap])}
ids.discard(int(me))
print(" ".join(str(i) for i in sorted(ids)))
' "$_self" "$_n" "$_VCS_AZURE_SCAN_CAP" 2>/dev/null || return 1
    [ "$_capped" = 0 ] || return "$_VCS_SIBLINGS_CAPPED"
  }

  local verb="$1"; shift
  case "$verb" in
    assign-issue)
      _vcs_shared_assign_issue "${1:-}" _az_assignee_get _az_assignee_set \
        az account show --query user.name --output tsv
      ;;
    current-user)
      _vcs_shared_print_current_user az account show --query user.name --output tsv
      exit $?
      ;;
    issue-assignees)
      _vcs_shared_issue_assignees "${1:-}" _az_assignee_login || exit 1
      ;;
    unassign-issue)
      _vcs_shared_unassign_issue "${1:-}" "${2:-}" _az_assignee_login _az_assignee_clear || exit 1
      ;;
    list-assignees)
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az boards query $ORG_ARG $PROJ_ARG --wiql \"SELECT [System.Id], [System.AssignedTo] FROM WorkItems ...\" --output json"
        return 0
      fi
      local _la_raw
      _la_raw="$(az boards query $ORG_ARG $PROJ_ARG \
        --wiql "SELECT [System.Id], [System.AssignedTo] FROM WorkItems WHERE [System.State] NOT IN ('Closed', 'Done', 'Removed') ORDER BY [System.ChangedDate] DESC" \
        --output json)" || exit 1
      printf '%s' "$_la_raw" | _vcs_shared_assignee_map azure || exit 1
      ;;
    list-issues)
      # ADO has no `az boards work-item list`. Discover work items with a WIQL
      # query instead. The GitHub adapter's "open issues only" maps to ADO's
      # non-terminal states — which are Done/Removed/Closed, not just Closed —
      # so exclude all three.
      #
      # PAGINATION (#171, #278): `az boards query` has no --top/--page flag
      # (see `az boards query --help`) and WIQL has NO "SELECT TOP N" clause
      # either -- ADO rejects it with "TF51006: The query statement is missing
      # a FROM clause. The error is caused by «N»" (#278; the REST endpoint's
      # cap is a `$top` query parameter `az` never exposes). The only ceiling
      # left is the server's own: a flat WIQL query returns at most 20000 work
      # items (VS402337 beyond that). Warn loudly if a result lands exactly on
      # it, since more work items may exist beyond what we can fetch this way.
      local _azli_cap=20000
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az boards query $ORG_ARG $PROJ_ARG --wiql \"SELECT [System.Id], ... FROM WorkItems ...\" --output json"
        return 0
      fi
      local _azli_out
      _azli_out="$(az boards query $ORG_ARG $PROJ_ARG \
        --wiql "SELECT [System.Id], [System.Title], [System.State], [System.Tags] FROM WorkItems WHERE [System.State] NOT IN ('Closed', 'Done', 'Removed') ORDER BY [System.ChangedDate] DESC" \
        --output json)" || exit 1
      local _azli_count
      _azli_count="$(printf '%s' "$_azli_out" | _json_array_count)"
      _list_cap_warn list-issues "$_azli_cap" "$_azli_count" "ADO flat-WIQL 20000-item server ceiling" "work items"
      printf '%s\n' "$_azli_out"
      ;;
    view-issue)
      # --spec (#201) is a GitHub-only compact form; fall back to the plain
      # full view rather than silently ignoring the flag.
      for _vi_a in "$@"; do
        case "$_vi_a" in --spec|--since-stage) echo "pipeline-vcs: view-issue $_vi_a: not implemented for provider 'azure' -- falling back to full view-issue" >&2 ;; esac
      done
      _run az boards work-item show --id "$1" $ORG_ARG --output json
      ;;
    comment-issue)
      _azure_post_comment "$1" "$2"
      ;;
    close-issue)
      local n="$1" body="$2"
      _azure_post_comment "$n" "$body"
      # #298: honour the process's terminal state (e.g. "Closed" on Agile/
      # CMMI), same key and default pipeline-status.sh uses for "Done".
      local done_state
      done_state="$(cfg board.azure_states.done)"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az boards work-item update --id $n --state $done_state $ORG_ARG"
      else
        az boards work-item update --id "$n" --state "$done_state" $ORG_ARG
      fi
      # A Done work item stays "open" on the board with its tags, so strip
      # every pipeline:* tag or the next run treats it as in flight. Goes
      # through label-issue's json-patch replace (--fields only appends).
      local tag stale_tags=()
      while IFS= read -r tag; do
        tag="${tag#"${tag%%[![:space:]]*}"}"
        case "$tag" in pipeline:*) stale_tags+=(--remove "$tag") ;; esac
      done < <(az boards work-item show --id "$n" $ORG_ARG \
        --query fields.\"System.Tags\" -o tsv 2>/dev/null | tr ';' '\n')
      [ ${#stale_tags[@]} -gt 0 ] && _azure label-issue "$n" "${stale_tags[@]}"
      return 0
      ;;
    label-issue)
      # Azure uses tags, not labels. Manage the whole System.Tags string.
      # `az boards work-item update` has no --tags flag, and its
      # `--fields System.Tags=...` path APPENDS (it issues a json-patch "add",
      # which ADO merges for tags) — so it can never REMOVE a tag. The only
      # reliable way to set the exact tag set is a json-patch "replace" via the
      # REST API. `az devops invoke` mishandles json-patch bodies, so use
      # `az rest`, which needs an absolute org URL (az devops defaults don't
      # apply to it).
      local n="$1"; shift
      _parse_label_args "$@"
      local base_org="$AZURE_ORG"
      if [ -z "$base_org" ]; then
        base_org="$(az devops configure --list 2>/dev/null \
          | awk -F'= *' '/^organization/{print $2}' | tr -d '[:space:]')"
      fi
      if [ -z "$base_org" ]; then
        echo "pipeline-vcs: azure label-issue needs an org URL — set vcs.azure.org_url or run 'az devops configure --defaults organization=<url>'" >&2
        exit 1
      fi
      # Fetch current tags
      local current_tags
      current_tags="$(az boards work-item show --id "$n" $ORG_ARG \
        --query fields.\"System.Tags\" -o tsv 2>/dev/null || echo "")"
      python3 -I - "$n" "$current_tags" "$ADD_LABELS" "$REMOVE_LABELS" \
        "$DRY_RUN" "$base_org" <<'PYEOF'
import json, os, subprocess, sys, tempfile
n, cur, add_s, rem_s = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
dry_run = sys.argv[5] == 'true'
base_org = sys.argv[6].rstrip('/')
tags = {t.strip() for t in cur.split(';') if t.strip()}
for t in add_s.split(): tags.add(t)
for t in rem_s.split(): tags.discard(t)
new_tags = '; '.join(sorted(tags))
url = f'{base_org}/_apis/wit/workitems/{n}?api-version=7.1'
ADO_RESOURCE = '499b84ac-1321-427f-aa17-267ca6975798'  # Azure DevOps AAD app id
# "replace" needs the field to exist; use "add" when the item has no tags yet.
op = 'replace' if cur.strip() else 'add'
patch = [{'op': op, 'path': '/fields/System.Tags', 'value': new_tags}]
if dry_run:
    print(f'[dry-run] az rest --method patch --url {url} --body {json.dumps(patch)}')
    sys.exit(0)
with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
    json.dump(patch, f)
    body_path = f.name
try:
    subprocess.run(['az', 'rest', '--method', 'patch', '--url', url,
                    '--resource', ADO_RESOURCE,
                    '--headers', 'Content-Type=application/json-patch+json',
                    '--body', f'@{body_path}'], check=True)
finally:
    os.unlink(body_path)
PYEOF
      ;;
    create-issue)
      # Signature mirrors github: create-issue <title> <body-file> [--label L]...
      # Labels map to ADO Tags. Work-item type + area path come from config so new
      # items land on the right board (vcs.azure.work_item_type / vcs.azure.area_path).
      local title="$1" body_file="$2"; shift 2
      local ci_tags=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --label) [ $# -ge 2 ] || _vcs_flag_needs_value --label "create-issue <title> <body-file> [--label <label>]..."; ci_tags="${ci_tags:+$ci_tags; }$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      local wtype ci_area ci_desc
      wtype="$(cfg vcs.azure.work_item_type)"
      ci_area="$(cfg vcs.azure.area_path)"
      ci_desc=""; [ -f "$body_file" ] && ci_desc="$(cat "$body_file")"
      # ADO's Description is an HTML field — convert the markdown body so it
      # renders instead of showing raw '#'/'**'/'- [ ]' text.
      [ -n "$ci_desc" ] && ci_desc="$(_md_to_html "$ci_desc")"
      local ci_args=(boards work-item create --title "$title" --type "$wtype")
      [ -n "$AZURE_ORG" ]     && ci_args+=(--org "$AZURE_ORG")
      [ -n "$AZURE_PROJECT" ] && ci_args+=(--project "$AZURE_PROJECT")
      [ -n "$ci_area" ]       && ci_args+=(--area "$ci_area")
      [ -n "$ci_desc" ]       && ci_args+=(--description "$ci_desc")
      [ -n "$ci_tags" ]       && ci_args+=(--fields "System.Tags=$ci_tags")
      ci_args+=(--output json)
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az ${ci_args[*]}"
        return 0
      fi
      local _ci_out
      _ci_out="$(az "${ci_args[@]}")" || return
      [ -n "$_ci_out" ] && printf '%s\n' "$_ci_out"
      # Assign the new work item (#299) -- stdout stays az's JSON alone.
      _vcs_shared_assign_issue "$(printf '%s' "$_ci_out" \
          | python3 -I -c "import json, sys; print(json.load(sys.stdin).get('id', ''))" 2>/dev/null)" \
        _az_assignee_get _az_assignee_set az account show --query user.name --output tsv >&2
      ;;
    create-pr)
      local branch="$1" title="$2" body_file="$3"
      [ -z "$BASE_BRANCH" ] && BASE_BRANCH="main"
      # `az repos pr create` requires --repository. REPO comes from vcs.repo
      # (or git-remote auto-detect); pass it only when set so az emits its own
      # clear error rather than us fabricating a repo name.
      local repo_arg=""; [ -n "$REPO" ] && repo_arg="--repository $REPO"
      # #298: link the work item named by the issue-<N> branch convention and
      # transition it on completion. ADO ignores `Closes #N` on a squash
      # merge, so this link is the native close path when a human merges.
      local wi_args=""
      [[ "$branch" =~ (^|/)issue-([0-9]+)(-|$) ]] \
        && wi_args="--work-items ${BASH_REMATCH[2]} --transition-work-items true"
      local draft_args=""; [ "$_PR_DRAFT" = "true" ] && draft_args="--draft true"
      _run az repos pr create \
        --source-branch "$branch" --target-branch "$BASE_BRANCH" \
        --title "$title" --description "$(cat "$body_file")" \
        $wi_args $ORG_ARG $PROJ_ARG $repo_arg --output json $draft_args
      ;;
    ready-pr|draft-pr)
      # (#332) `az repos pr update --draft false|true`.
      local _rd_n="${1:-}" _rd_state="false"
      _vcs_require_pr_id "$VERB" "$_rd_n"
      [ "$VERB" = "draft-pr" ] && _rd_state="true"
      _run az repos pr update --id "$_rd_n" --draft "$_rd_state" $ORG_ARG --output json
      ;;
    pr-is-draft)
      # (#332) `az repos pr show` carries a boolean `isDraft`. Fail closed.
      _azure_fetch_draft() {
        az repos pr show --id "$1" $ORG_ARG --output json
      }
      _vcs_shared_pr_is_draft "${1:-}" isDraft \
        "az repos pr show --id ${1:-} $ORG_ARG --output json" _azure_fetch_draft
      ;;
    pr-ci-runs)
      _vcs_draft_unsupported pr-ci-runs azure
      ;;
    view-pr)
      _run az repos pr show --id "$1" $ORG_ARG --output json
      ;;
    list-prs)
      # PAGINATION (#171): `az repos pr list --top` exists (unlike `az boards
      # query`), so use it and warn loudly if a result lands exactly on it.
      local _azlp_cap=1000
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az repos pr list --status active --top $_azlp_cap $ORG_ARG $PROJ_ARG --output json"
        return 0
      fi
      local _azlp_out
      _azlp_out="$(az repos pr list --status active --top "$_azlp_cap" $ORG_ARG $PROJ_ARG --output json)" || exit 1
      local _azlp_count
      _azlp_count="$(printf '%s' "$_azlp_out" | _json_array_count)"
      _list_cap_warn list-prs "$_azlp_cap" "$_azlp_count" "az repos pr list --top ceiling" PRs
      printf '%s\n' "$_azlp_out"
      ;;
    diff-pr)
      # az has no PR-diff command. Fetch both refs and diff them — this reads the
      # change without touching the working tree, so reviewer/security stay safe.
      local n="$1" src tgt
      src="$(az repos pr show --id "$n" $ORG_ARG --query sourceRefName -o tsv 2>/dev/null | sed 's|refs/heads/||')"
      tgt="$(az repos pr show --id "$n" $ORG_ARG --query targetRefName -o tsv 2>/dev/null | sed 's|refs/heads/||')"
      [ -z "$tgt" ] && tgt="${BASE_BRANCH:-main}"
      if [ -z "$src" ]; then echo "pipeline-vcs: could not resolve PR #$n source branch" >&2; return 1; fi
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] git fetch origin $tgt $src && git diff origin/$tgt...origin/$src"; return 0
      fi
      git fetch -q origin "$tgt" "$src" 2>/dev/null
      git diff "origin/$tgt...origin/$src"
      ;;
    checkout-pr)
      # Detached checkout of the fetched head — a named `git checkout <branch>`
      # fails with "already checked out" while the developer worktree still holds
      # the branch. Detaching sidesteps that and lets QA run in its own worktree.
      local n="$1" src
      src="$(az repos pr show --id "$n" $ORG_ARG --query sourceRefName -o tsv 2>/dev/null | sed 's|refs/heads/||')"
      if [ -z "$src" ]; then echo "pipeline-vcs: could not resolve PR #$n source branch" >&2; return 1; fi
      _run git fetch origin "$src"
      _run git checkout --detach FETCH_HEAD
      ;;
    approve-pr)
      local n="$1" body="${2:-}"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az repos pr set-vote --id $n --vote approve $ORG_ARG"
        [ -n "$body" ] && echo "[dry-run] (comment via PR thread REST)"
      else
        # set-vote may fail with "cannot approve your own pull request" in
        # single-account setups — expected and ignorable; the review:approved
        # label is the gate. Post the body as a PR thread (az has no comment cmd).
        az repos pr set-vote --id "$n" --vote approve $ORG_ARG 2>/dev/null || true
        if [ -n "$body" ]; then
          local gitbase; if gitbase="$(_azure_git_base)"; then
            local tf; tf="$(mktemp)"
            python3 -I -c 'import json,sys;open(sys.argv[1],"w").write(json.dumps({"comments":[{"parentCommentId":0,"content":sys.argv[2],"commentType":1}],"status":1}))' "$tf" "$body"
            az rest --method post --url "$gitbase/pullRequests/$n/threads?api-version=7.1-preview.1" \
              --resource "$ADO_RESOURCE" --headers "Content-Type=application/json" --body "@$tf" >/dev/null 2>&1 || true
            rm -f "$tf"
          fi
        fi
      fi
      ;;
    label-pr)
      # ADO PRs DO support labels via the REST API (az has no command for it).
      local n="$1"; shift
      _parse_label_args "$@"
      local gitbase; gitbase="$(_azure_git_base)" || { echo "pipeline-vcs: azure label-pr needs org/project/repo (vcs.azure.org_url, vcs.azure.project, vcs.repo)" >&2; return 0; }
      local l tf
      for l in $ADD_LABELS; do
        if [ "$DRY_RUN" = "true" ]; then echo "[dry-run] az rest POST $gitbase/pullRequests/$n/labels {\"name\":\"$l\"}"; continue; fi
        tf="$(mktemp)"; python3 -I -c 'import json,sys;open(sys.argv[1],"w").write(json.dumps({"name":sys.argv[2]}))' "$tf" "$l"
        az rest --method post --url "$gitbase/pullRequests/$n/labels?api-version=7.1-preview.1" \
          --resource "$ADO_RESOURCE" --headers "Content-Type=application/json" --body "@$tf" >/dev/null 2>&1 \
          || echo "pipeline-vcs: label-pr add '$l' failed on PR #$n" >&2
        rm -f "$tf"
      done
      # ADO rejects ':' in a URL path, and every Talos label has one, so DELETE
      # by label id (not name). Resolve names→ids from one GET.
      if [ -n "$REMOVE_LABELS" ]; then
        if [ "$DRY_RUN" = "true" ]; then
          for l in $REMOVE_LABELS; do echo "[dry-run] az rest DELETE (resolve id for '$l') $gitbase/pullRequests/$n/labels/<id>"; done
        else
          local labels_json; labels_json="$(az rest --method get \
            --url "$gitbase/pullRequests/$n/labels?api-version=7.1-preview.1" \
            --resource "$ADO_RESOURCE" 2>/dev/null)"
          for l in $REMOVE_LABELS; do
            local lid; lid="$(printf '%s' "$labels_json" | python3 -I -c "import sys,json;d=json.load(sys.stdin);print(next((x['id'] for x in d.get('value',[]) if x.get('name')==sys.argv[1]),''))" "$l" 2>/dev/null)"
            [ -z "$lid" ] && continue
            az rest --method delete --url "$gitbase/pullRequests/$n/labels/$lid?api-version=7.1-preview.1" \
              --resource "$ADO_RESOURCE" >/dev/null 2>&1 || true
          done
        fi
      fi
      ;;
    pr-checks)
      _run az repos pr show --id "$1" $ORG_ARG \
        --query "{status:status,mergeStatus:mergeStatus}" --output json
      ;;
    merge-pr)
      _run az repos pr update --id "$1" --status completed $ORG_ARG --output json
      ;;
    update-branch)
      # update-branch <n> (#289) — not supported for azure: ADO has no
      # single server-side "update branch with base" PR endpoint talos can
      # call idempotently here. Exit 2; the caller skips silently and falls
      # back to the developer merge-base dispatch.
      echo "pipeline-vcs: update-branch: not implemented for azure" >&2
      exit 2
      ;;
    comment-pr)
      # az has no PR-comment command; post a thread via REST.
      local n="$1" body="$2"
      local gitbase; gitbase="$(_azure_git_base)" || { echo "pipeline-vcs: azure comment-pr needs org/project/repo" >&2; return 0; }
      local url="$gitbase/pullRequests/$n/threads?api-version=7.1-preview.1"
      if [ "$DRY_RUN" = "true" ]; then echo "[dry-run] az rest POST $url {\"comments\":[{\"content\":<body>}]}"; return 0; fi
      local tf; tf="$(mktemp)"
      python3 -I -c 'import json,sys;open(sys.argv[1],"w").write(json.dumps({"comments":[{"parentCommentId":0,"content":sys.argv[2],"commentType":1}],"status":1}))' "$tf" "$body"
      az rest --method post --url "$url" --resource "$ADO_RESOURCE" \
        --headers "Content-Type=application/json" --body "@$tf" >/dev/null
      local rc=$?; rm -f "$tf"; return $rc
      ;;
    pr-mergeable)
      # pr-mergeable <n> (#214) — best-effort: `az repos pr show --query
      # mergeStatus` returns ADO's own status ("succeeded", "conflicts",
      # "queued", "rejectedByPolicy", "failure", "notSet"). Only the two
      # conclusive values are trusted; anything else (including a fetch
      # failure) is reported as UNKNOWN with a stderr note, same contract as
      # the GitHub providers but without their lazy-computation retry loop.
      local n="$1"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az repos pr show --id $n $ORG_ARG --query mergeStatus --output tsv"
        return 0
      fi
      local _pm_status
      _pm_status="$(az repos pr show --id "$n" $ORG_ARG --query mergeStatus --output tsv 2>/dev/null)"
      case "$_pm_status" in
        succeeded)  echo MERGEABLE;   exit 0 ;;
        conflicts)  echo CONFLICTING; exit 1 ;;
        *)
          echo "pipeline-vcs: pr-mergeable: azure mergeStatus '$_pm_status' not conclusive — reporting UNKNOWN" >&2
          echo UNKNOWN
          exit 2
          ;;
      esac
      ;;
    find-pr)
      # find-pr <work-item-id> [open|merged|closed|all] (#298). ADO links PRs
      # to work items natively (create-pr passes --work-items), so the
      # authoritative answer is the work item's own ArtifactLink relations:
      # one `work-item show --expand relations`, then one `pr show` per
      # linked PR. When no linked PR is in the requested state, fall back to
      # the shared branch-convention / closing-keyword matcher over
      # `repos pr list` -- that catches PRs created before linking existed.
      local n="$1" state="${2:-open}"
      local az_status
      case "$state" in
        merged) az_status="completed" ;;
        closed) az_status="abandoned" ;;
        all)    az_status="all" ;;
        *)      az_status="active" ;;
      esac
      local repo_arg=""; [ -n "$REPO" ] && repo_arg="--repository $REPO"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az boards work-item show --id $n --expand relations $ORG_ARG | az repos pr show --id <linked>; else az repos pr list --status $az_status | filter issue-$n"
        return 0
      fi
      # Normalise an ADO PR object to the shared {number,state,title,
      # headRefName,body} shape; state is OPEN/MERGED/CLOSED like github-api.
      local _azfp_norm='
import json, sys
def norm(p):
    st = {"active": "OPEN", "completed": "MERGED"}.get(p.get("status", ""), "CLOSED")
    return {"number": p.get("pullRequestId"), "state": st,
            "title": p.get("title", ""),
            "headRefName": (p.get("sourceRefName") or "").replace("refs/heads/", "", 1),
            "body": p.get("description") or ""}
'
      local _azfp_wi _azfp_ids _azfp_id _azfp_pr _azfp_linked=""
      _azfp_wi="$(az boards work-item show --id "$n" --expand relations $ORG_ARG --output json 2>/dev/null)" || {
        echo "pipeline-vcs: find-pr: could not read work item #$n relations" >&2; exit 1; }
      _azfp_ids="$(printf '%s' "$_azfp_wi" | _az_linked_pr_ids)"
      for _azfp_id in $_azfp_ids; do
        _azfp_pr="$(az repos pr show --id "$_azfp_id" $ORG_ARG --output json 2>/dev/null)" || continue
        [ -n "$_azfp_pr" ] && _azfp_linked="${_azfp_linked:+$_azfp_linked,}$_azfp_pr"
      done
      _azfp_linked="$(printf '[%s]' "$_azfp_linked" | STATE="$state" python3 -I -c "$_azfp_norm"'
import os
want = {"open": "OPEN", "merged": "MERGED", "closed": "CLOSED"}.get(os.environ["STATE"])
try: prs = json.load(sys.stdin)
except Exception: prs = []
for p in map(norm, prs):
    if want is None or p["state"] == want:
        print(json.dumps({k: p[k] for k in ("number", "state", "title", "headRefName")}))
')"
      if [ -n "$_azfp_linked" ]; then
        printf '%s\n' "$_azfp_linked"
        return 0
      fi
      local _azfp_list
      _azfp_list="$(az repos pr list --status "$az_status" --top 1000 $ORG_ARG $PROJ_ARG $repo_arg --output json)" || {
        echo "pipeline-vcs: find-pr: az repos pr list failed" >&2; exit 1; }
      _list_cap_warn find-pr 1000 "$(printf '%s' "$_azfp_list" | _json_array_count)" "az repos pr list --top ceiling" PRs
      printf '%s' "$_azfp_list" | python3 -I -c "$_azfp_norm"'
try: prs = json.load(sys.stdin)
except Exception: prs = []
json.dump([norm(p) for p in prs], sys.stdout)
' | _vcs_shared_find_pr "$n" "$state"
      ;;
    pr-files)
      # pr-files <id> (#304) -- same contract as github: one changed path
      # per line; a failed fetch exits 1 with no stdout.
      local n="${1:-}"
      _az_require_id pr-files "$n" || exit 1
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az rest GET .../pullRequests/$n/iterations, then .../iterations/<last>/changes (every page)"
        return 0
      fi
      _az_pr_files "$n" || { echo "pipeline-vcs: pr-files: could not fetch the changed files of PR #$n" >&2; exit 1; }
      ;;
    check-pr-files)
      # Forbidden-files merge gate (#304): pr-files output through the same
      # shared matcher github uses. Fails closed on any fetch failure.
      local n="${1:-}"
      _az_require_id check-pr-files "$n" || exit 1
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] pr-files $n | match against forbidden patterns"
        return 0
      fi
      local _azcpf_paths
      _azcpf_paths="$(_az_pr_files "$n")" || {
        echo "pipeline-vcs: check-pr-files: could not fetch the changed files of PR #$n -- failing closed, do not merge" >&2
        exit 1; }
      printf '%s\n' "$_azcpf_paths" | CONFIGURED="$(cfg merge.forbidden_files)" REPLACE="$(cfg merge.forbidden_files_replace)" ALLOW="$(cfg merge.forbidden_files_allow)" _vcs_shared_check_pr_files
      ;;
    check-closing-keyword)
      # check-closing-keyword <pr-id> <work-item-id> (#304). ADO closes a
      # work item through the PR's work-item link plus transitionWorkItems
      # (#298), not a keyword, so this gate is link-based: exit 1 when this
      # PR is linked to work item N and another ACTIVE PR is linked to N too
      # or sits on an issue-N branch. A fetch failure fails open with the
      # talos:closing-keyword-unverified marker (fixed-literal reason), as on
      # github.
      local pr_ref="${1:-}" issue_n="${2:-}"
      _az_require_id check-closing-keyword "$pr_ref" || exit 1
      _az_require_id check-closing-keyword "$issue_n" || exit 1
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] check-closing-keyword $pr_ref $issue_n: az repos pr work-item list, then work item $issue_n's linked PRs and az repos pr list --status active"
        return 0
      fi
      local _azck_linked
      _azck_linked="$(az repos pr work-item list --id "$pr_ref" $ORG_ARG --output json 2>/dev/null | python3 -I -c '
import json, sys
print("yes" if sys.argv[1] in {str(w["id"]) for w in json.load(sys.stdin)} else "no")
' "$issue_n" 2>/dev/null)"
      case "$_azck_linked" in
        no) return 0 ;;
        yes) ;;
        *)
          echo "pipeline-vcs: check-closing-keyword: could not read the work items linked to PR #$pr_ref — skipping check" >&2
          echo "talos:closing-keyword-unverified pr=$pr_ref issue=$issue_n reason=pr-fetch-failed"
          return 0
          ;;
      esac
      local _azck_siblings _azck_rc=0
      _azck_siblings="$(_az_closing_siblings "$pr_ref" "$issue_n")" || _azck_rc=$?
      if [ "$_azck_rc" -ne 0 ] && [ "$_azck_rc" -ne "$_VCS_SIBLINGS_CAPPED" ]; then
        echo "pipeline-vcs: check-closing-keyword: could not fetch the active PRs for work item #$issue_n — skipping sibling check" >&2
        echo "talos:closing-keyword-unverified pr=$pr_ref issue=$issue_n reason=sibling-fetch-failed"
        return 0
      fi
      if [ -z "$_azck_siblings" ]; then
        [ "$_azck_rc" -eq 0 ] || _vcs_shared_siblings_capped "$pr_ref" "$issue_n"
        return 0
      fi
      _vcs_shared_sibling_blocked "$pr_ref" "${_azck_siblings// / #}" \
        "is linked to work item #$issue_n, so completing it closes the item," "unlink work item #$issue_n from this PR"
      exit 1
      ;;
    check-epic-acceptance)
      # check-epic-acceptance <id> (#304): the work item's System.Description
      # (HTML) as text through the shared unticked-box scan. A failed fetch,
      # a response that is not a work item, or a description longer than the
      # scan cap exits 1 so the epic sweep never closes the epic.
      local n="${1:-}"
      _az_require_id check-epic-acceptance "$n" || exit 1
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az boards work-item show --id $n $ORG_ARG | System.Description | scan for unticked checkboxes"
        return 0
      fi
      local _azcea_json _azcea_text _azcea_rc=0
      _azcea_json="$(az boards work-item show --id "$n" $ORG_ARG --output json)" || {
        echo "pipeline-vcs: check-epic-acceptance: could not fetch work item #$n -- not closing" >&2
        exit 1; }
      _azcea_text="$(printf '%s' "$_azcea_json" | _ado_description_text 2>/dev/null)" || _azcea_rc=$?
      case "$_azcea_rc" in
        0) ;;
        3)
          # Not scanned at all: one pending item on stdout, so the epic
          # sweep's pending comment never lists nothing.
          echo "pipeline-vcs: check-epic-acceptance: the description of work item #$n is longer than $_VCS_AZURE_SCAN_CAP characters -- not scanned, not closing" >&2
          echo "(description exceeds $_VCS_AZURE_SCAN_CAP characters; not scanned — review manually)"
          exit 1
          ;;
        *) echo "pipeline-vcs: check-epic-acceptance: could not read the description of work item #$n -- not closing" >&2; exit 1 ;;
      esac
      printf '%s' "$_azcea_text" | _epic_acceptance_scan
      ;;
    rerun-ci)
      # rerun-ci <id> (#304): re-queue every failed build-validation policy
      # evaluation -- `az repos pr policy list --id <id>`, then `az repos pr
      # policy queue --id <id> --evaluation-id <eval>` for each Build-type
      # record (policy type 0609b952-1397-4640-95ec-e00a01b2c241) whose
      # status is rejected or broken. A PR with no build policy has no CI to
      # re-queue: exit 2, wait for a human. Any failure exits 1.
      local n="${1:-}"
      _az_require_id rerun-ci "$n" || exit 1
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az repos pr policy queue --id $n --evaluation-id <each failed build policy of PR #$n> $ORG_ARG"
        return 0
      fi
      local _azrc_json _azrc_ids _azrc_id _azrc_count=0
      _azrc_json="$(_az_pr_policies "$n")" || exit 1
      _azrc_ids="$(printf '%s' "$_azrc_json" | python3 -I -c '
import json, re, sys
BUILD = "0609b952-1397-4640-95ec-e00a01b2c241"
builds = [r for r in json.load(sys.stdin)
          if ((r.get("configuration") or {}).get("type") or {}).get("id") == BUILD]
if not builds:
    print("none")
for r in builds:
    if r.get("status") in ("rejected", "broken"):
        if not re.fullmatch(r"[0-9a-fA-F-]{36}", r.get("evaluationId") or ""):
            sys.exit(1)
        print(r["evaluationId"])
' 2>/dev/null)" || { echo "pipeline-vcs: rerun-ci: could not parse the policies of PR #$n" >&2; exit 1; }
      if [ "$_azrc_ids" = "none" ]; then
        echo "pipeline-vcs: rerun-ci: PR #$n has no build-validation policy to re-queue -- not supported, wait for a human" >&2
        exit 2
      fi
      for _azrc_id in $_azrc_ids; do
        az repos pr policy queue --id "$n" --evaluation-id "$_azrc_id" $ORG_ARG --output none || {
          echo "pipeline-vcs: rerun-ci: re-queue of policy evaluation $_azrc_id failed" >&2; exit 1; }
        _azrc_count=$((_azrc_count + 1))
      done
      if [ "$_azrc_count" -eq 0 ]; then
        echo "rerun-ci: no failed build policies found for PR #$n"
      else
        echo "rerun-ci: re-queued $_azrc_count failed build policy evaluation(s) for PR #$n"
      fi
      ;;
    pr-checks-required)
      # pr-checks-required <id> (#318): each merge.required_checks name maps,
      # case-insensitively, to the PR's policy evaluations whose display name
      # (configuration.settings.displayName, else configuration.type.
      # displayName) matches it; several matches take the worst status.
      # PolicyEvaluationStatus: approved and notApplicable ("the policy does
      # not apply to this pull request", so it does not block completion)
      # pass, rejected and broken fail, queued and running are pending, and
      # anything else fails. The records come from _az_pr_evaluations, with
      # includeNotApplicable=true, so a policy whose path filter excludes the
      # PR has a notApplicable record instead of none (#328); a name with no
      # record is still missing (exit 2), never passed. An approved record
      # whose context says it is out of date is pending (#328): the REST
      # reference gives context no schema ("Internal context data"), so
      # context.isExpired true, or a context.lastMergeSourceCommitId other
      # than the PR's lastMergeSourceCommit, is read when present. The exit
      # contract and summary lines are github's, via _eval_required_checks.
      # Any fetch or parse failure exits 1.
      local n="${1:-}" _required _azpc_json _azpc_norm
      _az_require_id pr-checks-required "$n" || exit 1
      _required="$(cfg merge.required_checks)"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] az rest --method get --url <org>/<projectId>/_apis/policy/evaluations?artifactId=vstfs:///CodeReview/CodeReviewId/<projectId>/$n&includeNotApplicable=true; evaluate against merge.required_checks"
        return 0
      fi
      # Empty config never passes vacuously and needs no CI data to say so.
      [ -z "$_required" ] && { printf '' | _eval_required_checks "$_required"; return; }
      _azpc_json="$(_az_pr_evaluations "$n")" || exit 1
      _azpc_norm="$(printf '%s' "$_azpc_json" | python3 -I -c '
import json, sys
STATUS = {"approved": "pass", "notapplicable": "pass", "rejected": "fail",
          "broken": "fail", "queued": "pending", "running": "pending"}
RANK = {"pass": 0, "pending": 1, "fail": 2}
def out_of_date(r, source):
    ctx = r.get("context")
    if not isinstance(ctx, dict):
        return False
    if str(ctx.get("isExpired")).lower() == "true":
        return True
    seen = ctx.get("lastMergeSourceCommitId")
    return seen is not None and str(seen).lower() != source.lower()
d = json.load(sys.stdin)
worst = {}
for r in d["records"]:
    conf = r.get("configuration") or {}
    name = (conf.get("settings") or {}).get("displayName") \
        or (conf.get("type") or {}).get("displayName")
    if not isinstance(name, str):
        continue
    key = name.strip().casefold()
    raw = str(r.get("status")).lower()
    status = STATUS.get(raw, "fail")
    if raw == "approved" and out_of_date(r, d["source"]):
        status = "pending"
    if RANK[status] >= RANK[worst.get(key, "pass")]:
        worst[key] = status
for req in sys.argv[1].splitlines():
    req = req.strip()
    if req and req.casefold() in worst:
        print(req + "\t" + worst[req.casefold()])
' "$_required" 2>/dev/null)" || {
        echo "pipeline-vcs: pr-checks-required: could not parse the policies of PR #$n" >&2; exit 1; }
      printf '%s\n' "$_azpc_norm" | _eval_required_checks "$_required"
      ;;
    *) echo "pipeline-vcs: unknown verb: $verb" >&2; exit 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# FILE MODE ADAPTER
#   Work items are markdown checklist items in a local file.
#   Format:  - [ ] Title text <!-- id: N -->
#            (indented lines are the detail block)
#   IDs are auto-assigned on first list-issues call.
# ─────────────────────────────────────────────────────────────────────────────
_file() {
  local verb="$1"; shift

  # Resolve the plan file path relative to the caller's working directory
  case "$FILE_PATH" in
    /*) : ;;                                       # already absolute
    *)  FILE_PATH="$(pwd)/$FILE_PATH" ;;
  esac

  # Delegate all file operations to an inline Python script
  DRY_RUN_FLAG=""
  [ "$DRY_RUN" = "true" ] && DRY_RUN_FLAG="--dry-run"

  case "$verb" in
    create-pr)
      echo "file mode: no PR created — developer should commit to branch and record it via comment-issue" >&2
      return 0
      ;;
    merge-pr)
      echo "file mode: no PR to merge — orchestrator should close-issue directly after verifying the branch" >&2
      return 0
      ;;
    ready-pr|draft-pr|pr-is-draft|pr-ci-runs)
      # (#332) No PR concept in file mode: exit 2 (unverified), nothing on stdout.
      _vcs_draft_unsupported "$verb" file
      ;;
    update-branch)
      # update-branch (#289) — no PR concept in file mode. Exit 2; caller skips.
      echo "file mode: update-branch not applicable in file mode" >&2
      exit 2
      ;;
    current-user)
      # No identity in file mode: nothing printed, exit 1 (not resolved).
      exit 1
      ;;
    issue-assignees|unassign-issue|list-assignees)
      # No assignees in file mode (#560): exit 2, nothing on stdout.
      echo "file mode: $verb not applicable in file mode" >&2
      exit 2
      ;;
    diff-pr|pr-checks|list-prs|view-pr|find-pr|check-pr-files|pr-files|rerun-ci|check-closing-keyword|check-epic-acceptance)
      echo "file mode: $verb not applicable in file mode" >&2
      return 0
      ;;
    pr-checks-required)
      # Fail closed, not open (#205) -- see the matching comment in _gitlab.
      echo "pipeline-vcs: pr-checks-required: not supported for provider file (fail closed)" >&2
      return 1
      ;;
    pr-mergeable)
      # No PR concept in file mode; report UNKNOWN (exit 2) rather than a
      # bare 0 so callers that switch on this verb's stdout never mistake
      # "not applicable" for MERGEABLE.
      echo "file mode: pr-mergeable not applicable in file mode" >&2
      echo UNKNOWN
      exit 2
      ;;
    checkout-pr)
      echo "file mode: checkout-pr not applicable — use 'git checkout <branch>'" >&2
      return 0
      ;;
    approve-pr)
      echo "file mode: approve-pr not applicable — no PR review in file mode" >&2
      return 0
      ;;
    label-issue|label-pr)
      # Labels are not tracked in file mode — pipeline state is the checkbox
      echo "file mode: label tracking not applicable (pipeline state = checkbox)" >&2
      return 0
      ;;
    create-issue)
      local ci_title="$1"
      # --label args are ignored in file mode (state = checkbox)
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] file: would append '- [ ] ${ci_title}' to ${FILE_PATH}"
        return 0
      fi
      touch "$FILE_PATH"
      FILE_PATH="$FILE_PATH" python3 -I - "$ci_title" <<'PYEOF'
import sys, re, os

title = sys.argv[1]
plan_path = os.environ['FILE_PATH']

try:
    with open(plan_path) as f:
        content = f.read()
except FileNotFoundError:
    content = ''

ids = [int(m.group(1)) for m in re.finditer(r'<!-- id: (\d+) -->', content)]
new_id = (max(ids) if ids else 0) + 1

line = f'\n- [ ] {title} <!-- id: {new_id} -->\n'
with open(plan_path, 'a') as f:
    f.write(line)

print(new_id)
PYEOF
      ;;
    *)
      # Delegate to Python for all file-mutation verbs
      FILE_PATH="$FILE_PATH" python3 -I - "$verb" $DRY_RUN_FLAG "$@" <<'PYEOF'
import sys, re, os, json, shutil, tempfile

verb = sys.argv[1]
dry_run = '--dry-run' in sys.argv
args = [a for a in sys.argv[2:] if a != '--dry-run']

plan_path = os.environ['FILE_PATH']

# ── Helpers ──────────────────────────────────────────────────────────────────

_ITEM_RE = re.compile(
    r'^(?P<indent>\s*)- \[(?P<check>[ x])\] (?P<title>[^<\n]+?)(?:\s*<!-- id: (?P<id>\d+) -->)?\s*$'
)

def load_file():
    try:
        with open(plan_path) as f:
            return f.read()
    except FileNotFoundError:
        print(f"pipeline-vcs: file not found: {plan_path}", file=sys.stderr)
        sys.exit(1)

def save_file(content):
    if dry_run:
        print(f"[dry-run] would write {plan_path}:")
        for i, line in enumerate(content.splitlines()[:10], 1):
            print(f"  {i}: {line}")
    else:
        # Encode BEFORE anything is opened (#453): an argv byte that is not valid
        # UTF-8 is a surrogate here, and writing it after open(..., 'w') used to
        # leave the plan at 0 bytes. Then write a temp file beside the plan and
        # replace it, so a failed write cannot leave a half-written plan either.
        try:
            data = content.encode('utf-8')
        except UnicodeEncodeError:
            print(f"pipeline-vcs: {verb}: the text is not valid UTF-8; {plan_path} left unchanged", file=sys.stderr)
            sys.exit(1)
        real_path = os.path.realpath(plan_path)
        tmp_path = None
        try:
            # mkstemp: an unpredictable name, created O_EXCL with mode 0600.
            fd, tmp_path = tempfile.mkstemp(prefix='.plan-', suffix='.tmp', dir=os.path.dirname(real_path))
            with os.fdopen(fd, 'wb') as f:
                f.write(data)
            shutil.copymode(real_path, tmp_path)
            os.replace(tmp_path, real_path)
        except OSError as exc:
            if tmp_path:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
            print(f"pipeline-vcs: {verb}: could not write {plan_path}: {exc}", file=sys.stderr)
            sys.exit(1)

def parse_items(content):
    """Return list of dicts: {id, title, checked, line_idx, detail_lines: [(idx, text)]}"""
    lines = content.split('\n')
    items = []
    i = 0
    while i < len(lines):
        m = _ITEM_RE.match(lines[i])
        if m:
            item_indent = m.group('indent')
            item = {
                'id':       m.group('id'),
                'title':    m.group('title').strip(),
                'checked':  m.group('check') == 'x',
                'line_idx': i,
                'detail_lines': [],
            }
            j = i + 1
            while j < len(lines):
                detail = lines[j]
                # Detail block: indented more than the item, or blank line with more content after
                if detail == '' or (detail.startswith(item_indent + '  ') and not _ITEM_RE.match(detail)):
                    item['detail_lines'].append((j, detail))
                    j += 1
                else:
                    break
            items.append(item)
            i = j
        else:
            i += 1
    return items

# A comment/resolution body is free text from an agent. A body line shaped like
# a checklist item would parse as a plan item -- adding one (`- [ ]`) or making
# a finished one (`- [x]`) -- so its `[` is escaped (`- \[ ] x`, which markdown
# still renders as a box) before it is written (#449).
_BODY_BOX_RE = re.compile(r'^(\s*[-*+]\s+)\[([ xX])\]')

def detail_lines_for(indent, text):
    """Indent every line of a free-text body into an item's detail block."""
    # The plan file is read back with universal newlines, so a lone \r (or \r\n)
    # in the body becomes a line break there: split on every one of them.
    text = text.replace('\r\n', '\n').replace('\r', '\n')
    return [indent + _BODY_BOX_RE.sub(r'\1\\[\2]', ln) for ln in text.split('\n')]

def ensure_ids(content):
    """Assign <!-- id: N --> to any item that lacks one. Returns updated content."""
    lines = content.split('\n')
    items = parse_items(content)
    # Find highest existing id
    max_id = max((int(it['id']) for it in items if it['id']), default=0)
    changed = False
    for item in items:
        if not item['id']:
            max_id += 1
            # Insert id comment into the line
            lines[item['line_idx']] = lines[item['line_idx']].rstrip() + f' <!-- id: {max_id} -->'
            changed = True
    return '\n'.join(lines) if changed else content, changed

def find_item(items, id_str):
    for it in items:
        if it['id'] == id_str:
            return it
    print(f"pipeline-vcs: no item with id {id_str} in {plan_path}", file=sys.stderr)
    sys.exit(1)

# ── Verb dispatch ─────────────────────────────────────────────────────────────

if verb == 'list-issues':
    content = load_file()
    content, changed = ensure_ids(content)
    if changed:
        save_file(content)
    items = parse_items(content)
    open_items = [it for it in items if not it['checked']]
    # Output as JSON array
    print(json.dumps([{'id': it['id'], 'title': it['title']} for it in open_items], indent=2))

elif verb == 'view-issue':
    n = args[0]
    for flag in ('--spec', '--since-stage'):
        if flag in args:
            # --spec (#201) and --since-stage (#548) are GitHub-only compact
            # forms; fall back to the plain full view rather than silently
            # ignoring the flag.
            print("pipeline-vcs: view-issue %s: not implemented for provider 'file' -- falling back to full view-issue" % flag, file=sys.stderr)
    content = load_file()
    content, changed = ensure_ids(content)
    if changed:
        save_file(content)
    items = parse_items(content)
    item = find_item(items, n)
    lines = content.split('\n')
    print(f"id: {item['id']}")
    print(f"title: {item['title']}")
    print(f"status: {'closed' if item['checked'] else 'open'}")
    if item['detail_lines']:
        print("detail:")
        for _, dl in item['detail_lines']:
            print(f"  {dl}")

elif verb == 'comment-issue':
    n, body = args[0], '\n'.join(args[1:]) if len(args) > 1 else (args[1] if len(args) > 1 else '')
    # Handle body as single arg or joined args
    body = args[1] if len(args) >= 2 else ''
    content = load_file()
    content, _ = ensure_ids(content)
    items = parse_items(content)
    item = find_item(items, n)
    lines = content.split('\n')
    # Determine indent (2 spaces more than item indent)
    item_line = lines[item['line_idx']]
    item_indent = len(item_line) - len(item_line.lstrip())
    detail_indent = ' ' * (item_indent + 2)
    # Insert comment lines after the last detail line (or right after item)
    insert_after = item['detail_lines'][-1][0] if item['detail_lines'] else item['line_idx']
    # Format body lines with detail indent
    comment_lines = detail_lines_for(detail_indent, body)
    for offset, cl in enumerate(comment_lines):
        lines.insert(insert_after + 1 + offset, cl)
    if dry_run:
        print(f"[dry-run] would append to item #{n} in {plan_path}:")
        for cl in comment_lines[:5]:
            print(f"  {cl}")
    else:
        save_file('\n'.join(lines))
        print(f"Commented on item #{n}")

elif verb == 'close-issue':
    n = args[0]
    body = args[1] if len(args) >= 2 else 'resolved'
    content = load_file()
    content, _ = ensure_ids(content)
    items = parse_items(content)
    item = find_item(items, n)
    lines = content.split('\n')
    # Check the box
    lines[item['line_idx']] = lines[item['line_idx']].replace('- [ ]', '- [x]', 1)
    # Append resolution note
    item_indent = len(lines[item['line_idx']]) - len(lines[item['line_idx']].lstrip())
    note_lines = detail_lines_for(' ' * (item_indent + 2), f'resolved: {body}')
    note_line = note_lines[0]
    insert_after = item['detail_lines'][-1][0] if item['detail_lines'] else item['line_idx']
    lines[insert_after + 1:insert_after + 1] = note_lines
    if dry_run:
        print(f"[dry-run] would close item #{n} in {plan_path} and append: {note_line}")
    else:
        save_file('\n'.join(lines))
        print(f"Closed item #{n}")

else:
    print(f"pipeline-vcs: unknown verb in file mode: {verb}", file=sys.stderr)
    sys.exit(1)
PYEOF
      ;;
  esac
}

# ── Comment-body normalisation ────────────────────────────────────────────────
# `comment-issue` / `comment-pr` take the body POSITIONALLY, but four lines above
# in the verb list `create-issue` / `create-pr` take a body *file*. That
# inconsistency is a trap: an agent composing a multi-KB markdown verdict
# reaches for `--body-file` by analogy — with this script's own siblings, and
# with `gh` — and the provider branches took "$2" as the body verbatim. The
# result was `gh issue comment N --body "--body-file"`: a comment whose entire
# content is the literal flag, the real verdict discarded, and exit 0.
#
# Silent, so it survives until someone audits comment content. Three verdicts
# were lost in a single pipeline run before it was noticed. Wanting a file is
# also legitimate rather than lazy — long markdown is hostile as a shell
# argument, and a body containing raw URLs can be refused outright by a
# permission rule, leaving a file as the only route.
#
# So accept both spellings, and refuse a body that is still a bare flag instead
# of posting it. Applied before dispatch, so every provider inherits it.
# Body text for `--body-file -` (#342). A closed fd 0 would make "$(cat)" read its
# own pipe and hang, and a terminal would wait for a human: both are an error.
_TALOS_STDIN_BODY=""
_read_stdin_body() {
  if [ -t 0 ] || ! { : 3<&0; } 2>/dev/null; then
    echo "pipeline-vcs: $VERB --body-file -: stdin is closed or a terminal; pipe the text in (heredoc)" >&2
    exit 1
  fi
  _TALOS_STDIN_BODY="$(cat)"
}
_TALOS_COMMENT_MAX=65536   # GitHub rejects longer comment bodies; cap every provider
# The body reaches `gh` / curl as ONE argument, and Linux caps a single argument
# (or environment string) at 128 KiB = 131072 bytes (MAX_ARG_STRLEN), failing the
# exec with "Argument list too long" where macOS has no such cap. 65536
# characters can be 262144 bytes of UTF-8, so the body is also capped by bytes,
# below that limit. Both caps are checked on stdin/file text, before any exec.
_TALOS_BODY_MAX_BYTES=120000

# edit-pr-body <pr> --body-file <path|-> (#455). github and github-api only (the
# rest exit 2 `not implemented`, as upsert-pr-comment does); the body comes ONLY
# from --body-file (a path, or stdin with `-`), never a positional, so it never
# sits inside shell quotes. Usage errors exit 2 before any body is read. The
# comment block below then reads the file, applies both size caps and the
# placeholder guard, and rewrites ARGS to `<pr> <body>` for the adapters.
if [ "$VERB" = "edit-pr-body" ]; then
  _epb_usage="Usage: edit-pr-body <pr> --body-file <path|->"
  if [ "$PROVIDER" != "github" ] && [ "$PROVIDER" != "github-api" ]; then
    echo "pipeline-vcs: edit-pr-body: not implemented for provider '$PROVIDER'" >&2
    exit 2
  fi
  case "${ARGS[0]-}" in
    ''|*[!0-9]*)
      echo "pipeline-vcs: edit-pr-body: <pr> must be a number (got '${ARGS[0]-}'); $_epb_usage" >&2
      exit 2
      ;;
  esac
  if [ "${#ARGS[@]}" -eq 2 ] && [ "${ARGS[1]}" = "--body-file" ]; then
    echo "pipeline-vcs: edit-pr-body: --body-file needs a value; $_epb_usage" >&2
    exit 2
  fi
  if [ "${#ARGS[@]}" -ne 3 ] || [ "${ARGS[1]}" != "--body-file" ]; then
    echo "pipeline-vcs: edit-pr-body: the body comes only from --body-file <path|->; $_epb_usage" >&2
    exit 2
  fi
  unset _epb_usage
fi
case "$VERB" in
  comment-issue|comment-pr|edit-pr-body)
    # A positional "-" is NOT stdin (#449): it would post a one-character
    # comment, exit 0 and lose the hand-off text (it happened on #349). The
    # stdin form is `--body-file -`. Checked on the raw arguments, before the
    # `--body-file -` rewrite below, so a stdin body that is itself "-" is fine.
    if [ "${ARGS[1]-}" = "-" ] || { [ "${ARGS[1]-}" = "--body" ] && [ "${ARGS[2]-}" = "-" ]; }; then
      echo "pipeline-vcs: $VERB: a body of exactly '-' is not stdin; use: $VERB <number> --body-file - (text on stdin). Nothing posted." >&2
      exit 1
    fi
    if [ "${#ARGS[@]}" -ge 3 ]; then
      case "${ARGS[1]}" in
        --body-file)
          # "--body-file -" reads the body from stdin (#342): the route for text
          # that must never sit inside shell quotes (heredoc on stdin). Same
          # trailing-newline trimming as a file read below.
          if [ "${ARGS[2]}" = "-" ]; then
            _read_stdin_body
            ARGS=("${ARGS[0]}" "$_TALOS_STDIN_BODY")
          # A UTF-8 character is at most 4 bytes, so a file over 4x the
          # character cap cannot fit; refuse it without reading it (#306).
          elif [ -r "${ARGS[2]}" ] && [ "$(wc -c < "${ARGS[2]}")" -gt $((4 * _TALOS_COMMENT_MAX)) ]; then
            echo "pipeline-vcs: $VERB: body is longer than $_TALOS_COMMENT_MAX characters (GitHub's comment limit); nothing posted." >&2
            exit 1
          elif [ -r "${ARGS[2]}" ]; then
            ARGS=("${ARGS[0]}" "$(cat "${ARGS[2]}")")
          else
            echo "pipeline-vcs: $VERB --body-file: cannot read '${ARGS[2]}'" >&2
            exit 1
          fi
          ;;
        --body)
          ARGS=("${ARGS[0]}" "${ARGS[2]}")
          ;;
      esac
    fi
    case "${ARGS[1]-}" in
      --*)
        echo "pipeline-vcs: $VERB: body looks like a flag ('${ARGS[1]}'), not comment text." >&2
        echo "              Usage: $VERB <number> <body>            # body is POSITIONAL" >&2
        echo "              or:    $VERB <number> --body-file <path>" >&2
        exit 1
        ;;
    esac
    # Bare readable absolute path guard (#94): an agent that writes a verdict to
    # a file and passes the path positionally gets a one-line path as the comment,
    # exits 0, and never notices. Detect and reject so --body-file is used instead.
    # Tie the check to [ -r ] so a body that merely looks path-like but does not
    # exist on this machine is posted as literal text (no over-rejection).
    case "${ARGS[1]-}" in
      /*)
        if [ -r "${ARGS[1]}" ]; then
          echo "pipeline-vcs: $VERB: body looks like a file path ('${ARGS[1]}'), not comment text." >&2
          echo "pipeline-vcs:   Use --body-file to post a file:" >&2
          printf 'pipeline-vcs:     bash scripts/pipeline-vcs.sh %s %s --body-file %s\n' \
            "$VERB" "${ARGS[0]}" "${ARGS[1]}" >&2
          exit 1
        fi
        ;;
    esac
    # Unsubstituted template placeholder guard (#306): the stage-comment recipe
    # renders templates/comments/*.md with string.Template, and a variable the
    # agent forgot to export used to survive as a literal `${HEADER}` in a public
    # comment -- no role attribution, and readers keyed on the `**Agent:**`
    # header miss it. Refuse such a body before any provider sees it.
    #
    # The variable names are derived from the templates themselves (the shipped
    # copy next to this script plus the project's comments.templates_dir), so
    # the list cannot drift; the shipped names are also built in, so the guard
    # still holds when neither directory resolves. Only those names count: `$5`,
    # `${foo}`, `$PATH` are ordinary text. Matched fence pairs and inline code
    # spans are skipped -- templates never place a variable in code, and a
    # comment *about* a placeholder quotes it that way. An unclosed fence exempts
    # nothing. A body over $_TALOS_COMMENT_MAX characters is refused before the
    # scan (exit 3), and the scan is a single linear pass: no regex backtracks
    # across backticks, and inline code is found by walking backtick runs once.
    if [ "${#ARGS[@]}" -ge 2 ]; then
      _ph_left="$(printf '%s' "${ARGS[1]}" | _TALOS_COMMENT_MAX="$_TALOS_COMMENT_MAX" _TALOS_BODY_MAX_BYTES="$_TALOS_BODY_MAX_BYTES" python3 -I -c '
import glob, os, re, sys
TOKEN = re.compile(r"\$(?:(\$)|\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))")
FENCE = re.compile(r"\s{0,3}(`{3,}|~{3,})")
RUN = re.compile(r"`+")
def names(text):
    return {m.group(2) or m.group(3) for m in TOKEN.finditer(text) if not m.group(1)}
def strip_code(line):
    # A run of k backticks opens a span closed by the next run of exactly k;
    # an unmatched run is literal text. Each per-length cursor only moves
    # forward, so the whole line costs O(len(line)).
    runs = [m.span() for m in RUN.finditer(line)]
    by_len, cursor = {}, {}
    for i, (s, e) in enumerate(runs):
        by_len.setdefault(e - s, []).append(i)
    out, pos, i = [], 0, 0
    while i < len(runs):
        k = runs[i][1] - runs[i][0]
        same, c = by_len[k], cursor.get(k, 0)
        while c < len(same) and same[c] <= i:
            c += 1
        cursor[k] = c
        if c < len(same):
            out.append(line[pos:runs[i][0]])
            pos, i = runs[same[c]][1], same[c] + 1
        else:
            i += 1
    out.append(line[pos:])
    return "".join(out)
raw = sys.stdin.buffer.read()
body = raw.decode("utf-8", errors="replace")
if len(body) > int(os.environ["_TALOS_COMMENT_MAX"]):
    sys.exit(3)
if len(raw) > int(os.environ["_TALOS_BODY_MAX_BYTES"]):
    sys.exit(4)
# Variables of the shipped templates/comments/*.md (#306 fallback).
known = {"ATTENTION_REPORT", "BLOCKED_BY", "DETAILS", "HEADER", "PR", "SUMMARY", "VERDICT"}
for d in sys.argv[1:]:
    for path in glob.glob(os.path.join(d, "*.md")):
        try:
            with open(path, encoding="utf-8") as f:
                known |= names(f.read())
        except (OSError, UnicodeDecodeError) as e:
            print("pipeline-vcs: placeholder guard: skipping unreadable template %s (%s)" % (path, type(e).__name__), file=sys.stderr)
prose, fence, held = [], None, []
for line in body.splitlines():
    if fence is None:
        m = FENCE.match(line)
        if m:
            fence, held = m.group(1), [line]
        else:
            prose.append(line)
    else:
        held.append(line)
        m = FENCE.match(line)
        if m and m.group(1).startswith(fence):
            fence, held = None, []
prose += held
print(" ".join(sorted(names("\n".join(strip_code(l) for l in prose)) & known)))
' "$SCRIPT_DIR/../templates/comments" "$(cfg comments.templates_dir)")"
      _ph_rc=$?
      if [ "$_ph_rc" -eq 3 ]; then
        echo "pipeline-vcs: $VERB: body is longer than $_TALOS_COMMENT_MAX characters (GitHub's comment limit); nothing posted." >&2
        exit 1
      elif [ "$_ph_rc" -eq 4 ]; then
        echo "pipeline-vcs: $VERB: body is longer than $_TALOS_BODY_MAX_BYTES bytes (Linux caps one argument at 128 KiB); nothing posted." >&2
        exit 1
      elif [ "$_ph_rc" -ne 0 ]; then
        echo "pipeline-vcs: $VERB: could not check the body for unsubstituted template placeholders; nothing posted." >&2
        exit 1
      elif [ -n "$_ph_left" ]; then
        echo "pipeline-vcs: $VERB: body still contains unsubstituted template placeholder(s): $_ph_left -- nothing posted." >&2
        echo "              Export each variable before rendering the template (see SKILL.md \"Stage comment convention\")." >&2
        exit 1
      fi
    fi
    ;;
esac
# An empty body would blank the PR description; refuse it before any call.
if [ "$VERB" = "edit-pr-body" ] && [ -z "$(tr -d '[:space:]' <<<"${ARGS[1]-}")" ]; then
  echo "pipeline-vcs: edit-pr-body: the body is empty; nothing changed" >&2
  exit 1
fi

# mark-needs-owner / list-needs-owner (#345) and upsert-pr-comment (#381) are
# GitHub only; the label and marker verbs have no gitlab, azure or file
# implementation. Exit 2, before any body is read from stdin or a file, so a
# caller reads it as "unsupported, skip" and not as the exit 1 of a failed call.
case "$VERB" in
  mark-needs-owner|list-needs-owner|upsert-pr-comment)
    if [ "$PROVIDER" != "github" ] && [ "$PROVIDER" != "github-api" ]; then
      echo "pipeline-vcs: $VERB: not implemented for provider '$PROVIDER'" >&2
      exit 2
    fi
    ;;
esac

# Both size caps on a body that is already in a variable: characters (GitHub's
# own limit) and bytes (Linux's single-argument limit). The text goes to python
# on stdin, never through env or argv. Over either cap: exit 1, nothing posted.
_check_body_caps() {
  local _cb_rc=0
  printf '%s' "$1" | python3 -I -c '
import sys
raw = sys.stdin.buffer.read()
if len(raw.decode("utf-8", errors="replace")) > int(sys.argv[1]):
    sys.exit(3)
sys.exit(4 if len(raw) > int(sys.argv[2]) else 0)
' "$_TALOS_COMMENT_MAX" "$_TALOS_BODY_MAX_BYTES" || _cb_rc=$?
  case "$_cb_rc" in
    0) ;;
    3) echo "pipeline-vcs: $VERB: body is longer than $_TALOS_COMMENT_MAX characters (GitHub's limit); nothing posted." >&2; exit 1 ;;
    4) echo "pipeline-vcs: $VERB: body is longer than $_TALOS_BODY_MAX_BYTES bytes (Linux caps one argument at 128 KiB); nothing posted." >&2; exit 1 ;;
    *) echo "pipeline-vcs: $VERB: could not check the body size; nothing posted." >&2; exit 1 ;;
  esac
}

# approve-pr / close-issue / mark-needs-owner take free text too (a reviewer
# summary, a resolution note, the question for the owner). Accept `<n>
# --body-file <path|->` here, before dispatch, so every provider inherits it and
# the text never has to be typed inside shell quotes (#342). The positional
# `<n> <body>` form is unchanged. The comment-issue / comment-pr block above is
# not folded into this one: it interleaves the same caps with the placeholder
# scan.
case "$VERB" in
  approve-pr|close-issue|mark-needs-owner)
    if [ "${#ARGS[@]}" -ge 3 ] && [ "${ARGS[1]}" = "--body-file" ]; then
      if [ "${ARGS[2]}" = "-" ]; then
        _read_stdin_body
        ARGS=("${ARGS[0]}" "$_TALOS_STDIN_BODY")
      elif [ -r "${ARGS[2]}" ] && [ "$(wc -c < "${ARGS[2]}")" -gt $((4 * _TALOS_COMMENT_MAX)) ]; then
        echo "pipeline-vcs: $VERB: body is longer than $_TALOS_COMMENT_MAX characters (GitHub's limit); nothing posted." >&2
        exit 1
      elif [ -r "${ARGS[2]}" ]; then
        ARGS=("${ARGS[0]}" "$(cat "${ARGS[2]}")")
      else
        echo "pipeline-vcs: $VERB --body-file: cannot read '${ARGS[2]}'" >&2
        exit 1
      fi
      _check_body_caps "${ARGS[1]}"
    fi
    ;;
esac

# Argument checks for the needs-owner verbs (#345), once for every provider.
case "$VERB" in
  mark-needs-owner)
    case "${ARGS[0]-}" in
      ''|*[!0-9]*)
        echo "pipeline-vcs: mark-needs-owner: <n> must be a number (got '${ARGS[0]-}')" >&2
        exit 1
        ;;
    esac
    if [ "${#ARGS[@]}" -ne 2 ]; then
      echo "pipeline-vcs: mark-needs-owner: Usage: mark-needs-owner <n> <text> | <n> --body-file <path|->" >&2
      exit 1
    fi
    case "${ARGS[1]}" in
      --*)
        echo "pipeline-vcs: mark-needs-owner: text looks like a flag ('${ARGS[1]}'); Usage: mark-needs-owner <n> <text> | <n> --body-file <path|->" >&2
        exit 1
        ;;
    esac
    if [ -z "$(printf '%s' "${ARGS[1]}" | tr -d '[:space:]')" ]; then
      echo "pipeline-vcs: mark-needs-owner: the text is empty; nothing posted" >&2
      exit 1
    fi
    _check_body_caps "${ARGS[1]}"
    ;;
  list-needs-owner)
    for _ln_flag in ${ARGS[@]+"${ARGS[@]}"}; do
      case "$_ln_flag" in
        --json|--clear-answered) ;;
        *)
          echo "pipeline-vcs: list-needs-owner: unknown argument '$_ln_flag'; Usage: list-needs-owner [--json] [--clear-answered]" >&2
          exit 1
          ;;
      esac
    done
    ;;
esac

# upsert-pr-comment <pr> --marker <name> --body-file <path|-> (#381). Its own
# block: the `--body-file` block above only matches `<n> --body-file <x>`, and
# this verb's body is not a positional. Validates everything and stages the
# FINAL body (text, a blank line, the marker) in a temp file, then rewrites ARGS
# to `<pr> <name> <file>` for the adapters; the body never travels as an argument
# to a command. Usage errors exit 2, a body that cannot be read, is empty or
# is over the caps exits 1, all before any call.
_TALOS_UPSERT_BODY_FILE=""
_TALOS_UPSERT_PAYLOAD_FILE=""
if [ "$VERB" = "upsert-pr-comment" ]; then
  _uc_usage="Usage: upsert-pr-comment <pr> --marker <name> --body-file <path|->"
  _uc_pr="${ARGS[0]-}"
  _uc_marker=""; _uc_src=""; _uc_have_marker=false; _uc_have_src=false
  _uc_i=1
  while [ "$_uc_i" -lt "${#ARGS[@]}" ]; do
    case "${ARGS[$_uc_i]}" in
      --marker|--body-file)
        if [ $((_uc_i + 1)) -ge "${#ARGS[@]}" ]; then
          echo "pipeline-vcs: upsert-pr-comment: ${ARGS[$_uc_i]} needs a value; $_uc_usage" >&2
          exit 2
        fi
        if [ "${ARGS[$_uc_i]}" = "--marker" ]; then
          _uc_marker="${ARGS[$((_uc_i + 1))]}"; _uc_have_marker=true
        else
          _uc_src="${ARGS[$((_uc_i + 1))]}"; _uc_have_src=true
        fi
        _uc_i=$((_uc_i + 2))
        ;;
      *)
        echo "pipeline-vcs: upsert-pr-comment: unexpected argument '${ARGS[$_uc_i]}' (the body comes only from --body-file <path|->); $_uc_usage" >&2
        exit 2
        ;;
    esac
  done
  case "$_uc_pr" in
    ''|*[!0-9]*)
      echo "pipeline-vcs: upsert-pr-comment: <pr> must be a number (got '$_uc_pr'); $_uc_usage" >&2
      exit 2
      ;;
  esac
  if [ "$_uc_have_marker" != true ] || [ "$_uc_have_src" != true ]; then
    echo "pipeline-vcs: upsert-pr-comment: --marker and --body-file are both required; $_uc_usage" >&2
    exit 2
  fi
  _uc_known=false
  for _uc_m in "${TALOS_MARKERS[@]:-}"; do
    [ -n "$_uc_marker" ] && [ "$_uc_m" = "talos:$_uc_marker" ] && _uc_known=true
  done
  if [ "$_uc_known" != true ]; then
    echo "pipeline-vcs: upsert-pr-comment: --marker '$_uc_marker' is not a TALOS_MARKERS member (give the name without the talos: prefix, e.g. spend)" >&2
    exit 2
  fi
  if [ "$_uc_src" = "-" ]; then
    _read_stdin_body
    _uc_body="$_TALOS_STDIN_BODY"
  elif [ ! -r "$_uc_src" ]; then
    echo "pipeline-vcs: upsert-pr-comment --body-file: cannot read '$_uc_src'" >&2
    exit 1
  elif [ "$(wc -c < "$_uc_src")" -gt $((4 * _TALOS_COMMENT_MAX)) ]; then
    echo "pipeline-vcs: upsert-pr-comment: body is longer than $_TALOS_COMMENT_MAX characters (GitHub's comment limit); nothing posted." >&2
    exit 1
  else
    _uc_body="$(cat "$_uc_src")"
  fi
  if [ -z "$(printf '%s' "$_uc_body" | tr -d '[:space:]')" ]; then
    echo "pipeline-vcs: upsert-pr-comment: the body is empty; nothing posted" >&2
    exit 1
  fi
  _uc_body="$_uc_body"$'\n\n'"<!-- talos:$_uc_marker -->"
  _check_body_caps "$_uc_body"
  _TALOS_UPSERT_BODY_FILE="$(mktemp)"
  _talos_on_exit 'rm -f "$_TALOS_UPSERT_BODY_FILE"'
  printf '%s' "$_uc_body" > "$_TALOS_UPSERT_BODY_FILE"
  ARGS=("$_uc_pr" "$_uc_marker" "$_TALOS_UPSERT_BODY_FILE")
  unset _uc_usage _uc_pr _uc_marker _uc_src _uc_have_marker _uc_have_src _uc_i _uc_known _uc_m _uc_body
fi

# ── assert-sync: working-tree precondition (provider-agnostic) ───────────────
# Called by the orchestrator before dispatching non-worktree-isolated stages.
# Provider-agnostic: exits before the provider dispatch so it works regardless
# of which VCS provider is configured.
if [ "$VERB" = "assert-sync" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] assert-sync: would check dirty tree, fetch origin, compare HEAD to origin/<base_branch>"
    exit 0
  fi

  # Step 1: Dirty tree — refuse BEFORE fetching.
  # Do not stash, do not pull over uncommitted work. Pulling over a dirty tree
  # risks mixing in-progress work into what a non-isolated stage reads, or
  # silently discarding it on conflict.
  _as_dirty="$(git status --porcelain 2>/dev/null)"
  if [ -n "$_as_dirty" ]; then
    printf 'pipeline-vcs: assert-sync: ABORT -- working tree is dirty; commit or stash before running the pipeline.
Dirty files:
%s
' "$_as_dirty" >&2
    exit 1
  fi

  # Step 2: Resolve base branch (same logic as SKILL.md config defaults:
  # configured value first, then symbolic-ref, then fall back to 'main').
  _as_base="$BASE_BRANCH"
  if [ -z "$_as_base" ]; then
    _as_base="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')"
  fi
  [ -z "$_as_base" ] && _as_base="main"

  # Step 3: Fetch — network failure is itself a reason to abort, not continue.
  if ! git fetch origin 2>/dev/null; then
    echo "pipeline-vcs: assert-sync: ABORT -- git fetch origin failed; check network connectivity." >&2
    exit 1
  fi

  # Step 4: Compare HEAD to origin/<base>.
  # Note: git rev-parse HEAD here answers "what commit is my working tree at?" —
  # a different question from "what commit does the PR point at?" (use pr-head for that).
  # The pr-head verb is for agents writing approval markers; this is a shell comparison
  # of two git refs to verify the working tree is current.
  _as_local="$(git rev-parse HEAD 2>/dev/null)"
  _as_origin="$(git rev-parse "origin/$_as_base" 2>/dev/null)"

  if [ -z "$_as_local" ] || [ -z "$_as_origin" ]; then
    echo "pipeline-vcs: assert-sync: ABORT -- could not resolve HEAD or origin/$_as_base" >&2
    exit 1
  fi

  if [ "$_as_local" = "$_as_origin" ]; then
    # Clean and level — exit 0, no output (safe to embed as a precondition
    # without cluttering orchestrator logs).
    exit 0
  fi

  _as_behind="$(git rev-list --count "HEAD..origin/$_as_base" 2>/dev/null || echo 0)"
  _as_ahead="$(git rev-list --count "origin/$_as_base..HEAD" 2>/dev/null || echo 0)"

  if [ "$_as_behind" -gt 0 ] && [ "$_as_ahead" -gt 0 ]; then
    # Diverged — both ahead and behind. Manual resolution required.
    printf 'pipeline-vcs: assert-sync: ABORT -- working tree has diverged from origin/%s (ahead %s, behind %s commits). Manual resolution required -- do NOT force-push; this may represent legitimate concurrent work.
  local:          %s
  origin/%s: %s
' \
      "$_as_base" "$_as_ahead" "$_as_behind" \
      "$_as_local" "$_as_base" "$_as_origin" >&2
    exit 1
  elif [ "$_as_behind" -gt 0 ]; then
    # Behind — stale checkout. Abort so non-isolated stages read current source.
    printf 'pipeline-vcs: assert-sync: ABORT -- working tree is behind origin/%s by %s commit(s). Run: git pull --ff-only
  local:          %s
  origin/%s: %s
' \
      "$_as_base" "$_as_behind" \
      "$_as_local" "$_as_base" "$_as_origin" >&2
    exit 1
  else
    # Ahead only — local has commits not yet pushed to origin/<base>.
    # The working tree is not stale; it is ahead of the remote.
    # Non-isolated stages reading this tree see a consistent, complete source
    # (even if not yet merged). Exits 0: ahead is not the failure mode this
    # check guards against. A warning is printed so a human with in-flight
    # local commits is aware — in normal automated use the orchestrator never
    # commits to the base branch, making this state unreachable automatically.
    printf 'pipeline-vcs: assert-sync: WARNING -- working tree is ahead of origin/%s by %s commit(s); non-isolated stages will read unpushed commits.\n'       "$_as_base" "$_as_ahead" >&2
    exit 0
  fi
fi

# ── has-spec: skip-PM detection (#199) ────────────────────────────────────────
# Exits 0 when issue <n>'s body already IS a usable spec (skip the PM stage),
# exits 1 when PM should still run. GitHub only (github, github-api parity) —
# fetches via this script's own view-issue verb, so both providers share one
# code path and one scan (_has_spec_scan above).
if [ "$VERB" = "has-spec" ]; then
  if [ "$PROVIDER" != "github" ] && [ "$PROVIDER" != "github-api" ]; then
    echo "pipeline-vcs: has-spec: not implemented for provider '$PROVIDER'" >&2
    exit 1
  fi
  _hs_n="${ARGS[0]:-}"
  if [ -z "$_hs_n" ]; then
    echo "pipeline-vcs: has-spec: missing issue number" >&2
    exit 1
  fi
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] has-spec: view-issue $_hs_n | scan for an 'acceptance criteria' heading with a checklist item, or a spec:ready label"
    exit 0
  fi
  _hs_json="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" view-issue "$_hs_n" ${REPO:+--repo "$REPO"})" || {
    echo "pipeline-vcs: has-spec: could not fetch issue #$_hs_n" >&2
    exit 1
  }
  printf '%s' "$_hs_json" | _has_spec_scan
  exit $?
fi

# ── slug-for: branch-slug derivation (#199) ───────────────────────────────────
# Provider-agnostic (pure string transform, no VCS call): prints the slug
# component of `fix/issue-<N>-<slug>` / `feat/issue-<N>-<slug>` for a given
# issue title. Lowercases the title, collapses every run of non-alphanumeric
# characters to a single '-', trims leading/trailing '-', then truncates to 40
# characters (re-trimming a trailing '-' left by the cut). The fix/feat prefix
# choice itself is not this verb's job — the caller decides that from the
# title (feat/... when the title starts with "feat").
if [ "$VERB" = "slug-for" ]; then
  _sf_title="${ARGS[0]:-}"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] slug-for: would derive a <=40-char slug from title '$_sf_title'"
    exit 0
  fi
  python3 -I -c "
import re, sys
title = sys.argv[1] if len(sys.argv) > 1 else ''
slug = re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')
print(slug[:40].rstrip('-'))
" "$_sf_title"
  exit 0
fi

# ── forbidden-files-patterns: effective merge.forbidden_files list (#262) ────
# Provider-agnostic (pure config transform, no VCS call): prints the
# effective merge.forbidden_files patterns, one per line -- built-in
# defaults unioned with config, or replaced wholesale under
# merge.forbidden_files_replace. Single source of truth
# (_vcs_shared_forbidden_patterns) reused by check-pr-files's own deny list
# AND by pipeline-mergebase.sh, which cross-checks merge.union_paths (and
# each actual conflicting path) against this same list before ever
# mechanically resolving a conflict -- an operator widening union_paths must
# never be able to get forbidden-shaped content union-merged and pushed
# unreviewed.
if [ "$VERB" = "forbidden-files-patterns" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] forbidden-files-patterns: print the effective merge.forbidden_files pattern list"
    exit 0
  fi
  CONFIGURED="$(cfg merge.forbidden_files)" REPLACE="$(cfg merge.forbidden_files_replace)" \
    _vcs_shared_forbidden_patterns
  exit 0
fi

# ── label-pr: approval-marker guard (#94) ────────────────────────────────────
# Recognised approval labels and their role names (same set as check-approval-sha).
# Two modes:
#   Default (no flag): after the label is applied, call check-approval-sha; if it
#     reports no current-head marker, print a loud WARNING to stderr and exit 0.
#     Non-fatal: profiles document label-then-stamp order; a fatal here deadlocks.
#   --require-marker: pre-apply check — fetch PR data directly, verify a marker
#     comment exists for the role being labelled; exit 1 if absent (label not applied).
#
# --require-marker is stripped from ARGS so provider functions never see it.
# _has_whole_approval_marker <sha> <role> -- comment text on stdin. Exit 0 only
# when some line, trimmed, IS the whole marker comment (#449). A substring match
# also counted a comment that merely quoted the marker mid-line (`> <!-- talos:
# approval ... -->`, or prose about it), so the warning stayed silent.
_has_whole_approval_marker() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -qxF "<!-- talos:approval sha=$1 role=$2 -->"
}
# _vcs_label_role <approval-label> -- the role that earns it; nothing for any other label.
_vcs_label_role() {
  case "$1" in
    qa:pass) echo qa ;; review:approved) echo reviewer ;;
    security:approved) echo security ;; docs:done) echo docs ;;
  esac
}
# _vcs_stamped_roles <pr> -- on one line, the roles with a whole approval marker
# comment at the PR's current head. Non-zero when the PR cannot be read.
_vcs_stamped_roles() {
  local _sr_data _sr_sha _sr_comments _sr_role _sr_out=""
  _vcs_pr_id_numeric "$1" || return 1
  _gh_init
  _sr_data="$(_gh_marker_data "$1" 2>/dev/null)" || return 1
  _sr_sha="$(printf '%s' "$_sr_data" | _gh_field headRefOid)"
  [ -n "$_sr_sha" ] || return 1
  _sr_comments="$(printf '%s' "$_sr_data" | python3 -I -c "
import json, sys
for c in json.load(sys.stdin).get('comments', []):
    print(c.get('body', ''))
")"
  for _sr_role in qa reviewer security docs; do
    printf '%s\n' "$_sr_comments" | _has_whole_approval_marker "$_sr_sha" "$_sr_role" && _sr_out="$_sr_out $_sr_role"
  done
  echo "$_sr_out"
}
# _vcs_label_stamped <approval-label> <stamped-roles> -- 0 when the label's role is among them.
_vcs_label_stamped() {
  local _ls_role
  _ls_role="$(_vcs_label_role "$1")"
  [ -n "$_ls_role" ] && case " $2 " in *" $_ls_role "*) return 0 ;; esac
  return 1
}
# _ADDING_APPROVAL_LABELS and _REQUIRE_MARKER are consumed by the post-dispatch block.
_REQUIRE_MARKER=false
_ADDING_APPROVAL_LABELS=""
_LABEL_PR_N=""
if [ "$VERB" = "label-pr" ] && [ "${#ARGS[@]}" -ge 1 ]; then
  _LABEL_PR_N="${ARGS[0]}"
  _lp_filtered=("${ARGS[0]}")
  _lp_i=1
  while [ "$_lp_i" -lt "${#ARGS[@]}" ]; do
    _lp_arg="${ARGS[$_lp_i]}"
    case "$_lp_arg" in
      --require-marker)
        _REQUIRE_MARKER=true ;;
      --add)
        _lp_ni=$((_lp_i + 1))
        [ "$_lp_ni" -lt "${#ARGS[@]}" ] \
          || _vcs_flag_needs_value --add "label-pr <n> [--add <label>]... [--remove <label>]... [--require-marker]"
        _lp_lbl="${ARGS[$_lp_ni]:-}"
        _lp_filtered+=("$_lp_arg" "$_lp_lbl")
        case "$_lp_lbl" in
          qa:pass|review:approved|security:approved|docs:done)
            _ADDING_APPROVAL_LABELS="$_ADDING_APPROVAL_LABELS $_lp_lbl" ;;
        esac
        _lp_i=$((_lp_ni + 1))
        continue ;;
      *)
        _lp_filtered+=("$_lp_arg") ;;
    esac
    _lp_i=$((_lp_i + 1))
  done
  ARGS=("${_lp_filtered[@]}")
  _ADDING_APPROVAL_LABELS="${_ADDING_APPROVAL_LABELS# }"

  # --require-marker: pre-apply check.  Fetch PR data and verify a marker comment
  # exists for each approval label being added.  Exit 1 (fatal) if absent.
  # Only implemented for the github provider (check-approval-sha is github-only).
  if [ "$_REQUIRE_MARKER" = "true" ] && [ -n "$_ADDING_APPROVAL_LABELS" ] \
      && [ "$DRY_RUN" != "true" ] && { [ "$PROVIDER" = "github" ] || [ "$PROVIDER" = "github-api" ]; }; then
    _lp_marker_found=false
    if _lp_stamped="$(_vcs_stamped_roles "$_LABEL_PR_N")"; then
      for _lp_lbl in $_ADDING_APPROVAL_LABELS; do
        _vcs_label_stamped "$_lp_lbl" "$_lp_stamped" && { _lp_marker_found=true; break; }
      done
    fi
    if [ "$_lp_marker_found" = "false" ]; then
      echo "pipeline-vcs: label-pr: ERROR -- --require-marker: no approval marker found at current head." >&2
      echo "pipeline-vcs: label-pr: Use post-approval to post the marker and apply the label in one step:" >&2
      printf 'pipeline-vcs:   bash scripts/pipeline-vcs.sh post-approval %s <role>\n' \
        "$_LABEL_PR_N" >&2
      exit 1
    fi
  fi
fi

# ── post-approval: atomic marker-post + label (#146) ─────────────────────────
# GitHub-only (github and github-api providers). For other providers, exit 1.
#
# Issue #128 note: post-approval is the single controlled surface through which
# all approval markers enter the system. Future provenance work (signed markers,
# dispatch-chain verification) instruments here. Do not add --skip-validation,
# --no-label, --raw-marker, or any bypass flag.
#
# Failure modes eliminated for stages that use this verb:
#   - Marker posted without <!-- --> wrapper (verb constructs wrapper always)
#   - sha=PLACEHOLDER_NOT_REAL (SHA always fetched from PR head, never caller-supplied)
#   - Correct marker posted, label never applied (verb does both atomically)
# Hand-construction of approval markers remains possible and remains the
# caller's responsibility -- these failures are eliminated for verb users only.
if [ "$VERB" = "post-approval" ]; then
  if [ "$PROVIDER" != "github" ] && [ "$PROVIDER" != "github-api" ]; then
    echo "pipeline-vcs: post-approval: not implemented for provider '$PROVIDER'" >&2
    exit 1
  fi

  _pa_n="${ARGS[0]:-}"
  _pa_role="${ARGS[1]:-}"
  _pa_body_file=""
  _pa_issue=""
  _pa_i=2
  while [ "$_pa_i" -lt "${#ARGS[@]}" ]; do
    case "${ARGS[$_pa_i]}" in
      --body-file)
        _pa_ni=$((_pa_i + 1))
        _pa_body_file="${ARGS[$_pa_ni]:-}"
        _pa_i=$((_pa_ni + 1))
        ;;
      --issue)
        _pa_ni=$((_pa_i + 1))
        _pa_issue="${ARGS[$_pa_ni]:-}"
        _pa_i=$((_pa_ni + 1))
        ;;
      *) _pa_i=$((_pa_i + 1)) ;;
    esac
  done
  if [ -n "$_pa_issue" ]; then
    case "$_pa_issue" in
      *[!0-9]*)
        echo "pipeline-vcs: post-approval: --issue must be an issue number, got '$_pa_issue'" >&2
        exit 1
        ;;
    esac
  fi

  # Validate PR number
  if [ -z "$_pa_n" ]; then
    echo "pipeline-vcs: post-approval: missing PR number" >&2
    exit 1
  fi
  case "$_pa_n" in
    ''|*[!0-9]*)
      echo "pipeline-vcs: post-approval: PR number must be an integer, got '$_pa_n'" >&2
      exit 1
      ;;
  esac

  # Validate role -- same set as check-approval-sha VALID_ROLES (#128).
  # Single source of truth: scripts/pipeline-contract.sh's
  # TALOS_APPROVAL_ROLES/TALOS_APPROVAL_LABELS (#178) -- never hand-restate
  # this list or the role->label mapping below. _vcs_shared_contract_env
  # both sources the contract (idempotent) and falls back to the pre-#178
  # literals if pipeline-contract.sh is missing (partial install/sync), so
  # TALOS_APPROVAL_ROLES/TALOS_APPROVAL_LABELS are guaranteed set here.
  _vcs_shared_contract_env
  # "docs, qa, reviewer, security" -- same sorted, comma-joined wording
  # check-approval-sha's unknown-role diagnostic uses, built from the
  # contract array rather than hand-restated (#178).
  _pa_valid_roles_msg="$(printf '%s\n' "${TALOS_APPROVAL_ROLES[@]}" | sort | paste -sd, -)"
  _pa_valid_roles_msg="${_pa_valid_roles_msg//,/, }"
  if [ -z "$_pa_role" ]; then
    echo "pipeline-vcs: post-approval: missing role (valid: ${_pa_valid_roles_msg})" >&2
    exit 1
  fi
  _pa_role_valid=false
  _pa_label=""
  for _pa_i2 in "${!TALOS_APPROVAL_ROLES[@]}"; do
    if [ "${TALOS_APPROVAL_ROLES[$_pa_i2]}" = "$_pa_role" ]; then
      _pa_role_valid=true
      _pa_label="${TALOS_APPROVAL_LABELS[$_pa_i2]%%|*}"
      break
    fi
  done
  if [ "$_pa_role_valid" = "false" ]; then
    echo "pipeline-vcs: post-approval: unknown role '$_pa_role' (valid: ${_pa_valid_roles_msg})" >&2
    exit 1
  fi

  # Validate body-file if provided
  if [ -n "$_pa_body_file" ] && [ ! -r "$_pa_body_file" ]; then
    echo "pipeline-vcs: post-approval: --body-file: cannot read '$_pa_body_file'" >&2
    exit 1
  fi

  if [ "$DRY_RUN" = "true" ]; then
    printf '[dry-run] post-approval: would fetch head SHA for PR #%s, post marker role=%s, add label %s\n' \
      "$_pa_n" "$_pa_role" "$_pa_label"
    exit 0
  fi

  # (#554) This pass shares one set of reads between the verbs it spawns (see
  # "Per-pass read cache"): the PR, its comments and the login are read once
  # before the writes and once after them. _talos_on_exit removes the directory.
  _pa_cache="$(mktemp -d "${TMPDIR:-/tmp}/talos-pass.XXXXXX" 2>/dev/null)" && {
    printf '%s' "$$" > "$_pa_cache/owner" && export TALOS_PASS_CACHE="$_pa_cache" \
      && _talos_on_exit 'rm -rf "$_pa_cache"'
  }

  # (#549) Tag the calling stage's worktree for its issue, so the sweeps and the
  # post-merge `remove <N>` find it (#240). Best effort: the main checkout is
  # refused by `tag`, and a stage with no worktree has nothing to tag.
  if [ -n "$_pa_issue" ] && [ -f "$SCRIPT_DIR/pipeline-worktree.sh" ]; then
    bash "$SCRIPT_DIR/pipeline-worktree.sh" tag "$_pa_issue" >/dev/null 2>&1 || :
  fi

  # (#549) The verb checks its own stamp, so no stage runs a second command to
  # confirm it. Only "all approval labels are current" counts as ok:
  # check-approval-sha also exits 0 for "no approval labels present", which here
  # means the label never landed. Another role's stale approval (reported as a
  # `stale role=<other>` line, and never this role's) is that role's gate to
  # clear, so it does not fail this stamp; it is named on the line. Anything
  # else -- an unreadable PR, a stale entry of this role, no stale list at all
  # -- fails closed. Prints the one result line; its exit status is the verb's.
  # $1 = what was done ("marker posted and qa:pass label applied").
  _pa_result() {
    local _r_out _r_rc _r_why _r_stale
    _r_out="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" check-approval-sha "$_pa_n" --stale-list \
      ${REPO:+--repo "$REPO"} 2>&1)"; _r_rc=$?
    if [ "$_r_rc" -eq 0 ] && grep -q 'all approval labels are current' <<<"$_r_out"; then
      printf 'post-approval: PR #%s %s %s; stamp ok\n' "$_pa_n" "$_pa_role" "$1"
      return 0
    fi
    _r_stale="$(printf '%s\n' "$_r_out" | sed -n 's/^stale role=\([a-z]*\) label=.*/\1/p' | paste -sd, -)"
    if [ "$_r_rc" -ne 0 ] && [ -n "$_r_stale" ]; then
      case ",$_r_stale," in
        *",$_pa_role,"*) ;;
        *)
          printf 'post-approval: PR #%s %s %s; stamp ok (stale elsewhere: %s)\n' "$_pa_n" "$_pa_role" "$1" "$_r_stale"
          return 0
          ;;
      esac
    fi
    _r_why="$(printf '%s\n' "$_r_out" | grep -v '^[[:space:]]*$' | head -n 1 | tr -cd '[:print:]' | cut -c1-160)"
    printf 'post-approval: PR #%s %s %s; stamp FAILED (check-approval-sha rc=%s: %s)\n' \
      "$_pa_n" "$_pa_role" "$1" "$_r_rc" "${_r_why:-no output}"
    return 1
  }

  # Fetch head SHA from the PR head -- not from the local worktree.
  # git rev-parse HEAD returns the agent's checkout, which may differ from the
  # PR head after a push or rebase (#85). Same call as pr-head verb.
  # Use 2>/dev/null so that any future warning on stderr does not corrupt the
  # SHA variable; exit status alone signals failure.
  _pa_sha="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" pr-head "$_pa_n" \
    ${REPO:+--repo "$REPO"} 2>/dev/null)" || {
    echo "pipeline-vcs: post-approval: could not resolve head SHA for PR #$_pa_n" >&2
    exit 1
  }
  # Validate SHA: must be exactly 40 lowercase hex characters before it enters
  # the marker. An internally derived value can still be wrong if the provider
  # API returns unexpected data (PR #68 discipline).
  case "$_pa_sha" in
    *[!0-9a-f]*|"")
      echo "pipeline-vcs: post-approval: invalid SHA from pr-head: '$_pa_sha'" >&2
      exit 1
      ;;
  esac
  if [ "${#_pa_sha}" -ne 40 ]; then
    echo "pipeline-vcs: post-approval: SHA must be 40 hex chars, got ${#_pa_sha}: '$_pa_sha'" >&2
    exit 1
  fi

  # Construct the marker body. The marker is a fixed template with only two
  # interpolated values: the SHA (validated 40-char hex from headRefOid) and
  # the role (validated member of _PA_VALID_ROLES). No config text, no API
  # response text, no caller-supplied strings enter the marker value (PR #68).
  _pa_marker="<!-- talos:approval sha=${_pa_sha} role=${_pa_role} -->"

  # ── Duplicate-marker detection (#172, restores what d7aedf2 removed) ──────
  # Fetch every PR comment (paginated via the shared read-comments verb --
  # _gh_comments; see the read-comments arm) and check whether this exact marker
  # already exists as the last non-whitespace line of any comment (same
  # last-line rule as read-attempt/check-approval-sha, #79). A different SHA
  # is a different marker string and always posts (re-stamp after a head
  # change). Fail-closed: if the fetch itself cannot complete, post nothing.
  _pa_comments_json="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" read-comments "$_pa_n" \
    ${REPO:+--repo "$REPO"} 2>/dev/null)"
  _pa_comments_rc=$?
  if [ $_pa_comments_rc -ne 0 ] || [ -z "$_pa_comments_json" ]; then
    echo "pipeline-vcs: post-approval: could not fetch PR #$_pa_n comments for duplicate check" >&2
    exit 1
  fi
  _pa_dup="$(printf '%s' "$_pa_comments_json" | PA_MARKER="$_pa_marker" python3 -I -c "
import json, os, sys
marker = os.environ.get('PA_MARKER', '')
try:
    data = json.load(sys.stdin)
except Exception:
    print('error')
    sys.exit(0)
for c in data.get('comments', []):
    body = c.get('body', '') or ''
    last_line = body.rstrip().rsplit('\n', 1)[-1].strip()
    if last_line == marker:
        print('found')
        sys.exit(0)
print('none')
")"
  if [ "$_pa_dup" = "error" ]; then
    echo "pipeline-vcs: post-approval: could not parse PR #$_pa_n comments for duplicate check" >&2
    exit 1
  fi
  if [ "$_pa_dup" = "found" ]; then
    echo "pipeline-vcs: post-approval: $_pa_role marker already exists at $_pa_sha; not posting again" >&2
    # Apply the label defensively — a missing label alongside an existing
    # marker must still self-heal (label-pr is idempotent).
    bash "$SCRIPT_DIR/pipeline-vcs.sh" label-pr "$_pa_n" --add "$_pa_label" >/dev/null || {
      echo "pipeline-vcs: post-approval: label-pr failed for PR #$_pa_n" >&2
      exit 1
    }
    _pa_result "marker already present at $_pa_sha; $_pa_label label ensured"
    exit $?
  fi

  _pa_tmpfile="$(mktemp)"
  # (#169) composable hook, not a bare `trap ... EXIT` -- pipeline-cfg-cache.sh
  # already registered its own cleanup for the config cache dir, and a bare
  # `trap ... EXIT` here would silently clobber it.
  _talos_on_exit 'rm -f "$_pa_tmpfile"'
  if [ -n "$_pa_body_file" ]; then
    cat "$_pa_body_file" > "$_pa_tmpfile"
    printf '\n%s\n' "$_pa_marker" >> "$_pa_tmpfile"
  else
    printf '%s\n' "$_pa_marker" > "$_pa_tmpfile"
  fi

  # Post via comment-pr so write-time validation (#110/#132) applies automatically.
  # No _TALOS_POST_APPROVAL_INTERNAL guard needed: comment-pr is invoked as a
  # subprocess whose stderr is captured into _pa_comment_url via 2>&1 -- any
  # marker-detection warning it emits is absorbed into the output variable and
  # not forwarded to the caller's stderr. Do not re-add the guard: it was
  # blocked on #151 as an externally-settable bypass.
  _pa_comment_url=""
  _pa_comment_url="$(bash "$SCRIPT_DIR/pipeline-vcs.sh" comment-pr "$_pa_n" \
    --body-file "$_pa_tmpfile" 2>&1)" || {
    echo "pipeline-vcs: post-approval: comment-pr failed for PR #$_pa_n" >&2
    rm -f "$_pa_tmpfile"
    exit 1
  }
  rm -f "$_pa_tmpfile"

  # Apply approval label via label-pr (both halves in one operation --
  # label-without-marker eliminated (marker posts first); marker-without-label
  # remains possible if label-pr fails, surfaced loudly by exit 1 -- #144).
  # Do NOT pass --repo here: label-pr's _parse_label_args has no --repo case,
  # so it falls through to the catch-all and treats "--repo" as a label name.
  # label-pr resolves $REPO independently from the config.
  bash "$SCRIPT_DIR/pipeline-vcs.sh" label-pr "$_pa_n" --add "$_pa_label" >/dev/null || {
    echo "pipeline-vcs: post-approval: label-pr failed for PR #$_pa_n" >&2
    exit 1
  }

  _pa_result "marker posted and $_pa_label label applied"
  exit $?
fi

# ── conflict-files: mechanical-merge eligibility check (#256) ────────────────
# GitHub-only (github and github-api providers), single shared implementation
# -- see _vcs_shared_conflict_files's header comment. Same top-level-gated-
# block shape as has-spec/post-approval above (a verb backed by one shared
# helper, reachable from both providers without duplicating a case arm into
# each provider's own dispatch function).
if [ "$VERB" = "conflict-files" ]; then
  if [ "$PROVIDER" != "github" ] && [ "$PROVIDER" != "github-api" ]; then
    echo "pipeline-vcs: conflict-files: not implemented for provider '$PROVIDER'" >&2
    exit 1
  fi
  _cf_n="${ARGS[0]:-}"
  if [ -z "$_cf_n" ]; then
    echo "pipeline-vcs: conflict-files: missing PR number" >&2
    exit 1
  fi
  case "$_cf_n" in
    ''|*[!0-9]*)
      echo "pipeline-vcs: conflict-files: PR number must be an integer, got '$_cf_n'" >&2
      exit 1
      ;;
  esac

  # Same base-branch resolution as assert-sync: configured value first, then
  # origin/HEAD's symbolic ref, else 'main'.
  _cf_base="$BASE_BRANCH"
  if [ -z "$_cf_base" ]; then
    _cf_base="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')"
  fi
  [ -z "$_cf_base" ] && _cf_base="main"

  if [ "$DRY_RUN" = "true" ]; then
    printf '[dry-run] conflict-files: git fetch origin refs/pull/%s/head %s; attempt a throwaway merge in a detached temp worktree; print conflicting paths\n' \
      "$_cf_n" "$_cf_base"
    exit 0
  fi

  _vcs_shared_conflict_files "$_cf_n" "$_cf_base"
  exit $?
fi

# ── Main dispatch ─────────────────────────────────────────────────────────────
_vcs_dispatch_provider() {
  case "$PROVIDER" in
    github|github-api) _github "$VERB" "${ARGS[@]+"${ARGS[@]}"}" ;;
    gitlab)     _gitlab     "$VERB" "${ARGS[@]+"${ARGS[@]}"}" ;;
    azure)      _azure      "$VERB" "${ARGS[@]+"${ARGS[@]}"}" ;;
    file)       _file       "$VERB" "${ARGS[@]+"${ARGS[@]}"}" ;;
    *)
      echo "pipeline-vcs: unknown provider '$PROVIDER'. Valid: github | github-api | gitlab | azure | file" >&2
      exit 1
      ;;
  esac
}

# Write journal (#418): append the verb name (no body) to $TALOS_WRITE_LOG after
# a successful non-idempotent verb. Callers pass only a success (rc 0). Reached
# from the main flow below and from _vcs_draft_gate_dispatch, which exits itself
# and so skipped the journal for `create-pr --draft` (#449). Unset: no-op.
_vcs_journal_write() {
  { [ -n "${TALOS_WRITE_LOG:-}" ] && [ "$DRY_RUN" != "true" ]; } || return 0
  case "$VERB" in
    comment-issue|comment-pr|edit-pr-body|create-pr|create-issue|post-approval|approve-pr|merge-pr|close-issue|record-attempt)
      printf '%s\n' "$VERB" >>"$TALOS_WRITE_LOG" 2>/dev/null || true ;;
  esac
}

# Draft verbs (#332) answer a gate ("is this PR ready for QA?"), so an adapter's
# setup failure (no token, unknown provider, missing CLI: exit 1) must never read
# as a result. Run the verb in a subshell and let only its exact success shapes
# through; everything else, whatever the adapter exited with, is exit 2 with
# nothing on stdout (the adapter's stderr has already explained why).
#   pr-is-draft   exit 0 only with stdout "draft"; exit 1 only with stdout "ready"
#   pr-ci-runs    exit 0 only with a non-negative integer on stdout
#   ready-pr, draft-pr, create-pr --draft   exit 0 only when the provider call succeeded
# --dry-run verifies nothing: the pr-is-draft / pr-ci-runs preview goes to
# stderr and the exit is 2.
_vcs_draft_gate_dispatch() {
  local _g_out _g_rc
  _g_out="$(_vcs_dispatch_provider)"; _g_rc=$?
  case "$VERB" in
    pr-is-draft)
      if [ "$DRY_RUN" != "true" ]; then
        if [ "$_g_rc" -eq 0 ] && [ "$_g_out" = "draft" ]; then echo draft; exit 0; fi
        if [ "$_g_rc" -eq 1 ] && [ "$_g_out" = "ready" ]; then echo ready; exit 1; fi
      fi
      ;;
    pr-ci-runs)
      if [ "$DRY_RUN" != "true" ] && [ "$_g_rc" -eq 0 ]; then
        case "$_g_out" in
          ''|*[!0-9]*) ;;
          *) printf '%s\n' "$_g_out"; exit 0 ;;
        esac
      fi
      ;;
    *)
      if [ "$_g_rc" -eq 0 ]; then
        [ -n "$_g_out" ] && printf '%s\n' "$_g_out"
        _vcs_journal_write
        exit 0
      fi
      ;;
  esac
  [ "$DRY_RUN" = "true" ] && [ -n "$_g_out" ] && printf '%s\n' "$_g_out" >&2
  exit 2
}

# pr-checks-required <n> --wait <seconds> (#355): poll the verb in one call, so
# a worktree-isolated stage needs no inline `until ... sleep` loop. Same exit
# codes and stderr lines as a single read; 2 only when still pending at the
# deadline. The flag is validated for every provider (digits, at most 3600,
# else exit 2 with usage); only github and github-api poll, the others drop it
# and answer once, exactly as before. Without --wait nothing here runs. The
# deadline is the larger of wall time and the summed nominal sleeps, so
# TALOS_RETRY_SLEEP_SCALE=0 makes a test instant and still deterministic. The
# poll interval backs off 30 s -> 60 s -> 120 s (#554).
_vcs_pr_checks_required_dispatch() {
  local _w="" _keep=() _i=0 _a _start _slept=0 _polls=0 _el _left _step _scale _rc
  while [ "$_i" -lt "${#ARGS[@]}" ]; do
    _a="${ARGS[$_i]}"
    if [ "$_a" = "--wait" ]; then
      _i=$((_i + 1))
      _w="${ARGS[$_i]-}"
      case "$_w" in
        ''|*[!0-9]*) _w="bad" ;;
        *) [ "${#_w}" -gt 4 ] && _w="bad" ;;
      esac
      # Digits only, so force base 10: `[ 08 -gt 3600 ]` and `$((_w - ...))` read
      # a leading zero as octal and fail on 08/09 (#449). `0010` waits 10 s.
      if [ "$_w" != "bad" ]; then
        _w=$((10#$_w))
        [ "$_w" -gt 3600 ] && _w="bad"
      fi
      if [ "$_w" = "bad" ]; then
        echo "pipeline-vcs: pr-checks-required: --wait needs <seconds>, digits, at most 3600" >&2
        echo "Usage: pipeline-vcs.sh pr-checks-required <n> [--wait <seconds>]" >&2
        exit 2
      fi
    else
      _keep+=("$_a")
    fi
    _i=$((_i + 1))
  done
  [ -z "$_w" ] && { _vcs_dispatch_provider; return; }
  ARGS=("${_keep[@]+"${_keep[@]}"}")
  if [ "$DRY_RUN" = "true" ] || { [ "$PROVIDER" != "github" ] && [ "$PROVIDER" != "github-api" ]; }; then
    _vcs_dispatch_provider; return
  fi
  _scale="${TALOS_RETRY_SLEEP_SCALE:-1}"
  case "$_scale" in ''|*[!0-9.]*) _scale=1 ;; esac
  _start=$SECONDS
  while :; do
    ( _vcs_dispatch_provider ); _rc=$?
    [ "$_rc" -ne 2 ] && break
    _el=$((SECONDS - _start)); [ "$_slept" -gt "$_el" ] && _el=$_slept
    _left=$((_w - _el))
    [ "$_left" -le 0 ] && break
    # Back off: 30 s, 60 s, then 120 s (#554) -- a CI run takes minutes, and every
    # poll is two REST reads, so a fixed 30 s step spent most of them on "pending".
    case "$_polls" in 0) _step=30 ;; 1) _step=60 ;; *) _step=120 ;; esac
    _polls=$((_polls + 1))
    [ "$_left" -lt "$_step" ] && _step=$_left
    sleep "$(awk -v s="$_step" -v k="$_scale" 'BEGIN { print s * k }')"
    _slept=$((_slept + _step))
  done
  return "$_rc"
}

_DISPATCH_RC=0
case "$VERB" in
  pr-checks-required) _vcs_pr_checks_required_dispatch ;;
  pr-is-draft|pr-ci-runs|ready-pr|draft-pr) _vcs_draft_gate_dispatch ;;
  create-pr) if [ "$_PR_DRAFT" = "true" ]; then _vcs_draft_gate_dispatch; else _vcs_dispatch_provider; fi ;;
  *) _vcs_dispatch_provider ;;
esac
_DISPATCH_RC=$?

# ── Write journal (#418) ──────────────────────────────────────────────────────
# pipeline-agent.sh exports TALOS_WRITE_LOG to a runner when a failover chain is
# configured; a successful non-idempotent verb appends its name (no body) so a
# provider failure after a write is never rerun on another runner. Unset: no-op.
[ "$_DISPATCH_RC" -eq 0 ] && _vcs_journal_write

# ── Post-dispatch: label-pr approval-marker warning (#94, #115) ──────────────
# After label-pr successfully adds a recognised approval label, verify that a
# matching marker comment exists at the current head.  Fetches headRefOid and
# comments directly — no label re-read, no race window (#115).  Exit remains 0
# (profiles label before stamping; the merge gate is the hard enforcement).
# Only runs for the github provider.
#
# Invariant: _ADDING_APPROVAL_LABELS is known locally; no remote label fetch is
# needed.  The only remote reads are headRefOid (cheap) and comments (already
# present in the PR object).  The race that plagued check-approval-sha cannot
# occur here because we never re-read the labels we just applied.
if [ "$VERB" = "label-pr" ] && [ -n "${_ADDING_APPROVAL_LABELS:-}" ] \
    && [ "${_REQUIRE_MARKER:-false}" = "false" ] && [ "$DRY_RUN" != "true" ] \
    && { [ "$PROVIDER" = "github" ] || [ "$PROVIDER" = "github-api" ]; } && [ "$_DISPATCH_RC" -eq 0 ]; then
  _pd_missing=false
  if _pd_stamped="$(_vcs_stamped_roles "$_LABEL_PR_N")"; then
    for _pd_lbl in $_ADDING_APPROVAL_LABELS; do
      _vcs_label_stamped "$_pd_lbl" "$_pd_stamped" || { _pd_missing=true; break; }
    done
  fi
  if [ "$_pd_missing" = "true" ]; then
    echo "pipeline-vcs: label-pr: WARNING — added approval label(s) but no approval marker found at current head." >&2
    echo "pipeline-vcs: label-pr: If you have not already posted your verdict reasoning, do so first." >&2
    echo "pipeline-vcs: label-pr: The gate will reject this PR. Post the marker:" >&2
    for _lp_wl in $_ADDING_APPROVAL_LABELS; do
      printf 'pipeline-vcs:   bash scripts/pipeline-vcs.sh post-approval %s %s\n' \
        "$_LABEL_PR_N" "$(_vcs_label_role "$_lp_wl")" >&2
    done
  fi
fi

# ── Post-dispatch: comment-pr hand-built marker warning (#146) ────────────────
# After comment-pr successfully posts, warn when the body's final non-whitespace
# line is a hand-built talos:approval HTML comment. The check is scoped to the
# last non-whitespace line only (#140: prose discussing the marker format does
# not trigger this). GitHub-only. Exit remains 0 (nudge, not a wall).
if [ "$VERB" = "comment-pr" ] && [ "$_DISPATCH_RC" -eq 0 ] \
    && [ "$DRY_RUN" != "true" ] \
    && { [ "$PROVIDER" = "github" ] || [ "$PROVIDER" = "github-api" ]; }; then
  _cp_warn_body="${ARGS[1]-}"
  if [ -n "$_cp_warn_body" ]; then
    printf '%s' "$_cp_warn_body" | python3 -I -c "
import re, sys
body = sys.stdin.read()
stripped = body.rstrip()
last_line = stripped.rsplit('\n', 1)[-1].strip()
MARKER_RE = re.compile(r'<!--\s*talos:approval\b[^>]*-->')
if MARKER_RE.match(last_line):
    sys.stderr.write(
        'pipeline-vcs: comment-pr: warning -- body ends with a hand-built'
        ' talos:approval marker; use post-approval instead to ensure'
        ' correct format and label application\n'
    )
" || true
  fi
fi

exit "$_DISPATCH_RC"
