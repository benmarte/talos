#!/usr/bin/env bash
# test-github-rate-limit-wait.sh -- a GitHub rate-limit answer is a wait, not a
# failure (#1004).
#
#   AC1  a 403 with x-ratelimit-remaining: 0 makes pipeline-vcs.sh exit 7 and
#        print one `rate-limited reset=<epoch>` line
#   AC2  talos.sh next maps it to `wait reason=rate-limited retry_after_s=<n>`
#        (n = reset - now, at least 1), never `stop reason=state-unavailable`
#   AC3  pr-checks-required --wait sleeps toward the reset within its budget and
#        reads again; it does not fail at once
#   AC4  a secondary limit (429, or 403 with Retry-After) is handled the same
#        way, from Retry-After
#   AC5  a 403 with no rate-limit header or text still fails as before
#
# curl stub only (github-api), a sleep stub on PATH for the waits: no network,
# no real sleep.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
TALOS="$TALOS_ROOT/scripts/talos.sh"
ERR="$SANDBOX/stderr"
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
github_leg curl ',"merge": {"required_checks": ["build"]}, "pr": {"draft": false}'
mv talos.pipeline.json "$PIPELINE_CONFIG"
export STUB_CURRENT_USER="operator1"
export TALOS_RETRY_SLEEP_SCALE=0

# A sleep stub that logs its argument and returns at once.
mkdir -p "$SANDBOX/sleepbin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$SANDBOX/sleep.log" > "$SANDBOX/sleepbin/sleep"
chmod +x "$SANDBOX/sleepbin/sleep"

printf '{"timestamp": "2026-10-11T10:00:00Z", "message": {"id": "m1", "usage": {"input_tokens": 5, "cache_read_input_tokens": 1000, "output_tokens": 50}}}\n' > "$SANDBOX/session.jsonl"
export TALOS_TRANSCRIPT_PATH="$SANDBOX/session.jsonl"

RL_BODY='403:{"message":"API rate limit exceeded for user ID 1.","documentation_url":"https://docs.github.com/rest"}'
rl_reset() { unset CURL_RATE_LIMIT_REMAINING CURL_RATE_LIMIT_RESET CURL_RETRY_AFTER; }
curl_calls() { grep -c "pulls\|commits" "$CURL_LOG" | tr -d ' '; }
now() { date +%s; }

# ── AC1: 403 + x-ratelimit-remaining: 0 -> exit 7 and one reset line ─────────
T="$(now)"; RESET=$((T + 300))
export CURL_RATE_LIMIT_REMAINING=0 CURL_RATE_LIMIT_RESET="$RESET"
: > "$CURL_LOG"
printf '%s\n' "$RL_BODY" > "$CURL_QUEUE"
OUT="$(bash "$VCS" list-prs 2>"$ERR")"; RC=$?
assert_eq "7" "$RC" "AC1 a primary rate limit exits with the rate-limit code"
assert_eq "" "$OUT" "AC1 nothing on stdout"
assert_eq "1" "$(grep -c '^rate-limited reset=' "$ERR")" "AC1 exactly one rate-limited line on stderr"
assert_contains "$(cat "$ERR")" "rate-limited reset=$RESET" "AC1 the reset is x-ratelimit-reset"
assert_eq "1" "$(curl_calls)" "AC1 a reset past the retry cap is not retried in place"

# ── AC2: talos.sh next maps it to a wait ─────────────────────────────────────
: > "$CURL_LOG"
printf '%s\n' "$RL_BODY" > "$CURL_QUEUE"
OUT="$(bash "$TALOS" next 2>"$ERR")"; RC=$?
assert_eq "0" "$RC" "AC2 next ends with exit 0, like another wait"
case "$OUT" in
  "action=wait reason=rate-limited retry_after_s="*) pass "AC2 next prints wait reason=rate-limited retry_after_s" ;;
  *) fail "AC2 next prints wait reason=rate-limited retry_after_s" "got: $OUT" ;;
esac
N="${OUT##*retry_after_s=}"
case "$N" in
  '' | *[!0-9]*) fail "AC2 retry_after_s is a number" "got: $N" ;;
  *) if [ "$N" -ge 290 ] && [ "$N" -le 300 ]; then pass "AC2 retry_after_s is reset - now"; else fail "AC2 retry_after_s is reset - now" "got: $N"; fi ;;
esac
assert_not_contains "$OUT" "state-unavailable" "AC2 not the state-unavailable stop"

# A reset already past (the quota came back while we retried): at least 1.
export CURL_RATE_LIMIT_RESET=$((T - 50))
printf '%s\n' "$RL_BODY" "$RL_BODY" "$RL_BODY" "$RL_BODY" "$RL_BODY" "$RL_BODY" > "$CURL_QUEUE"
OUT="$(bash "$TALOS" next 2>"$ERR")"; RC=$?
assert_eq "action=wait reason=rate-limited retry_after_s=1" "$OUT" "AC2 a reset in the past waits at least 1 s"
assert_eq "0" "$RC" "AC2 a past reset also exits 0"

