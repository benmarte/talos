# Project memory vault: an LLM-agnostic, self-improving memory for any repo

Date: 2026-09-07
Status: DRAFT, awaiting approval. Lives here temporarily; moves to its own repo once named.
Relationship to Talos: none required. Talos is one consumer via its generic `hooks.pre_dispatch` / `hooks.post_stage` (Talos roadmap Phase 2). Claude Code, Codex, Gemini, pi, or a human in Obsidian are equally valid consumers.

## 1. What it is

A **project setup**, not a service. Dropping it into a repo gives that repo a `memory/` directory that is:

- an Obsidian vault you can open, browse as a graph, and edit by hand;
- plain Markdown with YAML frontmatter and wikilinks, readable by any LLM with no client;
- diffable and reviewable in git, so memory changes are visible like code changes;
- optionally driven by a small CLI that selects the right notes for a task and updates their scores from outcomes.

The learning is not weight training. It is a contextual-bandit loop over which notes get shown: notes that precede good outcomes are shown more, notes that precede bad outcomes fade, and a human edit resets a note's standing. Reflexion-style postmortems and workflow induction supply the content.

## 2. Adoption tiers

The value is in the vault and the conventions. Code is added only when instructions alone stop being enough.

**Tier 0, no code.** `memory/` vault plus a paragraph in `AGENTS.md` / `CLAUDE.md` / `GEMINI.md`: read `memory/MEMORY.md` before starting; write a lesson note when you learn something reusable; link files and commands with wikilinks. This is how Claude Code's own auto-memory works. It validates the vault shape on real work with zero new code. Limits: no scoring, no token budgeting beyond the index, and it depends on each model following instructions (weak for small local models).

**Tier 1, the learning loop.** A CLI with five subcommands (`recall`, `record`, `note`, `consolidate`, `index`). Adds selection under a token budget, outcome-driven scoring, decay, promotion to rules, and derived risk/flake notes. A few hundred lines of Python; python3 is the only dependency. This is the only reason a code project exists.

**Tier 2, optional accelerators.** Rebuilt SQLite + sqlite-vec index for large vaults or vector search, embeddings via any OpenAI-compatible `/v1/embeddings` endpoint (llama-server works), an MCP stdio server for hosts that support it.

## 3. Vault layout

```
memory/                      # the vault root; open it in Obsidian directly
  MEMORY.md                  # generated index, one line per note; Tier 0 reads only this
  lessons/                   # Reflexion-style postmortems
  conventions/               # repo rules
  risks/                     # derived: paths that correlate with failures
  flakes/                    # derived: verify commands with repeated CI reruns
  workflows/                 # induced multi-step procedures (optional LLM step)
  rules/                     # promoted lessons, injected unconditionally for their scope
  entities/                  # one stub note per file, stage, model, command; targets of wikilinks
  ledger.jsonl               # append-only recall ledger for credit assignment (Tier 1)
  .index/                    # optional derived index (SQLite, sqlite-vec); safe to delete (Tier 2)
```

## 4. Note format

```markdown
---
id: lesson-2026-09-07-flaky-worktree-sweep
kind: lesson
scope: ["scripts/pipeline-worktree.sh", "tests/test-worktree.sh"]
roles: [developer, qa]
alpha: 3
beta: 1
valid_from: 2026-09-07
valid_to: null
supersedes: null
derived_from: ["#142"]
tags: [worktree, cleanup]
---
When `pipeline-worktree.sh sweep` runs while a developer worktree is mid-commit,
`git worktree prune` reports the path as prunable and the test suite deletes it.
Fix: sweep only ids not in the active queue; see [[entities/scripts-pipeline-worktree]].
```

Format rules: wikilinks, tags, folders, and frontmatter only. No plugin-specific syntax, so any model reads a note as ordinary Markdown. One note per file. Writes go to a temp file then rename, so parallel agents never see a half-written note. `ledger.jsonl` is the only shared mutable file and is append-only. `roles` is free-form: Talos stage names, or `reviewer`, `planner`, `anyone`.

Memory kinds:
- `lesson`: "When X happened, Y fixed it." Written by an agent after a failure, or drafted from a blocked comment.
- `convention`: repo rules ("tests live in tests/*.sh", "never use em-dashes").
- `risk`: path that correlates with failures. Derived from events, no LLM needed.
- `flake`: verify command with repeated CI reruns. Derived.
- `workflow`: a successful multi-step procedure induced from a merged change. Optional LLM summarisation, off by default.
- `rule`: a lesson promoted after N consistent rewards; injected unconditionally for its scope.

Graph: nodes are notes. Entity notes under `entities/` are stubs for File, Stage, Model, Command, Issue, and PR, created on first reference so wikilinks always resolve. Edges are wikilinks in the body plus typed frontmatter lists (`derived_from`, `scope`, `roles`, `supersedes`). Derived edges (failed-on, flaked) are counted from the ledger and events, then written as wikilinks in the generated `risks/` and `flakes/` notes so they appear in the Obsidian graph too. Temporal validity follows Graphiti: notes are invalidated with `valid_to`, never deleted.

