#!/usr/bin/env bash
# test-merge-pr-sha-941.sh -- `merge-pr <n> --sha <sha>` binds the merge to the
# head the gates approved (#941): GitHub sends `sha` in the merge PUT, GitLab
# passes glab's `--sha`, Azure completes through a PATCH carrying
# lastMergeSourceCommit; `talos.sh run` reads pr-head before `gate merge` and
# passes it, and `talos.sh queue run` passes each PR's cut head. Tests are named
# by the spec's criterion id.
#
# The fixture is tests/talos-run-sections.sh (sourced with TALOS_RUN_PART=941
# TALOS_RUN_EMBED=1, as tests/test-merge-queue-930.sh does): its sandbox,
# journaling stubs and merge_fixture. The provider criteria run the real
# pipeline-vcs.sh over the curl, gh, glab and az stubs. No network, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=941 TALOS_RUN_EMBED=1 . "$(dirname "$0")/talos-run-sections.sh"

export TALOS_RETRY_SLEEP_SCALE=0
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
SHA="0123456789abcdef0123456789abcdef01234567"
UPPER="0123456789ABCDEF0123456789ABCDEF01234567"
PR_JSON='{"number": 9, "head": {"ref": "feat/x", "sha": "'"$SHA"'", "repo": {"full_name": "acme/widget"}}, "base": {"ref": "main", "repo": {"full_name": "acme/widget"}}}'

