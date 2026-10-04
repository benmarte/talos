#!/usr/bin/env bash
# test-events-arg-hang.sh -- a value-taking flag given as the last argument
# exits 2 with a usage line instead of looping forever (#450):
#   (a) pipeline-hooks.sh post_stage: all 13 value flags
#   (b) pipeline-events.sh list: --issue --role --event --last; tail: --issue
# Every form runs under a kill-after-N-seconds guard that reports a hang.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

HOOKS="$TALOS_ROOT/scripts/pipeline-hooks.sh"
EVENTS="$TALOS_ROOT/scripts/pipeline-events.sh"

cat > talos.pipeline.json <<'JSON'
{"agents": {"runner": "claude"}}
JSON

# guarded SCRIPT ARGS... -- run `bash SCRIPT ARGS` in its own session with
# stdin closed; sets RC (the exit code, or HANG after 5 s, when the whole
# process group is killed and reaped) and ERR (stderr).
guarded() {
  local res
  res="$(python3 -I - "$@" <<'PY'
import os, signal, subprocess, sys
p = subprocess.Popen(["bash"] + sys.argv[1:], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.PIPE, start_new_session=True)
try:
    _, err = p.communicate(timeout=5)
    rc = str(p.returncode)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    _, err = p.communicate()
    rc = "HANG"
print(rc + " " + err.decode(errors="replace").strip().replace("\n", " / "))
PY
)"
  RC="${res%% *}"; ERR="${res#* }"
}

for flag in --pr --sha --verdict --summary --summary-file --details-file --attempt \
            --duration-s --tokens --tool-uses --ci-runs --model --runner; do
  guarded "$HOOKS" post_stage qa qa 1 "$flag"
  assert_eq "2" "$RC" "post_stage $flag as the last argument: exit 2, no hang"
  assert_contains "$ERR" "$flag needs a value" "post_stage $flag: names the flag"
  assert_contains "$ERR" "Usage: pipeline-hooks.sh" "post_stage $flag: prints the usage"
done

for form in "list --issue" "list --role" "list --event" "list --last" "tail --issue" "list --json --issue"; do
  # shellcheck disable=SC2086
  guarded "$EVENTS" $form
  assert_eq "2" "$RC" "events $form as the last argument: exit 2, no hang"
  assert_contains "$ERR" "needs a value" "events $form: says a value is missing"
  assert_contains "$ERR" "Usage: pipeline-events.sh" "events $form: prints the usage"
done

finish
