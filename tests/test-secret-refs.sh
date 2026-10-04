#!/usr/bin/env bash
# test-secret-refs.sh -- env: secret references, the ~/.talos/.env trust check
# and the global-config trust check (#443, epic #437).
#
# scripts/pipeline-secrets.sh resolves a config value `env:NAME` (and the
# documented SLACK_WEBHOOK_URL-style variables) in this order: exported env,
# repo .env, config reference, ${TALOS_HOME}/.env, legacy ~/.hermes/.env. A
# user-level .env is refused unless it is a 0600 regular file we own outside
# every git work tree; the global config file is refused when it is a symlink to
# something unsafe, owned by someone else, or group/world-writable.
#
# Secret values are assembled at run time and NEVER passed to assert_eq /
# assert_contains: those print the haystack on failure. Every check on a value
# goes through the local helpers below, whose messages are fixed text.
#
# Hermetic: make_sandbox gives a sandbox HOME (never set here), TALOS_HOME points
# into the sandbox, curl and nak are stubs, no webhook is ever real.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

NOTIFY="$TALOS_ROOT/scripts/pipeline-notify.sh"
CFG="$TALOS_ROOT/scripts/pipeline-config.sh"
SECRETS="$TALOS_ROOT/scripts/pipeline-secrets.sh"

# The sandbox repo (git init, in make_sandbox) encloses $SANDBOX/.home, so a
# user-level .env there is "inside a git work tree" and would be refused. Drop
# that repo and run from a project repo of its own: the sandbox itself, the
# sandbox HOME and TALOS_HOME below are then outside every work tree.
rm -rf "${SANDBOX:?}/.git"
PROJ="$SANDBOX/proj"
mkdir -p "$PROJ" || exit 1
git -C "$PROJ" init -q
git -C "$PROJ" remote add origin git@github.com:acme/widget.git
TH="$SANDBOX/th"
mkdir -p "$TH" || exit 1
export CURL_ARGV_LOG="$SANDBOX/curl.argv.log"
export CURL_HDR_LOG="$SANDBOX/curl.hdr.log"
OUT="$SANDBOX/out.txt"
ERR="$SANDBOX/err.txt"
export PIPELINE_THREAD_STATE="$SANDBOX/threads.json"

unset SLACK_WEBHOOK_URL DISCORD_WEBHOOK_URL TEAMS_WEBHOOK_URL SLACK_BOT_TOKEN \
      DISCORD_BOT_TOKEN BUZZ_BOT_PRIVATE_KEY BUZZ_RELAY_URL PIPELINE_SLACK_CHANNEL \
      PIPELINE_DISCORD_CHANNEL PIPELINE_BUZZ_CHANNEL PIPELINE_BUZZ_RELAY \
      PIPELINE_NOTIFY_DEBUG PIPELINE_CONFIG GITHUB_TOKEN GH_TOKEN

# ── non-leaking assertions ───────────────────────────────────────────────────
rnd() { printf '%s%s' "$RANDOM" "$RANDOM"; }
# A value assembled from fragments: no secret-shaped literal in this file.
secret_url() { printf 'https://hooks.example.invalid/%s%s%s' "$1" "-" "$(rnd)"; }
secret_tok()  { printf '%s%s%s' "tk" "$1" "$(rnd)"; }

has_in() {  # $1=file $2=value -> 0 when the file holds the value (prints nothing)
  [ -f "$1" ] && grep -qF -- "$2" "$1"
}
check() {  # $1=label, rest = command; passes on exit 0; prints only the label
  local _l="$1"; shift
  if "$@"; then pass "$_l"; else fail "$_l"; fi
}
check_not() {  # $1=label, rest = command; passes on NON-zero exit
  local _l="$1"; shift
  if "$@"; then fail "$_l"; else pass "$_l"; fi
}
curl_got_url() { cut -f1 "$CURL_LOG" | grep -qxF -- "$1"; }
no_leak() {  # $1=label $2=value; the value is in none of the captured streams/logs
  local _l="$1" _v="$2" _f _bad=""
  for _f in "$OUT" "$ERR" "$CURL_ARGV_LOG" "$NAK_LOG"; do
    has_in "$_f" "$_v" && _bad=1
  done
  if [ -z "$_bad" ]; then pass "$_l"; else fail "$_l"; fi
}
lines_in() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

