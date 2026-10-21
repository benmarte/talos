#!/usr/bin/env bash
# test-qa-fail-verdict-814.sh -- QA's FAIL path with Talos installed outside the repo (#814).
#   AC1 post-verdict <pr> qa --fail posts one marked, template-rendered comment (no scripts/ or templates/ in cwd)
#   AC2 ... and adds pipeline:blocked (PR, issue), removes pipeline:review, exits 0
#   AC3 a second identical call at the same head posts nothing, exits 0, labels still applied
#   AC4 a wrong role, a missing --fail, a non-numeric --issue, an empty body: exit 1, nothing posted
#   AC5 the driver posts no fallback when the thread gained a talos:qa-verdict comment; else one
#   AC6 every `talos.sh prompt` role names the absolute scripts and templates dirs; no `bash scripts/`
#   AC7 post-approval <pr> qa --issue <n> from the same cwd still posts one marked comment + qa:pass
# AC8 and AC9 are prose. The vcs cases run the real pipeline-vcs.sh by absolute path on the gh stub
# (a stateful comment store, as tests/test-post-approval.sh does); AC5 drives the QA-comment step of
# `talos.sh run` on the journaling stubs of tests/talos-run-sections.sh.
set -u
. "$(dirname "$0")/helpers.sh"
TALOS_RUN_PART=0
TALOS_RUN_EMBED=1
. "$(dirname "$0")/talos-run-sections.sh"

VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"
OUTSIDE="$SANDBOX/outside"
mkdir -p "$OUTSIDE" || exit 1
STUB_SHA="aabb1122ccdd3344eeff556677889900aabb1122"
CSTORE="$SANDBOX/cs814.json"
export STUB_COMMENT_STORE="$CSTORE" STUB_CURRENT_USER=bot STUB_PR_HEAD_SHA="$STUB_SHA"
export STUB_PR_LABELS_JSON='[{"name":"qa:pass"}]'
BODY_TXT=$'Two criteria failed.\n\n- AC2 rejects an expired token: got 200\n- AC3 logs the refusal: no log line'

# store_count / store_body N: the comments the gh stub kept, and the Nth one's text.
store_count() { python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$CSTORE"; }
store_body() { python3 -I -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))[int(sys.argv[2])]["body"])' "$CSTORE" "$1"; }
fresh() { printf '[]' > "$CSTORE"; : > "$GH_LOG"; }
# pv ARGS...: post-verdict from a cwd with no scripts/ and no templates/, the body on stdin.
pv() { (cd "$OUTSIDE" && printf '%s\n' "$BODY_TXT" | bash "$VCS" post-verdict "$@" 2>"$SANDBOX/pv.err"); }

[ ! -e "$OUTSIDE/scripts" ] && [ ! -e "$OUTSIDE/templates" ] || exit 1

# ── AC1 / AC2 ────────────────────────────────────────────────────────────────
fresh
pv 9 qa --fail --issue 5 --body-file - > "$SANDBOX/pv.out"; RC=$?
BODY1="$(store_body 0 2>/dev/null)"
assert_eq "1" "$(store_count)" "AC1 post-verdict posts exactly one PR comment"
assert_eq "**Agent:** qa (talos)" "$(printf '%s\n' "$BODY1" | head -n 1)" "AC1 the first line is the comments.header for qa"
assert_contains "$BODY1" "**QA:** FAIL — Two criteria failed." "AC1 the comment carries **QA:** FAIL — <summary>"
assert_contains "$BODY1" "AC3 logs the refusal: no log line" "AC1 the comment carries the details"
assert_eq "<!-- talos:qa-verdict sha=$STUB_SHA -->" "$(printf '%s\n' "$BODY1" | tail -n 1)" "AC1 the last line is the talos:qa-verdict marker at the PR head"
assert_eq "0" "$RC" "AC2 post-verdict exits 0"
GHLOG="$(cat "$GH_LOG")"
assert_contains "$GHLOG" 'issues/9/labels payload={"labels": ["pipeline:blocked"]}' "AC2 pipeline:blocked is added on the PR"
assert_contains "$GHLOG" "-X DELETE -H Accept: application/vnd.github+json repos/acme/widget/issues/9/labels/pipeline%3Areview" "AC2 pipeline:review is removed from the PR"
assert_contains "$GHLOG" 'issues/5/labels payload={"labels": ["pipeline:blocked"]}' "AC2 pipeline:blocked is added on the issue"