logs_reset() { : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CURL_QUEUE"; }
mp() { OUT="$(bash "$VCS" "$@" 2>"$ERR")"; RC=$?; }

# ── AC1, AC2, AC8: GitHub, both transports ───────────────────────────────────
for leg in gh curl; do
  github_leg "$leg"
  logs_reset
  printf '%s\n%s\n' "$PR_JSON" '{"merged": true}' > "$CURL_QUEUE"
  mp merge-pr 9 --sha "$SHA"
  merge_line="$(grep '/pulls/9/merge' "$CURL_LOG")"
  assert_eq "0" "$RC" "AC1 ($leg) merge-pr --sha exits 0"
  assert_contains "$merge_line" "PUT" "AC1 ($leg) the merge is a PUT .../pulls/9/merge"
  assert_contains "$merge_line" "\"sha\": \"$SHA\"" "AC1 ($leg) the merge body carries \"sha\" with the given head"
  assert_contains "$merge_line" '"merge_method": "squash"' "AC1 ($leg) merge_method stays beside the sha"

  logs_reset
  printf '%s\n%s\n' "$PR_JSON" '409:{"message": "Head branch was modified. Review and try the merge again."}' > "$CURL_QUEUE"
  mp merge-pr 9 --sha "$SHA"
  assert_eq "1" "$RC" "AC2 ($leg) a refused merge (409) exits 1"
  assert_eq "0" "$(grep -c '/git/refs/heads/' "$CURL_LOG")" "AC2 ($leg) a refused merge makes no DELETE of the head branch"

  logs_reset
  printf '%s\n%s\n' "$PR_JSON" '{"merged": true}' > "$CURL_QUEUE"
  mp merge-pr 9
  merge_line="$(grep '/pulls/9/merge' "$CURL_LOG")"
  assert_eq "0" "$RC" "AC8 ($leg) merge-pr without --sha exits 0"
  assert_contains "$merge_line" '{"merge_method": "squash"}' "AC8 ($leg) without --sha the body is merge_method only"
  assert_not_contains "$merge_line" '"sha"' "AC8 ($leg) without --sha the body has no sha key"
done
github_leg gh
mp --dry-run merge-pr 9 --sha "$SHA"
assert_eq "0" "$RC" "AC1 --dry-run merge-pr --sha exits 0"
assert_contains "$OUT" "sha=$SHA" "AC1 --dry-run names sha=<sha>"
mp --dry-run merge-pr 9
assert_not_contains "$OUT" "sha=" "AC8 --dry-run without --sha names no sha"

# ── AC3, AC8: GitLab ─────────────────────────────────────────────────────────
printf '{"vcs": {"provider": "gitlab"}}\n' > talos.pipeline.json
logs_reset
mp merge-pr 7 --sha "$SHA"
assert_eq "0" "$RC" "AC3 gitlab merge-pr --sha exits 0"
assert_contains "$(cat "$GH_LOG")" "GLAB mr merge 7 --sha $SHA" "AC3 glab mr merge 7 gets --sha <sha>"
logs_reset
mp merge-pr 7
assert_contains "$(cat "$GH_LOG")" "GLAB mr merge 7" "AC8 gitlab without --sha still runs glab mr merge 7"
assert_not_contains "$(cat "$GH_LOG")" "--sha" "AC8 gitlab without --sha passes no --sha"

# ── AC4, AC5, AC6, AC8: Azure ────────────────────────────────────────────────
az_cfg() {  # [<merge.method>]
  local _mm=""
  [ -n "${1:-}" ] && _mm=", \"merge\": {\"method\": \"$1\"}"
  printf '{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}}%s}\n' "$_mm" > talos.pipeline.json
}
az_body() { sed -n 's/^AZ BODY: //p' "$GH_LOG" | tail -n 1; }
# az_key <python expression over the body d>
az_key() { az_body | python3 -I -c "import json, sys; d = json.load(sys.stdin); print($1)" 2>/dev/null; }
export STUB_AZURE_PR_TITLE="fix: guard the thing"
az_cfg
logs_reset
mp merge-pr 9 --sha "$SHA"
assert_eq "0" "$RC" "AC4 azure merge-pr --sha exits 0"
assert_eq "1" "$(grep -c '^AZ ARGS: \[rest\] \[--method\] \[patch\] \[--url\] \[[^]]*/pullRequests/9?api-version=7.1\]' "$GH_LOG")" \
  "AC4 one az rest --method patch to .../pullRequests/9"
assert_eq "completed" "$(az_key 'd["status"]')" "AC4 the PATCH body holds status completed"
assert_eq "$SHA" "$(az_key 'd["lastMergeSourceCommit"]["commitId"]')" "AC4 the PATCH body binds lastMergeSourceCommit.commitId to the sha"
assert_eq "0" "$(grep -c '\[repos\] \[pr\] \[update\]' "$GH_LOG")" "AC4 no az repos pr update --status completed under --sha"
assert_eq "True|fix: guard the thing" "$(az_key 'str(d["completionOptions"]["squashMerge"]) + "|" + d["completionOptions"]["mergeCommitMessage"]')" \
  "AC5 unset merge.method: squashMerge true and the PR title as mergeCommitMessage"
az_cfg squash
logs_reset
mp merge-pr 9 --sha "$SHA"
assert_eq "True|fix: guard the thing" "$(az_key 'str(d["completionOptions"]["squashMerge"]) + "|" + d["completionOptions"]["mergeCommitMessage"]')" \
  "AC5 merge.method squash: squashMerge true and the PR title as mergeCommitMessage"
az_cfg merge
logs_reset
mp merge-pr 9 --sha "$SHA"
assert_eq "False" "$(az_key 'd["completionOptions"]["squashMerge"]')" "AC5 merge.method merge: squashMerge false"
az_cfg rebase
logs_reset
mp merge-pr 9 --sha "$SHA"
assert_eq "absent|$SHA" "$(az_key '("present" if "squashMerge" in d.get("completionOptions", {}) else "absent") + "|" + d["lastMergeSourceCommit"]["commitId"]')" \
  "AC5 merge.method rebase: no squashMerge key"
az_cfg
logs_reset
STUB_AZURE_PATCH_FAIL=1 mp merge-pr 9 --sha "$SHA"
[ "$RC" -ne 0 ] && pass "AC6 a failed PATCH makes merge-pr exit non-zero" \
  || fail "AC6 a failed PATCH makes merge-pr exit non-zero" "rc=$RC"
logs_reset
mp merge-pr 9
assert_contains "$(cat "$GH_LOG")" "[repos] [pr] [update] [--id] [9] [--status] [completed] [--squash] [true]" \
  "AC8 azure without --sha still runs az repos pr update with today's squash flags"
assert_eq "0" "$(grep -c '\[rest\] \[--method\] \[patch\]' "$GH_LOG")" "AC8 azure without --sha makes no PATCH"
unset STUB_AZURE_PR_TITLE

# ── AC7: a bad --sha is a usage error before any provider call ───────────────
for prov in gh curl gitlab azure; do
  case "$prov" in
    gh | curl) github_leg "$prov" ;;
    gitlab) printf '{"vcs": {"provider": "gitlab"}}\n' > talos.pipeline.json ;;
    azure) az_cfg ;;
  esac
  for bad in abc - "$UPPER"; do
    logs_reset
    if [ "$bad" = "-" ]; then mp merge-pr 9 --sha; label="--sha with no value"; else mp merge-pr 9 --sha "$bad"; label="--sha '$bad'"; fi
    assert_eq "1" "$RC" "AC7 ($prov) $label exits 1"
    assert_contains "$(cat "$ERR")" "merge-pr" "AC7 ($prov) $label: stderr names merge-pr"
    assert_contains "$(cat "$ERR")" "--sha" "AC7 ($prov) $label: stderr names --sha"
    assert_eq "0|0" "$(grep -c . "$GH_LOG")|$(grep -c . "$CURL_LOG")" "AC7 ($prov) $label: no provider call"
  done
