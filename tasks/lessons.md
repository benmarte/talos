# Lessons

## 2026-09-07: delegate to cheaper models

- Ben asked that work be delegated to cheaper subagents. The orchestrating session should only plan, decide, and synthesise.
- Rule: spawn Sonnet for implementation and research, Haiku for read-only lookups and docs. Never do bulk file reading in the main session.
- Talos routing lives in `talos.pipeline.json` under `agents.model` (Haiku) and `agents.roles.<role>.model` (Sonnet for developer, pm, qa, reviewer, security). Escalate one role at a time if it fails, never the global default.
