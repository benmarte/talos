#!/usr/bin/env bash
# Unit tests for the `pr-mergeable` verb (#214) — detect a CONFLICTING PR
# before waiting on CI or dispatching QA.
#
# Contract: prints exactly one of MERGEABLE / CONFLICTING / UNKNOWN on
# stdout; exit 0/1/2 respectively. UNKNOWN is retried up to 4 times,
# sleeping a TALOS_RETRY_SLEEP_SCALE-scaled 2s between attempts.
#
# Covers: github (MERGEABLE, CONFLICTING, UNKNOWN->MERGEABLE on retry,
# UNKNOWN after exhausting retries), github-api (same four cases via the
# REST mergeable true/false/null mapping), dry-run for both providers, and
# file mode (always UNKNOWN, no PR concept).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# Instant retries -- no test here should wait out a real 2s*N backoff.
export TALOS_RETRY_SLEEP_SCALE=0

# ── github provider ───────────────────────────────────────────────────────────

# (a) MERGEABLE -> exit 0, prints MERGEABLE
export STUB_PR_MERGEABLE="MERGEABLE"
out="$(bash "$VCS" pr-mergeable 42)"; rc=$?
assert_eq "0" "$rc" "github: pr-mergeable exits 0 for MERGEABLE"
assert_eq "MERGEABLE" "$out" "github: pr-mergeable prints MERGEABLE"

# (b) CONFLICTING -> exit 1, prints CONFLICTING
export STUB_PR_MERGEABLE="CONFLICTING"
out="$(bash "$VCS" pr-mergeable 42)"; rc=$?
assert_eq "1" "$rc" "github: pr-mergeable exits 1 for CONFLICTING"
assert_eq "CONFLICTING" "$out" "github: pr-mergeable prints CONFLICTING"
unset STUB_PR_MERGEABLE

# (c) UNKNOWN then MERGEABLE on retry -> exit 0, prints MERGEABLE
queue="$SANDBOX/mergeable.queue"
printf 'UNKNOWN\nUNKNOWN\nMERGEABLE\n' > "$queue"
export STUB_PR_MERGEABLE_QUEUE="$queue"
out="$(bash "$VCS" pr-mergeable 42)"; rc=$?
assert_eq "0" "$rc" "github: pr-mergeable retries past UNKNOWN and exits 0 once settled"
assert_eq "MERGEABLE" "$out" "github: pr-mergeable prints MERGEABLE once settled"
unset STUB_PR_MERGEABLE_QUEUE

# (d) UNKNOWN on every attempt -> exit 2, prints UNKNOWN, after retries
printf 'UNKNOWN\nUNKNOWN\nUNKNOWN\nUNKNOWN\nUNKNOWN\n' > "$queue"
export STUB_PR_MERGEABLE_QUEUE="$queue"
out="$(bash "$VCS" pr-mergeable 42)"; rc=$?
assert_eq "2" "$rc" "github: pr-mergeable exits 2 when still UNKNOWN after retries"
assert_eq "UNKNOWN" "$out" "github: pr-mergeable prints UNKNOWN after exhausting retries"
unset STUB_PR_MERGEABLE_QUEUE
rm -f "$queue"

# (e) dry-run: exits 0, prints a marker, makes no gh call
: > "$GH_LOG"
out="$(bash "$VCS" --dry-run pr-mergeable 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "github: pr-mergeable --dry-run exits 0"
assert_contains "$out" "[dry-run]" "github: pr-mergeable --dry-run prints marker"
log="$(cat "$GH_LOG" 2>/dev/null || true)"
assert_not_contains "$log" "pr view" "github: pr-mergeable --dry-run makes no gh call"

# ── github-api provider ───────────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "github-api", "repo": "acme/widget"}}
EOF
export GITHUB_TOKEN="test-token-pr-mergeable"

# (f) mergeable: true -> exit 0, prints MERGEABLE
: > "$CURL_QUEUE"
printf '%s\n' '{"number":42,"mergeable":true}' >> "$CURL_QUEUE"
out="$(bash "$VCS" pr-mergeable 42)"; rc=$?
assert_eq "0" "$rc" "github-api: pr-mergeable exits 0 for mergeable:true"
assert_eq "MERGEABLE" "$out" "github-api: pr-mergeable prints MERGEABLE"

# (g) mergeable: false -> exit 1, prints CONFLICTING
: > "$CURL_QUEUE"
printf '%s\n' '{"number":42,"mergeable":false}' >> "$CURL_QUEUE"
out="$(bash "$VCS" pr-mergeable 42)"; rc=$?
assert_eq "1" "$rc" "github-api: pr-mergeable exits 1 for mergeable:false"
assert_eq "CONFLICTING" "$out" "github-api: pr-mergeable prints CONFLICTING"

# (h) mergeable: null, null, then true -> exit 0, prints MERGEABLE
: > "$CURL_QUEUE"
{
  printf '%s\n' '{"number":42,"mergeable":null}'
  printf '%s\n' '{"number":42,"mergeable":null}'
  printf '%s\n' '{"number":42,"mergeable":true}'
} >> "$CURL_QUEUE"
out="$(bash "$VCS" pr-mergeable 42)"; rc=$?
assert_eq "0" "$rc" "github-api: pr-mergeable retries past null and exits 0 once settled"
assert_eq "MERGEABLE" "$out" "github-api: pr-mergeable prints MERGEABLE once settled"

# (i) mergeable: null on every attempt -> exit 2, prints UNKNOWN
: > "$CURL_QUEUE"
{
  printf '%s\n' '{"number":42,"mergeable":null}'
  printf '%s\n' '{"number":42,"mergeable":null}'
  printf '%s\n' '{"number":42,"mergeable":null}'
  printf '%s\n' '{"number":42,"mergeable":null}'
  printf '%s\n' '{"number":42,"mergeable":null}'
} >> "$CURL_QUEUE"
out="$(bash "$VCS" pr-mergeable 42)"; rc=$?
assert_eq "2" "$rc" "github-api: pr-mergeable exits 2 when still null after retries"
assert_eq "UNKNOWN" "$out" "github-api: pr-mergeable prints UNKNOWN after exhausting retries"

# (j) dry-run: exits 0, no curl call
: > "$CURL_LOG"
out="$(bash "$VCS" --dry-run pr-mergeable 42 2>&1)"; rc=$?
assert_eq "0" "$rc" "github-api: pr-mergeable --dry-run exits 0"
log="$(cat "$CURL_LOG" 2>/dev/null || true)"
assert_eq "" "$log" "github-api: pr-mergeable --dry-run makes no curl call"

unset GITHUB_TOKEN
rm -f talos.pipeline.json

# ── file mode ──────────────────────────────────────────────────────────────────
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "file"}}
EOF
out="$(bash "$VCS" pr-mergeable 42 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "file: pr-mergeable exits 2 (UNKNOWN, no PR concept)"
assert_eq "UNKNOWN" "$out" "file: pr-mergeable prints UNKNOWN"
rm -f talos.pipeline.json

finish