done
github_leg gh
logs_reset
mp --dry-run merge-pr 9 --sha abc
assert_eq "1" "$RC" "AC7 a bad --sha is refused before the --dry-run short-circuit"

# ── AC9: file provider ───────────────────────────────────────────────────────
printf '{"vcs": {"provider": "file"}}\n' > talos.pipeline.json
mp merge-pr 9 --sha "$SHA"
assert_eq "0" "$RC" "AC9 file merge-pr --sha exits 0"
assert_contains "$(cat "$ERR")" "file mode: no PR to merge" "AC9 file merge-pr --sha keeps its no-op message"

# ── AC10, AC11: talos.sh run's merge arm ─────────────────────────────────────
HEAD_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
run_merge() {
  TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --issue 9 --max-iterations 1
}
merge_fixture "$ALL_APPROVALS"
draft_ready
printf '%s' "$HEAD_A" > "$STUB_DIR/pr-head.12"
# The gate's first read moves the head: a push while the gate runs.
cat > "$STUB_DIR/hook.view-pr" <<HOOK
printf '%s' "$HEAD_B" > "\$d/pr-head.12"
HOOK
run_merge
assert_eq "1" "$(journal | grep -c "^vcs merge-pr 12 --sha $HEAD_A\$")" \
  "AC10 the merge is vcs merge-pr 12 --sha <the head read before gate merge>"
assert_eq "0" "$(journal | grep -c "merge-pr 12 --sha $HEAD_B")" "AC10 never the head pushed during the gate"
first_head="$(journal | grep -n '^vcs pr-head 12$' | head -n 1 | cut -d: -f1)"
first_gate="$(journal | grep -n '^vcs view-pr 12$' | head -n 1 | cut -d: -f1)"
[ -n "$first_head" ] && [ -n "$first_gate" ] && [ "$first_head" -lt "$first_gate" ] \
  && pass "AC10 pr-head is read before gate merge's first call" \
  || fail "AC10 pr-head is read before gate merge's first call" "pr-head line=${first_head:-none} gate view-pr line=${first_gate:-none}"

