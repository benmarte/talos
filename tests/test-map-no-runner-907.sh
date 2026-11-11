#!/usr/bin/env bash
# test-map-no-runner-907.sh -- map drawing does not need a runner CLI on PATH (#907).
# Tests are named by the spec's id. Every case runs with a PATH that has no `claude`
# and a config whose profile runner is `claude`.
#   AC1 talos.sh map exits 0 and prints map=
#   AC2 talos-buzz.sh redraw <slug> prints `talos-buzz done map=`
#   AC3 map --refresh gets past config loading: the stub provider is called
#   AC4 map --forget <slug> exits 0 and prints forgot=
#   AC5 run --issue 1 and prompt developer --issue 1 still fail with profile-unusable
#   AC6 an inherited TALOS_PROFILE_RUNNER_OPTIONAL=1 does not loosen `run`
#   AC7 an unknown profile still fails map with profile-unknown
# AC8 is prose (the doc wording).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

TALOS="$TALOS_ROOT/scripts/talos.sh"
BUZZ="$TALOS_ROOT/scripts/talos-buzz.sh"
unset PIPELINE_CONFIG TALOS_ROLE TALOS_RUN_STARTED TALOS_RUN_PID TALOS_PROFILE TALOS_HARNESS \
      TALOS_PROFILE_RUNNER_OPTIONAL
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export TALOS_HOME="$SANDBOX/th"; mkdir -p "$TALOS_HOME/maps"

# A PATH with no `claude`: only the gh stub, then the system directories.
BIN="$SANDBOX/bin"; mkdir -p "$BIN"
cp "$STUBS_DIR/gh" "$BIN/gh"; chmod +x "$BIN/gh"
export GH_LOG="$SANDBOX/gh.log"; : > "$GH_LOG"
export GH_QUEUE="$SANDBOX/gh.queue" GH_LINK_QUEUE="$SANDBOX/gh.link.queue" GH_REST_LOG="$SANDBOX/gh.rest.log"
: > "$GH_QUEUE"; : > "$GH_LINK_QUEUE"; : > "$GH_REST_LOG"
NOCLAUDE="$BIN:/usr/bin:/bin"
if PATH="$NOCLAUDE" command -v claude > /dev/null 2>&1; then
  echo "SKIP: a claude binary is on the system PATH"; exit 0
fi
export PATH="$NOCLAUDE"

CFGFILE="$SANDBOX/talos.pipeline.json"
GOOD="$SANDBOX/good.json"
BAD="$SANDBOX/unknown.json"
python3 -I -c '
import json, sys
good, bad = sys.argv[1:3]
base = {"vcs": {"provider": "github", "repo": "acme/widget"}}
prof = {"claude": {"runner": "claude"}}
json.dump(dict(base, agents={"profile": "claude", "profiles": prof}), open(good, "w"))
json.dump(dict(base, agents={"profile": "nope", "profiles": prof}), open(bad, "w"))' "$GOOD" "$BAD"
cfg() { cp "$1" "$CFGFILE"; export PIPELINE_CONFIG="$CFGFILE"; }
cfg "$GOOD"
run() { OUT="$(bash "$TALOS" "$@" 2> "$SANDBOX/err" < /dev/null)"; RC=$?; ERR="$(cat "$SANDBOX/err")"; }

# ── AC1 ──────────────────────────────────────────────────────────────────────
run map
assert_eq "0" "$RC" "AC1 map exits 0 with no runner on PATH ($ERR)"
assert_contains "$OUT" "map=" "AC1 map prints map="

# ── AC2 ──────────────────────────────────────────────────────────────────────
python3 -I -c '
import json, sys
sb, cfg = sys.argv[1:3]
json.dump({"acme/widget": {"file": "acme-widget.html", "root": sb, "config": cfg}}, open(sb + "/th/maps/index.json", "w"))' \
  "$SANDBOX" "$CFGFILE"
BOUT="$(bash "$BUZZ" redraw acme/widget 2> "$SANDBOX/buzz.err" < /dev/null)"; BRC=$?
assert_eq "0" "$BRC" "AC2 talos-buzz redraw exits 0 ($(cat "$SANDBOX/buzz.err") | $BOUT)"
assert_contains "$BOUT" "talos-buzz done map=" "AC2 talos-buzz redraw prints done map="

# ── AC3 ──────────────────────────────────────────────────────────────────────
: > "$GH_LOG"
run map --refresh
assert_not_contains "$OUT$ERR" "profile-unusable" "AC3 map --refresh is not stopped by the runner check"
assert_not_contains "$OUT$ERR" "config-unreadable" "AC3 map --refresh gets past config loading"
if [ -s "$GH_LOG" ]; then pass "AC3 map --refresh called the stub provider"; else fail "AC3 map --refresh called the stub provider" "gh.log is empty (rc=$RC, $OUT $ERR)"; fi

# ── AC4 ──────────────────────────────────────────────────────────────────────
run map --forget acme/widget
assert_eq "0" "$RC" "AC4 map --forget exits 0 ($ERR)"
assert_contains "$OUT" "forgot=" "AC4 map --forget prints forgot="

# ── AC5 ──────────────────────────────────────────────────────────────────────
run run --issue 1
assert_contains "$OUT$ERR" "reason=profile-unusable" "AC5 run --issue 1 fails with profile-unusable"
run prompt developer --issue 1
assert_contains "$OUT$ERR" "reason=profile-unusable" "AC5 prompt developer --issue 1 fails with profile-unusable"

# ── AC6 ──────────────────────────────────────────────────────────────────────
export TALOS_PROFILE_RUNNER_OPTIONAL=1
run run --issue 1
assert_contains "$OUT$ERR" "reason=profile-unusable" "AC6 run --issue 1 ignores an inherited TALOS_PROFILE_RUNNER_OPTIONAL=1"
run prompt developer --issue 1
assert_contains "$OUT$ERR" "reason=profile-unusable" "AC6 prompt developer ignores an inherited TALOS_PROFILE_RUNNER_OPTIONAL=1"
unset TALOS_PROFILE_RUNNER_OPTIONAL

# ── AC7 ──────────────────────────────────────────────────────────────────────
cfg "$BAD"
run map
assert_contains "$OUT$ERR" "reason=profile-unknown" "AC7 an unknown profile still fails map with profile-unknown"
assert_not_contains "$OUT" "map=" "AC7 an unknown profile draws no map"

finish
