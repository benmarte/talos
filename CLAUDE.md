
## Project knowledge (Obsidian vault)
Cross-session context for this project lives in the Obsidian vault at
`/Users/benmarte/Documents/github/personal/obsidian-vault/Projects/benmarte/talos/`.
- Before starting work, read `talos.md` (hub note), then `Decisions.md` and the top of `Log.md`.
- When you finish a task or make a design decision, record it with one command (no formatting needed):
  `python3 /Users/benmarte/Documents/github/personal/obsidian-vault/_tools/vault-log.py "what changed and why"`
  `python3 /Users/benmarte/Documents/github/personal/obsidian-vault/_tools/vault-log.py --decision "what was decided" "why"`
- `vault-log.py --where` prints this project's hub-note path. The vault's own rules are in its AGENTS.md.