for how in fail short; do
  merge_fixture "$ALL_APPROVALS"
  draft_ready
  case "$how" in
    fail) printf '%s' "$HEAD_A" > "$STUB_DIR/pr-head.12"; printf 1 > "$STUB_DIR/pr-head.12.rc" ;;
    short) printf 'a4f9' > "$STUB_DIR/pr-head.12" ;;
  esac
  run_merge
  assert_contains "$OUT" "stop reason=head-unresolved" "AC11 a pr-head that is $how ends the run stop reason=head-unresolved"
  assert_eq "0|0" "$(journal | grep -c '^vcs view-pr 12$')|$(journal | grep -c 'merge-pr')" \
    "AC11 a pr-head that is $how: no gate merge (its view-pr) and no merge-pr"
done

# ── AC12: talos.sh queue run merges each PR at its cut head ──────────────────
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
git remote set-url origin "$ORIGIN"
GQ="$SANDBOX/gq"
mkdir -p "$GQ"
cp "$GS"/* "$GQ/"
for s in pipeline-mergebase.sh pipeline-worktree.sh pipeline-status.sh; do
  printf '%s' "$STUB_BODY" > "$GQ/$s"
done
sg() { git -C "$SEED" "$@"; }
rm -rf "${ORIGIN:?}" "${SEED:?}"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SEED"
sg symbolic-ref HEAD refs/heads/main
sg config user.name talos-test
sg config user.email test@talos.invalid
sg config commit.gpgsign false
printf 'base\n' > "$SEED/base.txt"
sg add -A
sg commit -q -m base
sg remote add origin "$ORIGIN"
sg push -q origin main
reset_stubs
LEASE_RESET
printf 'owner' > "$STUB_DIR/current-user"
printf 'talos:checkout state=kept' > "$STUB_DIR/worktree.out"
printf '{"vcs": {"provider": "github"}, "base_branch": "main", "merge": {"queue": "talos", "method": "squash", "queue_batch": 2}}' \
  > "$SANDBOX/talos.pipeline.json"
Q_LIST=""
Q_SEQ=0
for pair in 11:41 12:42; do
  p="${pair%%:*}" n="${pair#*:}" br="feat/issue-${pair#*:}-q"
  sg checkout -q -B "$br" main
  printf 'x%s\n' "$p" > "$SEED/a$p.txt"
  sg add -A
  sg commit -q -m "pr$p"
  sg push -q -f origin "$br"
  h="$(sg rev-parse HEAD)"
  eval "QH_$p=$h"
  sg checkout -q main
  Q_SEQ=$((Q_SEQ + 1))
  printf '%s' "$h" > "$STUB_DIR/pr-head.$p"
  python3 -I -c '
import json, sys
body = "**Merge queue:**\n\nqueue: base=main head=%s eligible=2026-11-01T00:00:%02dZ\n\n<!-- talos:queue -->" % (sys.argv[1], int(sys.argv[2]))
print(json.dumps({"comments": [{"author": {"login": "owner"}, "body": body}]}))' "$h" "$Q_SEQ" > "$STUB_DIR/read-comments.$p"
  printf '{"number": %s, "headRefName": "%s", "baseRefName": "main", "labels": [], "state": "open"}' "$p" "$br" > "$STUB_DIR/view-pr.$p"
  Q_LIST="$Q_LIST${Q_LIST:+,}{\"number\":$p,\"baseRefName\":\"main\",\"headRefName\":\"$br\",\"isCrossRepository\":false}"
done
export LIST_PRS="[$Q_LIST]"
OUT="$(bash "$GQ/talos.sh" queue run </dev/null 2>"$ERR")"; RC=$?
assert_eq "0|verdict=merged" "$RC|$(printf '%s\n' "$OUT" | sed -n 1p)" "AC12 the queue run merges (exit 0, verdict=merged)"
assert_eq "vcs merge-pr 11 --sha $QH_11>vcs merge-pr 12 --sha $QH_12" \
  "$(journal | grep '^vcs merge-pr ' | tr '\n' '>' | sed 's/>$//')" \
  "AC12 each queue merge is vcs merge-pr <p> --sha <the cut head its checks ran on>"
unset LIST_PRS

finish
