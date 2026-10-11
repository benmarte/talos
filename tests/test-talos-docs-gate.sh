#!/usr/bin/env bash
# test-talos-docs-gate.sh -- `scripts/talos.sh docs-gate <pr> --issue <N>` (#546, epic #558).
#
# The docs stage costs an LLM dispatch only when the PR changes something docs
# own: README.md, docs/** or scripts/pipeline-defaults.sh (a config key). Everything else is
# stamped docs:done by code. This file pins, against a journaling stub of
# pipeline-vcs.sh:
#   (a) the decision: scripts+tests+changelog -> skip; README, docs/**, a
#       config-key row -> dispatch; a mix -> dispatch with only the
#       relevant paths in the paths file
#   (b) forced dispatch: docs_mode always (no paths file: the full diff), and
#       a failed pr-files fetch (fail closed: never "nothing to check")
#   (c) roles.docs false -> skip with no stamp (the stage is off, not done)
#   (d) the skip stamp: post-approval docs with the "no docs-relevant changes"
#       body, then `done docs` (the bookkeeping the dispatch path ends with)
#   (e) the dispatch writes no stamp and no `done`
#   (f) usage errors
#   (g) the delta re-stamp (#590): `docs:done` on the PR and stale with a marker
#       SHA -> a re-stamp dispatch with the delta since that SHA in a file, or a
#       stamp by code when that delta has no docs-relevant path; anything that
#       cannot be read is the full stage
set -u
. "$(dirname "$0")/helpers.sh"
make_sandbox || exit 1
use_stubs

export CLAUDE_CONFIG_DIR="$SANDBOX/cc"
export TALOS_RETRY_SLEEP_SCALE=0
ERR="$SANDBOX/stderr"

GS="$SANDBOX/gs"
STUB_DIR="$SANDBOX/stub"
export STUB_DIR
mkdir -p "$GS" "$STUB_DIR"
cp "$TALOS_ROOT"/scripts/* "$GS/"
mkdir -p "$SANDBOX/templates"
cp -R "$TALOS_ROOT/templates/comments" "$SANDBOX/templates/" 2>/dev/null
# One journaling stub for every script the verb may call except the real
# talos.sh (the skip path runs the real `done`) and the config reader.
STUB_BODY='#!/usr/bin/env bash
d="${STUB_DIR:?}"
n="$(basename "$0" .sh)"; n="${n#pipeline-}"
if [ "$n" = "vcs" ]; then key="$1"; else key="$n"; fi
printf "%s %s\n" "$n" "$*" >> "$d/journal"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then { printf "[%s]\n" "$*"; cat "$a"; } >> "$d/bodies"; fi
  prev="$a"
done
if [ -f "$d/$key.err" ]; then cat "$d/$key.err" >&2; fi
if [ -f "$d/$key.out" ]; then cat "$d/$key.out"; fi
rc=0
if [ -f "$d/$key.rc" ]; then rc="$(cat "$d/$key.rc")"; fi
exit "$rc"
'
for s in pipeline-vcs.sh pipeline-notify.sh pipeline-hooks.sh pipeline-status.sh pipeline-events.sh; do
  printf '%s' "$STUB_BODY" > "$GS/$s"
done
DG="$GS/talos.sh"

cfg_json() { printf '%s' "$1" > "$SANDBOX/talos.pipeline.json"; }
export PIPELINE_CONFIG="$SANDBOX/talos.pipeline.json"
reset() {  # $1 = the changed paths, one per line
  rm -rf "${STUB_DIR:?}" "${SANDBOX:?}/.git/talos-lease.ledger"; mkdir -p "$STUB_DIR"
  cfg_json '{"vcs": {"provider": "github"}, "comments": {"enabled": false}}'
  printf '%s\n' "$1" > "$STUB_DIR/pr-files.out"
}
journal() { cat "$STUB_DIR/journal" 2>/dev/null; }
# dg <args...>: run the verb; OUT, RC. PF is the paths file it names (if any).
dg() {
  OUT="$(bash "$DG" docs-gate "$@" 2>"$ERR")"; RC=$?
  PF="$(printf '%s\n' "$OUT" | sed -n 's/^docs=.* paths-file=\([^ ]*\).*/\1/p' | head -n 1)"
}
cleanup_pf() { [ -z "$PF" ] || rm -f "$PF"; }

