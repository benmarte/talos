#!/usr/bin/env bash
# test-talos-gate.sh -- `scripts/talos.sh gate fix-round` and `gate merge` (#466,
# slice 2 of epic #422).
#
# The two verbs replace the Step 3 intro (budget check -> record-attempt ->
# unblock) and the Step 4 gate prose of skills/pipeline/SKILL.md, so this file
# pins that they do what the prose said, in its order:
#   (a) gate merge, one case per verdict and per reason, against a stub
#       pipeline-vcs.sh that journals every call: the journal is the order pin
#   (b) gate fix-round: the old three-step sequence and the verb leave the same
#       gh journal under the real scripts; both ceilings, the budget stop, the
#       unblock, a failing record-attempt
#   (c) the output contract: `verdict=` first, one of merge|handoff|redispatch|
#       wait|block, `reason=` from the enum in talos.sh's header, sanitised
#       values; the checker is shown red by an out-of-vocabulary verdict and an
#       out-of-enum reason
#   (d) usage, missing scripts, and the writes a verdict must not make
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
TALOS="$TALOS_ROOT/scripts/talos.sh"
ERR="$SANDBOX/stderr"

# ── fixtures ─────────────────────────────────────────────────────────────────
# A copy of the scripts directory whose pipeline-vcs.sh, pipeline-notify.sh,
# pipeline-hooks.sh, pipeline-budget.sh, pipeline-mergebase.sh and
# pipeline-draft-check.sh are one journaling stub. For the stub, <key> is the
# verb of pipeline-vcs.sh, else the script's name without `pipeline-` and `.sh`;
# $STUB_DIR/<key>.{out,err,rc} is what it answers (rc 0 by default).
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="${1:-}"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then { printf "[%s]\n" "$*"; cat "$a"; } >> "$d/bodies"; fi
  prev="$a"
done
if [ "$n" = "hooks" ]; then cat > "$d/hooks.stdin"; fi
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-budget.sh pipeline-mergebase.sh pipeline-draft-check.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
GATE="$GS/talos.sh"

HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
OTHER_SHA="fedcba9876543210fedcba9876543210fedcba98"
cfg_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }
# set_stub <key> <rc> [out] [err]: what a stubbed call answers.
set_stub() {
  printf '%s\n' "$2" > "$STUB_DIR/$1.rc"
  printf '%s' "${3:-}" > "$STUB_DIR/$1.out"
  printf '%s' "${4:-}" > "$STUB_DIR/$1.err"
}
labels_json() {  # names... -> {"labels":[{"name":..},..]}
  local out="" n
  for n in "$@"; do out="${out:+$out,}{\"name\":\"$n\"}"; done
  printf '{"labels":[%s]}' "$out"
}
# reset_stubs: the happy path of a PR_DRAFT=false, merge.auto=true run.
reset_stubs() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  rm -f "$SANDBOX/talos.pipeline.json"
  set_stub view-pr 0 "$(labels_json qa:pass review:approved security:approved docs:done pipeline:review)"
  set_stub view-issue 0 "$(labels_json pipeline:review)"
  set_stub pr-head 0 "$HEAD_SHA"
  set_stub read-comments 0 '{"comments":[]}'
  set_stub draft-check 0 "false"
  set_stub pr-ci-runs 0 "2"
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
# calls <key-or-script>: how many journal lines start with "<name> <verb>".
called() { journal | grep -c "^$1 \|^vcs $1 "; }
bodies() { cat "$STUB_DIR/bodies" 2>/dev/null; }
gm() { OUT="$(bash "$GATE" gate merge 9 42 2>"$ERR")"; RC=$?; }
vcs_verbs() { journal | sed -n 's/^vcs \([a-z-]*\).*/\1/p' | tr '\n' ' ' | sed 's/ $//'; }
line_of() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }

# ── the output contract, as a checker ────────────────────────────────────────
GATE_REASONS="$(sed -n 's/^# gate-reasons: //p' "$TALOS" | head -n 1)"
# check_gate_output FILE: the first line is verdict=<vocab> (or a lone stop line);
# every line is KEY=value or `stop|warn reason=<enum>`; every reason= value and
# every stop|warn reason is in the header's enum (stop reasons also the
# unsupported-verb:<verb> shape); no raw control byte.
check_gate_output() {
  python3 -I -c '
import re, sys
reasons = set(sys.argv[2].split())
data = open(sys.argv[1], "rb").read()
if re.search(rb"[\x00-\x09\x0b-\x1f\x7f]|\xc2[\x80-\x9f]", data):
    sys.exit(1)
lines = data.decode("utf-8").split("\n")
if lines and lines[-1] == "":
    lines.pop()
if not lines:
    sys.exit(1)
stop_extra = {"usage", "unknown-verb", "scripts-missing", "python-missing", "scratch-unavailable",
              "config-unreadable", "draft-resolve-failed", "view-failed", "labels-unreadable",
              "approval-sha-failed", "draft-unverified", "ci-unverified", "head-unresolved",
              "comments-unreadable", "handoff-label-failed"}
warn_ok = {"closing-keyword-unverified", "ci-runs-unrecorded", "budget-check-failed", "unblock-failed",
           "comment-failed", "label-failed", "value-truncated"}
kv = re.compile(r"([A-Za-z][A-Za-z0-9_.]*)=")
sw = re.compile(r"(stop|warn) reason=([a-z:-]+)( key=[A-Za-z0-9_.-]+)?\Z")
if lines[0].startswith("stop "):
    ok = len(lines) == 1
else:
    ok = lines[0] in ("verdict=" + v for v in ("merge", "handoff", "redispatch", "wait", "block"))
if not ok:
    sys.exit(1)
for i, ln in enumerate(lines):
    m = kv.match(ln)
    if m:
        if m.group(1) == "verdict" and i != 0:
            sys.exit(1)
        if m.group(1) == "reason" and ln[7:] not in reasons:
            sys.exit(1)
        continue
    m = sw.match(ln)
    if m:
        r = m.group(2)
        if m.group(1) == "stop" and (r in stop_extra or r.startswith("unsupported-verb:")):
            continue
        if m.group(1) == "warn" and r in warn_ok:
            continue
    sys.exit(1)
' "$1" "$GATE_REASONS"
}
# assert_gate LABEL: the last gm output satisfies the contract.
assert_gate() { printf '%s\n' "$OUT" > "$SANDBOX/out.gate"; check_gate_output "$SANDBOX/out.gate"; assert_eq "0" "$?" "$1: output satisfies the line contract"; }

