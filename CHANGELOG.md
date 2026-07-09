# Changelog

## Unreleased

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
