#!/usr/bin/env bash
# test-map-dashboard-midnight.sh -- the map's Activity times do not depend on
# the time of day the test runs at (#1023). The map shows today's entries as
# `HH:MM` and an older one as `YYYY-MM-DD HH:MM`, both read against one clock;
# `TALOS_NOW` (unix seconds) pins that clock, as it does for the lease code.
#   AC1 the clock pinned to just after UTC midnight (2026-06-15T00:05:00Z)
#   AC2 the clock pinned to midday (2026-06-15T12:00:00Z): the same entries
#   AC3 (same) no override: a same-day fixture reads `HH:MM`, as for live use
# AC4 (the changelog line) is prose.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

TALOS="$TALOS_ROOT/scripts/talos.sh"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
printf '{"vcs": {"provider": "github", "repo": "acme/widget"}}\n' > "$PIPELINE_CONFIG"
MAP="$HOME/.talos/maps/acme-widget.html"
STATE="$SANDBOX/.git/talos"
mkdir -p "$STATE" "$HOME/.cache/talos/meta" "$SANDBOX/bin"
printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/gh"; chmod +x "$SANDBOX/bin/gh"
for c in curl glab az; do cp "$SANDBOX/bin/gh" "$SANDBOX/bin/$c"; done

# fixture <run started> <ts>x4: one run and four entries for issue 21 (a
# validator, reviewer, qa verdict and a merge), oldest first.
fixture() {
  python3 -I -c '
import json, sys
state, started, stamps = sys.argv[1], sys.argv[2], sys.argv[3:]
rows = [("validator", "CONFIRMED"), ("reviewer", "APPROVED"), ("qa", "PASS"), ("merged", "merged")]
with open(state + "/events.jsonl", "w") as f:
    for (role, v), ts in zip(rows, stamps):
        e = {"event": role, "role": "orchestrator" if role == "merged" else role,
             "issue": 21, "pr": 31 if role == "merged" else None, "verdict": v, "ts": ts}
        f.write(json.dumps(e) + "\n")
with open(state + "/state.json", "w") as f:
    json.dump({"ts": stamps[-1], "run": {"active": True, "started": started}, "collect": {}}, f)' "$STATE" "$@"
}
# render: the map page; the clock stays whatever the caller exported
render() {
  PATH="$SANDBOX/bin:$PATH" bash "$TALOS" map >/dev/null 2>"$SANDBOX/err" || return 1
  cat "$MAP"
}
# times: the Activity entries' times, newest first, space separated
times() {
  python3 -I -c '
import re, sys
print(" ".join(re.findall(r"<li><time>([^<]*)</time>", sys.stdin.read())))' <<< "$1"
}
epoch() {  # <ISO UTC>: unix seconds
  python3 -I -c '
import datetime, sys
print(int(datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$1"
}

# One entry the day before the pinned day and three on it.
fixture 2026-06-14T23:00:00Z 2026-06-14T23:50:00Z 2026-06-15T00:02:00Z 2026-06-15T00:03:00Z 2026-06-15T00:04:00Z
WANT="00:04 00:03 00:02 2026-06-14 23:50"

PAGE="$(TALOS_NOW="$(epoch 2026-06-15T00:05:00Z)" render)"
assert_eq "$WANT" "$(times "$PAGE")" "AC1 five minutes after UTC midnight the Activity reads HH:MM for today and a date for yesterday" "$(cat "$SANDBOX/err")"

PAGE="$(TALOS_NOW="$(epoch 2026-06-15T12:00:00Z)" render)"
assert_eq "$WANT" "$(times "$PAGE")" "AC2 at midday the same entries read the same" "$(cat "$SANDBOX/err")"

# AC3: no override. Today's entries sit at today's 00:00 UTC, so no time of day
# the test runs at moves them to the day before.
YDAY="$(python3 -I -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).date() - datetime.timedelta(days=1))')"
TODAY="$(python3 -I -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).date())')"
fixture "${YDAY}T12:00:00Z" "${YDAY}T23:59:00Z" "${TODAY}T00:00:00Z" "${TODAY}T00:00:01Z" "${TODAY}T00:00:02Z"
unset TALOS_NOW
PAGE="$(render)"
assert_eq "00:00 00:00 00:00 $YDAY 23:59" "$(times "$PAGE")" "AC3 with no override a same-day fixture reads HH:MM, a day-old one a date" "$(cat "$SANDBOX/err")"

finish