# ── (a) the decision ─────────────────────────────────────────────────────────
reset $'scripts/talos.sh\ntests/test-x.sh\nCHANGELOG.md'
dg 7 --issue 3
assert_eq "0" "$RC" "scripts+tests+changelog: exit 0"
assert_contains "$OUT" "docs=skip reason=no-docs-paths" "scripts+tests+changelog: skip, reason named"
assert_eq "" "$PF" "scripts+tests+changelog: no paths file"

reset $'README.md\nscripts/talos.sh'
dg 7 --issue 3
assert_contains "$OUT" "docs=dispatch reason=docs-paths paths-file=" "README PR: dispatch"
assert_eq "README.md" "$(cat "$PF")" "README PR: the paths file holds only the docs-relevant subset"
cleanup_pf

reset $'docs/reference.md\ntests/t.sh'
dg 7 --issue 3
assert_contains "$OUT" "docs=dispatch" "docs/** PR: dispatch"
assert_eq "docs/reference.md" "$(cat "$PF")" "docs/** PR: the paths file holds the doc path"
cleanup_pf

reset $'scripts/pipeline-defaults.sh\ntests/t.sh'
dg 7 --issue 3
assert_contains "$OUT" "docs=dispatch" "config-key PR (pipeline-defaults.sh): dispatch"
assert_eq "scripts/pipeline-defaults.sh" "$(cat "$PF")" "config-key PR: the defaults file is in the paths file"
cleanup_pf

reset $'docs-extra/x.md\nREADME.md.bak\nsub/README.md\ndocs/guide.md'
dg 7 --issue 3
assert_contains "$OUT" "docs=dispatch" "docs/guide.md among lookalikes: dispatch"
assert_eq "docs/guide.md" "$(cat "$PF")" "lookalike paths (docs-extra/, README.md.bak, sub/README.md) are not docs-relevant"
cleanup_pf

# ── (b) forced dispatch ──────────────────────────────────────────────────────
reset $'scripts/talos.sh\nCHANGELOG.md'
cfg_json '{"vcs": {"provider": "github"}, "comments": {"enabled": false}, "roles": {"docs_mode": "always"}}'
dg 7 --issue 3
assert_contains "$OUT" "docs=dispatch reason=always" "docs_mode always: dispatch even for a scripts-only PR"
assert_not_contains "$OUT" "paths-file" "docs_mode always: no paths file (the full diff)"
assert_not_contains "$(journal)" "pr-files" "docs_mode always: pr-files is never fetched"

reset $'scripts/talos.sh'
printf '1\n' > "$STUB_DIR/pr-files.rc"
printf 'boom\n' > "$STUB_DIR/pr-files.err"
dg 7 --issue 3
assert_eq "0" "$RC" "a pr-files failure: the verb still answers"
assert_contains "$OUT" "docs=dispatch reason=fetch-failed" "a pr-files failure fails closed: dispatch"
assert_not_contains "$OUT" "paths-file" "a pr-files failure: no paths file (the full diff)"
assert_not_contains "$(journal)" "post-approval" "a pr-files failure stamps nothing"

# ── (c) roles.docs false ─────────────────────────────────────────────────────
reset $'README.md'
cfg_json '{"vcs": {"provider": "github"}, "comments": {"enabled": false}, "roles": {"docs": false, "docs_mode": "always"}}'
dg 7 --issue 3
assert_contains "$OUT" "docs=skip reason=role-off" "roles.docs false: skip, even with docs_mode always"
assert_not_contains "$(journal)" "post-approval" "roles.docs false: no stamp (the stage is off, not done)"
assert_not_contains "$(journal)" "pr-files" "roles.docs false: nothing fetched"

