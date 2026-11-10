#!/usr/bin/env bash
# test-stage-label-873.sh -- #873: the opt-in display-only `talos:stage:<role>`
# label on the issue (board.stage_label), moved at every stage start by
# `talos.sh prompt` and cleared when a closing merge is recorded.
#   AC1  the config key (default false, repo scope) and its docs table row
#   AC2  the eight labels in the contract, outside TALOS_STAGE_LABELS, and
#        bootstrap-labels.sh creates them
#   AC3-AC6  `prompt`: exactly one marker, moved per stage, no call for roles
#        outside the eight, a failed write is one warn line
#   AC7-AC8  `post-merge` clears every marker for a closing merge only; a
#        blocking verdict keeps the marker
#   AC9  default off: no label call at all
#   AC10 routing (pipeline-next.py / the stage-label list) never reads it
# Everything runs on the gh stub; the label writes are read back from its log.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

TALOS="$TALOS_ROOT/scripts/talos.sh"
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export CLAUDE_CONFIG_DIR="$SANDBOX/cc" TALOS_RETRY_SLEEP_SCALE=0
export STUB_REPO=acme/widget STUB_CURRENT_USER=bot
N=42 PR=9

cfg_on() { github_leg gh ',"board": {"stage_label": true, "enabled": false}'; }
cfg_off() { github_leg gh ',"board": {"enabled": false}'; }

# end_state <initial csv>: replay the issue-N label writes in the gh log over an
# initial label set; prints the sorted talos:stage:* labels left, one per line.
end_state() {
  python3 -I - "$GH_LOG" "$N" "${1:-}" <<'TALOS_8f3kq2xw9zmd'
import json, re, sys, urllib.parse
log, n, init = sys.argv[1], sys.argv[2], sys.argv[3]
have = set(x for x in init.split(",") if x)
for line in open(log):
    m = re.search(r"-X (POST|DELETE) .*repos/acme/widget/issues/%s/labels(?:/(\S+))?" % n, line)
    if not m:
        continue
    if m.group(1) == "POST":
        p = re.search(r"payload=(\{.*\})", line)
        have |= set(json.loads(p.group(1))["labels"])
    else:
        have.discard(urllib.parse.unquote(m.group(2)))
print("\n".join(sorted(l for l in have if l.startswith("talos:stage:"))))
TALOS_8f3kq2xw9zmd
}
# label_calls: the issue-N label writes in the gh log (POST and DELETE lines).
label_calls() { grep -c "repos/acme/widget/issues/$N/labels" "$GH_LOG" || true; }
# pr_label_calls: label writes on the PR number's own path are never made.
prompt_run() {  # <role> [--pr n]: render the prompt; stdout in OUT, status in RC
  local _r="$1"; shift
  OUT="$(bash "$TALOS" prompt "$_r" --issue "$N" "$@" 2>"$SANDBOX/err")"; RC=$?
  local _pf; _pf="$(printf '%s\n' "$OUT" | sed -n 's/^prompt_file=//p')"
  [ -z "$_pf" ] || rm -f "${_pf:?}"
}

# ── AC1 the config key and its table rows ─────────────────────────────────────
cfg_off
assert_eq "false" "$(bash "$TALOS_ROOT/scripts/pipeline-config.sh" board.stage_label 2>/dev/null)" \
  "AC1 board.stage_label reads false by default"
assert_contains "$(cat "$TALOS_ROOT/scripts/pipeline-defaults.sh")" "$(printf 'board.stage_label\tbool\tfalse\t-\t-\trepo')" \
  "AC1 the defaults table has the row (bool, false, repo)"
assert_contains "$(cat "$TALOS_ROOT/docs/reference.md")" '| `board.stage_label` | bool | `false` | - | repo |' \
  "AC1 the generated config table in docs/reference.md has the row"