# ── AC3 ──────────────────────────────────────────────────────────────────────
: > "$GH_LOG"
pv 9 qa --fail --issue 5 --body-file - > /dev/null; RC=$?
assert_eq "0" "$RC" "AC3 a second identical call exits 0"
assert_eq "1" "$(store_count)" "AC3 a second identical call at the same head posts no second comment"
assert_contains "$(cat "$GH_LOG")" 'issues/9/labels payload={"labels": ["pipeline:blocked"]}' "AC3 the labels are still applied"

# ── AC4 ──────────────────────────────────────────────────────────────────────
refused() {  # $1 = label, rest = post-verdict args (body on stdin)
  local _l="$1"; shift
  fresh
  pv "$@" > /dev/null; RC=$?
  assert_eq "1" "$RC" "AC4 $_l: exit 1"
  assert_contains "$(cat "$SANDBOX/pv.err")" "post-verdict: " "AC4 $_l: the refusal is the verb's own, with a reason"
  assert_eq "0" "$(store_count)" "AC4 $_l: nothing posted"
  assert_not_contains "$(cat "$GH_LOG")" "/labels" "AC4 $_l: no label changed"
}
refused "role reviewer" 9 reviewer --fail --issue 5 --body-file -
refused "a missing --fail" 9 qa --issue 5 --body-file -
refused "a non-numeric --issue" 9 qa --fail --issue five --body-file -
fresh
(cd "$OUTSIDE" && printf '\n  \n' | bash "$VCS" post-verdict 9 qa --fail --issue 5 --body-file - > /dev/null 2> "$SANDBOX/pv.err"); RC=$?
assert_eq "1" "$RC" "AC4 an empty body: exit 1"
assert_contains "$(cat "$SANDBOX/pv.err")" "post-verdict: " "AC4 an empty body: the refusal is the verb's own, with a reason"
assert_eq "0" "$(store_count)" "AC4 an empty body: nothing posted"
assert_not_contains "$(cat "$GH_LOG")" "/labels" "AC4 an empty body: no label changed"

# ── AC7 ──────────────────────────────────────────────────────────────────────
fresh
(cd "$OUTSIDE" && bash "$VCS" post-approval 9 qa --issue 5 > /dev/null 2>&1); RC=$?
assert_eq "0" "$RC" "AC7 post-approval qa from an out-of-repo cwd exits 0"
assert_eq "1" "$(store_count)" "AC7 post-approval posts one comment"
assert_eq "<!-- talos:approval sha=$STUB_SHA role=qa -->" "$(store_body 0 | tail -n 1)" "AC7 the comment carries the approval marker"
assert_contains "$(cat "$GH_LOG")" 'issues/9/labels payload={"labels": ["qa:pass"]}' "AC7 qa:pass is applied"
unset STUB_COMMENT_STORE STUB_PR_LABELS_JSON

# ── AC5: the driver's fallback ───────────────────────────────────────────────
qa814_fixture() {
  reset_stubs
  LEASE_RESET
  draft_cfg '"timeout_ms": 600000, "ci_wait_s": 900'
  draft_collect ready
  draft_ready
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$STUB_DIR/pr-head.12"
  printf '{"number": 9, "title": "t", "labels": [{"name": "pipeline:ready"}], "body": "- [ ] AC1 the suite is green (prose: fixture)", "state": "open"}' \
    > "$STUB_DIR/view-issue.9"
  printf 'FAIL: the suite broke\n' > "$STUB_DIR/message.qa.1"
}
FALLBACK="the QA stage ended without its verdict comment"
fallback_count() { if [ -f "$STUB_DIR/bodies" ]; then grep -c "$FALLBACK" "$STUB_DIR/bodies" || true; else echo 0; fi; }

