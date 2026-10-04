#!/usr/bin/env bash
# test-env-allowlist.sh -- a .env may only export the notification variables
# (#476, found in the PR #474 security review of #443).
#
# The repo .env comes from the checkout Talos works in, which can be a PR
# branch. pipeline-notify.sh used to export every key in it, so BASH_ENV=...
# made every non-interactive bash child (the curl stub here is one) source an
# attacker's file. scripts/pipeline-secrets.sh now PARSES a .env and exports only
# _TALOS_DOTENV_ALLOW; a hard deny list wins even over that list.
#
# Hermetic: make_sandbox gives a sandbox HOME (never set here) and
# TALOS_HERMES_ENV, curl and nak are stubs, no webhook is ever real. Webhook
# values are fake https://hooks.example.invalid/... URLs.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

NOTIFY="$TALOS_ROOT/scripts/pipeline-notify.sh"
SECRETS="$TALOS_ROOT/scripts/pipeline-secrets.sh"

# A user-level .env inside a git work tree is refused, so drop the sandbox repo
# (make_sandbox's) and run from a project repo of its own, as test-secret-refs.sh
# does.
rm -rf "${SANDBOX:?}/.git"
PROJ="$SANDBOX/proj"
mkdir -p "$PROJ" || exit 1
git -C "$PROJ" init -q
git -C "$PROJ" remote add origin git@github.com:acme/widget.git
TH="$SANDBOX/th"
mkdir -p "$TH" || exit 1
OUT="$SANDBOX/out.txt"
ERR="$SANDBOX/err.txt"
export PIPELINE_THREAD_STATE="$SANDBOX/threads.json"

unset SLACK_WEBHOOK_URL DISCORD_WEBHOOK_URL TEAMS_WEBHOOK_URL SLACK_BOT_TOKEN \
      DISCORD_BOT_TOKEN BUZZ_BOT_PRIVATE_KEY BUZZ_RELAY_URL PIPELINE_SLACK_CHANNEL \
      PIPELINE_DISCORD_CHANNEL PIPELINE_BUZZ_CHANNEL PIPELINE_BUZZ_RELAY \
      PIPELINE_NOTIFY_DEBUG PIPELINE_CONFIG GITHUB_TOKEN GH_TOKEN BASH_ENV

URL1="https://hooks.example.invalid/one-$RANDOM"
URL2="https://hooks.example.invalid/two-$RANDOM"

