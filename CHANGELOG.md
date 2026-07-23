# Changelog

## [Unreleased]

## [0.3.0] - 2026-07-23

### Added

- **`merge.auto` toggle (human-merge mode)** — default `true`; when `false` the orchestrator runs every stage and gate (approval labels, `skip-qa` rules, forbidden files, CI) but stops at `pipeline:approved` with a "ready for human merge" PR comment instead of merging. The issue stays open and closes via the reconciliation sweep after the human merges. New `templates/comments/approved.md` template; documented in `talos.pipeline.yml.example` and the user guide. (9ddeba6)
- **Antigravity harness support** — named runner (`agy -p`) and `--harness antigravity` install support. (a460990)
- **Provider coverage tests** — regression suite now exercises every verb in the gitlab and azure adapters and all three Teams notification paths (debug, real AdaptiveCard post, silent no-op) via new `tests/test-providers.sh` + extended `tests/stubs/glab` + new `tests/stubs/az`. (3ec23f3)

### Fixed

- **Developer test-type mandate** — the developer stage now requires unit/component tests, a failing-first regression test on bug fixes, and an e2e test for user-facing changes when the repo has an e2e harness (`playwright.config.*` / `cypress.config.*` / `tests/e2e/` / `test:e2e` detection); the PR body must list test types added or skipped-with-reason. (11e4321)
- **Azure**: split org_arg into separate argv elements in the label-issue subprocess call so `az` receives `--org` and the URL as distinct arguments. (76d8041)
- **Self-run hardening** — SKILL.md rule + reviewer/security prompts prohibit `git checkout` in shared repo; re-approval paths clear `pipeline:blocked`; CHANGELOG serialization guard in Step 4; developer stage drops self-reported test counts; same-account `gh pr review --approve` failure documented as ignorable; `github-api` provider logs `X-RateLimit-Reset` on HTTP 429. (a315600)

## [0.2.0] - 2026-07-09

### Breaking Changes

- **Install layout moved to `.claude/talos/`** (was `.claude/pipeline/`). Re-run `install.sh` or move your directory manually. (8654d69)
- **`pipeline-notify.sh` now loads `.env` from repo root only** (`<repo-root>/.env` via `git rev-parse --show-toplevel`). Move any credentials from `.claude/talos/.env` (or `.claude/pipeline/.env`) to your repository root `.env`. Dotenv precedence: exported env vars always win over `.env` values. (1e27cbb)

### Added

- **Multi-harness support**: Codex CLI, Gemini CLI, and custom/local runners configurable in `pipeline-agent.sh` — Talos is no longer Claude-only. (9fa4c61)
- **Optional planner role**: new `roles.planner` toggle (default `false`). When enabled, a planner stage decomposes epics into dependency-ordered sub-issues before the PM/developer stages. Epics are detected by label, checklist count (>= 4), or body length (>= 2000 chars). (3e1a0a7)
- **Offline regression suite + e2e pipeline simulation** with stubbed `gh`/`curl` — full test coverage with no network dependency. (903527a)
- **Linked rich notifications**: messages now link to their GitHub issue/PR; notification templates are shipped automatically by `install.sh`. (e7de0d5)
- **Daedalus-style Talos-branded notifications** with install and label fixes. (848fcf5)
- **`github-api` provider**: token-only GitHub mode — all 18 VCS verbs via `curl + GITHUB_TOKEN` (REST + GraphQL for Projects v2). No `gh` CLI dependency required. (39e80d2)
- **Plugin marketplace manifest** (`.claude-plugin/marketplace.json`) — enables `/plugin marketplace add benmarte/talos` install flow. (7e66974)
- **Session-hardening batch**: recovery/reconciliation, find-pr, forbidden-files gate, priority handling, skip-qa flag, and CI retry support. (8a0fee4)

### Fixed

- Grant `Skill` tool access to `qa`, `reviewer`, and `security` role profiles — these roles were previously missing the tool permission. (9404d43)
- Dry-run variants and GitLab fail-open test coverage for all hardening verbs. (38b2d3a)

### Changed

- **Config renamed to `talos.pipeline.yml`** — legacy `.claude-pipeline.yaml`/`pipeline.yaml` are still honored; `talos.pipeline.yml` wins when both exist. No migration required for v0.1.0 configs. (f99eb97)
- **`/pipeline-setup` wizard** now prompts for agent harness (claude/codex/gemini/custom), emits `forbidden_files` defaults, and covers control labels in the generated `talos.pipeline.yml` template. (593f040)
- **Docs**: user guide expanded with per-harness setup, prerequisites, env vars, feature matrix, llama.cpp local-model recipe, and a worked example wiring `addyosmani/agent-skills` into role profiles. (40bc1c8, 88700d2, 21e5dd6)

## [0.1.0] - 2026-07-04

Initial release — autonomous issue-to-PR pipeline orchestrated by Claude Code.

### Added

- Orchestrator (`pipeline-orchestrator.sh`) driving validator -> PM -> developer -> QA -> reviewer -> security -> docs stages via labelled GitHub issues.
- Worktree-isolated developer subagent with per-issue git worktrees.
- VCS abstraction (`pipeline-vcs.sh`) with `github`, `gitlab`, `azure`, and `file` providers.
- Notification system (`pipeline-notify.sh`) with Hermes/ntfy/Slack adapters.
- Pipeline status dashboard (`pipeline-status.sh`).
- Setup wizard (`/pipeline-setup` skill).
- Claude Code plugin manifest (`.claude-plugin/plugin.json`) for marketplace install.
