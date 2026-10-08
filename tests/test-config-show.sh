#!/usr/bin/env bash
# Tests for `pipeline-config.sh --show` (#442, part of epic #437): one line per
# key, `key<TAB>value<TAB>layer`, layer being default|global|repo|env; secrets
# never print; `--dump-layers` is an alias; the restored "agents must be a
# mapping" warning.
#
# Sandboxed: TALOS_HOME always points inside $SANDBOX, so the real ~/.talos is
# never read or written. Secret-shaped values are planted only to prove they
# never reach stdout or stderr; no failure message below prints them.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1

CFG_SH="$TALOS_ROOT/scripts/pipeline-config.sh"
AGENT_SH="$TALOS_ROOT/scripts/pipeline-agent.sh"
PROJ="$SANDBOX/project"
GHOME="$SANDBOX/talos-home"
ERR="$SANDBOX/stderr"
TAB="$(printf '\t')"
mkdir -p "$PROJ" "$GHOME" || exit 1
cd "$PROJ" || exit 1

ENV_VARS="PIPELINE_REPO PIPELINE_PROJECT_NUMBER PIPELINE_BOARD_OWNER PIPELINE_STATUS_FIELD PIPELINE_SLACK_CHANNEL PIPELINE_DISCORD_CHANNEL PIPELINE_BUZZ_CHANNEL PIPELINE_BUZZ_RELAY"
reset_cfg() {
  rm -f "${PROJ:?}"/talos.pipeline.* "${GHOME:?}"/talos.pipeline.* "${SANDBOX:?}/.env"
  unset PIPELINE_CONFIG $ENV_VARS T442_SET T442_UNSET T442_DOTENV
  export TALOS_HOME="$GHOME"
}
glob_json() { printf '%s' "$1" > "$GHOME/talos.pipeline.json"; }
proj_json() { printf '%s' "$1" > "$PROJ/talos.pipeline.json"; }
show() { bash "$CFG_SH" --show "$@" 2>"$ERR"; }
line_for() { printf '%s\n' "$1" | grep "^$2$TAB" ; }

# ── (a) one key in each layer shows the right layer ──────────────────────────
reset_cfg
glob_json '{"limits":{"max_fix_attempts":5},"hooks":{"timeout_s":40},"verify":{"ci_wait_s":321}}'
proj_json '{"merge":{"method":"rebase"},"hooks":{"timeout_s":50}}'
export PIPELINE_SLACK_CHANNEL=CENV
out="$(show)"; rc=$?
assert_eq "0" "$rc" "(a) --show exits 0"
assert_eq "limits.warn_at${TAB}0.8${TAB}default" "$(line_for "$out" limits.warn_at)" "(a) an untouched key reports the table default"
assert_eq "limits.max_fix_attempts${TAB}5${TAB}global" "$(line_for "$out" limits.max_fix_attempts)" "(a) a key only the global file sets reports global"
assert_eq "merge.method${TAB}rebase${TAB}repo" "$(line_for "$out" merge.method)" "(a) a key only the repo file sets reports repo"
assert_eq "notifications.slack_channel${TAB}CENV${TAB}env" "$(line_for "$out" notifications.slack_channel)" "(a) a key its env variable sets reports env"
assert_eq "hooks.timeout_s${TAB}50${TAB}repo" "$(line_for "$out" hooks.timeout_s)" "(a) the repo file wins over the global one"
assert_eq "verify.ci_wait_s${TAB}321${TAB}global" "$(line_for "$out" verify.ci_wait_s)" "(a) a nested global key reports global"
# the env layer beats a file that sets the same key
proj_json '{"notifications":{"slack_channel":"CREPO"}}'
assert_eq "notifications.slack_channel${TAB}CENV${TAB}env" "$(line_for "$(show)" notifications.slack_channel)" "(a) env wins over the repo file"
unset PIPELINE_SLACK_CHANNEL
assert_eq "notifications.slack_channel${TAB}CREPO${TAB}repo" "$(line_for "$(show)" notifications.slack_channel)" "(a) without the env variable the repo value shows"
# an empty env variable is not a layer (same as the lookup)
export PIPELINE_SLACK_CHANNEL=""
assert_eq "notifications.slack_channel${TAB}CREPO${TAB}repo" "$(line_for "$(show)" notifications.slack_channel)" "(a) an empty env variable does not count"
unset PIPELINE_SLACK_CHANNEL