reset() {
  : > "$CURL_LOG"; : > "$CURL_ARGV_LOG"; : > "$CURL_HDR_LOG"; : > "$NAK_LOG"; : > "$NAK_ENV_LOG"
  : > "$OUT"; : > "$ERR"
  rm -f "$PROJ/.env" "$PROJ/talos.pipeline.json" "$TH/.env" "$HOME/.hermes/.env" "$PIPELINE_THREAD_STATE"
  rm -rf "${TH:?}"/* "${HOME:?}/.hermes" "${HOME:?}/.talos"
}
nrun() {  # run notify from the project repo; streams to $OUT / $ERR, status to RC
  ( cd "$PROJ" && PIPELINE_ISSUE_TITLE="T" bash "$NOTIFY" info "#1" "hello" 1 </dev/null >"$OUT" 2>"$ERR" )
  RC=$?
}
write_env() {  # $1=file, rest = lines; mode 0600
  local _f="$1"; shift
  mkdir -p "$(dirname "$_f")"
  : > "$_f"
  chmod 600 "$_f"
  printf '%s\n' "$@" >> "$_f"
}
cfg_ref() {  # $1=json fragment for "notifications"
  printf '{"notifications": %s}\n' "$1" > "$PROJ/talos.pipeline.json"
}

# ═════════════════════════════════════════════════════════════════════════════
# Name and reference syntax (unit)
# ═════════════════════════════════════════════════════════════════════════════
# shellcheck disable=SC1090
. "$SECRETS"
for n in SLACK_WEBHOOK_URL _x A1 a_b_C2; do
  check "name '$n' is accepted" _talos_secret_name_ok "$n"
done
for n in "" "A B" 'A$B' 'A;B' '1A' 'A-B' 'A.B' 'A=B' 'é' 'A$(id)' "A'B" 'A"B'; do
  check_not "malformed name (case: $(printf '%s' "$n" | tr -c 'A-Za-z0-9_' '?')) is rejected" _talos_secret_name_ok "$n"
done

# ═════════════════════════════════════════════════════════════════════════════
# (a) a reference in config delivers through the stubbed curl
# ═════════════════════════════════════════════════════════════════════════════
reset
U="$(secret_url a)"
cfg_ref '{"slack": {"webhook": "env:SLACK_WEBHOOK_URL"}}'
write_env "$TH/.env" "SLACK_WEBHOOK_URL=$U"
TALOS_HOME="$TH" nrun
check "(a) env:SLACK_WEBHOOK_URL in config, value in ~/.talos/.env, delivers via curl" curl_got_url "$U"
check "(a) notify still exits 0" test "$RC" = "0"
no_leak "(f) the webhook value is in no output, stderr or curl argv" "$U"

reset
U="$(secret_url b)"
cfg_ref '{"slack": {"webhook": "env:MY_CUSTOM_HOOK"}}'
MY_CUSTOM_HOOK="$U" nrun
check "a reference to a differently named exported variable delivers" curl_got_url "$U"
no_leak "(f) a referenced exported value is in no output or argv" "$U"

# every platform, through its own config key
reset
UD="$(secret_url d)"; UT="$(secret_url t)"
cfg_ref '{"discord": {"webhook": "env:H_D"}, "teams": {"webhook": "env:H_T"}}'
H_D="$UD" H_T="$UT" nrun
check "discord webhook reference delivers" curl_got_url "$UD"
check "teams webhook reference delivers" curl_got_url "$UT"

# bot tokens: the Authorization header reaches curl (config on stdin), not argv
reset
TK="$(secret_tok s)"
cfg_ref '{"slack": {"bot_token": "env:SLK_TOK"}}'
SLK_TOK="$TK" PIPELINE_SLACK_CHANNEL=C0TEST nrun
check "slack bot_token reference reaches curl as the Authorization header" has_in "$CURL_HDR_LOG" "Authorization: Bearer $TK"
check "slack bot_token delivery went to the slack api" grep -q 'slack.com/api/chat.postMessage' "$CURL_LOG"
no_leak "(f) the slack bot token is in no output or curl argv" "$TK"

reset
TK="$(secret_tok d)"
cfg_ref '{"discord": {"bot_token": "env:DSC_TOK"}}'
DSC_TOK="$TK" PIPELINE_DISCORD_CHANNEL=123456789 nrun
check "discord bot_token reference reaches curl as the Authorization header" has_in "$CURL_HDR_LOG" "Authorization: Bot $TK"
no_leak "(f) the discord bot token is in no output or curl argv" "$TK"

# buzz key: through NOSTR_SECRET_KEY (environment), never argv
reset
BK="$(secret_tok b)"
cfg_ref '{"buzz": {"bot_key": "env:BZ_KEY"}}'
BZ_KEY="$BK" BUZZ_RELAY_URL=ws://localhost:3000 PIPELINE_BUZZ_CHANNEL=chan-1 nrun
check "buzz bot_key reference reaches nak in NOSTR_SECRET_KEY" has_in "$NAK_ENV_LOG" "$BK"
no_leak "(f) the buzz key is in no output or nak argv" "$BK"

# ═════════════════════════════════════════════════════════════════════════════
# Resolution order: exported env > repo .env > config reference > ~/.talos/.env
# > ~/.hermes/.env
# ═════════════════════════════════════════════════════════════════════════════
reset
U1="$(secret_url 1)"; U2="$(secret_url 2)"; U3="$(secret_url 3)"; U4="$(secret_url 4)"; U5="$(secret_url 5)"
cfg_ref '{"slack": {"webhook": "env:REFD_HOOK"}}'
printf 'SLACK_WEBHOOK_URL=%s\n' "$U2" > "$PROJ/.env"
write_env "$TH/.env" "SLACK_WEBHOOK_URL=$U4" "REFD_HOOK=$U3"
write_env "$HOME/.hermes/.env" "SLACK_WEBHOOK_URL=$U5" "REFD_HOOK=$U5"
SLACK_WEBHOOK_URL="$U1" TALOS_HOME="$TH" nrun
check "order 1: exported env wins over everything" curl_got_url "$U1"
check_not "order 1: nothing else was posted" curl_got_url "$U2"

: > "$CURL_LOG"
TALOS_HOME="$TH" nrun
check "order 2: repo .env wins over the config reference and the user-level .env" curl_got_url "$U2"

: > "$CURL_LOG"; rm -f "$PROJ/.env"
TALOS_HOME="$TH" nrun
check "order 3: the config reference (resolved by name) wins over ~/.talos/.env's own variable" curl_got_url "$U3"
check_not "order 3: not the direct ~/.talos/.env value" curl_got_url "$U4"

: > "$CURL_LOG"; rm -f "$PROJ/talos.pipeline.json"
TALOS_HOME="$TH" nrun
check "order 4: ~/.talos/.env wins over ~/.hermes/.env" curl_got_url "$U4"
check_not "order 4: no deprecation line while ~/.hermes/.env is unused" grep -q 'hermes' "$ERR"

: > "$CURL_LOG"; rm -f "$TH/.env"
TALOS_HOME="$TH" nrun
check "order 5: ~/.hermes/.env is the last fallback" curl_got_url "$U5"
no_leak "(f) no value from any layer reaches output or argv" "$U5"

# ═════════════════════════════════════════════════════════════════════════════
# (c) ~/.hermes/.env: works, and warns once
# ═════════════════════════════════════════════════════════════════════════════
reset
UA="$(secret_url h1)"; UB="$(secret_url h2)"
write_env "$HOME/.hermes/.env" "SLACK_WEBHOOK_URL=$UA" "TEAMS_WEBHOOK_URL=$UB"
TALOS_HOME="$TH" nrun
check "(c) the legacy ~/.hermes/.env still delivers (slack)" curl_got_url "$UA"
check "(c) the legacy ~/.hermes/.env still delivers (teams)" curl_got_url "$UB"
check "(c) the deprecation is warned exactly once for two values" test "$(grep -c 'deprecated' "$ERR")" = "1"
check "(c) the deprecation line names the replacement" grep -q '/.env (chmod 600)' "$ERR"
no_leak "(c)(f) the legacy values stay out of output and argv" "$UA"

# a legacy bot token and relay still resolve (the old inline greps)
reset
TK="$(secret_tok l)"
write_env "$HOME/.hermes/.env" "SLACK_BOT_TOKEN=$TK" "BUZZ_RELAY_URL=ws://localhost:3000"
PIPELINE_SLACK_CHANNEL=C0TEST TALOS_HOME="$TH" nrun
check "(c) a bot token from ~/.hermes/.env still reaches curl" has_in "$CURL_HDR_LOG" "Authorization: Bearer $TK"

# dotenv syntax: quotes, export prefix, CRLF
reset
UQ="$(secret_url q)"
printf 'export SLACK_WEBHOOK_URL="%s"\r\n' "$UQ" > "$TH/.env"; chmod 600 "$TH/.env"
TALOS_HOME="$TH" nrun
check ".env: export prefix, double quotes and CRLF are handled" curl_got_url "$UQ"

# ═════════════════════════════════════════════════════════════════════════════
# (b) the .env trust check
# ═════════════════════════════════════════════════════════════════════════════
reset
UB="$(secret_url m)"
write_env "$TH/.env" "SLACK_WEBHOOK_URL=$UB"
chmod 644 "$TH/.env"
TALOS_HOME="$TH" nrun
check "(b) a 0644 .env is not used" test ! -s "$CURL_LOG"
check "(b) the refusal names the path" grep -qF "$TH/.env" "$ERR"
check "(b) the refusal says chmod 600" grep -q 'chmod 600' "$ERR"
check "(b) the refusal is one line" test "$(grep -c 'refusing' "$ERR")" = "1"
check "(b) notify still exits 0" test "$RC" = "0"
no_leak "(b)(f) a refused .env's value is never printed" "$UB"
chmod 600 "$TH/.env"; : > "$CURL_LOG"; : > "$ERR"
TALOS_HOME="$TH" nrun
check "(b) the same file at 0600 is used" curl_got_url "$UB"
check "(b) and prints no refusal" test ! -s "$ERR"

for m in 640 660 666 400 700; do
  : > "$CURL_LOG"; : > "$ERR"; chmod "$m" "$TH/.env"
  TALOS_HOME="$TH" nrun
  check "(b) mode $m is refused (only 0600 passes)" test ! -s "$CURL_LOG"
done

# a symlink is refused, whether it points at a bad file or a good one
reset
UL="$(secret_url n)"
write_env "$SANDBOX/real.env" "SLACK_WEBHOOK_URL=$UL"
chmod 644 "$SANDBOX/real.env"
ln -s "$SANDBOX/real.env" "$TH/.env"
TALOS_HOME="$TH" nrun
check "(b) a symlink to a 0644 .env is refused" test ! -s "$CURL_LOG"
check "(b) the symlink refusal names the path and never the value" grep -qF "$TH/.env" "$ERR"
no_leak "(b)(f) a refused symlink's value is never printed" "$UL"
chmod 600 "$SANDBOX/real.env"; : > "$CURL_LOG"; : > "$ERR"
TALOS_HOME="$TH" nrun
check "(b) a symlink even to a good 0600 .env is refused (regular files only)" test ! -s "$CURL_LOG"
rm -f "$SANDBOX/real.env"

# a directory or a fifo named .env is not a regular file
reset
mkdir "$TH/.env"
TALOS_HOME="$TH" nrun
check "(b) a directory named .env is refused, not crashed on" test "$RC" = "0"
check "(b) a directory named .env produces one refusal line" test "$(grep -c 'refusing' "$ERR")" = "1"
rmdir "$TH/.env"

# outside every git work tree
reset
mkdir -p "$PROJ/th-in-repo"
UG="$(secret_url g)"
write_env "$PROJ/th-in-repo/.env" "SLACK_WEBHOOK_URL=$UG"
TALOS_HOME="$PROJ/th-in-repo" nrun
check "(b) a .env inside a git work tree is refused" test ! -s "$CURL_LOG"
check "(b) the work-tree refusal names the work tree" grep -q 'git work tree' "$ERR"
no_leak "(b)(f) a work-tree .env's value is never printed" "$UG"
rm -rf "${PROJ:?}/th-in-repo"

# the other-owner rule, without a second user: ask the shared check to expect
# another uid. (The real uid is what talos_trust_check always passes.)
reset
write_env "$TH/.env" "X=1"
ME="$(id -u)"
OTHER=$((ME + 1))
_talos_trust_py_run "$ME" lbl secret-file "$TH/.env" ".env" 2>"$ERR"; rc_me=$?
check "trust check: the same file passes for its owner" test "$rc_me" = "0"
_talos_trust_py_run "$OTHER" lbl secret-file "$TH/.env" ".env" 2>"$ERR"; rc_other=$?
check "(b) trust check: a .env owned by someone else is refused" test "$rc_other" = "1"
check "(b) the owner refusal names the path" grep -qF "$TH/.env" "$ERR"
check "(b) the owner refusal is one line" test "$(lines_in "$ERR")" = "1"
_talos_trust_py_run "$OTHER" lbl config-file "$TH/.env" "global config" 2>"$ERR"; rc_other=$?
check "(b) trust check: the config-file policy also refuses another owner" test "$rc_other" = "1"
if [ "$ME" != "0" ] && [ -f /etc/hosts ]; then
  talos_trust_check lbl secret-file /etc/hosts ".env" 2>"$ERR"; rc_root=$?
  check "trust check: a real file owned by root is refused for a normal user" test "$rc_root" = "1"
fi
talos_trust_check lbl secret-file "$SANDBOX/does-not-exist" ".env" 2>"$ERR"; rc_gone=$?
check "trust check: a missing path is refused, not crashed on" test "$rc_gone" = "1"

# ═════════════════════════════════════════════════════════════════════════════
# (d) an unset reference skips the platform with one line, never a crash
# ═════════════════════════════════════════════════════════════════════════════
reset
cfg_ref '{"slack": {"webhook": "env:NOPE_NOT_SET_ANYWHERE"}}'
TALOS_HOME="$TH" nrun
check "(d) an unset reference posts nothing" test ! -s "$CURL_LOG"
check "(d) an unset reference exits 0" test "$RC" = "0"
check "(d) an unset reference prints exactly one stderr line" test "$(lines_in "$ERR")" = "1"
check "(d) the line names the key and the variable" grep -q 'notifications.slack.webhook references NOPE_NOT_SET_ANYWHERE' "$ERR"
# an unset reference on one platform does not stop another
reset
UO="$(secret_url o)"
cfg_ref '{"slack": {"webhook": "env:NOPE_NOT_SET_ANYWHERE"}}'
TEAMS_WEBHOOK_URL="$UO" TALOS_HOME="$TH" nrun
check "(d) another platform still delivers" curl_got_url "$UO"

# ═════════════════════════════════════════════════════════════════════════════
# (e) a malformed reference is rejected and never evaluated
# ═════════════════════════════════════════════════════════════════════════════
LIT="$(secret_url lit)"
# each case: the JSON string value, then a label
while IFS='|' read -r ref lbl; do
  reset
  rm -f "$SANDBOX/PWNED"
  cfg_ref "{\"slack\": {\"webhook\": \"$ref\"}}"
  PWN="touch $SANDBOX/PWNED"
  export PWN
  write_env "$TH/.env" "SLACK_WEBHOOK_URL=$LIT"
  TALOS_HOME="$TH" nrun
  check "(e) $lbl: rejected, nothing posted" test ! -s "$CURL_LOG"
  check "(e) $lbl: exits 0" test "$RC" = "0"
  check "(e) $lbl: one stderr line naming the key" test "$(grep -c 'notifications.slack.webhook is not an env:NAME reference' "$ERR")" = "1"
  check "(e) $lbl: nothing was executed" test ! -e "$SANDBOX/PWNED"
done <<EOF
env:|empty name
env:A B|name with a space
env:A\$B|name with a dollar sign
env:\$(touch $SANDBOX/PWNED)|command substitution in the name
env:A;touch $SANDBOX/PWNED|semicolon in the name
env:\`touch $SANDBOX/PWNED\`|backticks in the name
env:1ABC|name starting with a digit
env:\${PWN}|parameter expansion in the name
EOF
unset PWN

# a literal secret pasted into the config is rejected and never echoed
reset
cfg_ref "{\"slack\": {\"webhook\": \"$LIT\"}}"
TALOS_HOME="$TH" nrun
check "a literal value in a secret key is rejected, nothing posted" test ! -s "$CURL_LOG"
check "the literal-value rejection names the key" grep -q 'notifications.slack.webhook is not an env:NAME reference' "$ERR"
no_leak "(f) a literal value pasted into the config is never echoed" "$LIT"

# a webhook reference must resolve to an https URL: a repo-controlled reference
# cannot point curl at "whatever that variable holds"
reset
cfg_ref '{"slack": {"webhook": "env:SOME_TOKEN_VAR"}}'
NOTURL="$(secret_tok x)"
SOME_TOKEN_VAR="$NOTURL" nrun
check "a webhook reference that resolves to a non-https value posts nothing" test ! -s "$CURL_LOG"
check "the non-https rejection is one line" test "$(grep -c 'does not resolve to an https' "$ERR")" = "1"
no_leak "(f) a rejected non-URL value is never echoed" "$NOTURL"

# a value with a newline cannot add lines to the curl config
reset
BAD="$(printf 'https://hooks.example.invalid/x\nheader = "X-Injected: 1"')"
SLACK_WEBHOOK_URL="$BAD" nrun
check "a webhook value holding a newline posts nothing" test ! -s "$CURL_LOG"
check "the control-character refusal exits 0" test "$RC" = "0"

# ═════════════════════════════════════════════════════════════════════════════
# (f) debug mode and argv
# ═════════════════════════════════════════════════════════════════════════════
reset
UD1="$(secret_url dbg)"; TKD="$(secret_tok dbg)"
write_env "$TH/.env" "SLACK_WEBHOOK_URL=$UD1" "DISCORD_BOT_TOKEN=$TKD" "BUZZ_BOT_PRIVATE_KEY=$TKD"
cfg_ref '{"teams": {"webhook": "env:H_TEAMS"}}'
H_TEAMS="$UD1" PIPELINE_NOTIFY_DEBUG=1 PIPELINE_DISCORD_CHANNEL=123 BUZZ_RELAY_URL=ws://localhost:3000 \
  PIPELINE_BUZZ_CHANNEL=chan-1 TALOS_HOME="$TH" nrun
check "debug mode prints the [pipeline-notify DEBUG] lines" grep -q '\[pipeline-notify DEBUG\]' "$OUT"
no_leak "(f) debug output holds neither webhook values nor bot credentials" "$UD1"
no_leak "(f) debug output holds no bot token or key" "$TKD"
check "debug mode posts nothing" test ! -s "$CURL_LOG"

# live run: no value on any curl or nak argv line (the stubs log argv)
reset
UL2="$(secret_url live)"; TKL="$(secret_tok live)"; BKL="$(secret_tok liveb)"
write_env "$TH/.env" "SLACK_WEBHOOK_URL=$UL2" "DISCORD_BOT_TOKEN=$TKL" "BUZZ_BOT_PRIVATE_KEY=$BKL"
PIPELINE_DISCORD_CHANNEL=123 BUZZ_RELAY_URL=ws://localhost:3000 PIPELINE_BUZZ_CHANNEL=chan-1 \
  TALOS_HOME="$TH" nrun
check "live run delivered to the webhook" curl_got_url "$UL2"
check "live run called curl" test -s "$CURL_ARGV_LOG"
no_leak "(f) the webhook never reaches argv, stdout or stderr" "$UL2"
no_leak "(f) the bot token never reaches argv, stdout or stderr" "$TKL"
no_leak "(f) the buzz key never reaches argv, stdout or stderr" "$BKL"
check "(f) the curl command line is the fixed -K - form" grep -q -- '-K -' "$CURL_ARGV_LOG"

# the source: no eval and no secret on a command line
check "(e) pipeline-secrets.sh carries no eval" test "$(grep -v '^[[:space:]]*#' "$SECRETS" | grep -cw eval)" = "0"
check "(e) pipeline-notify.sh does not eval a secret" test "$(grep -v '^[[:space:]]*#' "$NOTIFY" | grep -cw eval)" = "0"
check "pipeline-notify.sh has no inline ~/.hermes/.env grep left" test "$(grep -c 'grep -m1' "$NOTIFY")" = "0"

# ═════════════════════════════════════════════════════════════════════════════
# The global config trust check (#441 layer, #443 scope)
# ═════════════════════════════════════════════════════════════════════════════
reset
GFILE="$TH/talos.pipeline.json"
gcfg() { printf '{"limits": {"warn_at": 0.5}, "hooks": {"pre_dispatch": "echo hi"}}\n' > "$GFILE"; }
glook() {  # key -> stdout; stderr to $ERR; status to RC
  ( cd "$PROJ" && TALOS_HOME="$TH" bash "$CFG" "$@" 2>"$ERR" )
}

gcfg; chmod 600 "$GFILE"
check "global config 0600 is read" test "$(glook limits.warn_at)" = "0.5"
chmod 644 "$GFILE"
check "global config 0644 (a normal file) is read" test "$(glook limits.warn_at)" = "0.5"
check "a trusted global config prints no warning" test ! -s "$ERR"

for m in 666 664 662 646 620 660; do
  chmod "$m" "$GFILE"
  check "global config mode $m is refused: the table default answers" test "$(glook limits.warn_at)" = "0.8"
  check "global config mode $m: one stderr line" test "$(lines_in "$ERR")" = "1"
  check "global config mode $m: the line names the path and the fix" grep -q "refusing global config.*$GFILE.*chmod go-w" "$ERR"
done
chmod 666 "$GFILE"
check "an untrusted global config does not apply hooks.pre_dispatch" test -z "$(glook hooks.pre_dispatch)"
( cd "$PROJ" && TALOS_HOME="$TH" bash "$CFG" --dump 2>"$ERR" | tr '\0' '\n' | grep -c 'hooks.pre_dispatch' ) > "$OUT"
check "--dump omits every key of an untrusted global config" test "$(cat "$OUT")" = "0"
check "--dump says so once" test "$(lines_in "$ERR")" = "1"
glook limits.warn_at >/dev/null
check "a refused global config never crashes the lookup" test "$?" = "0"

# the repo's own config still applies when the global one is refused
printf '{"limits": {"warn_at": 0.3}}\n' > "$PROJ/talos.pipeline.json"
check "a refused global file leaves the repo config in force" test "$(glook limits.warn_at)" = "0.3"
rm -f "$PROJ/talos.pipeline.json"

# symlinks: to a trusted regular file it is followed; to anything else, refused
rm -f "$GFILE"
printf '{"limits": {"warn_at": 0.5}}\n' > "$SANDBOX/real-cfg.json"; chmod 600 "$SANDBOX/real-cfg.json"
ln -s "$SANDBOX/real-cfg.json" "$GFILE"
check "a symlink to a trusted regular file is followed" test "$(glook limits.warn_at)" = "0.5"
chmod 666 "$SANDBOX/real-cfg.json"
check "a symlink to a world-writable file is refused" test "$(glook limits.warn_at)" = "0.8"
check "the symlink refusal is one line naming the link" test "$(grep -c "refusing global config.*$GFILE" "$ERR")" = "1"
rm -f "$GFILE" "$SANDBOX/real-cfg.json"
if [ "$ME" != "0" ] && [ -f /etc/hosts ]; then
  ln -s /etc/hosts "$GFILE"
  check "a symlink to a file owned by another user is refused" test "$(glook limits.warn_at)" = "0.8"
  check "the other-owner refusal names the owner problem" grep -q 'owned by uid' "$ERR"
  rm -f "$GFILE"
fi
ln -s "$SANDBOX/no-such-target" "$GFILE"
check "a dangling symlink reads as absent (no crash)" test "$(glook limits.warn_at)" = "0.8"
rm -f "$GFILE"

# the shared helper answers for both policies
gcfg; chmod 600 "$GFILE"
talos_trust_check lbl config-file "$GFILE" "global config"; rc=$?
check "the shared helper: config-file policy accepts a 0600 file" test "$rc" = "0"
chmod 666 "$GFILE"
talos_trust_check lbl config-file "$GFILE" "global config" 2>"$ERR"; rc=$?
check "the shared helper: config-file policy refuses 0666" test "$rc" = "1"
check "pipeline-config.sh holds no second stat check" test "$(grep -c 'S_ISREG\|st_uid\|S_IMODE' "$CFG")" = "0"
check "pipeline-config.sh uses the shared trust_problem" grep -q 'trust_problem(os.geteuid()' "$CFG"

# a missing helper fails closed for the global file
mkdir -p "$SANDBOX/partial" || exit 1
cp "$CFG" "$TALOS_ROOT/scripts/pipeline-defaults.sh" "$TALOS_ROOT/scripts/pipeline-defaults-check.sh" "$SANDBOX/partial/"
gcfg; chmod 600 "$GFILE"
( cd "$PROJ" && TALOS_HOME="$TH" bash "$SANDBOX/partial/pipeline-config.sh" limits.warn_at 2>"$ERR" ) > "$OUT"
check "without pipeline-secrets.sh the global config is refused (fail closed)" test "$(cat "$OUT")" = "0.8"
check "without pipeline-secrets.sh one line says why" test "$(grep -c 'pipeline-secrets.sh is missing' "$ERR")" = "1"

finish