# ── (a) gate merge ───────────────────────────────────────────────────────────
reset_stubs
gm
assert_eq "0" "$RC" "merge: exits 0"
assert_eq "verdict=merge" "$OUT" "merge: PR_DRAFT=false, all gates green: exactly one verdict line"
assert_eq "view-pr view-issue check-approval-sha check-pr-files check-closing-keyword pr-checks-required conflict-files" "$(vcs_verbs)" "merge: the gates run in Step 4's order and nothing else is called"
assert_eq "0" "$(called pr-is-draft)" "merge: PR_DRAFT=false never asks pr-is-draft"
assert_eq "0" "$(called pr-ci-runs)" "merge: PR_DRAFT=false never reads pr-ci-runs"
assert_eq "0" "$(called merge-pr)" "merge: the verdict never merges"
assert_eq "0" "$(called label-pr)" "merge: a green run writes no label"
assert_eq "1" "$(called check-approval-sha)" "merge: check-approval-sha runs once"
assert_contains "$(journal)" "vcs check-approval-sha 9 --stale-list" "merge: the approval-SHA gate asks for --stale-list"
assert_contains "$(journal)" "vcs check-closing-keyword 9 42" "merge: the closing-keyword gate gets the PR and the issue"
assert_gate "merge"

reset_stubs; set_stub draft-check 0 "true"; set_stub pr-is-draft 1 "ready"
gm
assert_eq "verdict=merge
ci_runs=2" "$OUT" "merge: PR_DRAFT=true reads the CI-run count before the verdict"
assert_eq "view-pr view-issue check-approval-sha check-pr-files check-closing-keyword pr-is-draft pr-checks-required conflict-files pr-ci-runs" "$(vcs_verbs)" "merge: PR_DRAFT=true adds pr-is-draft before CI and pr-ci-runs last"
assert_gate "merge (draft)"
set_stub pr-ci-runs 2 ""
gm
assert_contains "$OUT" "warn reason=ci-runs-unrecorded" "merge: a pr-ci-runs that fails is warned about, never a guessed count"
assert_eq "verdict=merge" "$(printf '%s\n' "$OUT" | head -n 1)" "merge: a missing CI-run count does not block an otherwise green merge"
assert_not_contains "$OUT" "ci_runs=" "merge: no ci_runs key when the count is unverified"
set_stub pr-ci-runs 0 "two"
gm
assert_contains "$OUT" "warn reason=ci-runs-unrecorded" "merge: a non-numeric pr-ci-runs answer is not recorded"
assert_gate "merge (ci-runs unrecorded)"

# Human-merge mode.
reset_stubs; cfg_json '{"merge": {"auto": false}}'
gm
assert_eq "verdict=handoff" "$OUT" "handoff: merge.auto=false with every gate green"
assert_contains "$(journal)" "vcs label-pr 9 --add pipeline:approved" "handoff: the PR gets pipeline:approved"
assert_eq "0" "$(called merge-pr)" "handoff: merge-pr is never called"
assert_eq "0" "$(called pr-ci-runs)" "handoff: no CI-run count (nothing merges)"
assert_gate "handoff"
set_stub view-pr 0 "$(labels_json qa:pass review:approved security:approved docs:done pipeline:approved)"
rm -f "$STUB_DIR/journal"
gm
assert_eq "verdict=wait
reason=awaiting-human-merge" "$OUT" "handoff: a PR already carrying pipeline:approved waits for the human, silently"
assert_eq "0" "$(called label-pr)" "handoff: the second pass writes nothing"
assert_gate "handoff (already)"
reset_stubs; cfg_json '{"merge": {"auto": false}}'; set_stub label-pr 1 "" "boom"
gm
assert_eq "stop reason=handoff-label-failed" "$OUT" "handoff: a failed pipeline:approved label stops, so no comment follows a missing label"
assert_eq "1" "$RC" "handoff: that stop exits 1"

