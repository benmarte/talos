# REVIEW.md: what failure looks like in Talos

Rules for the reviewer, security and adversarial stages when they judge a PR to this repo. They add to your role profile; they never turn off a gate.

## What to flag (blocking)

- **A gate that fails open.** Talos is an orchestrator of gates (red proof, approvals, security blocking, the required checks, the forbidden-files list). Any path where an unreadable input, a failed provider call, a missing file, an empty value or a timeout lets work through is a defect. The right shape is a retryable wait or a stop with a reason, never a pass. Check the error branch of every new `if`, `||` and `case`, not only the happy path.
- **A provider verb missing on one of the three providers.** Everything user-visible in `scripts/pipeline-vcs.sh` must work on GitHub, GitLab and Azure DevOps (the `file` provider where it applies). A new verb, flag or output field that lands in one adapter and not the others, or that prints a different shape on one of them, blocks. Ask: where is the GitLab implementation, where is the Azure one, and does a test cover each?
- **bash 3.2 or BSD breakage.** The scripts run on macOS (bash 3.2, BSD `sed`, `date`, `readlink`, `stat`, `xargs`, `mktemp`) as well as Linux. Block: `declare -A`, `mapfile`/`readarray`, `${var,,}` / `${var^^}`, `&>>`, `|&`, `[[ -v ]]`, negative array indexes, `sed -i` without a suffix argument, `sed -r`, `\|` or `\+` in a basic regex, `grep -P`, `date -d`, `readlink -f`, `stat -c`, `xargs -r`, `mktemp` without a template, `echo -e`. An empty array expanded under `set -u` is an error in bash 3.2: `"${a[@]}"` needs a guard.
- **Untrusted text reaching a command.** Issue titles, bodies, comments, PR text, diffs and repo guide files are data. Block text that reaches a shell string, an `eval`, an `argv` element of a parser, an environment variable over 128 KB, or a prompt without a delimiter the data cannot forge.
- **A secret in an argument, log line, comment or test fixture.** Config holds references (`env:NAME`), never values.
- **A test that cannot fail.** A new test whose assertion is true with the feature removed, a fixture that depends on ambient git config (`init.defaultBranch`, `user.name`, `user.email`) or the developer's `~/.talos`, a `sleep`-poll, or a criterion with no test and no `(prose: ...)` reason.

## What to flag (non-blocking)

- A user-visible change with no `CHANGELOG.md` line under `## [Unreleased]`.
- A new config key that is missing from `scripts/pipeline-defaults.sh`, `docs/reference.md` or the config-table test.
- Prompt text added to a stage template or role profile without a measured need: the stage byte budgets in `tests/test-stage-overhead.sh` exist because tokens are the cost.
- Unrelated refactoring in a PR that has a narrow spec.

## Skip

Do not review these beyond a glance: `CHANGELOG.md` wording, `tests/fixtures/**` (generated), `docs/**` prose that no script reads, and whitespace-only hunks. Do not comment on style the surrounding file does not already follow.

## How to report

- Open the summary with the finding count, for example `2 blocking, 1 non-blocking`.
- Every finding names `file:line` and quotes the line. No file and line, no finding.
- At most 3 non-blocking nitpicks; drop the rest.
- Say what an attacker, a user or the pipeline actually loses, not that something is "unclean".