# ── AC2 the contract ───────────────────────────────────────────────────────────
ROLES8="validator pm developer reviewer security adversarial docs qa"
(
  . "$TALOS_ROOT/scripts/pipeline-contract.sh"
  [ -n "${TALOS_STAGE_MARKER_LABELS+x}" ] || { echo "AC2 no TALOS_STAGE_MARKER_LABELS in pipeline-contract.sh" >&2; exit 1; }
  entries=("${TALOS_STAGE_MARKER_LABELS[@]}")
  [ "${#entries[@]}" -eq 8 ] || { echo "AC2 want 8 entries, got ${#entries[@]}" >&2; exit 1; }
  for r in $ROLES8; do
    found=0
    for e in "${entries[@]}"; do [ "${e%%|*}" = "talos:stage:$r" ] && found=1; done
    [ "$found" -eq 1 ] || { echo "AC2 missing talos:stage:$r" >&2; exit 1; }
  done
  for e in "${entries[@]}"; do talos_contract_check_label_length "$e" || exit 1; done
  for e in "${TALOS_STAGE_LABELS[@]}" "${TALOS_APPROVAL_LABELS[@]}"; do
    case "${e%%|*}" in talos:stage:*) echo "AC2 routing array holds ${e%%|*}" >&2; exit 1 ;; esac
  done
)
assert_eq "0" "$?" "AC2 eight marker labels in their own array, within limits, outside TALOS_STAGE_LABELS/TALOS_APPROVAL_LABELS"
: > "$GH_LOG"
bash "$TALOS_ROOT/scripts/bootstrap-labels.sh" acme/widget >"$SANDBOX/bl.out" 2>&1
for r in $ROLES8; do
  assert_contains "$(cat "$SANDBOX/bl.out" "$GH_LOG")" "talos:stage:$r" "AC2 bootstrap-labels creates talos:stage:$r"
done

# ── AC3 one marker per stage start, on the issue only ──────────────────────────
cfg_on
for r in $ROLES8; do
  : > "$GH_LOG"
  case "$r" in reviewer | security | adversarial | docs | qa) set -- --pr "$PR" ;; *) set -- ;; esac
  prompt_run "$r" "$@"
  assert_eq "0" "$RC" "AC3 prompt $r renders"
  assert_eq "talos:stage:$r" "$(end_state "")" "AC3 $r: the issue carries exactly talos:stage:$r"
  assert_eq "0" "$(grep -c "repos/acme/widget/issues/$PR/labels\|pulls/$PR/labels" "$GH_LOG" || true)" "AC3 $r: never the PR"
done

# ── AC4 two stages in a row, and the same stage twice ──────────────────────────
: > "$GH_LOG"
prompt_run developer
prompt_run reviewer --pr "$PR"
assert_eq "talos:stage:reviewer" "$(end_state "")" "AC4 developer then reviewer leaves only the reviewer marker"
: > "$GH_LOG"
prompt_run qa --pr "$PR"
prompt_run qa --pr "$PR"
assert_eq "talos:stage:qa" "$(end_state "talos:stage:reviewer")" "AC4 re-running a stage leaves exactly one marker"
: > "$GH_LOG"
prompt_run docs --pr "$PR"
assert_eq "talos:stage:docs" "$(end_state "talos:stage:qa,talos:stage:pm")" "AC4 a stale marker the issue carries is removed too"

# ── AC5 a role outside the eight ───────────────────────────────────────────────
: > "$GH_LOG"
prompt_run threat
assert_eq "0" "$RC" "AC5 prompt threat renders"
assert_eq "0" "$(label_calls)" "AC5 threat: no label call"
: > "$GH_LOG"
prompt_run planner
assert_eq "0" "$(label_calls)" "AC5 planner: no label call"

