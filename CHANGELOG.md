# Changelog

## Unreleased

### Added

#### Issue #2 — Plugin marketplace manifest + doc fix

Added `.claude-plugin/marketplace.json` so the Claude Code plugin marketplace flow works end-to-end (`/plugin marketplace add benmarte/talos` + `/plugin install talos@talos`). Updated README Quickstart Option A and `docs/user-guide.md` Setup: Claude Code section to document the plugin path as the recommended install with a caveat that per-repo scripts/templates still come from `install.sh`.

#### Issue #7 — Optional planner role: epic decomposition

New optional `roles.planner` toggle (default `false`). When enabled, a planner stage
runs after the validator confirms an issue and before the PM writes the spec. An issue
is treated as an epic if it carries the `epic` label, contains ≥ 4 checklist items,
or has a body ≥ 2000 characters. The planner subagent (Claude Opus, read-only) produces
a structured breakdown of up to 10 sub-tasks; the orchestrator creates dependency-ordered
sub-issues via the new `create-issue` VCS verb. Independent sub-issues are labelled
`pipeline:ready` immediately; dependent sub-issues are held unlabelled and auto-unblocked
when their predecessor closes. Epic issues receive `pipeline:epic-decomposed` and skip
the PM/developer stages. Step 1 reconciliation adds two new sweeps: an epic auto-close
sweep (closes the epic when all sub-issues are resolved) and a dependency-unblocking
sweep (adds `pipeline:ready` to sub-issues whose blocker just closed). The new
`create-issue` verb is supported across all four providers (github, github-api, gitlab,
azure, file). The planner is off by default — it adds no overhead when disabled.

#### Story #6 — `github-api` provider: token-only GitHub mode

New `vcs.provider: github-api` adapter implements all 18 VCS verbs via
`curl + GITHUB_TOKEN` (REST for issues/PRs/labels/merge; GraphQL for Projects
v2 board) so Talos runs in CI containers with no `gh` CLI dependency. Token
is sourced from `GITHUB_TOKEN` or `GH_TOKEN` (or a custom env var named by
`vcs.token_env`) and is never logged. `pipeline-status.sh` falls back to the
token-based GraphQL path automatically when `gh` is absent.
`pipeline-notify.sh` uses the token to resolve issue/PR titles and repo URL
when `gh` is unavailable. Covered by 47 new assertions in
`tests/test-github-api.sh` using the curl stub (no network).

### Breaking Changes

#### Story #3 / Issue #5 — `pipeline-notify.sh` .env path change

`pipeline-notify.sh` previously sourced `.env` from a script-relative path that
resolved to `.claude/talos/.env` (or `.claude/pipeline/.env`) in installed
repos. This was accidental and surprising.

**New behaviour (>= v0.2.0):**

- The pipeline loads exactly one `.env` file: `<repo-root>/.env`, resolved via
  `git rev-parse --show-toplevel` (falls back to `$PWD` outside a git repo).
- **Dotenv precedence**: exported environment variables always win over `.env`
  values — only currently-unset variables are assigned from the file.
- `~/.hermes/.env` bot-token convenience fallback is unchanged.

**Migration:** move any credentials from `.claude/talos/.env` (or
`.claude/pipeline/.env`) to your repository root `.env`. If you relied on
sourcing overwriting exported vars, export them explicitly instead.

### Enhancements

- **`/pipeline-setup` wizard** now prompts for agent harness (claude/codex/gemini/custom) and emits `forbidden_files` defaults in the generated `talos.pipeline.yml` template (#4).