# --show agrees with the single-key path on the value of every key it lists
reset_cfg
glob_json '{"limits":{"max_fix_attempts":5},"agents":{"model":"sonnet"}}'
proj_json '{"merge":{"method":"rebase"}}'
export PIPELINE_BUZZ_CHANNEL=BZ
out="$(show)"
for k in limits.max_fix_attempts merge.method agents.model notifications.buzz_channel limits.warn_at; do
  want="$(bash "$CFG_SH" "$k" 2>/dev/null)"
  got="$(line_for "$out" "$k" | cut -f2)"
  assert_eq "$want" "$got" "(a) --show value of $k matches the lookup"
done
unset PIPELINE_BUZZ_CHANNEL

# ── (b) no agents.*-only restriction; prefix filter; --origin-only ───────────
reset_cfg
glob_json '{"agents":{"model":"sonnet"},"limits":{"warn_at":0.5}}'
proj_json '{"board":{"status_map":{"ready":"Todo"}},"bogus":{"thing":"x"},"agents":{"roles":{"qa":{"model":"haiku"}}}}'
out="$(show)"
assert_contains "$out" "limits.warn_at${TAB}0.5${TAB}global" "(b) a non-agents key is listed"
assert_contains "$out" "agents.roles.qa.model${TAB}haiku${TAB}repo" "(b) a wildcard row lists the present key under it"
assert_contains "$out" "board.status_map.ready${TAB}Todo${TAB}repo" "(b) board.status_map.* lists the present key"
assert_contains "$out" "bogus.thing${TAB}x${TAB}repo" "(b) an unknown key present is listed"
assert_contains "$out" "release_branch${TAB}main${TAB}default" "(b) a table key nobody sets is listed with its default"
assert_not_contains "$out" "agents.roles.*" "(b) a wildcard row is never listed as itself"
assert_not_contains "$out" "agents.roles.pm.model" "(b) a wildcard row lists only the keys that are present"
only="$(show agents.)"
assert_eq "0" "$(printf '%s\n' "$only" | grep -vc '^agents\.')" "(b) KEY-PREFIX keeps only the keys that start with it"
assert_contains "$only" "agents.model${TAB}sonnet${TAB}global" "(b) the prefix output still carries value and layer"
assert_eq "agents.model${TAB}global" "$(line_for "$(show --origin-only agents.)" agents.model)" "(b) --origin-only prints key and layer, no value"
assert_eq "agents.model${TAB}global" "$(line_for "$(show agents. --origin-only)" agents.model)" "(b) option and prefix may come in either order"
bash "$CFG_SH" --show --bogus >/dev/null 2>"$ERR"; rc=$?
assert_eq "2" "$rc" "(b) an unknown option exits 2"
# a `verify:` mapping is not also listed as a value of its own
reset_cfg
proj_json '{"verify":{"qa_mode":"local"}}'
out="$(show verify)"
assert_eq "0" "$(printf '%s\n' "$out" | grep -c "^verify$TAB")" "(b) the bare verify row is not listed when verify is a mapping"
assert_contains "$out" "verify.qa_mode${TAB}local${TAB}repo" "(b) the verify mapping's key is listed"
reset_cfg
proj_json '{"verify":["bash t.sh","bash u.sh"]}'
assert_eq 'bash t.sh\nbash u.sh' "$(line_for "$(show verify)" verify | cut -f2)" "(b) a verify list is one line"

# ── an empty mapping under a repo-only key is not listed as set ──────────────
reset_cfg
glob_json '{"board":{"status_map":{}},"markers":{},"limits":{"warn_at":0.4}}'
out="$(show)"
assert_eq "0" "$(printf '%s\n' "$out" | grep -c '^board\.status_map\.')" "an {} left under a repo-only key lists no key"
assert_contains "$out" "limits.warn_at${TAB}0.4${TAB}global" "the any-scope sibling still lists"
reset_cfg
glob_json '{"board":{"owner":"gone","status_map":{"ready":"R"}}}'
out="$(show board.)"
assert_eq "board.owner${TAB}${TAB}default" "$(line_for "$out" board.owner)" "a repo-only key dropped from the global file reads default"