has_in() { [ -f "$1" ] && grep -qF -- "$2" "$1"; }
curl_got_url() { cut -f1 "$CURL_LOG" | grep -qxF -- "$1"; }
check() {  # $1=label, rest = command; passes on exit 0
  local _l="$1"; shift
  if "$@"; then pass "$_l"; else fail "$_l"; fi
}
check_not() {  # $1=label, rest = command; passes on NON-zero exit
  local _l="$1"; shift
  if "$@"; then fail "$_l"; else pass "$_l"; fi
}
reset() {
  : > "$CURL_LOG"; : > "$OUT"; : > "$ERR"
  rm -f "$PROJ/.env" "$PROJ/talos.pipeline.json" "$PIPELINE_THREAD_STATE" "$SANDBOX"/marker-*
  rm -rf "${TH:?}"/* "${HOME:?}/.hermes" "${HOME:?}/.talos"
}
nrun() {  # run notify from the project repo; streams to $OUT / $ERR
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
# A script that records it ran: what BASH_ENV, or a PATH-shadowing curl, would run.
make_marker_script() {  # $1=path $2=marker file
  printf '#!/usr/bin/env bash\n: > "%s"\n' "$2" > "$1"
  chmod 755 "$1"
}

# ═════════════════════════════════════════════════════════════════════════════
# (a) BASH_ENV in the repo .env must not run: end to end through notify
# ═════════════════════════════════════════════════════════════════════════════
reset
M="$SANDBOX/marker-bashenv"
make_marker_script "$PROJ/evil.sh" "$M"
write_env "$PROJ/.env" "BASH_ENV=$PROJ/evil.sh" "SLACK_WEBHOOK_URL=$URL1"
nrun
check "(a) the repo .env sets BASH_ENV: notify still exits 0" test "$RC" = "0"
assert_file_absent "$M" "(a) BASH_ENV from the repo .env is not exported, so no child sources the marker script"
check "(a) the allow-listed key beside it still delivers" curl_got_url "$URL1"
check "(a) stderr names BASH_ENV" has_in "$ERR" "ignoring BASH_ENV"
check_not "(a) stderr never names the value" has_in "$ERR" "$PROJ/evil.sh"

# Control: the same script DOES run when the operator exports BASH_ENV, so the
# marker really does detect "a child bash sourced it".
reset
M="$SANDBOX/marker-bashenv-ctl"
make_marker_script "$PROJ/evil.sh" "$M"
write_env "$PROJ/.env" "SLACK_WEBHOOK_URL=$URL1"
( cd "$PROJ" && BASH_ENV="$PROJ/evil.sh" PIPELINE_ISSUE_TITLE="T" bash "$NOTIFY" info "#1" "hello" 1 </dev/null >"$OUT" 2>"$ERR" )
assert_file_exists "$M" "(a) control: an exported BASH_ENV makes the stub curl source the marker (the probe works)"

# ═════════════════════════════════════════════════════════════════════════════
# (b) PATH from the repo .env must not shadow curl
# ═════════════════════════════════════════════════════════════════════════════
reset
M="$SANDBOX/marker-path"
mkdir -p "$PROJ/evilbin"
make_marker_script "$PROJ/evilbin/curl" "$M"
write_env "$PROJ/.env" "PATH=$PROJ/evilbin:$PATH" "SLACK_WEBHOOK_URL=$URL1"
nrun
assert_file_absent "$M" "(b) PATH from the repo .env is not exported: the shadow curl never runs"
check "(b) the real (stub) curl still delivered" curl_got_url "$URL1"
check "(b) stderr names PATH" has_in "$ERR" "ignoring PATH "

# ═════════════════════════════════════════════════════════════════════════════
# (c) the deny list and the allow list, at the loader (unit)
# ═════════════════════════════════════════════════════════════════════════════
# One bash -c per case so nothing leaks between them. $1 of the inner script is
# the .env file. It prints one "BAD <name>" per denied name that was exported or
# changed, and "done" last.
DENIED="BASH_ENV ENV PATH LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH PYTHONPATH PYTHONSTARTUP GIT_DIR GIT_SSH_COMMAND PROMPT_COMMAND IFS SHELLOPTS BASHOPTS HOME TMPDIR TALOS_ROLE TALOS_HERMES_ENV HTTPS_PROXY https_proxy"
ENVF="$SANDBOX/denied.env"
: > "$ENVF"
UNSETS=""
for n in $DENIED; do
  printf '%s=/evil/%s\n' "$n" "$n" >> "$ENVF"
  case "$n" in PATH|HOME|TMPDIR|IFS|SHELLOPTS) ;; *) UNSETS="$UNSETS -u $n" ;; esac
done
printf 'export SLACK_WEBHOOK_URL=%s\n' "$URL1" >> "$ENVF"

PROBE='
. "$1"
[ "${2:-}" = widen ] && _TALOS_DOTENV_ALLOW="$_TALOS_DOTENV_ALLOW $3 "
p0="$PATH"; h0="$HOME"; t0="${TMPDIR:-}"; i0="$IFS"; so0="$SHELLOPTS"
for _v in BASH_ENV ENV LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH PYTHONPATH PYTHONSTARTUP GIT_DIR GIT_SSH_COMMAND PROMPT_COMMAND BASHOPTS TALOS_ROLE TALOS_HERMES_ENV HTTPS_PROXY https_proxy; do
  [ -z "${!_v+x}" ] || echo "BAD $_v"
done
talos_dotenv_load "$4" "repo .env"
for _v in BASH_ENV ENV LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH PYTHONPATH PYTHONSTARTUP GIT_DIR GIT_SSH_COMMAND PROMPT_COMMAND BASHOPTS TALOS_ROLE TALOS_HERMES_ENV HTTPS_PROXY https_proxy; do
  [ -z "${!_v+x}" ] || echo "BAD $_v"
done
[ "$PATH" = "$p0" ] || echo "BAD PATH"
[ "$HOME" = "$h0" ] || echo "BAD HOME"
[ "${TMPDIR:-}" = "$t0" ] || echo "BAD TMPDIR"
[ "$IFS" = "$i0" ] || echo "BAD IFS"
[ "$SHELLOPTS" = "$so0" ] || echo "BAD SHELLOPTS"
[ "${TALOS_HOME:-}" = "${TH0:-}" ] || echo "BAD TALOS_HOME"
printf "slack=%s\n" "${SLACK_WEBHOOK_URL:-}"
echo done
'

RES="$(env $UNSETS TH0="${TALOS_HOME:-}" bash -c "$PROBE" probe "$SECRETS" narrow x "$ENVF" 2>"$ERR")"
assert_not_contains "$RES" "BAD" "(c) no denied name is exported or changed by the loader"
assert_contains "$RES" "slack=$URL1" "(c) the allow-listed key in the same file (export prefix) is exported"
for n in $DENIED; do
  check "(c) one stderr line names $n" grep -q "ignoring $n (" "$ERR"
done
check_not "(c) stderr never holds a value" grep -q '/evil/' "$ERR"
assert_eq "1" "$(grep -c 'ignoring PATH (' "$ERR")" "(c) one line per ignored key"

# The deny list wins even if a name were ever added to the allow list.
RES="$(env $UNSETS TH0="${TALOS_HOME:-}" bash -c "$PROBE" probe "$SECRETS" widen "BASH_ENV PATH LD_PRELOAD GIT_DIR HOME TMPDIR TALOS_ROLE IFS PYTHONPATH DYLD_INSERT_LIBRARIES PROMPT_COMMAND" "$ENVF" 2>/dev/null)"
assert_not_contains "$RES" "BAD" "(c) widening the allow list does not export a denied name (the deny list wins)"

# ═════════════════════════════════════════════════════════════════════════════
# (d) every allow-listed name works, and the parse rules
# ═════════════════════════════════════════════════════════════════════════════
ALLOWED="SLACK_WEBHOOK_URL DISCORD_WEBHOOK_URL TEAMS_WEBHOOK_URL SLACK_BOT_TOKEN DISCORD_BOT_TOKEN BUZZ_BOT_PRIVATE_KEY BUZZ_RELAY_URL PIPELINE_SLACK_CHANNEL PIPELINE_DISCORD_CHANNEL PIPELINE_BUZZ_CHANNEL PIPELINE_BUZZ_RELAY"
ENVF="$SANDBOX/allowed.env"
: > "$ENVF"
for n in $ALLOWED; do printf '%s=v-%s\n' "$n" "$n" >> "$ENVF"; done
GOT="$(env bash -c '. "$1"; talos_dotenv_load "$2" x; for n in $3; do printf "%s=%s\n" "$n" "${!n-UNSET}"; done' probe "$SECRETS" "$ENVF" "$ALLOWED" 2>"$ERR")"
for n in $ALLOWED; do
  assert_contains "$GOT" "$n=v-$n" "(d) $n is exported from a .env"
done
assert_eq "0" "$(wc -c < "$ERR" | tr -d ' ')" "(d) no stderr when every key is allow-listed"

# exported env wins; quotes are stripped literally; = inside a value; CRLF
ENVF="$SANDBOX/parse.env"
printf '%s\r\n' \
  'SLACK_WEBHOOK_URL="https://hooks.example.invalid/dq?a=b&c=d"' \
  "DISCORD_WEBHOOK_URL='https://hooks.example.invalid/sq'" \
  'TEAMS_WEBHOOK_URL=https://hooks.example.invalid/bare' \
  'SLACK_BOT_TOKEN=exported-wins-not' \
  '# a comment' \
  '' \
  'no equals sign here' > "$ENVF"
GOT="$(SLACK_BOT_TOKEN=from-env bash -c '. "$1"; talos_dotenv_load "$2" x; printf "%s\n" "$SLACK_WEBHOOK_URL" "$DISCORD_WEBHOOK_URL" "$TEAMS_WEBHOOK_URL" "$SLACK_BOT_TOKEN"' probe "$SECRETS" "$ENVF" 2>"$ERR")"
assert_eq "https://hooks.example.invalid/dq?a=b&c=d
https://hooks.example.invalid/sq
https://hooks.example.invalid/bare
from-env" "$GOT" "(d) quotes stripped, CRLF tolerated, = kept, an exported value beats the .env"
assert_eq "0" "$(wc -c < "$ERR" | tr -d ' ')" "(d) comments, blanks and lines without = are skipped silently"

# ═════════════════════════════════════════════════════════════════════════════
# (e) values are parsed, never evaluated
# ═════════════════════════════════════════════════════════════════════════════
reset
rm -f "$PROJ/pwned" "$PROJ/pwned-bt" "$PROJ/pwned-var"
write_env "$PROJ/.env" \
  "SLACK_WEBHOOK_URL=https://hooks.example.invalid/\$(touch $PROJ/pwned)" \
  "DISCORD_WEBHOOK_URL=\"https://hooks.example.invalid/\`touch $PROJ/pwned-bt\`\"" \
  "PIPELINE_SLACK_CHANNEL=\${PROJ_PWN:-x}" \
  "export \$(touch $PROJ/pwned-var)=1"
nrun
assert_file_absent "$PROJ/pwned" "(e) \$(touch x) in a value is not run"
assert_file_absent "$PROJ/pwned-bt" "(e) backticks in a value are not run"
assert_file_absent "$PROJ/pwned-var" "(e) a command substitution in a key is not run"
check "(e) the \$(...) value reaches curl as literal text" curl_got_url "https://hooks.example.invalid/\$(touch $PROJ/pwned)"
check "(e) the backtick value reaches curl as literal text" curl_got_url "https://hooks.example.invalid/\`touch $PROJ/pwned-bt\`"
GOT="$(bash -c '. "$1"; talos_dotenv_load "$2" x; printf "%s" "$PIPELINE_SLACK_CHANNEL"' probe "$SECRETS" "$PROJ/.env" 2>/dev/null)"
assert_eq '${PROJ_PWN:-x}' "$GOT" "(e) a parameter expansion in a value is not expanded"
check_not "(e) a malformed key line is not echoed to stderr" grep -q 'touch' "$ERR"

# the loader has no eval-like construct
check_not "(e) pipeline-secrets.sh never sources, evals or exports a command substitution" \
  grep -nE '^[^#]*((^|[ ;(])(eval|source) |export +\$\()' "$SECRETS"

# ═════════════════════════════════════════════════════════════════════════════
# (f) the legacy fallback is overridable, and a sandboxed run reads nothing
#     outside the sandbox
# ═════════════════════════════════════════════════════════════════════════════
# $HOME/.hermes/.env and $HOME/.talos/.env stand in for the real ones: bait
# files, holding URLs no assertion expects to see delivered.
reset
write_env "$HOME/.hermes/.env" "SLACK_WEBHOOK_URL=$URL1"
write_env "$HOME/.talos/.env" "DISCORD_WEBHOOK_URL=$URL2"
check "(f) make_sandbox set TALOS_HERMES_ENV inside the sandbox" test "$TALOS_HERMES_ENV" = "$HOME/.hermes/.env"
TALOS_HERMES_ENV="" nrun
check_not "(f) an empty TALOS_HERMES_ENV: the bait ~/.hermes/.env is never read" curl_got_url "$URL1"
check_not "(f) an empty TALOS_HERMES_ENV: no deprecation line either" has_in "$ERR" "hermes"
check "(f) ~/.talos/.env (HOME-derived, TALOS_HOME unset) is the sandbox one" curl_got_url "$URL2"

reset
write_env "$HOME/.hermes/.env" "SLACK_WEBHOOK_URL=$URL1"
write_env "$TH/hermes.env" "SLACK_WEBHOOK_URL=$URL2"
TALOS_HERMES_ENV="$TH/hermes.env" nrun
check "(f) TALOS_HERMES_ENV=<path> reads that file" curl_got_url "$URL2"
check_not "(f) ... and not the HOME-derived one" curl_got_url "$URL1"
check "(f) the deprecation line still appears once" test "$(grep -c 'hermes' "$ERR")" = "1"

# Control: with the override unset the fallback follows HOME, which is why the
# override exists.
reset
write_env "$HOME/.hermes/.env" "SLACK_WEBHOOK_URL=$URL1"
( unset TALOS_HERMES_ENV; cd "$PROJ" && PIPELINE_ISSUE_TITLE="T" bash "$NOTIFY" info "#1" "hello" 1 </dev/null >"$OUT" 2>"$ERR" )
check "(f) control: with TALOS_HERMES_ENV unset the HOME-derived file is read" curl_got_url "$URL1"

# A denied or unlisted name in a user-level .env is not exported either: the
# user-level files are only ever looked up, never loaded.
reset
M="$SANDBOX/marker-user"
make_marker_script "$PROJ/evil.sh" "$M"
write_env "$HOME/.talos/.env" "BASH_ENV=$PROJ/evil.sh" "SLACK_WEBHOOK_URL=$URL1"
nrun
assert_file_absent "$M" "(f) BASH_ENV in ~/.talos/.env is never exported"
check "(f) ~/.talos/.env still delivers" curl_got_url "$URL1"
reset
write_env "$TH/hermes.env" "BASH_ENV=$PROJ/evil.sh" "SLACK_WEBHOOK_URL=$URL1"
TALOS_HERMES_ENV="$TH/hermes.env" nrun
assert_file_absent "$M" "(f) BASH_ENV in the legacy hermes .env is never exported"
check "(f) the legacy hermes .env still delivers" curl_got_url "$URL1"

# env:NAME may not point at a denied name
reset
write_env "$TH/hermes.env" "PATH=$URL1"
printf '{"notifications": {"slack": {"webhook": "env:PATH"}}}\n' > "$PROJ/talos.pipeline.json"
TALOS_HERMES_ENV="$TH/hermes.env" nrun
check_not "(f) env:PATH is not resolved from a .env (deny list)" curl_got_url "$URL1"

finish
