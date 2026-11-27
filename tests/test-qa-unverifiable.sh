#!/usr/bin/env bash
# test-qa-unverifiable.sh -- qa.unverifiable: what a prose criterion QA cannot
# check does to the verdict (#1095).
#   AC1 unset or `note`: `AC<n> prose unverified (<why>)` is no FAIL. post-approval
#       lists it under "Needs a human" and adds qa:pass; post-verdict refuses a
#       FAIL that names nothing else, and lists it under that heading beside a real
#       failure; qa-run prints the policy next to the prose criteria
#   AC2 `fail`: the same input is today's FAIL, and post-approval refuses it
# The real pipeline-vcs.sh runs on the gh stub (a stateful comment store).
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
STUB_SHA="aabb1122ccdd3344eeff556677889900aabb1122"
CSTORE="$SANDBOX/cs.json"
export STUB_COMMENT_STORE="$CSTORE" STUB_CURRENT_USER=bot STUB_PR_HEAD_SHA="$STUB_SHA"
export STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]'
export PIPELINE_CONFIG="$SANDBOX/cfg.json"

# cfg_qa <value|->: the repo config, with qa.unverifiable set unless `-`.
cfg_qa() {
  if [ "$1" = - ]; then printf '{"vcs": {"provider": "github"}}' > "$PIPELINE_CONFIG"
  else printf '{"vcs": {"provider": "github"}, "qa": {"unverifiable": "%s"}}' "$1" > "$PIPELINE_CONFIG"; fi
}
store_count() { python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$CSTORE"; }
store_body() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.stdout.write(d[0]["body"] if d else "")' "$CSTORE"; }
fresh() { printf '[]' > "$CSTORE"; : > "$GH_LOG"; }
pa() { fresh; printf '%s\n' "$1" | bash "$VCS" post-approval 9 qa --issue 5 --body-file - >"$SANDBOX/out" 2>"$SANDBOX/err"; RC=$?; ERRT="$(cat "$SANDBOX/err")"; }
# pv <body> [extra post-verdict args...]
pv() { fresh; local b="$1"; shift; printf '%s\n' "$b" | bash "$VCS" post-verdict 9 qa --fail --issue 5 "$@" --body-file - >"$SANDBOX/out" 2>"$SANDBOX/err"; RC=$?; ERRT="$(cat "$SANDBOX/err")"; }
count_line() { printf '%s\n' "$2" | grep -cF -- "$1" || true; }
# section <body>: the lines after the "Needs a human" heading.
section() { printf '%s\n' "$1" | awk 'on { print } /^### Needs a human$/ { on = 1 }'; }

UNVER='AC2 prose unverified (no browser: Playwright is not configured)'
ONLY_UNVER="AC1 red@abc12345 green@head
- $UNVER"
REAL="AC1 FAIL head=fail red=fail: greet prints nothing

$UNVER"

# ── AC1: unset and note ──────────────────────────────────────────────────────
for mode in - note; do
  tag="[qa.unverifiable ${mode/-/unset}]"
  cfg_qa "$mode"

  pa "$ONLY_UNVER"
  body="$(store_body)"
  assert_eq "0" "$RC" "AC1 $tag a PASS with an unverified prose criterion posts"
  assert_contains "$body" "### Needs a human" "AC1 $tag the approval carries the Needs a human heading"
  assert_contains "$(section "$body")" "- $UNVER" "AC1 $tag the unverified criterion is listed under it"
  assert_eq "1" "$(count_line "$UNVER" "$body")" "AC1 $tag the criterion is listed once"
  assert_eq "<!-- talos:approval sha=$STUB_SHA role=qa -->" "$(printf '%s\n' "$body" | tail -n 1)" "AC1 $tag the approval marker stays last"
  assert_contains "$(cat "$GH_LOG")" 'issues/9/labels payload={"labels": ["qa:pass"]}' "AC1 $tag the PR gets qa:pass"

  pv "$ONLY_UNVER"
  assert_eq "1" "$RC" "AC1 $tag a FAIL that names only unverified prose is refused"
  assert_eq "0" "$(store_count)" "AC1 $tag no FAIL verdict is posted"
  assert_not_contains "$(cat "$GH_LOG")" "pipeline:blocked" "AC1 $tag nothing is blocked"
  assert_contains "$ERRT" "post-approval" "AC1 $tag the refusal names post-approval"

  pv "$REAL"
  body="$(store_body)"
  assert_eq "0" "$RC" "AC1 $tag a real failure beside unverified prose still posts a FAIL"
  assert_contains "$body" "**QA:** FAIL — AC1 FAIL head=fail" "AC1 $tag the summary is the real failure"
  assert_contains "$(section "$body")" "- $UNVER" "AC1 $tag the unverified criterion is under Needs a human"
  assert_eq "1" "$(count_line "$UNVER" "$body")" "AC1 $tag it is not also listed as a failure"
done

cfg_qa -
pa 'AC1 red@abc12345 green@head'
assert_not_contains "$(store_body)" "Needs a human" "AC1 an approval with nothing unverified gets no heading"

pa "AC1 red@abc12345 green@head

### Needs a human
- $UNVER"
assert_eq "1" "$(grep -c '^### Needs a human$' <<<"$(store_body)")" "AC1 a heading QA wrote itself is not doubled"

pv "FAIL: ci-pending build
$UNVER"
assert_eq "0" "$RC" "AC1 a ci-pending wait beside unverified prose still posts"
assert_not_contains "$(cat "$GH_LOG")" "pipeline:blocked" "AC1 the ci-pending wait blocks nothing"

# A defect written like a harmless line still posts the FAIL: only a whole line
# in a known report format counts as no failure.
cfg_qa -
while IFS= read -r defect; do
  pv "AC1 red@abc12345 green@head
$defect
$UNVER"
  assert_eq "0" "$RC" "AC1 the FAIL posts for: $defect"
  assert_contains "$(cat "$GH_LOG")" 'issues/9/labels payload={"labels": ["pipeline:blocked"]}' "AC1 the PR is blocked for: $defect"
  assert_contains "$(store_body)" "$defect" "AC1 the comment keeps the line: $defect"
done <<'TALOS_h3Vn8cYt5QwZ'
AC3 prose hand-checked: FAIL, the submit button does nothing
### AC3 FAIL: button is dead
## Defect: app crashes on load
AC1 green@head, but the page now crashes
note: data is lost on save
note: data is lost on save; red proof skipped, and the app crashes
qa-run: verdict FAIL e2e exited 1
qa-run: missing test file: tests/test-x.sh
qa-run: e2e ok but the page is blank
targeted run skipped: CI is the full run (merge.required_checks), yet login fails
| viewer-tests | fail |
| viewer-tests | pass | login is broken |
```the app crashes on load
AC2 prose unverified (no browser) but the app crashes (see the log)
TALOS_h3Vn8cYt5QwZ

# A long header line with text after it is read in linear time, not backtracked.
LONG="qa-run: issue #5 PR #9 head aabb1122 red abc12345 runner talos tests$(printf ' tests/a.b.c.d.sh%.0s' {1..40}) !"
started=$SECONDS
pv "$LONG
$UNVER"
assert_eq "0" "$RC" "AC1 a header line with trailing text posts the FAIL"
assert_eq "yes" "$([ $((SECONDS - started)) -lt 20 ] && echo yes || echo no)" "AC1 and it is matched without backtracking"

# The report lines agents/qa.md and the QA prompt require are no failure. The
# criterion lines are real `report` output, not hand-written ones.
printf '%s\n' '- [ ] AC1 greet prints (test)' '- [ ] AC2 the page looks right (prose: visual)' > "$SANDBOX/spec.md"
printf 'FAIL  AC1 greet prints\n' > "$SANDBOX/red.out"
printf '  ok  AC1 greet prints\n' > "$SANDBOX/head.out"
REPORT="$(bash "$TALOS_ROOT/scripts/pipeline-criteria.sh" report --spec "$SANDBOX/spec.md" --red "$SANDBOX/red.out" --head "$SANDBOX/head.out" --red-sha abc12345)"
assert_contains "$REPORT" "AC1 red@abc12345 green@head" "AC1 fixture: report prints the criterion line"
for skip in 'targeted run skipped: CI is the full run (merge.required_checks)' \
  'targeted run skipped: CI ran the tests this change selects (merge.required_checks)' \
  'targeted run skipped: estimated 700 s over budget; CI is the full run' \
  'CI: the merge-queue candidate is the gate (merge.queue_ci: candidate)'; do
  pv "qa-run: issue #5 PR #9 head aabb1122 red abc12345 runner talos tests tests/test-greet.sh
note: frozen run: tests/test-greet.sh differs from red commit abc12345
$REPORT
AC3 guard green@head (green at red@abc12345)
AC4 PASS same green@head frozen@head (red: missing)
AC5 green@head (red: missing)
qa-run: e2e ok
qa-run: e2e artifacts none found in shots
qa-run: unverifiable prose policy: note (report one you cannot check as \`AC<n> prose unverified (<why>)\`; it is not a FAIL)
qa-run: verdict PASS (1 test criteria green, 1 prose to hand-check) e2e ok

\`$skip\`.

### CI per-job results

| job | result | known flake |
|---|---|---|
| test (ubuntu-latest) | pass | - |
| lint | skipping |  |

\`\`\`
$UNVER
\`\`\`"
  assert_eq "1" "$RC" "AC1 a realistic verdict body naming only unverified prose is refused: $skip"
  assert_eq "0" "$(store_count)" "AC1 nothing is posted for the realistic body: $skip"
done

# --summary and a ci-pending wait are read before the refusal.
pv "$ONLY_UNVER" --summary 'FAIL: ci-pending build'
assert_eq "0" "$RC" "AC1 a ci-pending --summary still posts the wait"
assert_contains "$(store_body)" "**QA:** FAIL — FAIL: ci-pending build" "AC1 the wait comment carries the summary"
assert_not_contains "$(cat "$GH_LOG")" "pipeline:blocked" "AC1 the ci-pending summary blocks nothing"

pv "$ONLY_UNVER" --summary 'login crashes'
assert_eq "0" "$RC" "AC1 a failure named only in --summary posts"
assert_contains "$(store_body)" "**QA:** FAIL — login crashes" "AC1 the summary failure is the verdict line"
assert_contains "$(cat "$GH_LOG")" 'issues/9/labels payload={"labels": ["pipeline:blocked"]}' "AC1 the summary failure blocks the PR"

pv "$ONLY_UNVER" --summary "$UNVER"
assert_eq "1" "$RC" "AC1 a --summary that is only the unverified line is still refused"

# Small variants of the line: listed under Needs a human under note, no FAIL.
for variant in 'AC2: prose unverified (x)' '**AC2** prose unverified (x)' '**AC2:** prose unverified (x)' \
  '- [ ] AC2 prose unverified (x)' 'AC2 prose unverified (no simctl (refused))'; do
  pa "AC1 red@abc12345 green@head
$variant"
  assert_eq "0" "$RC" "AC1 [variant] a PASS posts: $variant"
  assert_contains "$(section "$(store_body)")" "- AC2 prose unverified (" "AC1 [variant] listed under Needs a human: $variant"
  pv "AC1 red@abc12345 green@head
$variant"
  assert_eq "1" "$RC" "AC1 [variant] a FAIL naming only it is refused: $variant"
done

# With trailing text it may say anything: listed, and a FAIL naming it posts.
TRAIL='AC2 prose unverified (x) - see notes'
pa "$TRAIL"
assert_contains "$(section "$(store_body)")" "- $TRAIL" "AC1 [variant] trailing text is listed under Needs a human"
pv "$TRAIL"
assert_eq "0" "$RC" "AC1 [variant] a FAIL with trailing text posts"
assert_contains "$(cat "$GH_LOG")" 'issues/9/labels payload={"labels": ["pipeline:blocked"]}' "AC1 [variant] and blocks"

# ── AC2: fail ────────────────────────────────────────────────────────────────
cfg_qa fail
for variant in 'AC2: prose unverified (x)' '**AC2** prose unverified (x)' '- [ ] AC2 prose unverified (x)' \
  'AC2 prose unverified (x) - see notes' '| AC2 | **prose unverified** | no browser |' 'ac2 Prose Unverified'; do
  pa "AC1 red@abc12345 green@head
$variant"
  assert_eq "1" "$RC" "AC2 [variant] post-approval refuses: $variant"
  assert_not_contains "$(cat "$GH_LOG")" '"qa:pass"' "AC2 [variant] qa:pass is not added: $variant"
done

cfg_qa fail
pv "$ONLY_UNVER"
body="$(store_body)"
assert_eq "0" "$RC" "AC2 post-verdict posts the same input as a FAIL"
assert_contains "$body" "**QA:** FAIL" "AC2 the comment is a FAIL verdict"
assert_contains "$body" "$UNVER" "AC2 the criterion stays in the details"
assert_not_contains "$body" "Needs a human" "AC2 no Needs a human heading"
assert_contains "$(cat "$GH_LOG")" 'issues/9/labels payload={"labels": ["pipeline:blocked"]}' "AC2 the PR is blocked"
assert_contains "$(cat "$GH_LOG")" 'issues/5/labels payload={"labels": ["pipeline:blocked"]}' "AC2 the issue is blocked"

pa "$ONLY_UNVER"
assert_eq "1" "$RC" "AC2 post-approval refuses an unverified prose criterion"
assert_eq "0" "$(store_count)" "AC2 no approval is posted"
assert_not_contains "$(cat "$GH_LOG")" '"qa:pass"' "AC2 qa:pass is not added"
assert_contains "$ERRT" "qa.unverifiable" "AC2 the refusal names the key"

# ── AC1: qa-run says what the policy is ──────────────────────────────────────
unset PIPELINE_CONFIG
REPO_DIR="$SANDBOX/repo"
mkdir -p "$REPO_DIR/scripts" || exit 1
cd "$REPO_DIR" || exit 1
git init -q -b main
git config user.email t@t.invalid
git config user.name t
cp "$TALOS_ROOT"/scripts/* scripts/
cat > scripts/pipeline-vcs.sh <<'TALOS_k4Wm9qZt2VbE'
#!/usr/bin/env bash
case "$1" in
  view-issue) echo '{"title": "t", "body": "- [ ] AC1 the page looks right (prose: visual)", "labels": [], "comments": []}' ;;
  pr-mergeable) echo MERGEABLE ;;
  checkout-pr) : ;;
  *) exit 99 ;;
esac
TALOS_k4Wm9qZt2VbE
git add -A
git commit -q -m base
for mode in note fail; do
  printf '{"qa": {"unverifiable": "%s"}}' "$mode" > "$SANDBOX/qarun.json"
  out="$(PIPELINE_CONFIG="$SANDBOX/qarun.json" bash scripts/pipeline-criteria.sh qa-run 7 9 2>&1)"
  assert_contains "$out" "qa-run: unverifiable prose policy: $mode" "AC1 qa-run prints the $mode policy beside prose criteria"
done

finish