qa814_fixture
printf '%s' '{"comments": [{"body": "**Agent:** qa (talos)\n\nAC1 failed\n\n<!-- talos:qa-verdict sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->", "author": {"login": "bot"}}]}' \
  > "$STUB_DIR/read-comments.out"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --max-iterations 1
assert_contains "$(journal)" "agent qa" "AC5 the QA dispatch ran"
assert_eq "0" "$(fallback_count)" "AC5 a talos:qa-verdict comment on the thread: the driver posts no fallback"
assert_not_contains "$OUT" "qa-comment-missing" "AC5 a talos:qa-verdict comment on the thread: no qa-comment-missing stop"

qa814_fixture
printf '%s' '{"comments": []}' > "$STUB_DIR/read-comments.out"
TALOS_LEASE_TTL_S=1800 TALOS_NOW=12000 rn --max-iterations 1
assert_eq "1" "$(fallback_count)" "AC5 with no new verdict comment the driver still posts one fallback"

# ── AC6: the prompts name the install ────────────────────────────────────────
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
TALOS="$TALOS_ROOT/scripts/talos.sh"
rm -f "$SANDBOX/talos.pipeline.json"
unset PIPELINE_CONFIG
printf 'title\n' > "$SANDBOX/p-title.txt"
printf 'body\n' > "$SANDBOX/p-body.txt"
printf 'approved sha: aaa111\n' > "$SANDBOX/p-rs.txt"
printf 'approved_sha=aaa111\nhead_sha=bbb222\n' > "$SANDBOX/p-delta.txt"
printf 'FAIL: x\n' > "$SANDBOX/p-prior.txt"
P_CASES='validator|validator --issue 9
pm|pm --issue 9
planner|planner --issue 9 --title-file P_TITLE --body-file P_BODY
developer|developer --issue 9 --prior-file P_PRIOR
developer-fix|developer --issue 9 --pr 12 --shape fix-round --draft --prior-file P_PRIOR
qa|qa --issue 9 --pr 12
reviewer|reviewer --issue 9 --pr 12
security|security --issue 9 --pr 12
adversarial|adversarial --issue 9 --pr 12
docs|docs --issue 9 --pr 12
restamp-qa|qa --issue 9 --pr 12 --shape restamp --restamp-file P_RS
restamp-reviewer|reviewer --issue 9 --pr 12 --shape restamp --restamp-file P_RS
restamp-docs|docs --issue 9 --pr 12 --shape restamp --restamp-file P_DELTA'
while IFS='|' read -r name args; do
  a=()
  for w in $args; do
    case "$w" in
      P_TITLE) a+=("$SANDBOX/p-title.txt") ;; P_BODY) a+=("$SANDBOX/p-body.txt") ;;
      P_PRIOR) a+=("$SANDBOX/p-prior.txt") ;; P_RS) a+=("$SANDBOX/p-rs.txt") ;;
      P_DELTA) a+=("$SANDBOX/p-delta.txt") ;; *) a+=("$w") ;;
    esac
  done
  (cd "$OUTSIDE" && bash "$TALOS" prompt "${a[@]}" > "$SANDBOX/p.out" 2> "$SANDBOX/p.err"); RC=$?
  PF="$(sed -n 's/^prompt_file=//p' "$SANDBOX/p.out")"
  TXT=""
  [ "$RC" -ne 0 ] || [ -z "$PF" ] || { TXT="$(cat "$PF")"; rm -f "${PF:?}"; }
  assert_eq "0" "$RC" "AC6 $name: the prompt renders"
  assert_contains "$TXT" "Talos scripts: $TALOS_ROOT/scripts" "AC6 $name: the Talos scripts line carries the absolute dir"
  assert_contains "$TXT" "Talos templates: $TALOS_ROOT/templates/comments" "AC6 $name: the Talos templates line carries the absolute dir"
  assert_not_contains "$TXT" "bash scripts/" "AC6 $name: no instruction depends on a repo-relative scripts/"
  if [ "$name" = qa ]; then
    assert_contains "$TXT" "bash $TALOS_ROOT/scripts/pipeline-criteria.sh qa-run 9 12" "AC6 the qa prompt's qa-run command uses the absolute scripts dir"
  fi
done <<EOF
$P_CASES
EOF

finish