# Ready: blocked, skip-qa, approval labels.
reset_stubs; set_stub view-pr 0 "$(labels_json qa:pass review:approved security:approved docs:done pipeline:blocked)"
gm
assert_eq "verdict=wait
reason=blocked-label" "$OUT" "wait: pipeline:blocked on the PR"
assert_eq "view-pr view-issue" "$(vcs_verbs)" "wait: a blocked PR runs no later gate"
assert_gate "wait (blocked pr)"
reset_stubs; set_stub view-issue 0 "$(labels_json pipeline:blocked)"
gm
assert_eq "verdict=wait
reason=blocked-label" "$OUT" "wait: pipeline:blocked on the issue"
reset_stubs; set_stub view-pr 0 "$(labels_json qa:pass docs:done)"
gm
assert_eq "verdict=wait
reason=approvals-missing
missing=review:approved,security:approved" "$OUT" "wait: the missing approval labels are named, in contract order"
assert_gate "wait (approvals)"
cfg_json '{"roles": {"reviewer": false, "security": false}}'
gm
assert_eq "verdict=merge" "$OUT" "ready: a disabled role's label is not required"
cfg_json '{"roles": {"adversarial": true}}'
gm
assert_contains "$OUT" "missing=review:approved,security:approved,adversarial:approved" "ready: roles.adversarial=true requires adversarial:approved"
reset_stubs; set_stub view-pr 0 "$(labels_json skip-qa)"
gm
assert_eq "verdict=merge" "$OUT" "skip-qa: on the PR it waives the approval labels"
assert_contains "$(vcs_verbs)" "check-pr-files" "skip-qa: the forbidden-files gate still runs"
assert_contains "$(vcs_verbs)" "pr-checks-required" "skip-qa: the CI gate still runs"
reset_stubs; set_stub view-pr 0 "$(labels_json)"; set_stub view-issue 0 "$(labels_json skip-qa)"
gm
assert_eq "verdict=merge" "$OUT" "skip-qa: on the issue it waives the approval labels too"
reset_stubs; set_stub view-pr 0 "$(labels_json)"; set_stub view-issue 0 "$(labels_json qa:pass review:approved security:approved docs:done)"
gm
assert_contains "$OUT" "reason=approvals-missing" "ready: approval labels count on the PR only, not on the issue"
reset_stubs; set_stub view-pr 0 "not json"
gm
assert_eq "stop reason=labels-unreadable" "$OUT" "stop: a view-pr answer that is not JSON stops"
reset_stubs; set_stub view-pr 1
gm
assert_eq "stop reason=view-failed" "$OUT" "stop: a failing view-pr stops"
assert_eq "1" "$RC" "stop: view-failed exits 1"

# Approval SHAs.
reset_stubs
set_stub check-approval-sha 1 "stale role=reviewer label=review:approved
stale role=qa label=qa:pass
stale role=docs label=docs:done" "qa: approved at aaa, head is bbb
docs: approved at aaa, head is bbb"
gm
assert_eq "verdict=redispatch
reason=stale-approvals
stale=qa,docs,reviewer" "$OUT" "redispatch: stale roles come back in re-stamp order (qa, docs, reviewers), whatever order the helper printed"
assert_contains "$(journal)" "vcs label-pr 9 --remove qa:pass" "stale: the stale QA label is stripped"
assert_contains "$(journal)" "vcs label-pr 9 --remove docs:done" "stale: the stale docs label is stripped"
assert_contains "$(journal)" "vcs label-pr 9 --remove review:approved" "stale: the stale reviewer label is stripped"
assert_not_contains "$(journal)" "security:approved" "stale: only the stale labels are stripped"
assert_contains "$(bodies)" "Stale approvals reset for re-review: qa,docs,reviewer" "stale: the PR comment names the roles"
assert_contains "$(bodies)" "qa: approved at aaa, head is bbb" "stale: the PR comment carries the helper's reasons"
assert_eq "view-pr view-issue check-approval-sha label-pr label-pr label-pr comment-pr" "$(vcs_verbs)" "stale: no later gate runs after a stale approval"
assert_gate "redispatch (stale)"
set_stub check-approval-sha 1 "stale role=evil label=x:y
stale role=qa label=hostile-label" "reason"
gm
assert_contains "$(journal)" "vcs label-pr 9 --remove qa:pass" "stale: the label comes from the contract for the role, never from the helper's text"
assert_not_contains "$(journal)" "hostile-label" "stale: a label named by the helper's line is never passed on"
assert_eq "verdict=redispatch
reason=stale-approvals
stale=qa" "$OUT" "stale: an unknown role in a stale line is ignored"
set_stub check-approval-sha 1 "" "api down"
gm
assert_eq "stop reason=approval-sha-failed" "$OUT" "stop: check-approval-sha failing with no stale line is approval-sha-failed"
set_stub check-approval-sha 1 "stale role=evil label=x:y" "x"
rm -f "$STUB_DIR/journal"
gm
assert_eq "stop reason=approval-sha-failed" "$OUT" "stop: only unknown stale roles is approval-sha-failed"
assert_eq "0" "$(called label-pr)" "stop: no label is touched when nothing known is stale"

# Forbidden files.
reset_stubs; set_stub check-pr-files 1 ".env" "check-pr-files: forbidden file .env"
gm
assert_eq "verdict=block
reason=forbidden-files" "$OUT" "block: forbidden files"
assert_contains "$(journal)" "vcs label-pr 9 --add pipeline:blocked" "block: forbidden files set pipeline:blocked on the PR"
assert_contains "$(bodies)" "check-pr-files: forbidden file .env" "block: the check output is the PR comment"
assert_contains "$(journal)" 'notify blocked #42 forbidden files in PR #9 42' "block: a blocked notice is sent"
assert_eq "0" "$(called check-closing-keyword)" "block: forbidden files stop before the closing-keyword gate"
assert_eq "0" "$(called label-issue)" "block: the gate blocks the PR, not the issue"
assert_gate "block (forbidden-files)"
reset_stubs; set_stub check-pr-files 2 "" "not supported by this provider"
gm
assert_eq "stop reason=unsupported-verb:check-pr-files" "$OUT" "stop: check-pr-files exit 2 (unsupported) never merges"
assert_eq "1" "$RC" "stop: unsupported-verb exits 1"
assert_eq "0" "$(called label-pr)" "stop: an unchecked gate sets no label"
assert_gate "stop (unsupported-verb)"