# ── (d) the skip stamp ───────────────────────────────────────────────────────
reset $'scripts/talos.sh\nCHANGELOG.md'
dg 7 --issue 3
assert_contains "$(journal)" "vcs post-approval 7 docs --body-file" "skip: the stamp is post-approval docs"
assert_contains "$(cat "$STUB_DIR/bodies")" "no docs-relevant changes" "skip: the stamp body says why"
assert_contains "$(journal)" "hooks " "skip: done docs ran its bookkeeping (post_stage hook)"
post_line="$(journal | grep -n 'vcs post-approval' | head -n 1 | cut -d: -f1)"
hook_line="$(journal | grep -n '^hooks ' | head -n 1 | cut -d: -f1)"
if [ -n "$post_line" ] && [ -n "$hook_line" ] && [ "$post_line" -lt "$hook_line" ]; then
  pass "skip: the stamp lands before done"
else
  fail "skip: the stamp lands before done" "post-approval at line '$post_line', hook at '$hook_line'"
fi

reset $'scripts/talos.sh'
printf '1\n' > "$STUB_DIR/post-approval.rc"
dg 7 --issue 3
assert_contains "$OUT" "stop reason=stamp-failed" "skip: a failed stamp is a stop, never a claimed skip"
assert_not_contains "$OUT" "docs=skip" "skip: a failed stamp does not print docs=skip"
assert_eq "1" "$RC" "skip: a failed stamp exits 1"

# ── (e) dispatch writes nothing ──────────────────────────────────────────────
reset $'README.md'
dg 7 --issue 3
assert_not_contains "$(journal)" "post-approval" "dispatch: no stamp"
assert_not_contains "$(journal)" "hooks " "dispatch: no done"
cleanup_pf

# ── (f) usage ────────────────────────────────────────────────────────────────
reset $'README.md'
dg
assert_eq "2" "$RC" "no PR: usage exit 2"
dg x --issue 3
assert_eq "2" "$RC" "non-numeric PR: usage exit 2"
dg 7
assert_eq "2" "$RC" "no --issue: usage exit 2"
dg 7 --issue y
assert_eq "2" "$RC" "non-numeric issue: usage exit 2"
dg 7 --issue 3 --bogus 1
assert_eq "2" "$RC" "unknown flag: usage exit 2"

# ── (g) the delta re-stamp (#590) ────────────────────────────────────────────
# After a fix round `docs:done` is on the PR and stale. The verb then looks only
# at what changed since the SHA docs approved: a docs-relevant path in that
# delta is a re-stamp dispatch with the delta in a file, none is a stamp by
# code. The history is the sandbox's own repo: S is the approved SHA, H_DOCS a
# fix round that touched docs/guide.md and a script, H_CODE one that touched
# only the script.
git config user.name "talos-test"
git config user.email "test@talos.invalid"
mkdir -p docs scripts
printf 'base\n' > README.md
printf 'a\n' > scripts/a.sh
git add README.md scripts/a.sh
git commit -q -m "base"
printf 'readme before the approval\n' > README.md
printf 'old page\n' > docs/old.md
git add README.md docs/old.md
git commit -q -m "docs before the approval"
S="$(git rev-parse HEAD)"
printf 'the new guide line\n' > docs/guide.md
printf 'b\n' > scripts/a.sh
git add docs/guide.md scripts/a.sh
git commit -q -m "fix round: a doc and a script"
H_DOCS="$(git rev-parse HEAD)"
git checkout -q --detach "$S"
printf 'c\n' > scripts/a.sh
git add scripts/a.sh
git commit -q -m "fix round: a script only"
H_CODE="$(git rev-parse HEAD)"
PR_PATHS=$'README.md\ndocs/old.md\ndocs/guide.md\nscripts/a.sh'

# delta <pr-files> <stale line> <head>: docs:done on the PR, the stale-list
# answer and the PR head.
delta() {
  reset "$1"
  printf '{"labels": [{"name": "qa:pass"}, {"name": "docs:done"}]}' > "$STUB_DIR/view-pr.out"
  printf '%s\n' "$2" > "$STUB_DIR/check-approval-sha.out"
  printf '1\n' > "$STUB_DIR/check-approval-sha.rc"
  printf '%s\n' "$3" > "$STUB_DIR/pr-head.out"
}
rf_of() { printf '%s\n' "$OUT" | sed -n 's/^docs=.* restamp-file=\([^ ]*\).*/\1/p' | head -n 1; }
# full_dispatch <label>: today's answer for a PR with docs-relevant paths.
full_dispatch() {
  dg 7 --issue 3
  assert_contains "$OUT" "docs=dispatch reason=docs-paths paths-file=" "AC8 $1: the full docs stage (docs-paths)"
  assert_not_contains "$OUT" "restamp" "AC8 $1: no re-stamp"
  assert_not_contains "$(journal)" "post-approval" "AC8 $1: never a stamp"
  cleanup_pf
}

