#!/usr/bin/env bash
# Tests for the secret-shape check on config load (#444, part of epic #437): a
# string leaf in the repo file or the global file that looks like a secret (a
# Slack token or webhook URL, a GitHub token, an AWS key, a private key, ...)
# is dropped as absent with one stderr line that names the key and never the
# value; `env:NAME` is always allowed. Also: an `env:NAME` reference may not
# point at a denied variable (it used to resolve from the exported environment),
# and `--show` never prints a secret from a list of mappings.
#
# Every secret-shaped fixture is assembled from fragments at run time, so this
# file holds no secret-shaped literal. `--print-fixtures` prints them as
# name<TAB>value lines for the drift test in test-worktree-checkpoint.sh; it is
# the only place the values leave this file, and no assertion below prints one.
# Sandboxed: TALOS_HOME is always inside $SANDBOX; no real webhook is ever called.

# fixture <name> <index> -- one planted value per shape (the rest are variants).
fixture() {
  case "$1" in
    slack-token) case "$2" in
        1) printf '%s%s' "xo" "xb-1234567890-abcdefghijkl" ;;
        2) printf '%s%s' "xo" "xs-1234567890-abcdefghijkl" ;;
        3) printf '%s%s' "xo" "xr-123456789012" ;;
        4) printf '%s%s' "xo" "xo-123456789012" ;;
      esac ;;
    slack-webhook) printf '%s%s' "https://hooks.sl" "ack.com/services/T01ABCDEF/B01ABCDEF/abcdEFGH12345678abcdEFGH" ;;
    discord-webhook) printf '%s%s' "https://dis" "cord.com/api/webhooks/123456789012345678/abcdEFGH12345678abcdEFGH_-abcdEFGH12" ;;
    teams-webhook) printf '%s%s' "https://contoso.webh" "ook.office.com/webhookb2/0a1b2c3d-1111-2222-3333-444455556666@0a1b2c3d-1111-2222-3333-444455556666/IncomingWebhook/x/y" ;;
    github-token) case "$2" in
        1) printf '%s%s' "gh" "p_abcdEFGH12345678abcdEFGH12345678abcd" ;;
        2) printf '%s%s' "gh" "o_abcdEFGH12345678abcdEFGH12345678abcd" ;;
        3) printf '%s%s' "gh" "s_abcdEFGH12345678abcdEFGH" ;;
        4) printf '%s%s' "gh" "u_abcdEFGH12345678abcdEFGH" ;;
        5) printf '%s%s' "gh" "r_abcdEFGH12345678abcdEFGH" ;;
      esac ;;
    github-pat) printf '%s%s' "github_" "pat_abcdEFGH12345678abcdEFGH12" ;;
    gitlab-pat) printf '%s%s' "glp" "at-abcdEFGH12345678abcd" ;;
    openai-key) printf '%s%s' "s" "k-abcdEFGH12345678abcdEFGH" ;;
    aws-access-key) printf '%s%s' "AK" "IAABCDEFGH12345678" ;;
    private-key) printf '%s%s' "-----BE" "GIN OPENSSH PRIVATE KEY-----" ;;
    nostr-nsec) printf '%s%s' "ns" "ec1qpzry9x8gf2tvdw0s3jn" ;;
  esac
}
fixtures() {  # every fixture, as name<TAB>value
  local _n _i _v
  for _n in slack-token slack-webhook discord-webhook teams-webhook github-token \
            github-pat gitlab-pat openai-key aws-access-key private-key nostr-nsec; do
    for _i in 1 2 3 4 5; do
      _v="$(fixture "$_n" "$_i")"
      [ -n "$_v" ] && printf '%s\t%s\n' "$_n" "$_v"
    done
  done
}
if [ "${1:-}" = "--print-fixtures" ]; then fixtures; exit 0; fi

set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
NOTIFY="$TALOS_ROOT/scripts/pipeline-notify.sh"
PROJ="$SANDBOX/project"
GHOME="$SANDBOX/talos-home"
ERR="$SANDBOX/stderr"
TAB="$(printf '\t')"
mkdir -p "$PROJ" "$GHOME" || exit 1
cd "$PROJ" || exit 1
git init -q
git remote add origin git@github.com:acme/widget.git

reset_cfg() {
  rm -f "${PROJ:?}"/talos.pipeline.* "${GHOME:?}"/talos.pipeline.* "${PROJ:?}/.env"
  unset PIPELINE_CONFIG PIPELINE_SLACK_CHANNEL TALOS_CONFIG_STRICT_KEYS
  export TALOS_HOME="$GHOME"
}
glob_json() { printf '%s' "$1" > "$GHOME/talos.pipeline.json"; }
proj_json() { printf '%s' "$1" > "$PROJ/talos.pipeline.json"; }
get() { bash "$CFG_SH" "$1" "${2:-SENT}" 2>"$ERR"; }
# Passes when $1 does not contain $2; the failure line never prints either.
hides() {  # $1=haystack $2=planted value $3=label
  case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac
}
errcount() { wc -l < "$ERR" | tr -d ' '; }

