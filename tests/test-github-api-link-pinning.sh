#!/usr/bin/env bash
# Regression tests for #320: github-api pagination must only follow a
# Link: rel="next" URL on the configured API origin (https, same host, same
# port). Any other next link stops paging, names only the refused host on
# stderr, exits non-zero with no partial output (#302 contract), and never
# sends the Authorization header anywhere off the API origin.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
export TALOS_RETRY_SLEEP_SCALE=0
export GITHUB_TOKEN="tok-320-secret"
printf '{"vcs": {"provider": "github-api", "repo": "acme/widget"}}' > talos.pipeline.json

_page1='[{"filename":"a.txt"}]'
_page2='[{"filename":"b.txt"}]'

# _320_run <next-url> -- run pr-files with page 1 advertising <next-url>.
# Leaves stdout in $out, stderr in $err, exit code in $rc.
_320_run() {
  : > "$CURL_LOG"
  printf '%s\n' "$1" "" > "$CURL_LINK_QUEUE"
  printf '%s\n' "$_page1" "$_page2" > "$CURL_QUEUE"
  out="$(bash "$VCS" pr-files 5 2>"$SANDBOX/err")"; rc=$?
  err="$(cat "$SANDBOX/err")"
}

# _320_refused <label> <next-url> <host-in-error>
_320_refused() {
  local _label="$1" _url="$2" _host="$3"
  _320_run "$_url"
  assert_eq "1" "$rc" "#320 $_label: pr-files exits non-zero"
  assert_eq "" "$out" "#320 $_label: no partial output"
  assert_contains "$err" "$_host" "#320 $_label: stderr names the refused host"
  assert_not_contains "$err" "leak=1" "#320 $_label: stderr omits the query string"
  assert_not_contains "$err" "$GITHUB_TOKEN" "#320 $_label: stderr never contains the token"
  assert_eq "1" "$(wc -l < "$CURL_LOG" | tr -d ' ')" "#320 $_label: only the first page was requested"
  assert_eq "" "$(grep -F "$_url" "$CURL_LOG" | cut -f3)" \
    "#320 $_label: no Authorization header sent to the refused URL"
}

# ── Same-origin next links are followed (different path and query) ─────────
_320_run "https://api.github.com/repositories/123/pulls/5/files?per_page=100&page=2"
assert_eq "0" "$rc" "#320 same host: pr-files exits 0"
assert_eq "$(printf 'a.txt\nb.txt')" "$out" "#320 same host: both pages returned"
assert_eq "Authorization: Bearer" "$(grep -F '/repositories/123/' "$CURL_LOG" | cut -f3)" \
  "#320 same host: page 2 is fetched with the token"

_320_run "https://API.github.com:443/repos/acme/widget/pulls/5/files?page=2"
assert_eq "0" "$rc" "#320 explicit :443 and host case: treated as the same origin"
assert_eq "$(printf 'a.txt\nb.txt')" "$out" "#320 explicit :443: both pages returned"

# ── Off-origin next links are refused before any request ────────────────────
_320_refused "cross host" "https://evil.example.com/repos/acme/widget/pulls/5/files?leak=1" "evil.example.com"
_320_refused "http downgrade" "http://api.github.com/repos/acme/widget/pulls/5/files?leak=1" "api.github.com"
_320_refused "different port" "https://api.github.com:8443/repos/acme/widget/pulls/5/files?leak=1" "8443"
_320_refused "userinfo host trick" "https://api.github.com@evil.example.com/pulls/5/files?leak=1" "evil.example.com"
_320_refused "subdomain lookalike" "https://api.github.com.evil.example.com/pulls/5/files?leak=1" "api.github.com.evil.example.com"

rm -f talos.pipeline.json
finish