# ── (c) a secret never prints ────────────────────────────────────────────────
reset_cfg
PLANTED_WEBHOOK='https://hooks.example.test/services/PLANTEDWEBHOOK9f2'
glob_json '{"notifications":{"slack":{"webhook":"'"$PLANTED_WEBHOOK"'"},"discord":{"bot_token":"env:T442_SET"},"teams":{"webhook":"env:T442_UNSET"},"buzz":{"bot_key":"env:T442_DOTENV"},"slack_api_token":"PLANTEDUNKNOWN77"},"agents":{"runner_cmd":"env:BAD NAME PLANTEDENVSHAPE55"}}'
export T442_SET=PLANTEDVALUE31
printf 'T442_DOTENV=PLANTEDDOTENV42\n' > "$SANDBOX/.env"
chmod 600 "$SANDBOX/.env"
out="$(show)"
errtxt="$(cat "$ERR")"
assert_eq "notifications.slack.webhook${TAB}<masked>${TAB}global" "$(line_for "$out" notifications.slack.webhook)" "(c) a literal in a secret-typed key prints <masked>"
assert_eq "notifications.discord.bot_token${TAB}env:T442_SET (set)${TAB}global" "$(line_for "$out" notifications.discord.bot_token)" "(c) a reference to a variable in the environment prints (set)"
assert_eq "notifications.teams.webhook${TAB}env:T442_UNSET (unset)${TAB}global" "$(line_for "$out" notifications.teams.webhook)" "(c) a reference to a variable that is nowhere prints (unset)"
assert_eq "notifications.buzz.bot_key${TAB}env:T442_DOTENV (set)${TAB}global" "$(line_for "$out" notifications.buzz.bot_key)" "(c) a reference the repo .env answers prints (set)"
assert_eq "notifications.slack_api_token${TAB}<masked>${TAB}global" "$(line_for "$out" notifications.slack_api_token)" "(c) an unknown key that reads like a secret is masked"
assert_eq "agents.runner_cmd${TAB}<masked>${TAB}global" "$(line_for "$out" agents.runner_cmd)" "(c) a malformed env: value in an ordinary key is masked"
all="$out
$errtxt
$(show --origin-only 2>&1)
$(show notifications. 2>&1)"
for planted in PLANTEDWEBHOOK9f2 PLANTEDVALUE31 PLANTEDDOTENV42 PLANTEDUNKNOWN77 PLANTEDENVSHAPE55; do
  assert_eq "0" "$(printf '%s\n' "$all" | grep -c "$planted")" "(c) the planted string $planted is in neither stdout nor stderr"
done
# a secret-typed key with no value is listed with an empty value
reset_cfg
assert_eq "notifications.slack.webhook${TAB}${TAB}default" "$(line_for "$(show)" notifications.slack.webhook)" "(c) an unset secret key shows empty, layer default"
# control characters in a value or key cannot forge a row
reset_cfg
proj_json '{"hooks":{"pre_dispatch":"a\tb\nforged\u001b[31m"},"evil\nkey":"v"}'
out="$(show)"
assert_eq "hooks.pre_dispatch${TAB}a\\tb\\nforged\\x1b[31m${TAB}repo" "$(line_for "$out" hooks.pre_dispatch)" "a control character in a value prints escaped"
assert_eq "0" "$(printf '%s\n' "$out" | grep -c '^forged')" "a newline in a value cannot start a row"
assert_contains "$out" 'evil\nkey' "a newline in a key prints escaped"

# ── (e) one python3 spawn ────────────────────────────────────────────────────
reset_cfg
glob_json '{"limits":{"warn_at":0.5},"notifications":{"discord":{"bot_token":"env:T442_SET"}}}'
proj_json '{"notifications":{"slack_channel":"CREPO"}}'
export PIPELINE_BUZZ_CHANNEL=BZ
SHIMDIR="$SANDBOX/shim"; mkdir -p "$SHIMDIR"
PY_LOG="$SANDBOX/py.log"; : > "$PY_LOG"
REAL_PY="$(command -v python3)"
cat > "$SHIMDIR/python3" <<SHIM
#!/usr/bin/env bash
echo spawn >> "$PY_LOG"
exec "$REAL_PY" "\$@"
SHIM
chmod +x "$SHIMDIR/python3"
PATH="$SHIMDIR:$PATH" bash "$CFG_SH" --show >/dev/null 2>&1
assert_eq "1" "$(wc -l < "$PY_LOG" | tr -d ' ')" "(e) --show with global, repo, env and a reference costs one python3 spawn"
: > "$PY_LOG"
PATH="$SHIMDIR:$PATH" bash "$CFG_SH" --show agents. >/dev/null 2>&1
assert_eq "1" "$(wc -l < "$PY_LOG" | tr -d ' ')" "(e) --show agents. costs one python3 spawn"
unset PIPELINE_BUZZ_CHANNEL