# ── (a) one fixture per shape is rejected: key named, value never shown ──────
reset_cfg
export SHAPES_PY="$TALOS_ROOT/scripts/pipeline-secret-shapes.py"
while IFS="$TAB" read -r _name _val; do
  proj_json "{\"notifications\":{\"slack_channel\":\"$_val\"}}"
  out="$(get notifications.slack_channel)"; rc=$?
  assert_eq "0" "$rc" "(a) $_name: a secret-shaped value does not change the exit status"
  assert_eq "SENT" "$out" "(a) $_name: the value is dropped as absent (the caller's default comes back)"
  hides "$out" "$_val" "(a) $_name: the value is not on stdout"
  hides "$(cat "$ERR")" "$_val" "(a) $_name: the value is not on stderr"
  assert_contains "$(cat "$ERR")" "notifications.slack_channel" "(a) $_name: stderr names the key"
  assert_contains "$(cat "$ERR")" "env:NAME" "(a) $_name: stderr says to use env:NAME"
  assert_eq "1" "$(errcount)" "(a) $_name: exactly one stderr line"
  # the shape file itself names the shape (it is what the drift test relies on)
  _shape="$(FXV="$_val" python3 -I -c 'import os; exec(open(os.environ["SHAPES_PY"]).read()); print(secret_shape(os.environ["FXV"]))' 2>/dev/null)"
  assert_eq "$_name" "$_shape" "(a) $_name: pipeline-secret-shapes.py matches the fixture under its own name"
done < <(fixtures)
unset _name _val

# A list item and a mapping inside a list are scanned too; the rest of the list stays.
reset_cfg
GH="$(fixture github-token 1)"
proj_json "{\"zz\":[\"keep\",\"$GH\"],\"yy\":[{\"a\":\"fine\",\"b\":\"$GH\"}]}"
out="$(bash "$CFG_SH" --show zz 2>"$ERR"; bash "$CFG_SH" --show yy 2>>"$ERR")"
assert_contains "$out" "zz${TAB}keep${TAB}repo" "(a) a secret-shaped list item is dropped, the other item stays"
hides "$out$(cat "$ERR")" "$GH" "(a) neither list item reaches --show output"
assert_contains "$(cat "$ERR")" "'zz[1]'" "(a) the list item is named by its position"
assert_contains "$(cat "$ERR")" "'yy[0].b'" "(a) a key inside a mapping inside a list is named by its path"

# ── (b) ordinary values pass untouched ───────────────────────────────────────
reset_cfg
for v in '#eng-alerts' 'L2Vuby9wYXRoL3RvL2ZpbGU/a+b/c==' 'https://hooks.example.com' 'https://hooks.example.com/services/team' 'plain words with spaces' 'task-management-planning-queue-review' 'sk-learn-pipeline'; do
  proj_json "{\"notifications\":{\"slack_channel\":\"$v\"}}"
  assert_eq "$v" "$(get notifications.slack_channel)" "(b) ordinary value passes: $v"
  assert_eq "0" "$(errcount)" "(b) ... with no stderr: $v"
done
proj_json '{"limits":{"max_fix_attempts":3},"hooks":{"enabled":true}}'
assert_eq "3" "$(get limits.max_fix_attempts)" "(b) non-string leaves are untouched"

# ── (c) env:NAME is always allowed ───────────────────────────────────────────
reset_cfg
proj_json '{"notifications":{"slack":{"webhook":"env:SLACK_WEBHOOK_URL"}}}'
assert_eq "env:SLACK_WEBHOOK_URL" "$(get notifications.slack.webhook)" "(c) env:SLACK_WEBHOOK_URL passes"
assert_eq "0" "$(errcount)" "(c) ... with no stderr"
proj_json "{\"notifications\":{\"slack_channel\":\"env:$GH\"}}"
assert_eq "env:$GH" "$(get notifications.slack_channel)" "(c) a value that starts env: is never checked"

