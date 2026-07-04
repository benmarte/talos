# GitHub Actions driver (experimental, unmaintained)

An earlier design drove the pipeline with `anthropics/claude-code-action` on
issue/label events instead of a local orchestrator session. It is kept here for
reference only — it is NOT the supported path and will fire Actions runs on
every pipeline-labeled issue/PR if installed.

To experiment with it, copy `pipeline.yml` to `.github/workflows/` in your repo
and provision `ANTHROPIC_API_KEY` as a repo secret. The supported path is the
local orchestrator: see the main README.