# ── AC3: pr-checks-required --wait sleeps toward the reset, then reads again ─
PR_JSON='{"number":9,"head":{"sha":"1111111111111111111111111111111111111111"},"state":"open"}'
RUNS_JSON='{"check_runs":[{"name":"build","status":"completed","conclusion":"success","started_at":"2026-10-11T10:00:00Z","completed_at":"2026-10-11T10:01:00Z","html_url":"https://x/1","id":1}]}'
T="$(now)"; RESET=$((T + 300))
export CURL_RATE_LIMIT_REMAINING=0 CURL_RATE_LIMIT_RESET="$RESET"
: > "$CURL_LOG"; : > "$SANDBOX/sleep.log"
printf '%s\n%s\n%s\n' "$RL_BODY" "$PR_JSON" "$RUNS_JSON" > "$CURL_QUEUE"
TALOS_RETRY_SLEEP_SCALE=1 PATH="$SANDBOX/sleepbin:$PATH" bash "$VCS" pr-checks-required 9 --wait 600 >/dev/null 2>"$ERR"; RC=$?
assert_eq "0" "$RC" "AC3 the wait outlasts the rate limit and the read then passes"
S="$(head -n 1 "$SANDBOX/sleep.log" 2>/dev/null)"
case "$S" in
  '' | *[!0-9.]*) fail "AC3 one sleep toward the reset" "sleep.log: $(cat "$SANDBOX/sleep.log")" ;;
  *) if [ "${S%.*}" -ge 290 ] && [ "${S%.*}" -le 300 ]; then pass "AC3 one sleep toward the reset"; else fail "AC3 one sleep toward the reset" "slept: $S"; fi ;;
esac
assert_eq "1" "$(grep -c . "$SANDBOX/sleep.log")" "AC3 it slept once, not a poll storm"
assert_eq "2" "$(grep -c '/pulls/9' "$CURL_LOG")" "AC3 the PR is read again after the sleep"

# A budget shorter than the reset: it sleeps its budget, reads again, then ends
# as a rate limit (exit 7), not as a pending or failed check.
: > "$CURL_LOG"; : > "$SANDBOX/sleep.log"
printf '%s\n%s\n' "$RL_BODY" "$RL_BODY" > "$CURL_QUEUE"
TALOS_RETRY_SLEEP_SCALE=1 PATH="$SANDBOX/sleepbin:$PATH" bash "$VCS" pr-checks-required 9 --wait 100 >/dev/null 2>"$ERR"; RC=$?
assert_eq "7" "$RC" "AC3 a rate limit that outlasts the budget ends exit 7"
S="$(head -n 1 "$SANDBOX/sleep.log" 2>/dev/null)"
case "$S" in
  '' | *[!0-9.]*) fail "AC3 the sleep is bounded by the budget" "sleep.log: $(cat "$SANDBOX/sleep.log")" ;;
  *) if [ "${S%.*}" -le 100 ] && [ "${S%.*}" -ge 90 ]; then pass "AC3 the sleep is bounded by the budget"; else fail "AC3 the sleep is bounded by the budget" "slept: $S"; fi ;;
esac
assert_contains "$(cat "$ERR")" "rate-limited reset=$RESET" "AC3 the end names the reset"

# ── AC4: a secondary limit, from Retry-After ─────────────────────────────────
rl_reset
T="$(now)"
export CURL_RETRY_AFTER=120
for ST in 429 403; do
  : > "$CURL_LOG"
  printf '%s\n' "$ST"':{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}' > "$CURL_QUEUE"
  OUT="$(bash "$VCS" list-prs 2>"$ERR")"; RC=$?
  assert_eq "7" "$RC" "AC4 a secondary limit ($ST) exits with the rate-limit code"
  R="$(sed -n 's/^rate-limited reset=\([0-9]*\)$/\1/p' "$ERR")"
  case "$R" in
    '' | *[!0-9]*) fail "AC4 ($ST) the reset is now + Retry-After" "stderr: $(cat "$ERR")" ;;
    *) if [ "$R" -ge $((T + 118)) ] && [ "$R" -le $(($(now) + 121)) ]; then pass "AC4 ($ST) the reset is now + Retry-After"; else fail "AC4 ($ST) the reset is now + Retry-After" "got: $R"; fi ;;
  esac
done
# A 403 with a Retry-After and no other text is a secondary limit too.
: > "$CURL_LOG"
printf '403:{"message":"Forbidden"}\n' > "$CURL_QUEUE"
OUT="$(bash "$VCS" list-prs 2>"$ERR")"; RC=$?
assert_eq "7" "$RC" "AC4 a 403 carrying Retry-After is a secondary limit"
rl_reset

# ── AC5 (same: other 403s are not rate limits) ───────────────────────────────
: > "$CURL_LOG"
printf '403:{"message":"Resource not accessible by integration"}\n' > "$CURL_QUEUE"
OUT="$(bash "$VCS" list-prs 2>"$ERR")"; RC=$?
assert_eq "1" "$RC" "AC5 a 403 with no rate-limit header or text still exits 1"
assert_contains "$(cat "$ERR")" "HTTP 403" "AC5 the 403 is reported as before"
assert_not_contains "$(cat "$ERR")" "rate-limited" "AC5 and is not called a rate limit"
assert_eq "1" "$(curl_calls)" "AC5 and is not retried"

finish