# Closing keyword.
reset_stubs; set_stub check-closing-keyword 1 "" "PR body closes #42 while PR #11 is open"
gm
assert_eq "verdict=block
reason=closing-keyword" "$OUT" "block: a closing keyword with sibling PRs open"
assert_contains "$(bodies)" "PR body closes #42 while PR #11 is open" "block: the diagnostic is the PR comment"
assert_contains "$(journal)" "vcs label-pr 9 --add pipeline:blocked" "block: the closing-keyword block labels the PR"
assert_eq "0" "$(called pr-checks-required)" "block: the closing-keyword gate stops before CI"
reset_stubs; set_stub check-closing-keyword 0 "talos:closing-keyword-unverified pr=9 issue=42 reason=siblings-capped"
gm
assert_eq "verdict=block
reason=siblings-capped" "$OUT" "block: siblings-capped blocks even though the gate exited 0"
assert_contains "$(bodies)" "talos:closing-keyword-unverified pr=9 issue=42 reason=siblings-capped" "block: the marker line is the PR comment"
reset_stubs; set_stub check-closing-keyword 0 "talos:closing-keyword-unverified pr=9 issue=42 reason=pr-fetch-failed"
gm
assert_eq "verdict=merge
warn reason=closing-keyword-unverified" "$OUT" "warn: any other unverified marker is logged and the gates go on"
assert_gate "merge (closing-keyword warn)"
reset_stubs; set_stub check-closing-keyword 2
gm
assert_eq "stop reason=unsupported-verb:check-closing-keyword" "$OUT" "stop: check-closing-keyword exit 2 never merges"

# Draft state.
reset_stubs; set_stub draft-check 0 "true"; set_stub pr-is-draft 0 "draft"
gm
assert_eq "verdict=redispatch
reason=draft-pr" "$OUT" "redispatch: a draft PR goes back to the Draft stage order"
assert_eq "0" "$(called pr-checks-required)" "redispatch: a draft PR is not CI-checked"
assert_gate "redispatch (draft)"
set_stub pr-is-draft 2 ""
gm
assert_eq "stop reason=draft-unverified" "$OUT" "stop: pr-is-draft exit 2 (unverified) never merges"
set_stub pr-is-draft 1 "draft"
gm
assert_eq "stop reason=draft-unverified" "$OUT" "stop: exit 1 without the word ready is unverified"
set_stub pr-is-draft 0 "ready"
gm
assert_eq "stop reason=draft-unverified" "$OUT" "stop: exit 0 without the word draft is unverified"
set_stub draft-check 0 "maybe"
gm
assert_eq "stop reason=draft-resolve-failed" "$OUT" "stop: a PR_DRAFT resolve that prints neither true nor false stops, never defaulting to false"
set_stub draft-check 3 "true"
gm
assert_eq "stop reason=draft-resolve-failed" "$OUT" "stop: a failing PR_DRAFT resolver stops"

