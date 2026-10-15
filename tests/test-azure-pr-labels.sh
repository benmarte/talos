#!/usr/bin/env bash
# test-azure-pr-labels.sh -- azure view-pr and check-approval-sha read the PR's
# labels from the PR labels REST API (#702). `az repos pr show` never returns
# labels (it answers `labels: null`), so reading them there made the driver see
# "no labels" or crash. Also pins that the driver's label reader treats a null
# `labels` as empty. Uses the tests/stubs/az stub; no credentials needed. Tests
# are named by the spec's criterion id (AC1 ...).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
cat > talos.pipeline.json <<'EOF'
{"vcs": {"provider": "azure", "repo": "widget", "azure": {"org_url": "https://dev.azure.com/acme", "project": "proj"}},
 "markers": {"trusted_authors": ["bot@acme.com"]}}
EOF
git config user.email "test@talos.invalid"
git config user.name "talos-test"

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PR='{"pullRequestId":9,"title":"t","status":"active","targetRefName":"refs/heads/main","lastMergeSourceCommit":{"commitId":"'"$HEAD_SHA"'"},"labels":null}'
LABELS='{"count":2,"value":[{"id":"1","name":"pipeline:review","active":true},{"id":"2","name":"qa:pass","active":true}]}'
THREADS='{"value":[{"id":1,"comments":[{"id":1,"content":"ok\n<!-- talos:approval sha='"$HEAD_SHA"' role=qa -->","commentType":"text","author":{"displayName":"B","uniqueName":"bot@acme.com"},"publishedDate":"2026-10-15T00:00:00Z"}]}]}'

# ── AC1: view-pr lists the labels from the labels API ────────────────────────
out="$(STUB_AZURE_PR_9="$PR" STUB_AZURE_PR_LABELS="$LABELS" bash "$VCS" view-pr 9 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC1 view-pr exits 0"
assert_eq '[{"name": "pipeline:review"}, {"name": "qa:pass"}]' \
  "$(printf '%s' "$out" | python3 -I -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["labels"]))')" \
  "AC1 view-pr labels are objects holding only the label name"
assert_eq "9|t|active" \
  "$(printf '%s' "$out" | python3 -I -c 'import json,sys;d=json.load(sys.stdin);print("|".join([str(d["pullRequestId"]),d["title"],d["status"]]))')" \
  "AC1 view-pr leaves the other pr show fields unchanged"

# ── AC2: a failed labels read fails view-pr ──────────────────────────────────
out="$(STUB_AZURE_PR_9="$PR" STUB_AZURE_PR_LABELS_FAIL=1 bash "$VCS" view-pr 9 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "AC2 view-pr exits non-zero when the labels read fails"
assert_eq "" "$out" "AC2 view-pr prints no JSON when the labels read fails"

# ── AC3: _talos_labels on a null labels ──────────────────────────────────────
eval "$(sed -n "/^_TALOS_LABELS_PY=/,/^_talos_labels()/p" "$TALOS_ROOT/scripts/talos.sh")"
out="$(_talos_labels '{"labels": null}' 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC3 _talos_labels exits 0 on a null labels"
assert_eq "" "$out" "AC3 _talos_labels prints nothing on a null labels"

# ── AC4: check-approval-sha reads the labels API ─────────────────────────────
out="$(STUB_AZURE_PR_9="$PR" STUB_AZURE_PR_LABELS="$LABELS" STUB_AZURE_PR_THREADS="$THREADS" \
  bash "$VCS" check-approval-sha 9 --stale-list 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC4 check-approval-sha exits 0 with the approval label on the labels API"
assert_contains "$out" "all approval labels are current" "AC4 check-approval-sha reads the labels API's labels"
out="$(STUB_AZURE_PR_9="$PR" STUB_AZURE_PR_LABELS="$LABELS" STUB_AZURE_PR_THREADS='{"value":[]}' \
  bash "$VCS" check-approval-sha 9 2>&1)"
assert_not_contains "$out" "no approval labels" "AC4 check-approval-sha does not report no approval labels"
out="$(STUB_AZURE_PR_9="$PR" STUB_AZURE_PR_LABELS_FAIL=1 STUB_AZURE_PR_THREADS="$THREADS" \
  bash "$VCS" check-approval-sha 9 2>&1)"; rc=$?
assert_eq "1" "$rc" "AC4 check-approval-sha fails closed when the labels read fails"
assert_not_contains "$out" "no approval labels" "AC4 a failed labels read is not read as no labels"

# ── AC5: real `az` output is indented, so both bodies span many lines ────────
# The stub prints the labels body indented, as `az rest` does; the `pr show`
# body is pretty-printed here the same way.
PR_PRETTY="$(printf '%s' "$PR" | python3 -I -c 'import json,sys;print(json.dumps(json.load(sys.stdin), indent=2))')"
out="$(STUB_AZURE_PR_9="$PR_PRETTY" STUB_AZURE_PR_LABELS="$LABELS" bash "$VCS" view-pr 9 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "AC5 view-pr exits 0 on indented az output"
assert_eq '[{"name": "pipeline:review"}, {"name": "qa:pass"}]' \
  "$(printf '%s' "$out" | python3 -I -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["labels"]))' 2>/dev/null)" \
  "AC5 view-pr lists the labels from indented az output"
out="$(STUB_AZURE_PR_9="$PR_PRETTY" STUB_AZURE_PR_LABELS="$LABELS" STUB_AZURE_PR_THREADS="$THREADS" \
  bash "$VCS" check-approval-sha 9 --stale-list 2>&1)"; rc=$?
assert_eq "0" "$rc" "AC5 check-approval-sha exits 0 on indented az output"
assert_contains "$out" "all approval labels are current" "AC5 check-approval-sha reads labels from indented az output"

finish
