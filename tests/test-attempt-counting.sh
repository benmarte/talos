#!/usr/bin/env bash
# Tests for pipeline-vcs.sh record-attempt / read-attempt / check-attempt.
# Covers all 7 [test] acceptance criteria from the PM spec (issue #56) plus:
#  - corrupted marker fails-closed
#  - per-stage count resets on stage change; total does NOT
#  - total ceiling blocks even when per-stage resets (ping-pong)
#  - no marker treated as zero attempts
# Every test can fail: disabling the feature causes RED.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

# Isolated config — avoids bleeding in any real talos.pipeline.yml
cat > "$SANDBOX/talos.pipeline.json" <<'EOF'
{"limits": {"max_fix_attempts": 3, "max_total_dispatches": 8}}
EOF
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"

# ── Helper: build a JSON comments array with a talos:attempt marker ────────────
# mk_attempt_comment <stage> <count> <total>
# Produces a single-comment JSON array whose body ends with the marker line.
mk_attempt_comment() {
  local stage="$1" count="$2" total="$3"
  printf '[{"body":"Talos attempt record\\n<!-- talos:attempt stage=%s count=%s total=%s -->"}]' \
    "$stage" "$count" "$total"
}

# ── Helpers: run each verb, capturing output and/or exit code separately ───────

# read_attempt <comments_json>  — stdout only
read_attempt() {
  STUB_ISSUE_COMMENTS_JSON="$1" PIPELINE_CONFIG="$PIPELINE_CONFIG" \
    bash "$VCS" read-attempt 42 2>/dev/null
}
read_attempt_rc() {
  STUB_ISSUE_COMMENTS_JSON="$1" PIPELINE_CONFIG="$PIPELINE_CONFIG" \
    bash "$VCS" read-attempt 42 >/dev/null 2>&1; echo $?
}
read_attempt_err() {
  STUB_ISSUE_COMMENTS_JSON="$1" PIPELINE_CONFIG="$PIPELINE_CONFIG" \
    bash "$VCS" read-attempt 42 2>&1 >/dev/null
}

# check_attempt <comments_json>  — stdout+stderr only
check_attempt_out() {
  STUB_ISSUE_COMMENTS_JSON="$1" PIPELINE_CONFIG="$PIPELINE_CONFIG" \
    bash "$VCS" check-attempt 42 2>&1
}
check_attempt_rc() {
  STUB_ISSUE_COMMENTS_JSON="$1" PIPELINE_CONFIG="$PIPELINE_CONFIG" \
    bash "$VCS" check-attempt 42 >/dev/null 2>&1; echo $?
}