# AC2: a docs-relevant path in the delta.
delta "$PR_PATHS" "stale role=qa label=qa:pass sha=$S
stale role=docs label=docs:done sha=$S" "$H_DOCS"
dg 7 --issue 3
RF="$(rf_of)"
assert_eq "0" "$RC" "AC2 a docs delta: exit 0"
assert_eq "docs=dispatch reason=docs-delta shape=restamp restamp-file=$RF" "$OUT" "AC2 a docs delta: the re-stamp dispatch line"
if [ -n "$RF" ] && [ -f "$RF" ]; then pass "AC2 a docs delta: the re-stamp file exists"
else fail "AC2 a docs delta: the re-stamp file exists" "restamp-file='$RF'"; fi
RF_TEXT="$(cat "${RF:-/dev/null}")"
assert_eq "approved_sha=$S" "$(sed -n 1p <<<"$RF_TEXT")" "AC2 the re-stamp file: line 1 is approved_sha=<S>"
assert_eq "head_sha=$H_DOCS" "$(sed -n 2p <<<"$RF_TEXT")" "AC2 the re-stamp file: line 2 is head_sha=<head>"
assert_eq "docs/guide.md" "$(sed -n 3p <<<"$RF_TEXT")" "AC2 the re-stamp file: the delta's docs-relevant paths, one per line"
TOKEN="$(sed -n 4p <<<"$RF_TEXT" | sed -n 's/^----- BEGIN DIFF \([A-Za-z0-9]\{24\}\) -----$/\1/p')"
if [ -n "$TOKEN" ]; then pass "AC2 the re-stamp file: the diff opens a token-delimited DIFF section"
else fail "AC2 the re-stamp file: the diff opens a token-delimited DIFF section" "line 4: $(sed -n 4p <<<"$RF_TEXT")"; fi
assert_eq "----- END DIFF $TOKEN -----" "$(tail -n 1 <<<"$RF_TEXT")" "AC2 the re-stamp file: the DIFF section ends on the same token"
assert_contains "$RF_TEXT" "diff --git a/docs/guide.md b/docs/guide.md" "AC2 the re-stamp file: the delta's diff of the docs path"
assert_contains "$RF_TEXT" "+the new guide line" "AC2 the re-stamp file: the diff carries the changed line"
assert_not_contains "$RF_TEXT" "docs/old.md" "AC2 a docs path changed before <S> and not since is not in the file"
assert_not_contains "$RF_TEXT" "README.md" "AC2 a second docs path changed only before <S> is not in the file"
assert_not_contains "$RF_TEXT" "scripts/a.sh" "AC2 a path docs do not own is not in the file"
assert_not_contains "$(journal)" "post-approval" "AC2 a docs delta: no stamp"
assert_not_contains "$(journal)" "hooks " "AC2 a docs delta: no done"
[ -z "$RF" ] || rm -f "$RF"
cleanup_pf

# AC3: the delta holds no docs-relevant path.
delta "$PR_PATHS" "stale role=docs label=docs:done sha=$S" "$H_CODE"
dg 7 --issue 3
assert_eq "0" "$RC" "AC3 no docs delta: exit 0"
assert_eq "docs=skip reason=no-docs-delta" "$OUT" "AC3 no docs delta: skip, reason named"
assert_contains "$(journal)" "vcs post-approval 7 docs --body-file" "AC3 no docs delta: the stamp is post-approval docs"
assert_contains "$(cat "$STUB_DIR/bodies" 2>/dev/null)" "no docs-relevant changes since $S" "AC3 no docs delta: the stamp body names the approved SHA"
assert_contains "$(cat "$STUB_DIR/bodies" 2>/dev/null)" "no subagent dispatched" "AC3 no docs delta: the stamp body says no subagent ran"
assert_contains "$(journal)" "hooks post_stage docs docs 3 --pr 7" "AC3 no docs delta: done docs ran its bookkeeping"
post_line="$(journal | grep -n 'vcs post-approval' | head -n 1 | cut -d: -f1)"
hook_line="$(journal | grep -n '^hooks ' | head -n 1 | cut -d: -f1)"
if [ -n "$post_line" ] && [ -n "$hook_line" ] && [ "$post_line" -lt "$hook_line" ]; then
  pass "AC3 no docs delta: the stamp lands before done"
