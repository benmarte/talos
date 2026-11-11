#!/usr/bin/env bash
# talos-usage-hook.sh -- the Talos plugin's SubagentStop hook (#911).
#
# Claude Code runs it when a subagent finishes, with the hook payload on stdin
# (agent_type, agent_id, agent_transcript_path, transcript_path). For a subagent of
# a Talos role (validator, pm, planner, developer, qa, reviewer, security, docs,
# adversarial, with or without the `talos:` prefix) it runs
# `talos-usage.py hook`, which imports that one transcript as a `usage` event
# (the same code as `pipeline-events.sh import-usage --transcript`, so a
# transcript already imported is never counted twice). Any other agent is ignored.
#
# It never blocks or fails the session: always exit 0, nothing on stdout, at most
# one stderr line, no network call, back within 2 s. TALOS_USAGE_HOOK=0 turns it
# off; so does disabling the plugin's hooks as Claude Code documents.
set -u
[ "${TALOS_USAGE_HOOK:-1}" = "0" ] && exit 0
DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || exit 0
if [ ! -f "$DIR/talos-usage.py" ]; then
  echo "talos-usage-hook: talos-usage.py missing; reinstall Talos" >&2
  exit 0
fi
command -v python3 > /dev/null 2>&1 || exit 0
python3 -I -B "$DIR/talos-usage.py" hook > /dev/null || true
exit 0