# ── (d) the global file is checked too ───────────────────────────────────────
reset_cfg
glob_json "{\"notifications\":{\"slack_channel\":\"$GH\"}}"
out="$(get notifications.slack_channel)"
assert_eq "SENT" "$out" "(d) the same value in the global file is dropped"
hides "$(cat "$ERR")" "$GH" "(d) ... and never printed"
assert_contains "$(cat "$ERR")" "notifications.slack_channel" "(d) ... with the key named"
assert_contains "$(cat "$ERR")" "user-level config" "(d) ... and the layer named"
# a rejected repo value falls through to the global layer's ordinary value
glob_json '{"notifications":{"slack_channel":"#from-global"}}'
proj_json "{\"notifications\":{\"slack_channel\":\"$GH\"}}"
assert_eq "#from-global" "$(get notifications.slack_channel)" "(d) a dropped repo value is absent: the global layer shows through"

# ── (e) TALOS_CONFIG_STRICT_KEYS=0 does not disable the check ────────────────
reset_cfg
proj_json "{\"notifications\":{\"slack_channel\":\"$GH\"}}"
out="$(TALOS_CONFIG_STRICT_KEYS=0 bash "$CFG_SH" notifications.slack_channel SENT 2>"$ERR")"
assert_eq "SENT" "$out" "(e) TALOS_CONFIG_STRICT_KEYS=0: the value is still dropped"
assert_contains "$(cat "$ERR")" "notifications.slack_channel" "(e) ... and the key still named"

# --has: a dropped key is absent from the file layers too
reset_cfg
proj_json "{\"notifications\":{\"slack_channel\":\"$GH\"}}"
bash "$CFG_SH" --has notifications.slack_channel >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "(e) --has: a dropped key is not set by a file"

# ── (f) still one python3 spawn per lookup ───────────────────────────────────
REAL_PY="$(command -v python3)"
mkdir -p "$SANDBOX/pybin" || exit 1
printf '#!/bin/sh\necho x >> "%s"\nexec "%s" "$@"\n' "$SANDBOX/py.count" "$REAL_PY" > "$SANDBOX/pybin/python3"
chmod 755 "$SANDBOX/pybin/python3"
count_spawns() {  # run the lookup under the counting python3 shim
  : > "$SANDBOX/py.count"
  PATH="$SANDBOX/pybin:$PATH" bash "$CFG_SH" notifications.slack_channel SENT >/dev/null 2>&1
  wc -l < "$SANDBOX/py.count" | tr -d ' '
}
reset_cfg
proj_json '{"notifications":{"slack_channel":"#clean"}}'
glob_json '{"limits":{"warn_at":0.5}}'
BASE="$(count_spawns)"
proj_json "{\"notifications\":{\"slack_channel\":\"$GH\"}}"
glob_json "{\"notifications\":{\"discord_channel\":\"$GH\"}}"
assert_eq "$BASE" "$(count_spawns)" "(f) scanning both layers costs no extra python3 spawn"
assert_eq "1" "$BASE" "(f) a lookup is one python3 spawn"

# ── --show: a list of mappings never prints a secret; bidi is escaped ────────
reset_cfg
proj_json '{"foo":[{"token":"PLANTEDLISTVAL77"}],"bar":[{"name":"ok"}]}'
out="$(bash "$CFG_SH" --show foo 2>"$ERR")"
hides "$out$(cat "$ERR")" "PLANTEDLISTVAL77" "(show) a token inside a list of mappings does not print"
assert_contains "$out" "foo${TAB}<masked>${TAB}repo" "(show) ... the row is masked"
proj_json "{\"foo\":[{\"token\":\"$GH\"}]}"
out="$(bash "$CFG_SH" --show foo 2>"$ERR")"
hides "$out$(cat "$ERR")" "$GH" "(show) a secret-shaped token inside a list of mappings is rejected on load"
reset_cfg
BS=$(printf "\134"); proj_json "{\"zz\":\"a${BS}u202eb${BS}u2066c\"}"
out="$(bash "$CFG_SH" --show zz 2>"$ERR")"
assert_contains "$out" "a${BS}u202eb${BS}u2066c" "(show) bidi override characters print escaped"
case "$out" in *$'\xe2\x80\xae'*|*$'\xe2\x81\xa6'*) fail "(show) no raw bidi character reaches stdout" ;; *) pass "(show) no raw bidi character reaches stdout" ;; esac

# --show applies the same deny check as the secrets path and never says whether
# a denied name is set.
reset_cfg
proj_json '{"notifications":{"slack":{"bot_token":"env:GH_TOKEN"}}}'
out="$(GH_TOKEN=PLANTEDDENIED41 bash "$CFG_SH" --show notifications.slack.bot_token 2>"$ERR")"
assert_eq "notifications.slack.bot_token${TAB}env:GH_TOKEN (denied)${TAB}repo" "$out" "(show) a reference to a denied name prints (denied), set or not"

