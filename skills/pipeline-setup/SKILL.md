---
name: pipeline-setup
description: "Deprecated alias of /talos:setup, removed in v0.20. Prints the rename notice, then runs the Talos setup wizard."
---
<!-- talos:alias -->
Print this line first, exactly: `renamed to /talos:setup; this alias is removed in v0.20`

Then run the command it points at, unchanged and with the same arguments: read the playbook with your file-read tool and follow it exactly. Use the first of these that exists: `$TALOS_HOME/skills/setup/SKILL.md` (only when TALOS_HOME is set), `~/.talos/skills/setup/SKILL.md`, `$CLAUDE_PLUGIN_ROOT/skills/setup/SKILL.md` (only when CLAUDE_PLUGIN_ROOT is set).
If none of them exists, tell the user to run `bash install.sh --global` from the Talos repo, and stop.