else
  fail "AC3 no docs delta: the stamp lands before done" "post-approval at line '$post_line', hook at '$hook_line'"
fi
cleanup_pf

# AC8: every other answer is the one the verb gave before the re-stamp.
delta "$PR_PATHS" "stale role=docs label=docs:done sha=$S" "$H_DOCS"
printf '{"labels": [{"name": "qa:pass"}]}' > "$STUB_DIR/view-pr.out"
full_dispatch "docs:done absent (a first pass)"
assert_not_contains "$(journal)" "check-approval-sha" "AC8 docs:done absent: the stale list is not read"

delta "$PR_PATHS" "stale role=qa label=qa:pass sha=$S" "$H_DOCS"
full_dispatch "docs not on the stale list"

delta "$PR_PATHS" "stale role=docs label=docs:done" "$H_DOCS"
full_dispatch "a docs stale line with no sha="

delta "$PR_PATHS" "stale role=docs label=docs:done sha=$S" "$H_DOCS"
printf '1\n' > "$STUB_DIR/view-pr.rc"
full_dispatch "a failed label read"

delta "$PR_PATHS" "" "$H_DOCS"
full_dispatch "a failed stale-list read"

delta "$PR_PATHS" "stale role=docs label=docs:done sha=$S" "$H_DOCS"
printf '1\n' > "$STUB_DIR/pr-head.rc"
: > "$STUB_DIR/pr-head.out"
full_dispatch "a failed head read"

delta "$PR_PATHS" "stale role=docs label=docs:done sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$H_DOCS"
full_dispatch "a failed git diff (the approved SHA is not in the repo)"

delta "$PR_PATHS" "stale role=docs label=docs:done sha=$S" "$H_DOCS"
export TALOS_PROMPT_CHANGE_MAX_BYTES=20
full_dispatch "delta sections over TALOS_PROMPT_CHANGE_MAX_BYTES"
unset TALOS_PROMPT_CHANGE_MAX_BYTES

delta $'scripts/a.sh\nCHANGELOG.md' "stale role=docs label=docs:done sha=$S" "$H_DOCS"
dg 7 --issue 3
assert_contains "$OUT" "docs=skip reason=no-docs-paths" "AC8 no docs-relevant path: today's skip"
assert_eq "vcs pr-files 7" "$(journal | grep -E '^vcs (pr-files|view-pr|check-approval-sha|pr-head)')" "AC8 no docs-relevant path: no extra read"

delta "$PR_PATHS" "stale role=docs label=docs:done sha=$S" "$H_DOCS"
cfg_json '{"vcs": {"provider": "github"}, "comments": {"enabled": false}, "roles": {"docs_mode": "always"}}'
dg 7 --issue 3
assert_eq "docs=dispatch reason=always" "$OUT" "AC8 docs_mode always: the full stage, no re-stamp"

delta "$PR_PATHS" "stale role=docs label=docs:done sha=$S" "$H_DOCS"
cfg_json '{"vcs": {"provider": "github"}, "comments": {"enabled": false}, "roles": {"docs": false}}'
dg 7 --issue 3
assert_eq "docs=skip reason=role-off" "$OUT" "AC8 roles.docs false: skip, no re-stamp"

delta "$PR_PATHS" "stale role=docs label=docs:done sha=$S" "$H_DOCS"
printf '1\n' > "$STUB_DIR/pr-files.rc"
dg 7 --issue 3
assert_eq "docs=dispatch reason=fetch-failed" "$OUT" "AC8 a failed pr-files read: the full stage, no re-stamp"

finish