# no config file at all: still the table, with the env layer
reset_cfg
rm -rf "${GHOME:?}"; mkdir -p "$GHOME"
export PIPELINE_BUZZ_CHANNEL=BZ
out="$(show)"
assert_contains "$out" "limits.warn_at${TAB}0.8${TAB}default" "no config file: the table defaults list"
assert_contains "$out" "notifications.buzz_channel${TAB}BZ${TAB}env" "no config file: the env layer still applies"
unset PIPELINE_BUZZ_CHANNEL

# ── --dump-layers keeps its old output (install.sh's model hint reads it) ────
reset_cfg
glob_json '{"agents":{"model":"sonnet"},"limits":{"warn_at":0.5}}'
proj_json '{"agents":{"roles":{"qa":{"model":"haiku"}}}}'
assert_eq "$(printf 'agents.model\tglobal\nagents.roles.qa.model\tproject')" "$(bash "$CFG_SH" --dump-layers 2>/dev/null)" "--dump-layers: agents.* file layers only, project|global names"
reset_cfg
assert_eq "" "$(bash "$CFG_SH" --dump-layers 2>/dev/null)" "--dump-layers: no config file, no rows (a default row would hide install.sh's model hint)"
export PIPELINE_BUZZ_CHANNEL=BZ
assert_eq "" "$(bash "$CFG_SH" --dump-layers 2>/dev/null)" "--dump-layers: env and default rows are not listed"
unset PIPELINE_BUZZ_CHANNEL
assert_eq "0" "$(grep -c -- '--dump-layers' "$AGENT_SH")" "pipeline-agent.sh no longer calls --dump-layers"
assert_eq "1" "$(grep -c -- 'pipeline-config.sh" --show agents\.' "$AGENT_SH")" "pipeline-agent.sh --resolve-all calls --show agents."

# ── --has: a config FILE layer only, documented ──────────────────────────────
reset_cfg
export PIPELINE_BUZZ_CHANNEL=BZ
proj_json '{"merge":{"method":"rebase"}}'
bash "$CFG_SH" --has notifications.buzz_channel >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "--has does not see the env layer"
assert_eq "notifications.buzz_channel${TAB}BZ${TAB}env" "$(line_for "$(show notifications.buzz_channel)" notifications.buzz_channel)" "--show does see it"
assert_contains "$(sed -n '1,80p' "$CFG_SH")" "ignores the env layer" "the header says --has ignores the env layer"
unset PIPELINE_BUZZ_CHANNEL

# ── agents must be a mapping, in either layer ────────────────────────────────
reset_cfg
glob_json '{"agents":"sonnet"}'
proj_json '{"agents":{"model":"haiku"}}'
out="$(bash "$CFG_SH" agents.model 2>"$ERR")"
assert_eq "haiku" "$out" "a non-mapping global agents: does not hide the repo's agents.*"
assert_contains "$(cat "$ERR")" "agents must be a mapping" "a non-mapping agents: in the global file warns"
reset_cfg
glob_json '{"agents":{"model":"sonnet"}}'
proj_json '{"agents":["haiku"]}'
out="$(bash "$CFG_SH" agents.model 2>"$ERR")"
assert_eq "sonnet" "$out" "a non-mapping repo agents: does not erase the global agents.*"
assert_contains "$(cat "$ERR")" "agents must be a mapping" "a non-mapping agents: in the repo file warns"
assert_eq "1" "$(grep -c 'agents must be a mapping' "$ERR")" "the warning prints once"
reset_cfg
proj_json '{"agents":{"model":"haiku"}}'
bash "$CFG_SH" agents.model >/dev/null 2>"$ERR"
assert_eq "0" "$(wc -c < "$ERR" | tr -d ' ')" "a mapping agents: warns nothing"

finish
