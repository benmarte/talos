# Harness, runners, adapter, inline mode, failover

Read when `talos.sh env` prints `ref=harness`: `agents.subagents` is false, the global runner is not `claude`, a role's runner is not `claude`, or a fallback chain is set.

**Settings.** `agents.subagents` (`auto` = true when the global runner is `claude`) and `agents.runner` (`claude|pi|codex|gemini|antigravity|custom`). Per role: `agents.roles.<role>.runner` else `agents.runner` (`pipeline-agent.sh --resolve` shows it). On the native path (`subagents: true`) a `claude` role spawns natively; any other role goes through `pipeline-agent.sh <role> -` while the rest of the pipeline stays native. The adapter path exports the resolved effort as `TALOS_EFFORT` (empty when unset).

**Role profile order** (adapter and pi-inline paths): `$PWD/.claude/agents/<role>.md`; `$PWD/.agents/talos/agents/<role>.md` (a symlink is ignored); the install's `agents/`; self-relative fallbacks. `bash scripts/pipeline-agent.sh --resolve-profile <role>` prints the one that wins. A natively run role is overridden in `.claude/agents/`.

**Native path detail.** `model:` of a spawn is `agent.<role>.model` (`agents.roles.<role>.model`, else `agents.model`; the project config wins over the user-level file), else the session model. The shipped `agents/*.md` carry no `model:` line. A value may be a full model ID or one of the aliases `opus`/`sonnet`/`haiku`; a harness that accepts only aliases takes the family alias for a full ID, and the config value itself is never rewritten (`--resolve-all` shows the routing). Effort has no per-spawn parameter and the orchestrator never writes a tracked file: config effort is advisory, so relay `agent.<role>.effort_notice` when Step 0 printed one (`bash scripts/pipeline-agent.sh --check-effort <role>` prints it). The adapter path applies `TALOS_EFFORT`.

**`subagents: false` + `runner: pi`: inline mode.** You act as each stage role yourself. For every "spawn a subagent" step:
1. `bash scripts/pipeline-agent.sh --resolve-profile <role>` prints one absolute path (non-zero with the locations searched when there is none). Read it; strip the YAML frontmatter, use only the body.
2. Adopt the role: role body plus stage prompt are your current instructions, carried out inline.
3. Run `talos.sh done` after each stage, then continue. pi runs in the orchestrator's checkout (developer: branch from a clean tree; dirty means stop).

**`subagents: false` + any other runner.** Replace every "spawn" step with:

```bash
bash scripts/pipeline-agent.sh <role> - < "$PROMPT_FILE"
```

`PROMPT_FILE` is the `prompt_file=` path (the prompt text never touches a command line). The adapter finds the role definition itself and combines it with the stage prompt. There are no native subagents: developer stages run sequentially, `max_parallel: 1`.

**Usage on these paths.** Named and adapter-path spawns report no input/output split, no model and no dollar cost (completion without usage is expected there, so omit `--tokens`, `--tool-uses`, `--duration-s`); they show as `unrecorded` in the spend line, not as zero.

**Provider failover.** `agents.fallback` reruns a provider-error death (exit 75: rate limit, quota, overload, auth, network) on the next runner unless the attempt wrote. Exit **69** = exhausted, or refused after a write: no `record-attempt`, no fix round. Set `pipeline:blocked` on the issue (and PR), relay the stderr line, post blocked.md with BLOCKED_BY="talos.pipeline.json:agents.fallback (explicit)". The owner resumes by removing `pipeline:blocked` (each block grants one more limit) or raising `limits.tokens_per_issue`.