# Required CI and the re-run budget.
reset_stubs; set_stub pr-checks-required 2 "" "pr-checks-required: pending or missing: ci / test"
gm
assert_eq "verdict=wait
reason=ci-pending" "$OUT" "wait: a pending required check"
assert_eq "0" "$(called rerun-ci)" "wait: a pending check is not re-run"
assert_eq "0" "$(called conflict-files)" "wait: CI pending stops before the stale-base guard"
assert_gate "wait (ci-pending)"
RED="pr-checks-required: failed: ci / test"
reset_stubs; set_stub pr-checks-required 1 "" "$RED"
gm
assert_eq "verdict=wait
reason=ci-rerun
attempt=1" "$OUT" "wait: the first red build is re-run (attempt 1 of 2)"
assert_contains "$(journal)" "vcs rerun-ci 9" "rerun: rerun-ci is called"
assert_contains "$(bodies)" "<!-- talos:ci-rerun $HEAD_SHA -->" "rerun: the PR comment carries the marker for this head"
assert_contains "$(journal)" "vcs pr-head 9" "rerun: the marker is keyed by the PR head SHA"
assert_gate "wait (ci-rerun)"
set_stub read-comments 0 "{\"comments\":[{\"body\":\"re-run\\n<!-- talos:ci-rerun $HEAD_SHA -->\"},{\"body\":\"<!-- talos:ci-rerun $OTHER_SHA -->\"},{\"body\":\"unrelated\"}]}"
rm -f "$STUB_DIR/journal" "$STUB_DIR/bodies"
gm
assert_eq "verdict=wait
reason=ci-rerun
attempt=2" "$OUT" "wait: one marker for this head makes the next re-run attempt 2; a marker for another head is not counted"
set_stub read-comments 0 "{\"comments\":[{\"body\":\"<!-- talos:ci-rerun $HEAD_SHA -->\"},{\"body\":\"x <!-- talos:ci-rerun $HEAD_SHA -->\"}]}"
rm -f "$STUB_DIR/journal" "$STUB_DIR/bodies"
gm
assert_eq "verdict=wait
reason=ci-failed" "$OUT" "wait: two re-runs spent for this head, not blocked, waiting for a human or a new commit"
assert_eq "0" "$(called rerun-ci)" "rerun: the third re-run is never started"
assert_contains "$(bodies)" "pr-checks-required: failed: ci / test" "rerun: the PR comment lists the failing checks"
assert_eq "0" "$(called label-pr)" "rerun: a spent budget does not set pipeline:blocked"
assert_gate "wait (ci-failed)"
assert_contains "$(bodies)" "<!-- talos:ci-failed $HEAD_SHA -->" "ci-failed: the PR comment carries the marker for this head"
set_stub read-comments 0 "{\"comments\":[{\"body\":\"<!-- talos:ci-rerun $HEAD_SHA -->\"},{\"body\":\"<!-- talos:ci-rerun $HEAD_SHA -->\"},{\"body\":\"x\\n<!-- talos:ci-failed $HEAD_SHA -->\"}]}"
rm -f "$STUB_DIR/journal" "$STUB_DIR/bodies"
gm
assert_eq "verdict=wait
reason=ci-failed" "$OUT" "ci-failed: the second pass for the same head gives the same verdict"
assert_eq "0" "$(called comment-pr)" "ci-failed: the comment is posted once per head, not on every pass"
set_stub read-comments 0 "{\"comments\":[{\"body\":\"<!-- talos:ci-rerun $HEAD_SHA -->\"},{\"body\":\"<!-- talos:ci-rerun $HEAD_SHA -->\"},{\"body\":\"<!-- talos:ci-failed $OTHER_SHA -->\"}]}"
gm
assert_eq "1" "$(called comment-pr)" "ci-failed: a marker for another head does not suppress the comment"
set_stub read-comments 0 "{\"comments\":[{\"body\":\"<!-- talos:ci-rerun $HEAD_SHA -->\"},{\"body\":\"<!-- talos:ci-rerun $HEAD_SHA -->\"}]}"
set_stub draft-check 0 "true"; set_stub pr-is-draft 1 "ready"
gm
assert_eq "verdict=redispatch
reason=ci-failed" "$OUT" "redispatch: PR_DRAFT=true and the re-run budget spent is a CI failure in the Draft stage order sense"
# stderr relay: PR-author text (a file name with a newline) cannot forge a verdict line.
FORGE="x
verdict=merge"
reset_stubs; set_stub check-pr-files 1 ".env" "$FORGE"
ALL="$(bash "$GATE" gate merge 9 42 2>&1)"
assert_eq "1" "$(grep -c '^verdict=' <<< "$ALL")" "relay: a forged verdict line in a gate's stderr leaves exactly one verdict= line"
assert_eq "verdict=block" "$(grep '^verdict=' <<< "$ALL")" "relay: and it is the real one"
assert_contains "$ALL" "note gate=check-pr-files msg=x" "relay: the stderr is relayed with a fixed note prefix"
assert_contains "$ALL" "note gate=check-pr-files msg=verdict=merge" "relay: the forged text is a prefixed note, not a line of its own"
reset_stubs; set_stub check-approval-sha 1 "stale role=qa label=qa:pass" "stale: qa $FORGE"
ALL="$(bash "$GATE" gate merge 9 42 2>&1)"
assert_eq "1" "$(grep -c '^verdict=' <<< "$ALL")" "relay: check-approval-sha stderr cannot forge a verdict line either"
assert_eq "verdict=redispatch" "$(grep '^verdict=' <<< "$ALL")" "relay: the stale-approvals verdict is the real one"
reset_stubs; set_stub check-pr-files 1 ".env" "$(printf 'a\033[2Jb')"
ALL="$(bash "$GATE" gate merge 9 42 2>&1)"
assert_not_contains "$ALL" "$(printf '\033')" "relay: a control byte in a relayed line is escaped"
reset_stubs; set_stub pr-checks-required 1 "" "$RED"; set_stub rerun-ci 2 "" "not supported"
gm
assert_eq "verdict=wait
reason=rerun-unsupported" "$OUT" "wait: rerun-ci exit 2 (unsupported) waits for a human"
assert_eq "0" "$(called comment-pr)" "rerun: no marker is posted when no re-run started"
reset_stubs; set_stub pr-checks-required 1 "" "pipeline-vcs: pr-checks-required not implemented for gitlab"
gm
assert_eq "stop reason=ci-unverified" "$OUT" "stop: exit 1 with no failed: line (unsupported provider, no checks) is ci-unverified"
assert_eq "0" "$(called rerun-ci)" "stop: nothing is re-run for an unverified CI"
reset_stubs; set_stub pr-checks-required 1 "" "$RED"; set_stub pr-head 0 "abc123"
gm
assert_eq "stop reason=head-unresolved" "$OUT" "stop: a head SHA that is not 40 hex never builds a marker"
reset_stubs; set_stub pr-checks-required 1 "" "$RED"; set_stub read-comments 1
gm
assert_eq "stop reason=comments-unreadable" "$OUT" "stop: unreadable comments stop rather than re-run blind"
assert_eq "0" "$(called rerun-ci)" "stop: no re-run without the marker count"