# record_attempt <comments_json> <stage>  — stdout only
record_attempt_out() {
  STUB_ISSUE_COMMENTS_JSON="$1" PIPELINE_CONFIG="$PIPELINE_CONFIG" \
    bash "$VCS" record-attempt 42 "$2" 2>/dev/null
}
record_attempt_rc() {
  STUB_ISSUE_COMMENTS_JSON="$1" PIPELINE_CONFIG="$PIPELINE_CONFIG" \
    bash "$VCS" record-attempt 42 "$2" >/dev/null 2>&1; echo $?
}
record_attempt_err() {
  STUB_ISSUE_COMMENTS_JSON="$1" PIPELINE_CONFIG="$PIPELINE_CONFIG" \
    bash "$VCS" record-attempt 42 "$2" 2>&1 >/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════════
# [test] No marker present → behaves as zero attempts (deliberate, not accidental)
# ═══════════════════════════════════════════════════════════════════════════════

out="$(read_attempt '[]')"; rc="$(read_attempt_rc '[]')"
assert_exit_code 0 "$rc" "no marker: read-attempt exits 0"
assert_contains "$out" "count=0" "no marker: count is 0"
assert_contains "$out" "total=0" "no marker: total is 0"

rc_ca="$(check_attempt_rc '[]')"
assert_exit_code 0 "$rc_ca" "no marker: check-attempt exits 0 (below limit)"

# ═══════════════════════════════════════════════════════════════════════════════
# [test] record-attempt posts a marker comment (URL returned) and exits 0
# when below both ceilings
# ═══════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
out_r1="$(record_attempt_out '[]' qa)"; rc_r1="$(record_attempt_rc '[]' qa)"
assert_exit_code 0 "$rc_r1" "record-attempt first qa: exits 0 (count=1 below limit)"
assert_contains "$out_r1" "stage=qa" "record-attempt first qa: stdout reports stage"
assert_contains "$out_r1" "count=1"  "record-attempt first qa: count=1"
assert_contains "$out_r1" "total=1"  "record-attempt first qa: total=1"
assert_contains "$(cat "$GH_LOG")" "issue comment 42" "record-attempt: posted via gh"

# ═══════════════════════════════════════════════════════════════════════════════
# [test] per-stage count increments on same stage; total also increments
# ═══════════════════════════════════════════════════════════════════════════════

prior_1="$(mk_attempt_comment qa 1 1)"
out_r2="$(record_attempt_out "$prior_1" qa)"; rc_r2="$(record_attempt_rc "$prior_1" qa)"
assert_exit_code 0 "$rc_r2" "same-stage second attempt: exits 0 (count=2 below limit 3)"
assert_contains "$out_r2" "count=2" "same stage: count increments to 2"
assert_contains "$out_r2" "total=2" "same stage: total increments to 2"

# ═══════════════════════════════════════════════════════════════════════════════
# [test] per-stage count resets when blocking stage changes; total does NOT
# ═══════════════════════════════════════════════════════════════════════════════

prior_qa2="$(mk_attempt_comment qa 2 5)"
out_sc="$(record_attempt_out "$prior_qa2" reviewer)"; rc_sc="$(record_attempt_rc "$prior_qa2" reviewer)"
assert_exit_code 0 "$rc_sc" "stage change: exits 0 (new stage count=1)"
assert_contains "$out_sc" "stage=reviewer" "stage change: new stage reported"
assert_contains "$out_sc" "count=1"        "stage change: per-stage count reset to 1"
assert_contains "$out_sc" "total=6"        "stage change: total kept incrementing (was 5 → 6)"

# ═══════════════════════════════════════════════════════════════════════════════
# [test] per-stage ceiling (max_fix_attempts) blocks when count >= limit
# ═══════════════════════════════════════════════════════════════════════════════

# check-attempt: count=3 equals max_fix_attempts=3 → blocked
prior_qa3="$(mk_attempt_comment qa 3 3)"
out_ca3="$(check_attempt_out "$prior_qa3")"; rc_ca3="$(check_attempt_rc "$prior_qa3")"
assert_exit_code 1 "$rc_ca3" "check-attempt: per-stage limit reached → exit 1"
assert_contains "$out_ca3" "BLOCKED" "check-attempt: per-stage blocked message"

# record-attempt: prior count=2 → new count=3 = max_fix_attempts → exit 1
prior_qa2b="$(mk_attempt_comment qa 2 2)"
rc_rec3="$(record_attempt_rc "$prior_qa2b" qa)"
assert_exit_code 1 "$rc_rec3" "record-attempt: exits 1 when resulting count reaches max_fix_attempts"

# ═══════════════════════════════════════════════════════════════════════════════
# [test] total ceiling trips even when per-stage counts keep resetting
# (the ping-pong loophole: QA → reviewer → QA → reviewer … must terminate)
# ═══════════════════════════════════════════════════════════════════════════════

# check-attempt: total=8 equals max_total_dispatches=8, per-stage count=1 (would not trip)
prior_pp="$(mk_attempt_comment qa 1 8)"
out_pp="$(check_attempt_out "$prior_pp")"; rc_pp="$(check_attempt_rc "$prior_pp")"
assert_exit_code 1 "$rc_pp" "check-attempt: total ceiling blocks ping-pong → exit 1"
assert_contains "$out_pp" "BLOCKED" "check-attempt: total ceiling message"

# record-attempt: prior total=7 → new total=8 = max_total_dispatches → exit 1
prior_t7="$(mk_attempt_comment reviewer 1 7)"
rc_pp2="$(record_attempt_rc "$prior_t7" qa)"
assert_exit_code 1 "$rc_pp2" "record-attempt: exits 1 when total reaches max_total_dispatches"

# ═══════════════════════════════════════════════════════════════════════════════
# [test] corrupted/unparseable marker FAILS CLOSED (must NOT treat as zero)
# ═══════════════════════════════════════════════════════════════════════════════

# Unknown stage — not in KNOWN_STAGES → fail-closed
corrupt_stage='[{"body":"Talos attempt record\n<!-- talos:attempt stage=badstage count=1 total=1 -->"}]'
rc_cs="$(read_attempt_rc "$corrupt_stage")"
err_cs="$(read_attempt_err "$corrupt_stage")"
assert_exit_code 1 "$rc_cs" "corrupted marker (unknown stage): read-attempt exits 1 (fail-closed)"
assert_contains "$err_cs" "fail-closed" "corrupted marker: fail-closed reason in stderr"

# total < count — logically impossible → fail-closed
corrupt_order='[{"body":"Talos attempt record\n<!-- talos:attempt stage=qa count=5 total=2 -->"}]'
rc_co="$(read_attempt_rc "$corrupt_order")"
assert_exit_code 1 "$rc_co" "corrupted marker (total < count): fails closed"

# count=abc — non-numeric count; LOOSE_RE finds it, STRICT_RE cannot parse → fail-closed
corrupt_abc='[{"body":"Talos attempt record\n<!-- talos:attempt stage=qa count=abc total=1 -->"}]'
rc_abc="$(read_attempt_rc "$corrupt_abc")"
err_abc="$(read_attempt_err "$corrupt_abc")"
assert_exit_code 1 "$rc_abc" "corrupt marker (count=abc): read-attempt exits 1 (fail-closed)"
assert_contains "$err_abc" "fail-closed" "corrupt marker (count=abc): fail-closed in stderr"

# count=-1 — negative count; not matched by \d+ → fail-closed
corrupt_neg='[{"body":"Talos attempt record\n<!-- talos:attempt stage=qa count=-1 total=1 -->"}]'
rc_neg="$(read_attempt_rc "$corrupt_neg")"
err_neg="$(read_attempt_err "$corrupt_neg")"
assert_exit_code 1 "$rc_neg" "corrupt marker (count=-1): read-attempt exits 1 (fail-closed)"
assert_contains "$err_neg" "fail-closed" "corrupt marker (count=-1): fail-closed in stderr"

# count= (empty) — empty count field → fail-closed
corrupt_empty_count='[{"body":"Talos attempt record\n<!-- talos:attempt stage=qa count= total=1 -->"}]'
rc_ec="$(read_attempt_rc "$corrupt_empty_count")"
err_ec="$(read_attempt_err "$corrupt_empty_count")"
assert_exit_code 1 "$rc_ec" "corrupt marker (count=empty): read-attempt exits 1 (fail-closed)"
assert_contains "$err_ec" "fail-closed" "corrupt marker (count=empty): fail-closed in stderr"

# total missing — no total= field at all → fail-closed
corrupt_no_total='[{"body":"Talos attempt record\n<!-- talos:attempt stage=qa count=1 -->"}]'
rc_nt="$(read_attempt_rc "$corrupt_no_total")"
err_nt="$(read_attempt_err "$corrupt_no_total")"
assert_exit_code 1 "$rc_nt" "corrupt marker (total missing): read-attempt exits 1 (fail-closed)"
assert_contains "$err_nt" "fail-closed" "corrupt marker (total missing): fail-closed in stderr"

# stage=notarealstage — unknown stage name (semantic check) → fail-closed
corrupt_nostage='[{"body":"Talos attempt record\n<!-- talos:attempt stage=notarealstage count=1 total=1 -->"}]'
rc_nst="$(read_attempt_rc "$corrupt_nostage")"
err_nst="$(read_attempt_err "$corrupt_nostage")"
assert_exit_code 1 "$rc_nst" "corrupt marker (stage=notarealstage): read-attempt exits 1 (fail-closed)"
assert_contains "$err_nst" "fail-closed" "corrupt marker (stage=notarealstage): fail-closed in stderr"

# truncated marker — missing all fields → fail-closed
corrupt_trunc='[{"body":"Talos attempt record\n<!-- talos:attempt -->"}]'
rc_tr="$(read_attempt_rc "$corrupt_trunc")"
err_tr="$(read_attempt_err "$corrupt_trunc")"
assert_exit_code 1 "$rc_tr" "corrupt marker (truncated, no fields): read-attempt exits 1 (fail-closed)"
assert_contains "$err_tr" "fail-closed" "corrupt marker (truncated): fail-closed in stderr"

# marker with embedded literal \n (backslash-n) in a field value → fail-closed
# JSON \\n → literal backslash-n (two chars) in the Python string, so the
# marker stays on one last-line; LOOSE_RE sees it, STRICT_RE rejects it.
corrupt_enl='[{"body":"Talos attempt record\n<!-- talos:attempt stage=qa count=1\\ntotal=1 -->"}]'
rc_enl="$(read_attempt_rc "$corrupt_enl")"
err_enl="$(read_attempt_err "$corrupt_enl")"
assert_exit_code 1 "$rc_enl" "corrupt marker (embedded literal backslash-n): read-attempt exits 1 (fail-closed)"
assert_contains "$err_enl" "fail-closed" "corrupt marker (embedded literal backslash-n): fail-closed in stderr"

# All three verbs must propagate the fail-closed signal (spot-check with count=abc marker).
rc_ca_corrupt="$(check_attempt_rc "$corrupt_abc")"
assert_exit_code 1 "$rc_ca_corrupt" "corrupt marker: check-attempt also exits 1 (fail-closed)"
rc_ra_corrupt="$(record_attempt_rc "$corrupt_abc" qa)"
assert_exit_code 1 "$rc_ra_corrupt" "corrupt marker: record-attempt also exits 1 (fail-closed)"

# Regression: no marker at all must still exit 0 with count=0 (not treated as corrupt).
out_reg_none="$(read_attempt '[]')"; rc_reg_none="$(read_attempt_rc '[]')"
assert_exit_code 0 "$rc_reg_none" "regression: no marker → exit 0 (not corrupt)"
assert_contains "$out_reg_none" "count=0" "regression: no marker → count=0"

# Regression: a well-formed marker must still exit 0 with correct values.
valid_reg="$(mk_attempt_comment qa 2 5)"
out_reg_valid="$(read_attempt "$valid_reg")"; rc_reg_valid="$(read_attempt_rc "$valid_reg")"
assert_exit_code 0 "$rc_reg_valid" "regression: valid marker → exit 0"
assert_contains "$out_reg_valid" "count=2" "regression: valid marker → count=2"
assert_contains "$out_reg_valid" "total=5" "regression: valid marker → total=5"

# Marker inside a fenced block must NOT win — it is not the last line
fenced_marker='[{"body":"```\n<!-- talos:attempt stage=qa count=99 total=99 -->\n```\nsome text after"}]'
out_fm="$(read_attempt "$fenced_marker")"; rc_fm="$(read_attempt_rc "$fenced_marker")"
assert_exit_code 0 "$rc_fm" "marker inside fenced block: ignored, exits 0"
assert_contains "$out_fm" "count=0" "marker inside fenced block: treated as no marker (zero)"

# ═══════════════════════════════════════════════════════════════════════════════
# [test] read-attempt: most-recent (newest) marker wins when multiple exist
# GitHub returns comments oldest-first; we search newest-first
# ═══════════════════════════════════════════════════════════════════════════════

two_markers='[
  {"body":"old record\n<!-- talos:attempt stage=qa count=1 total=1 -->"},
  {"body":"newer record\n<!-- talos:attempt stage=qa count=2 total=2 -->"}
]'
out_2m="$(read_attempt "$two_markers")"; rc_2m="$(read_attempt_rc "$two_markers")"
assert_exit_code 0 "$rc_2m" "multiple markers: exits 0"
assert_contains "$out_2m" "count=2" "multiple markers: newest wins (count=2)"
assert_contains "$out_2m" "total=2" "multiple markers: newest wins (total=2)"