# ── AC6 a failed write is one warn line ────────────────────────────────────────
mkdir -p "$SANDBOX/failbin"
cat > "$SANDBOX/failbin/gh" <<'TALOS_q7v2m9c4tz1x'
#!/usr/bin/env bash
case "$*" in *issues/*/labels*) echo "HTTP 500" >&2; exit 1 ;; esac
exec "$REAL_GH_STUB" "$@"
TALOS_q7v2m9c4tz1x
chmod +x "$SANDBOX/failbin/gh"
OK_OUT=""; prompt_run developer; OK_OUT="$OUT"; OK_RC="$RC"
export REAL_GH_STUB="$STUBS_DIR/gh"
OLDPATH="$PATH"; PATH="$SANDBOX/failbin:$PATH"
prompt_run developer
PATH="$OLDPATH"
assert_eq "$OK_RC" "$RC" "AC6 a failed marker write leaves the exit status unchanged"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c '^warn reason=stage-label-failed issue='"$N"'$')" "AC6 one warn line names the failure"
assert_contains "$OUT" "prompt_file=" "AC6 the stage prompt is still produced"

# ── AC7 a closing merge clears every marker; a part-of merge does not ──────────
export STUB_PR_BODY="Closes #$N"
: > "$GH_LOG"
bash "$TALOS" post-merge "$PR" "$N" >"$SANDBOX/pm.out" 2>&1
CLEARED="$(end_state "talos:stage:qa,talos:stage:docs")"
assert_eq "" "$CLEARED" "AC7 post-merge (closes) removes every talos:stage:* label"
export STUB_PR_BODY="Part of #$N"
: > "$GH_LOG"
bash "$TALOS" post-merge "$PR" "$N" >"$SANDBOX/pm.out" 2>&1
assert_eq "talos:stage:qa" "$(end_state "talos:stage:qa")" "AC7 post-merge (part-of) leaves the marker"
export STUB_PR_BODY="Closes #$N"
: > "$GH_LOG"
OLDPATH="$PATH"; PATH="$SANDBOX/failbin:$PATH"
bash "$TALOS" post-merge "$PR" "$N" >"$SANDBOX/pm.out" 2>&1; PM_RC=$?
PATH="$OLDPATH"
assert_eq "0" "$PM_RC" "AC7 a failed clear does not fail post-merge"
assert_contains "$(cat "$SANDBOX/pm.out")" "warn reason=stage-label-failed issue=$N" "AC7 a failed clear is a warn line"

# ── AC8 a blocking verdict keeps the marker ────────────────────────────────────
: > "$GH_LOG"
bash "$TALOS" done reviewer --issue "$N" --pr "$PR" --verdict CHANGES --summary-file - <<<"changes" >"$SANDBOX/done.out" 2>&1
assert_eq "talos:stage:reviewer" "$(end_state "talos:stage:reviewer")" "AC8 a CHANGES verdict keeps the stage marker"
: > "$GH_LOG"
bash "$TALOS" done developer --issue "$N" --verdict BLOCKED --summary-file - <<<"blocked" >"$SANDBOX/done.out" 2>&1
assert_eq "talos:stage:developer" "$(end_state "talos:stage:developer")" "AC8 a BLOCKED verdict keeps the stage marker"

# ── AC9 default off: no label call, no marker ──────────────────────────────────
cfg_off
for r in developer reviewer threat; do
  : > "$GH_LOG"
  prompt_run "$r" --pr "$PR"
  assert_eq "0" "$(grep -c "/labels" "$GH_LOG" || true)" "AC9 off: prompt $r makes no label call"
done
: > "$GH_LOG"
bash "$TALOS" post-merge "$PR" "$N" >"$SANDBOX/pm.out" 2>&1
assert_eq "0" "$(grep -c "talos%3Astage\|talos:stage" "$GH_LOG" || true)" "AC9 off: post-merge makes no stage-label call"
printf '%s' '{"vcs": {"provider": "github", "repo": "acme/widget"}}' > talos.pipeline.json
: > "$GH_LOG"
prompt_run developer
assert_eq "0" "$(grep -c "/labels" "$GH_LOG" || true)" "AC9 unset: prompt makes no label call"

# ── AC10 routing never reads the marker ────────────────────────────────────────
assert_eq "0" "$(grep -c 'talos:stage' "$TALOS_ROOT/scripts/pipeline-next.py" || true)" "AC10 pipeline-next.py does not mention the marker"
NEXT_BASE='[{"number":42,"title":"t","labels":[{"name":"pipeline:dev"}],"body":"b"}]'
NEXT_MARK='[{"number":42,"title":"t","labels":[{"name":"pipeline:dev"},{"name":"talos:stage:developer"}],"body":"b"}]'
cfg_off
export STUB_ISSUE_LABELS_JSON="$NEXT_BASE"
A="$(bash "$TALOS" next --issue "$N" 2>/dev/null)"
export STUB_ISSUE_LABELS_JSON="$NEXT_MARK"
B="$(bash "$TALOS" next --issue "$N" 2>/dev/null)"
assert_eq "$A" "$B" "AC10 next answers the same with and without the marker label"

finish