# The stale-base guard.
reset_stubs; set_stub conflict-files 0 "CHANGELOG.md"
gm
assert_eq "verdict=wait
reason=base-synced" "$OUT" "wait: a union-path conflict resolved by pipeline-mergebase.sh; the pushed head is not CI-verified yet"
assert_contains "$(journal)" "mergebase 9" "base: the mechanical union merge runs first"
assert_eq "0" "$(called update-branch)" "base: no update-branch after a successful union merge"
assert_contains "$(vcs_verbs)" "pr-mergeable" "base: the mergeability is re-checked after the sync"
assert_gate "wait (base-synced)"
set_stub mergebase 3
gm
assert_eq "verdict=wait
reason=base-synced" "$OUT" "wait: a path outside merge.union_paths goes to update-branch (merge.auto_sync defaults to true)"
assert_contains "$(journal)" "vcs update-branch 9" "base: update-branch is called"
set_stub update-branch 1
gm
assert_eq "verdict=redispatch
reason=merge-conflict" "$OUT" "redispatch: update-branch fails (409): the developer merge-base task"
set_stub update-branch 2
gm
assert_eq "verdict=redispatch
reason=merge-conflict" "$OUT" "redispatch: update-branch unsupported: the developer merge-base task"
assert_gate "redispatch (merge-conflict)"
set_stub update-branch 0; set_stub pr-mergeable 1 "CONFLICTING"
gm
assert_eq "verdict=redispatch
reason=merge-conflict" "$OUT" "redispatch: the PR still conflicts after the sync: the developer merge-base task"
set_stub pr-mergeable 2 "UNKNOWN"
gm
assert_eq "verdict=wait
reason=base-synced" "$OUT" "wait: UNKNOWN mergeability after the sync fails open, as every best-effort gate does"
set_stub pr-mergeable 0 "MERGEABLE"; set_stub update-branch 0
cfg_json '{"merge": {"auto_sync": false}}'
rm -f "$STUB_DIR/journal"
gm
assert_eq "verdict=redispatch
reason=merge-conflict" "$OUT" "redispatch: merge.auto_sync=false goes straight to the developer task"
assert_eq "0" "$(called update-branch)" "base: merge.auto_sync=false never calls update-branch"
reset_stubs; set_stub conflict-files 2 "" "cannot determine"
gm
assert_eq "verdict=wait
reason=conflict-check-unverified" "$OUT" "wait: a conflict check that cannot be determined (exit 2) fails closed, never a merge"
assert_gate "wait (conflict-check-unverified, exit 2)"
set_stub conflict-files 1 "" "git fetch origin main failed"
gm
assert_eq "verdict=wait
reason=conflict-check-unverified" "$OUT" "wait: a conflict check that fails (exit 1, e.g. an unsupported provider) fails closed, never a merge"
assert_eq "0" "$(called merge-pr)" "wait: an unverified conflict check does not merge"
assert_gate "wait (conflict-check-unverified, exit 1)"
reset_stubs; set_stub conflict-files 0 ""
gm
assert_eq "0" "$(called mergebase)" "base: a clean merge with the base needs no sync"

# Order: an earlier gate wins.
reset_stubs
set_stub check-approval-sha 1 "stale role=qa label=qa:pass" "x"
set_stub check-pr-files 1 ".env" "x"
gm
assert_contains "$OUT" "reason=stale-approvals" "order: a stale approval is reported before forbidden files"
assert_eq "0" "$(called check-pr-files)" "order: check-pr-files does not run behind a stale approval"
reset_stubs
set_stub check-pr-files 1 ".env" "x"
set_stub check-closing-keyword 1 "" "x"
set_stub pr-checks-required 1 "" "$RED"
gm
assert_contains "$OUT" "reason=forbidden-files" "order: forbidden files are reported before the closing keyword"
assert_eq "0" "$(called check-closing-keyword)" "order: check-closing-keyword does not run behind forbidden files"

# Scope: the gates this slice did not add.
reset_stubs
gm
assert_eq "0" "$(journal | grep -c 'assert-sync')" "scope: gate merge does not call assert-sync (Step 0 and before 3e)"
assert_eq "0" "$(called pr-mergeable)" "scope: pr-mergeable is not a leading gate of gate merge (Step 3c); it only re-checks after a base update"

# Hostile text never reaches the output unsanitised.
reset_stubs; printf '%s' "$(printf 'talos:budget warn issue=42 \033[2Jx\nFORGED=1')" > "$STUB_DIR/budget.out"
OUT="$(bash "$GATE" gate fix-round 42 qa --pr 9 2>"$ERR")"; RC=$?
assert_contains "$OUT" 'budget=talos:budget warn issue=42 \x1b[2Jx\x0aFORGED=1' "sanitising: a control byte and a newline in the budget line print as \\xNN"
assert_eq "0" "$(printf '%s\n' "$OUT" | grep -c '^FORGED')" "sanitising: a newline in a value cannot forge a line"
printf '%s\n' "$OUT" > "$SANDBOX/out.gate"
check_gate_output "$SANDBOX/out.gate"; assert_eq "0" "$?" "sanitising: the sanitised output satisfies the line contract"

# ── (c) the checker is not vacuous ───────────────────────────────────────────
printf 'verdict=merge\n' > "$SANDBOX/ok.gate"
check_gate_output "$SANDBOX/ok.gate"; assert_eq "0" "$?" "checker: a bare verdict=merge passes"
printf 'verdict=maybe\n' > "$SANDBOX/mut.gate"
check_gate_output "$SANDBOX/mut.gate"; assert_eq "1" "$?" "mutation: a verdict outside merge|handoff|redispatch|wait|block turns the checker red"
printf 'verdict=wait\nreason=because\n' > "$SANDBOX/mut.gate"
check_gate_output "$SANDBOX/mut.gate"; assert_eq "1" "$?" "mutation: an out-of-enum reason= turns the checker red"
printf 'reason=ci-pending\nverdict=wait\n' > "$SANDBOX/mut.gate"
check_gate_output "$SANDBOX/mut.gate"; assert_eq "1" "$?" "mutation: verdict not on the first line turns the checker red"
printf 'verdict=wait\nreason=ci-pending\nEVIL=a\033[2Jb\n' > "$SANDBOX/mut.gate"
check_gate_output "$SANDBOX/mut.gate"; assert_eq "1" "$?" "mutation: an unsanitised ESC byte turns the checker red"
printf 'verdict=wait\nfree text\n' > "$SANDBOX/mut.gate"
check_gate_output "$SANDBOX/mut.gate"; assert_eq "1" "$?" "mutation: a line that is neither KEY=value nor stop|warn turns the checker red"
printf 'stop reason=made-up\n' > "$SANDBOX/mut.gate"
check_gate_output "$SANDBOX/mut.gate"; assert_eq "1" "$?" "mutation: an out-of-enum stop reason turns the checker red"