# ── YAML aliases: a cycle and a billion-laughs config load, no traceback ─────
if python3 -I -c 'import site, sys; sys.path.append(site.getusersitepackages()); import yaml' 2>/dev/null; then
  reset_cfg
  printf 'notifications:\n  slack_channel: "#from-yaml"\nzz: &r\n  self: *r\n  keep: ok\nll: &l [*l, fine]\n' > "$PROJ/talos.pipeline.yml"
  out="$(get notifications.slack_channel)"; rc=$?
  assert_eq "0" "$rc" "(alias) a self-referencing alias: the lookup exits 0"
  assert_eq "#from-yaml" "$out" "(alias) ... and the rest of the file still loads"
  assert_not_contains "$(cat "$ERR")" "Traceback" "(alias) ... with no traceback"
  assert_contains "$(cat "$ERR")" "'zz.self' refers to itself" "(alias) the cycle is dropped with one line naming the key path"
  assert_contains "$(bash "$CFG_SH" --show zz.keep 2>/dev/null)" "zz.keep${TAB}ok${TAB}repo" "(alias) the sibling of a dropped cycle key stays"
  # the same cycle in the global file (it is walked before the repo-only drop)
  reset_cfg
  printf 'notifications:\n  slack_channel: "#from-global"\nzz: &r\n  self: *r\n' > "$GHOME/talos.pipeline.yml"
  assert_eq "#from-global" "$(get notifications.slack_channel)" "(alias) a cycle in the global file loads too"
  assert_not_contains "$(cat "$ERR")" "Traceback" "(alias) ... with no traceback (global)"

  reset_cfg
  {
    printf 'notifications:\n  slack_channel: "#from-yaml"\n'
    printf 'a: &a [x, x, x, x, x, x, x, x, x]\n'
    _prev=a
    for _l in b c d e f g h i; do
      printf '%s: &%s [*%s, *%s, *%s, *%s, *%s, *%s, *%s, *%s, *%s]\n' "$_l" "$_l" "$_prev" "$_prev" "$_prev" "$_prev" "$_prev" "$_prev" "$_prev" "$_prev" "$_prev"
      _prev="$_l"
    done
    printf 'zz: *i\n'
  } > "$PROJ/talos.pipeline.yml"
  _t0=$SECONDS
  out="$(get notifications.slack_channel)"; rc=$?
  _dt=$((SECONDS - _t0))
  assert_eq "#from-yaml" "$out" "(alias) a nested-alias config still yields the value"
  if [ "$_dt" -lt 20 ]; then pass "(alias) ... and completes quickly"; else fail "(alias) ... and completes quickly" "took ${_dt}s"; fi
  assert_not_contains "$(cat "$ERR")" "Traceback" "(alias) ... with no traceback"
  assert_contains "$(cat "$ERR")" "expands to too many values" "(alias) the blown-up value is dropped with one line naming the key"
  unset _prev _l _t0 _dt
else
  pass "(alias) PyYAML is not installed here: the alias cases need a YAML parser and are skipped"
fi
reset_cfg

# ── env:NAME may not point at a denied variable, even from the environment ───
CURL_URL1="https://hooks.example.invalid/one-$RANDOM"
CURL_URL2="https://hooks.example.invalid/two-$RANDOM"
export PIPELINE_THREAD_STATE="$SANDBOX/threads.json"
curl_got() { cut -f1 "$CURL_LOG" | grep -qxF -- "$1"; }
notify_with() {  # $1 = the env: name in the config; the exported value is $CURL_URL1
  : > "$CURL_LOG"; rm -f "$PIPELINE_THREAD_STATE"
  printf '{"notifications":{"slack":{"webhook":"env:%s"}}}\n' "$1" > "$PROJ/talos.pipeline.json"
  ( cd "$PROJ" && unset SLACK_WEBHOOK_URL && env "$1=$CURL_URL1" PIPELINE_ISSUE_TITLE=T \
      bash "$NOTIFY" info "#1" "hello" 1 </dev/null >/dev/null 2>"$ERR" )
}
reset_cfg
notify_with MY_CUSTOM_HOOK
if curl_got "$CURL_URL1"; then pass "(env) control: env:MY_CUSTOM_HOOK resolves from the environment"; else fail "(env) control: env:MY_CUSTOM_HOOK resolves from the environment"; fi
for _denied in GIT_ASKPASS GH_TOKEN BASH_ENV; do
  notify_with "$_denied"
  if curl_got "$CURL_URL1"; then fail "(env) env:$_denied is not resolved from the exported environment"; else pass "(env) env:$_denied is not resolved from the exported environment"; fi
  assert_contains "$(cat "$ERR")" "slack.webhook references $_denied" "(env) env:$_denied is refused with one line naming the key"
done
hides "$(cat "$ERR")" "$CURL_URL1" "(env) the refused value never reaches stderr"
unset CURL_URL2

finish