# ═══════════════════════════════════════════════════════════════════════════════
# [test] dry-run mode prints description and makes no issue comment writes
# ═══════════════════════════════════════════════════════════════════════════════

: > "$GH_LOG"
out_dr="$(PIPELINE_CONFIG="$PIPELINE_CONFIG" bash "$VCS" --dry-run record-attempt 42 qa 2>&1)"
rc_dr=$?
assert_exit_code 0 "$rc_dr" "dry-run record-attempt: exits 0"
assert_contains "$out_dr" "[dry-run]" "dry-run record-attempt: prints dry-run marker"
assert_contains "$out_dr" "record-attempt" "dry-run record-attempt: names the verb"
# Only repo-detection may appear; no "issue comment" write should be logged
assert_not_contains "$(cat "$GH_LOG")" "issue comment" "dry-run record-attempt: no issue comment write"

out_dr2="$(PIPELINE_CONFIG="$PIPELINE_CONFIG" bash "$VCS" --dry-run read-attempt 42 2>&1)"
assert_contains "$out_dr2" "[dry-run]" "dry-run read-attempt: prints dry-run marker"

out_dr3="$(PIPELINE_CONFIG="$PIPELINE_CONFIG" bash "$VCS" --dry-run check-attempt 42 2>&1)"
assert_contains "$out_dr3" "[dry-run]" "dry-run check-attempt: prints dry-run marker"