## 5. The CLI (Tier 1)

```
recall --role <r> [--issue <n>] [--files a,b] [--budget-tokens N]   # markdown to stdout, appends ledger row
record  < event.json                                                # one outcome event; updates posteriors
note    --kind lesson|convention|risk --scope 'path/**' --text '...' # agent-authored memory
consolidate [--llm <openai-compatible-url>]                         # invalidate, promote, derive, detect manual edits
index                                                               # regenerate MEMORY.md and the optional .index/
```

**Retrieval:** walk the vault, parse frontmatter, filter by role and scope glob, rank by `ripgrep` keyword relevance times a Thompson sample from `alpha`/`beta` times recency decay, print the top notes under a token budget. Fast up to thousands of notes; the optional index takes over beyond that.

**Reward:** the event JSON carries an outcome. A generic mapping, overridable per project:

| Outcome | Reward to notes recalled for that task |
|---|---|
| merged, CI green | +1.0 |
| approved on first attempt | +0.5 |
| failed, re-dispatched | -0.5 |
| blocked | -1.0 |
| CI rerun on same SHA | flake signal on the command, no note reward |

Talos supplies these outcomes through `hooks.post_stage`. Any other host can call `record` with the same shape.

**Credit assignment:** `recall` appends `{task_id, role, note_ids}` to the ledger. `record` joins the outcome to the ledger and edits the frontmatter of only those notes. Notes never shown keep their prior.

**Human reward:** editing or deleting a note in Obsidian is a direct correction. `consolidate` treats a manual edit (mtime newer than the last `record`) as a reset to a neutral prior.

**LLM independence:** the core never calls an LLM. Content comes from structured events, from agents writing `note` with whatever model they run on, and from pure derivations. `consolidate --llm` and the embedder accept any OpenAI-compatible endpoint and are optional.

## 6. How a project adopts it

`memory-setup` (a script, or a Claude Code skill in the project's plugin) does three things: creates `memory/` with the folders, `MEMORY.md`, and `.obsidian/` workspace defaults; appends the Tier 0 paragraph to whichever of `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` exist; and, if Talos is present, adds the two `hooks:` lines to `talos.pipeline.*`. No other file in the repo changes.

## 7. Workplan

| # | Item | Tier | Effort |
|---|---|---|---|
| 1 | Repo scaffold, vault layout, `memory-setup` script, Tier 0 paragraph, `.gitignore` for `.index/` | 0 | S |
| 2 | Dogfood Tier 0 on the Talos repo for one week of pipeline runs; keep a list of what the vault shape gets wrong | 0 | S |
| 3 | Frontmatter schema, atomic note writer, entity stub creation | 1 | S |
| 4 | `note` | 1 | S |
| 5 | `recall` with ledger append | 1 | M |
| 6 | `record` with ledger join and posterior update | 1 | M |
| 7 | `index` with wikilink validation | 1 | S |
| 8 | `consolidate`: manual-edit detection, supersede, promote to `rules/`, derive `risks/` and `flakes/` | 1 | M |
| 9 | End-to-end test: synthetic events, assert recall order changes after a failure | 1 | M |
| 10 | Obsidian smoke test: graph view shows lessons linked to entities with no plugin | 1 | S |
| 11 | `backfill` from `.talos/events.jsonl` | 1 | S |
| 12 | Optional `.index/` SQLite + sqlite-vec, embeddings via OpenAI-compatible endpoint, hybrid rank | 2 | M |
| 13 | Optional `consolidate --llm` workflow induction | 2 | M |
| 14 | MCP stdio server wrapping the CLI | 2 | S |
| 15 | `stats`: reward per note, per role, per model; generated `stats.md` | 2 | S |

## 8. Open decisions

1. Name and repo. `mneme` (Greek muse of memory) is a placeholder.
2. Vault location default: `memory/` in-repo (committed, shared) versus a private per-user directory. Recommendation: in-repo with an override, because shared conventions are most of the value.
3. Whether to ship Tier 0 alone first as a template repo and hold Tier 1 until dogfooding shows it is needed. Recommendation: yes.

## 9. Out of scope

Weight fine-tuning, hosted graph databases, a web dashboard, HTTP APIs, Obsidian plugin development, and Obsidian Sync (use git).

## Appendix: research notes

- Kuzu, the embedded graph engine Cognee defaults to, was archived in October 2025 after an acqui-hire. Zep/Graphiti requires a Neo4j or FalkorDB server. Mem0 is provider-swappable but Python-centric. None fit a Bash-and-Markdown host with a zero-infra promise.
- Anthropic's memory tool and Claude Code auto-memory are plain files plus commands, which validated the vault-first design.
- MCP support is uneven across Codex, Gemini CLI, and pi, so a plain CLI is the portable contract and MCP is a convenience layer.
- Bandit-based retrieval control (AEL, RSCB-MC, 2026) is the closest published pattern to the reward loop here; no production system was found doing merge-as-reward for a coding pipeline.