# ── (b) gate fix-round ───────────────────────────────────────────────────────
fr() { OUT="$(bash "$GATE" gate fix-round "$@" 2>"$ERR")"; RC=$?; }

reset_stubs; set_stub record-attempt 0 "stage=qa count=1 total=2"
fr 42 qa --pr 9
assert_eq "verdict=redispatch
count=1
total=2
stage=qa" "$OUT" "fix-round: budget ok, attempt recorded, unblocked: redispatch with the counts"
assert_eq "record-attempt label-pr label-issue" "$(vcs_verbs)" "fix-round: record-attempt, then the PR unblock, then the issue unblock"
assert_eq "budget
vcs record-attempt 42 qa --pr 9
vcs label-pr 9 --remove pipeline:blocked
vcs label-issue 42 --remove pipeline:blocked" "$(journal | sed -n 's/^\(budget\) .*/\1/p;/^vcs /p')" "fix-round: the budget check runs before record-attempt, the unblock after it"
assert_contains "$(journal)" "budget check --issue 42" "fix-round: the guard is pipeline-budget.sh check --issue <N>"
assert_gate "fix-round (redispatch)"
reset_stubs; set_stub record-attempt 0 "stage=developer count=1 total=1"
fr 42 developer
assert_eq "record-attempt label-issue" "$(vcs_verbs)" "fix-round: no --pr: no PR unblock"
assert_contains "$(journal)" "vcs record-attempt 42 developer" "fix-round: no --pr: record-attempt gets no key"
assert_not_contains "$(journal)" "--pr" "fix-round: no --pr: nothing mentions a PR"
reset_stubs; set_stub budget 0 "talos:budget warn issue=42 used=80 limit=100 effective=100 pct=80 unrecorded=0"; set_stub record-attempt 0 "stage=qa count=1 total=1"
fr 42 qa --pr 9
assert_contains "$OUT" "budget=talos:budget warn issue=42 used=80" "fix-round: a budget warn line is relayed"
assert_contains "$OUT" "verdict=redispatch" "fix-round: a budget warn still proceeds"
reset_stubs; set_stub budget 0 "talos:budget ok issue=42 used=1 limit=100 effective=100 pct=1 unrecorded=0"; set_stub record-attempt 0 "stage=qa count=1 total=1"
fr 42 qa --pr 9
assert_not_contains "$OUT" "budget=" "fix-round: a budget ok line is not relayed"
reset_stubs; set_stub budget 3 "" "pipeline-budget: boom"; set_stub record-attempt 0 "stage=qa count=1 total=1"
fr 42 qa --pr 9
assert_contains "$OUT" "warn reason=budget-check-failed" "fix-round: any other budget exit proceeds with a warn line"
assert_contains "$OUT" "verdict=redispatch" "fix-round: a failed budget check proceeds"
assert_gate "fix-round (budget-check-failed)"

reset_stubs; set_stub budget 1 "talos:budget exceeded issue=42 used=120 limit=100 effective=100 pct=120 unrecorded=0"
fr 42 qa --pr 9
assert_eq "verdict=block
budget=talos:budget exceeded issue=42 used=120 limit=100 effective=100 pct=120 unrecorded=0
reason=budget-exceeded
blocked_by=talos.pipeline.yml:limits.tokens_per_issue (explicit)" "$OUT" "block: a budget stop prints the line, the reason and BLOCKED_BY"
assert_eq "0" "$(called record-attempt)" "block: a budget stop records no attempt"
assert_contains "$(journal)" "vcs label-pr 9 --add pipeline:blocked" "block: a budget stop sets pipeline:blocked on the PR"
assert_contains "$(journal)" "vcs label-issue 42 --add pipeline:blocked" "block: a budget stop sets pipeline:blocked on the issue"
assert_contains "$(journal)" "hooks post_stage budget-blocked orchestrator 42 --pr 9 --summary -" "block: the budget-blocked post_stage fires once, with the summary on stdin"
assert_contains "$(cat "$STUB_DIR/hooks.stdin")" "talos:budget exceeded issue=42" "block: the hook's stdin is the budget line"
assert_eq "0" "$(called label-pr | grep -c remove)" "block: a budget stop never unblocks"
assert_gate "block (budget)"
reset_stubs; set_stub budget 1 "talos:budget exceeded issue=42 used=120 limit=100 effective=100 pct=120 unrecorded=0"
fr 42 developer
assert_eq "0" "$(called label-pr)" "block: a budget stop with no PR touches no PR"
assert_contains "$(journal)" "hooks post_stage budget-blocked orchestrator 42 --summary -" "block: no --pr in the hook call when no PR exists"