# ═══════════════════════════════════════════════════════════════════════════════
# [test] record-attempt verifies the write landed (empty URL → exit 1)
# ═══════════════════════════════════════════════════════════════════════════════

mkdir -p "$SANDBOX/stubs-fail"
cat > "$SANDBOX/stubs-fail/gh" <<'GHEOF'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
case "$args" in
  "issue comment "*)  printf '' ;;            # empty URL — simulate failed write
  "issue view "*"--json comments"*)  printf '{"comments":[]}\n' ;;
  "issue view "*"--json state -q .state"*)  printf 'OPEN\n' ;;
  "repo view "*) printf 'acme/widget\n' ;;
  *) exit 0 ;;
esac
GHEOF
chmod +x "$SANDBOX/stubs-fail/gh"

out_nw="$(PATH="$SANDBOX/stubs-fail:$PATH" PIPELINE_CONFIG="$PIPELINE_CONFIG" \
  bash "$VCS" record-attempt 42 qa 2>&1)"; rc_nw=$?
assert_exit_code 1 "$rc_nw" "record-attempt: exits 1 when comment URL not returned"
assert_contains "$out_nw" "failed to post" "record-attempt: explains failed write"

# ═══════════════════════════════════════════════════════════════════════════════
# [test] custom limits from config are respected
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$SANDBOX/talos-custom.json" <<'EOF'
{"limits": {"max_fix_attempts": 2, "max_total_dispatches": 4}}
EOF
prior_custom="$(mk_attempt_comment qa 2 2)"
rc_cust="$(STUB_ISSUE_COMMENTS_JSON="$prior_custom" PIPELINE_CONFIG="$SANDBOX/talos-custom.json" \
  bash "$VCS" check-attempt 42 >/dev/null 2>&1; echo $?)"
assert_exit_code 1 "$rc_cust" "custom limits: max_fix_attempts=2 triggers at count=2"

prior_tot4="$(mk_attempt_comment qa 1 4)"
rc_tot="$(STUB_ISSUE_COMMENTS_JSON="$prior_tot4" PIPELINE_CONFIG="$SANDBOX/talos-custom.json" \
  bash "$VCS" check-attempt 42 >/dev/null 2>&1; echo $?)"
assert_exit_code 1 "$rc_tot" "custom limits: max_total_dispatches=4 triggers at total=4"

finish
