# Talos roadmap: robustness, performance, automation, extensibility

Date: 2026-09-07
Status: APPROVED 2026-09-07; issues filed (see Issue map)
Scope: work inside Talos only. A companion document, `2026-09-07-project-memory-vault-design.md`, describes a per-project memory setup that Talos consumes through the generic hooks in Phase 2 but does not own.

## 0. Findings that shape the plan

Five parallel audits (architecture, script health, backlog, learnable signals, external research) produced these load-bearing facts:

- **No cross-run state exists outside VCS.** Attempt counts and approvals live in `<!-- talos:attempt ... -->` and `<!-- talos:approval sha=... role=... -->` HTML markers in issue/PR comments (`scripts/pipeline-vcs.sh`). There is no local log, no cache. Every run re-derives everything.
- **No extension points exist.** Prompts are assembled inline in `skills/pipeline/SKILL.md` (native path) and by string concatenation in `scripts/pipeline-agent.sh:131-142` (adapter path). Outcomes fan out only to chat sinks via `scripts/pipeline-notify.sh`; there is no command or webhook sink.
- **Config is fail-open.** `scripts/pipeline-config.sh` returns the default for any unknown key. A new `hooks:` block is safe to add. A typo'd key is silently ignored, which is also a bug.
- **The two GitHub adapters have drifted.** `_github` and `_github_api` hand-duplicate roughly 700-900 lines. The parity test compares verb names only. A concrete drift already exists: the waiver rejection message uses an em-dash at `pipeline-vcs.sh:1149` and a double hyphen at `:2555`.
- **Performance hot spots.** `cfg()` spawns python3 and re-parses the config on every call (30+ sites). `check-attempt` and `record-attempt` each re-fetch the full unpaginated comment history. `list-issues` truncates silently at 100.
- **Robustness gaps.** No 429 backoff except detection in `_ga_req`. No `flock` anywhere despite `max_parallel > 1`. Duplicate-marker detection was removed in #159 and not replaced. 74 stale worktrees sit in `.claude/worktrees` right now.
- **Trust is instruction-based in several places.** Env identity on the native path, approval provenance (#128 shipped as defence-in-depth), base-currency check not run in CI.
- **Open backlog is small:** #166 (global install puts agents where Claude Code cannot find them), #167 (per-role runner and adversarial stage), #168 (epic auto-close ignores epic acceptance criteria).

## 1. Workplan

Effort: S under half a day, M one to two days, L three days or more, for an autonomous agent. Every item is written so it can become one GitHub issue and run through the Talos pipeline itself.

### Phase 0: hygiene and quick robustness wins (all S, run first, parallelisable)

| # | Item | Why |
|---|---|---|
| 0.1 | Cache config: parse once per script invocation, keep in an assoc array or a temp JSON | 30+ python3 spawns per verb |
| 0.2 | `pipeline-worktree.sh sweep` runs unconditionally at end of run; warn above a stale threshold; prune `.claude/worktrees` | 74 stale dirs today |
| 0.3 | Paginate `list-issues` or fail loudly at the 100 cap | silent truncation |
| 0.4 | Restore paginated duplicate-marker detection for `post-approval` and add it to `record-attempt` | double-posting inflates attempt counts |
| 0.5 | 429 retry with backoff in `_ga_req`; basic handling in gitlab and azure | rate-limit exits kill a run |
| 0.6 | Merge the two `read-attempt` fetches in `check-attempt` + `record-attempt` into one | 3N network calls per tick |
| 0.7 | Parallelise `tests/run-tests.sh` | 5+ minute serial run |
| 0.8 | Fix #166: global install writes agents to `~/.claude/agents/`; print which script version resolved | stale agents on global install |
| 0.9 | Fix #168: epic auto-close checks the epic's own unchecked boxes | false closes |
| 0.10 | Unknown config key warning (schema list, warn not fail) | typos silently no-op |

### Phase 1: structural debt (M to L)

| # | Item |
|---|---|
| 1.1 | Extract shared waiver / approval-SHA / marker parsing into one sourced library used by `_github` and `_github_api`; upgrade parity test to compare bodies, not names (#155, #143) |
| 1.2 | Single role/label/marker contract table sourced by scripts, SKILL.md, and tests |
| 1.3 | Reduce prompt duplication: SKILL.md references `agents/*.md` bodies instead of restating them |
| 1.4 | `flock` around board updates and any shared local state when `max_parallel > 1` |
| 1.5 | #167: per-role runner override (`agents.roles.<role>.runner`, `runner_cmd`) |

### Phase 2: extensibility, hooks and event log

These are generic. They let any external tool (a memory vault, a metrics collector, a cost tracker, a second reviewer) plug into Talos without Talos depending on it. They follow the existing never-break contract of `pipeline-notify.sh`: non-zero exit or empty output is a no-op.

| # | Item | Effort |
|---|---|---|
| 2.1 | `hooks.pre_dispatch: <cmd>` on both execution paths. Stdin JSON `{role, issue, pr, repo, base_branch, worktree_path, files_hint[]}`. Stdout is prepended to the task prompt under a `## Context` heading. Invoked at `scripts/pipeline-agent.sh:131` and before each inline prompt block in `skills/pipeline/SKILL.md` | M |
| 2.2 | `hooks.post_stage: <cmd>` at every verdict, approval, merge and blocked site. Stdin JSON `{event, role, issue, pr, repo, sha, verdict, summary, details, attempt:{stage,count,total}, model, runner, duration_s}`. Fire-and-forget | M |
| 2.3 | `.talos/events.jsonl` local event log (gitignored) written from the same payload, plus `pipeline-status.sh events` reader. Gives Talos an audit trail and resumability on its own | S |
| 2.4 | `notifications.cmd` generic command sink in `pipeline-notify.sh` | S |
| 2.5 | `talos.pipeline.*` docs and a user-guide section for hooks, with the two JSON schemas | S |

Config example:

```yaml
hooks:
  pre_dispatch: "some-tool recall --role $TALOS_ROLE --issue $TALOS_ISSUE_NUMBER"
  post_stage: "some-tool record"
```

### Phase 3: trust hardening

| # | Item |
|---|---|
| 3.1 | Mechanical env identity on the native path (wrapper script sets exports, not instructions) |
| 3.2 | Approval provenance on by default when a trusted-author list can be inferred (#128 closure) |
| 3.3 | Nightly canary job against a sandbox repo exercising real `gh` and REST paths |
| 3.4 | CI runs the base-currency check |

## 2. Token economy for running this plan

Talos already supports `agents.roles.<role>.model`. Recommended routing while executing the phases: validator, docs, qa on Haiku 4.5; pm, reviewer, security on Sonnet 5; developer on Opus 5 or Fable 5.1 only for Phase 1 items. Phase 0 items are small enough for Sonnet as developer.

## 3. Open decisions

1. Start order. Recommendation: Phase 0 as a batch of issues run by the pipeline itself, Phase 2 next because it unblocks the memory vault, Phase 1 interleaved, Phase 3 last.

## 4. Out of scope

Anything memory-specific. Talos learns nothing itself; it exposes hooks so a project-level memory can.

## 5. Issue map

| Item | Issue | Queue |
|---|---|---|
| 0.1 config cache | #169 | pipeline:ready |
| 0.2 worktree sweep | #170 | pipeline:ready |
| 0.3 list-issues pagination | #171 | pipeline:ready |
| 0.4 duplicate-marker detection | #172 | pipeline:ready |
| 0.5 rate-limit backoff | #173 | pipeline:ready |
| 0.6 single attempt fetch | #174 | pipeline:ready |
| 0.7 parallel tests | #175 | pipeline:ready |
| 0.8 global install agents | #166 | pipeline:ready |
| 0.9 epic auto-close | #168 | pipeline:ready |
| 0.10 unknown config keys | #176 | pipeline:ready |
| 1.1 adapter dedup | #177 | interactive |
| 1.2 contract table | #178 | interactive |
| 1.3 prompt dedup | #179 | interactive |
| 1.4 flock | #180 | interactive |
| 1.5 per-role runner | #167 | interactive |
| 2.1 pre_dispatch hook | #181 | interactive |
| 2.2 post_stage hook | #182 | interactive |
| 2.3 events.jsonl | #183 | interactive |
| 2.4 notifications.cmd | #184 | interactive |
| 2.5 hooks docs | #185 | after 2.1, 2.2 |
| 3.1 mechanical env identity | #186 | interactive |
| 3.2 marker author trust | #187 | interactive |
| 3.3 + 3.4 canary CI | #188 | interactive |

"Interactive" items are intentionally not labelled `pipeline:ready`. Label one when you want Talos to take it.