reset_stubs; set_stub record-attempt 1 "stage=qa count=3 total=3" "pipeline-vcs: record-attempt: BLOCKED — qa consecutive attempts (3) >= max_fix_attempts (3)"
fr 42 qa --pr 9
assert_eq "verdict=block
count=3
total=3
reason=max-fix-attempts
blocked_by=talos.pipeline.yml:limits.max_fix_attempts (explicit)" "$OUT" "block: the per-stage ceiling"
assert_contains "$(journal)" "vcs label-pr 9 --add pipeline:blocked" "block: a ceiling sets pipeline:blocked on the PR"
assert_contains "$(journal)" "vcs label-issue 42 --add pipeline:blocked" "block: a ceiling sets pipeline:blocked on the issue"
assert_eq "0" "$(journal | grep -c 'remove pipeline:blocked')" "block: a ceiling never unblocks"
assert_contains "$(cat "$ERR")" "BLOCKED — qa consecutive attempts" "block: record-attempt's stderr passes through"
assert_gate "block (max-fix-attempts)"
set_stub record-attempt 1 "stage=qa count=1 total=8" "pipeline-vcs: record-attempt: BLOCKED — total dispatches (8) >= max_total_dispatches (8)"
fr 42 qa --pr 9
assert_contains "$OUT" "reason=max-total-dispatches" "block: the total-dispatches ceiling"
assert_contains "$OUT" "blocked_by=talos.pipeline.yml:limits.max_total_dispatches (explicit)" "block: BLOCKED_BY names the ceiling record-attempt reported"
set_stub record-attempt 1 "" "pipeline-vcs: record-attempt: could not resolve head SHA for PR #9"
fr 42 qa --pr 9
assert_contains "$OUT" "reason=record-failed" "block: a record-attempt that fails without a ceiling fails closed"
assert_contains "$OUT" "blocked_by=scripts/pipeline-vcs.sh:record-attempt exited non-zero (interpreted)" "block: that BLOCKED_BY says it is interpreted"
assert_gate "block (record-failed)"
reset_stubs; set_stub record-attempt 0 "stage=qa count=1 total=1"; set_stub label-pr 1 "" "boom"
fr 42 qa --pr 9
assert_contains "$OUT" "warn reason=unblock-failed" "fix-round: a failing unblock is a warn line"
assert_contains "$OUT" "verdict=redispatch" "fix-round: a failing unblock does not stop the round"
assert_gate "fix-round (unblock-failed)"

# The same sequence as the old prose, under the real scripts and the gh stub:
# the two leave the same gh journal.
reset_stubs
cp "$TALOS_ROOT"/scripts/pipeline-*.sh "$GS/"
export STUB_PR_HEAD_SHA="$HEAD_SHA"
run_old() {
  : > "$GH_LOG"
  bash "$GS/pipeline-budget.sh" check --issue 42 > /dev/null
  bash "$GS/pipeline-vcs.sh" record-attempt 42 qa --pr 9 > /dev/null 2>&1
  bash "$GS/pipeline-vcs.sh" label-pr 9 --remove pipeline:blocked > /dev/null 2>&1
  bash "$GS/pipeline-vcs.sh" label-issue 42 --remove pipeline:blocked > /dev/null 2>&1
  cp "$GH_LOG" "$SANDBOX/gh.old"
}
run_new() {
  : > "$GH_LOG"
  OUT="$(bash "$GS/talos.sh" gate fix-round 42 qa --pr 9 2>/dev/null)"; RC=$?
  cp "$GH_LOG" "$SANDBOX/gh.new"
}
run_old; run_new
assert_eq "verdict=redispatch
count=1
total=1
stage=qa" "$OUT" "equivalence: real scripts, a first QA failure: redispatch with the counts record-attempt printed"
assert_eq "$(cat "$SANDBOX/gh.old")" "$(cat "$SANDBOX/gh.new")" "equivalence: the verb leaves the gh journal the three-step prose left"
assert_gate "fix-round (real scripts)"
assert_contains "$(cat "$SANDBOX/gh.new")" "pr edit 9 --remove-label pipeline:blocked" "equivalence: the PR unblock reached gh"
cfg_json '{"limits": {"max_fix_attempts": 1}}'
run_new
assert_contains "$OUT" "verdict=block" "equivalence: a ceiling of 1 blocks the first attempt under the real record-attempt"
assert_contains "$OUT" "reason=max-fix-attempts" "equivalence: the real BLOCKED line is mapped to max-fix-attempts"
assert_contains "$(cat "$SANDBOX/gh.new")" "pr edit 9 --add-label pipeline:blocked" "equivalence: the block label reached gh"
assert_eq "0" "$(grep -c 'remove-label pipeline:blocked' "$SANDBOX/gh.new")" "equivalence: a ceiling leaves pipeline:blocked in place"
rm -f "$SANDBOX/talos.pipeline.json"
unset STUB_PR_HEAD_SHA

# ── (d) usage and environment ────────────────────────────────────────────────
reset_stubs
for args in "gate" "gate nonsense" "gate merge" "gate merge 9" "gate merge 9 42 7" "gate merge x 42" "gate merge 9 4x" \
            "gate fix-round" "gate fix-round 42" "gate fix-round x qa" "gate fix-round 42 bogus" "gate fix-round 42 qa --pr" \
            "gate fix-round 42 qa --pr x" "gate fix-round 42 qa --nope 9" "gate fix-round 42 qa --pr 9 extra"; do
  # shellcheck disable=SC2086
  OUT="$(bash "$GATE" $args 2>/dev/null)"; RC=$?
  assert_eq "2:stop reason=usage" "$RC:$OUT" "usage: talos.sh $args exits 2 with stop reason=usage"
done
assert_eq "0" "$(journal | wc -l | tr -d ' ')" "usage: a usage error calls nothing"

mkdir "$SANDBOX/lone"
cp "$TALOS" "$SANDBOX/lone/talos.sh"
OUT="$(bash "$SANDBOX/lone/talos.sh" gate merge 9 42 2>/dev/null)"; RC=$?
assert_eq "1:stop reason=scripts-missing" "$RC:$OUT" "stop: gate merge without its sibling scripts"
OUT="$(bash "$SANDBOX/lone/talos.sh" gate fix-round 42 qa 2>/dev/null)"; RC=$?
assert_eq "1:stop reason=scripts-missing" "$RC:$OUT" "stop: gate fix-round without its sibling scripts"
assert_contains "$(bash "$TALOS" help 2>&1)" "gate merge <pr> <issue>" "help: names gate merge"
assert_contains "$(bash "$TALOS" help 2>&1)" "gate fix-round <N> <stage> [--pr M]" "help: names gate fix-round"

finish
