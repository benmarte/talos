#!/usr/bin/env bash
# test-trust-empty-login.sh -- #966: a `current-user` that exits 0 but prints no
# login is "no identity resolved" (like exit 1), so the soft trust callers (the
# dependency sweep) trust nobody instead of turning the author check off.
#   AC1 exit 0, empty output, no markers.trusted_authors: no issue from outside the trust set is unblocked
#   AC2 the same with markers.trusted_authors set: a listed author's issue is still unblocked
#   AC3 exit 0 with a login: that login joins the trust set and its issue is unblocked
#   AC4 exit 1 and exit 3 are unchanged (tests/test-talos-gate.sh and
#       tests/test-sweep-unblock-code-driver.sh hold the full trust cases)
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
# One journaling stub for every script the sweep calls: `vcs <verb>` answers
# from $STUB_DIR/<verb>.out (rc 0 unless <verb>.rc exists).
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
printf "%s %s\n" "$n" "$*" >> "$d/journal"
cat > /dev/null 2>&1 < /dev/null
if [ "$n" = "vcs" ]; then
  [ -f "$d/$1.out" ] && cat "$d/$1.out"
  [ -f "$d/$1.rc" ] && exit "$(cat "$d/$1.rc")"
fi
exit 0
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-mergebase.sh \
         pipeline-status.sh pipeline-worktree.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
PM="$GS/talos.sh"
ERR="$SANDBOX/stderr"

CFG_PLAIN='{"vcs": {"provider": "github"}}'
CFG_TRUSTED='{"vcs": {"provider": "github"}, "markers": {"trusted_authors": ["stranger"]}}'

# fresh <author> <current-user output> <config json>: one open issue 30
# depending on a closed #29, a GitHub provider, `current-user` answering rc 0.
fresh() {
  rm -rf "${STUB_DIR:?}"; mkdir -p "$STUB_DIR"
  printf '%s' "$3" > "$SANDBOX/talos.pipeline.json"
  printf '[{"number":30,"title":"t","labels":[{"name":"bug"}],"author":{"login":"%s"},"body":"Depends on: #29"}]' "$1" > "$STUB_DIR/list-issues.out"
  printf '%s' '[]' > "$STUB_DIR/list-prs.out"
  printf '%s' "$2" > "$STUB_DIR/current-user.out"
}
sw() { OUT="$(bash "$PM" sweep 2>"$ERR")"; RC=$?; }
readied() { grep -c "^vcs label-issue 30 --add pipeline:ready" "$STUB_DIR/journal" 2>/dev/null; }

fresh stranger "" "$CFG_PLAIN"
sw
assert_eq "0" "$(readied)" "AC1 an empty login with exit 0 and no trusted_authors unblocks no outside author's issue"
assert_contains "$OUT" "warn reason=trust-unverified" "AC1 the sweep warns reason=trust-unverified"

fresh stranger "  " "$CFG_PLAIN"
sw
assert_eq "0" "$(readied)" "AC1 a whitespace-only login counts as no login"

fresh stranger "" "$CFG_TRUSTED"
sw
assert_eq "1" "$(readied)" "AC2 an empty login with markers.trusted_authors set still unblocks a listed author's issue"

fresh stranger "stranger" "$CFG_PLAIN"
sw
assert_eq "1" "$(readied)" "AC3 a login with exit 0 joins the trust set and its issue is unblocked"

fresh stranger "bot" "$CFG_PLAIN"
sw
assert_eq "0" "$(readied)" "AC3 a login with exit 0 does not trust other authors"

for RC_CASE in 1 3; do
  fresh stranger "" "$CFG_PLAIN"
  printf '%s' "$RC_CASE" > "$STUB_DIR/current-user.rc"
  sw
  assert_eq "0" "$(readied)" "AC4 current-user exit $RC_CASE (no identity) still trusts nobody in the sweep"
done

finish
