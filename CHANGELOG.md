# Changelog

## Unreleased

### Added

#### Issue #2 — Plugin marketplace manifest + doc fix

Added `.claude-plugin/marketplace.json` so the Claude Code plugin marketplace flow works end-to-end (`/plugin marketplace add benmarte/talos` + `/plugin install talos@talos`). Updated README Quickstart Option A and `docs/user-guide.md` Setup: Claude Code section to document the plugin path as the recommended install with a caveat that per-repo scripts/templates still come from `install.sh`.

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
