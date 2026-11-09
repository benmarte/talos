#!/usr/bin/env bash
# test-require-roles-848.sh -- `check-approval-sha <n> --require-roles` (#848): the
# opt-in flag that makes a PR with an absent approval label fail, so a merge
# script can use the verb as its last gate. Without the flag the verb is unchanged
# (pinned by test-approval-sha.sh, test-post-approval.sh, test-vcs-shared-markers.sh).
#   AC1 no labels: exit 1, one `missing role=` line per enabled role
#   AC2 one fresh label: exit 1, names exactly the absent roles
#   AC3 roles.required_when: a skipped role is not required, a matched one is
#   AC4 a disabled role is never required
#   AC5 every required role fresh: exit 0, all current
#   AC6 a stale label still exits 1 with its `stale role=` line
#   AC7 without the flag the verb is unchanged
#   AC8 --require-roles with --evidence-list: usage error, no pass line
# Every test runs on stubs under make_sandbox: no GitHub write, no LLM call.
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs
export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
VCS="$TALOS_ROOT/scripts/pipeline-vcs.sh"

git config user.email "test@talos.invalid"
git config user.name "talos-test"
printf 'one\n' > src_core.js; git add src_core.js; git commit -q -m one
OLD="$(git rev-parse HEAD)"
printf 'two\n' > src_core.js; git add src_core.js; git commit -q -m two
SHA="$(git rev-parse HEAD)"

LABEL_qa="qa:pass"; LABEL_reviewer="review:approved"; LABEL_security="security:approved"
LABEL_docs="docs:done"; LABEL_adversarial="adversarial:approved"

# rq <config members|""> <roles with a fresh label, space-separated|""> [flags...]:
# run check-approval-sha 9 on the gh leg. OUT is stdout, ERR stderr, RC the exit.
# MARKER_SHA (default: the head) is the SHA the fresh labels' markers carry.
rq() {
  local members="$1" fresh="$2" labels="" comments="" r l; shift 2
  for r in $fresh; do
    eval "l=\$LABEL_$r"
    labels="${labels:+$labels,}{\"name\":\"$l\"}"
    comments="${comments:+$comments,}{\"body\":\"<!-- talos:approval sha=${MARKER_SHA:-$SHA} role=$r -->\"}"
  done
  if [ -n "$members" ]; then github_leg gh ",$members"; else github_leg gh; fi
  OUT="$(STUB_PR_HEAD_SHA="$SHA" STUB_PR_LABELS_JSON="[$labels]" STUB_PR_COMMENTS_JSON="[$comments]" \
    bash "$VCS" check-approval-sha 9 "$@" 2>"$SANDBOX/rq.err")"; RC=$?
  ERR="$(cat "$SANDBOX/rq.err")"
}
missing() { printf '%s\n' "$OUT" | sed -n 's/^missing role=\([a-z]*\) label=.*/\1/p' | tr '\n' ' ' | sed 's/ $//'; }

# AC1: no labels at all.
rq "" "" --require-roles --stale-list
assert_exit_code 1 "$RC" "AC1 no approval labels: exit 1"
assert_eq "qa reviewer security docs" "$(missing)" "AC1 one missing line per enabled role, adversarial (off) not named"
assert_contains "$OUT" "missing role=reviewer label=review:approved" "AC1 the line carries the label"
assert_contains "$ERR" "MISSING qa:pass (qa)" "AC1 stderr names each missing label"

# AC2: one fresh label.
rq "" "qa" --require-roles --stale-list
assert_exit_code 1 "$RC" "AC2 one fresh label: exit 1"
assert_eq "reviewer security docs" "$(missing)" "AC2 exactly the absent roles are named"

# AC3: roles.required_when. The verb's own required-roles call reads the head and
# the changed files; the stub answers the files from STUB_PR_FILES.
RT='"roles": {"required_when": {"security": ["internal/auth/**"]}}'
rq3() {  # <changed file>: qa, reviewer and docs fresh, security absent
  STUB_PR_FILES="$1" rq "$RT" "qa reviewer docs" --require-roles --stale-list
}
rq3 docs/guide.md
assert_exit_code 0 "$RC" "AC3 no glob matched: the skipped security role is not required"
assert_eq "" "$(missing)" "AC3 no glob matched: nothing named"
rq3 internal/auth/x.go
assert_exit_code 1 "$RC" "AC3 a glob matched: security is required and absent"
assert_eq "security" "$(missing)" "AC3 a glob matched: security is named"

# AC4: a disabled role is never required; an enabled-by-config one is.
rq '"roles": {"docs": false}' "qa reviewer security" --require-roles
assert_exit_code 0 "$RC" "AC4 roles.docs false: its absent label does not fail the gate"
assert_eq "" "$(missing)" "AC4 roles.docs false: docs is not named"
rq '"roles": {"docs": false}' "qa reviewer" --require-roles
assert_eq "security" "$(missing)" "AC4 only enabled roles are named"
rq '"roles": {"adversarial": true}' "qa reviewer security docs" --require-roles
assert_eq "adversarial" "$(missing)" "AC4 control: roles.adversarial true makes it required"

# AC5: every required role fresh.
rq "" "qa reviewer security docs" --require-roles --stale-list
assert_exit_code 0 "$RC" "AC5 every required role fresh: exit 0"
assert_contains "$OUT" "all approval labels are current" "AC5 prints the pass line"
assert_eq "" "$(missing)" "AC5 no missing line"

# AC6: a stale label still fails, with its stale line.
MARKER_SHA="$OLD" rq "" "qa reviewer security docs" --require-roles --stale-list
assert_exit_code 1 "$RC" "AC6 stale labels: exit 1"
assert_contains "$OUT" "stale role=qa label=qa:pass" "AC6 the stale line is printed"
assert_eq "" "$(missing)" "AC6 a stale label is not reported as missing"

# AC7: without the flag the verb is unchanged: no labels still passes.
rq "" "" --stale-list
assert_exit_code 0 "$RC" "AC7 no flag, no labels: exit 0"
assert_contains "$OUT" "no approval labels present" "AC7 no flag: the verb's own line"

# AC8: --require-roles reads evidence itself, so the two flags cannot combine.
rq "" "qa reviewer security docs" --require-roles --evidence-list
assert_eq "2" "$RC" "AC8 --require-roles with --evidence-list: usage exit"
assert_contains "$ERR" "usage" "AC8 a usage line is printed"
case "$OUT" in
  *"all approval labels are current"*) fail "AC8 no pass line" "$OUT" ;;
  *) pass "AC8 no pass line" ;;
esac

finish
