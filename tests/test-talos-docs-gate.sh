#!/usr/bin/env bash
# test-talos-docs-gate.sh -- `scripts/talos.sh docs-gate <pr> --issue <N>` (#546, epic #558).
#
# The docs stage costs an LLM dispatch only when the PR changes something docs
# own: README.md, docs/** (not CHANGELOG fragments, not the status fragments
# dir) or scripts/pipeline-defaults.sh (a config key). Everything else is
# stamped docs:done by code. This file pins, against a journaling stub of
# pipeline-vcs.sh:
#   (a) the decision: scripts+tests+changelog -> skip; README, docs/**, a
#       config-key row -> dispatch; fragments alone -> skip; a mix -> dispatch
#       with only the relevant paths in the paths file
#   (b) forced dispatch: docs_mode always (no paths file: the full diff), and
#       a failed pr-files fetch (fail closed: never "nothing to check")
#   (c) roles.docs false -> skip with no stamp (the stage is off, not done)
#   (d) the skip stamp: post-approval docs with the "no docs-relevant changes"
#       body, then `done docs` (the bookkeeping the dispatch path ends with)
#   (e) the dispatch writes no stamp and no `done`
#   (f) usage errors
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
  rm -rf "${STUB_DIR:?}" "$SANDBOX/.git/talos-done.ledger" "$SANDBOX/.git/talos-lease.ledger"; mkdir -p "$STUB_DIR"
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

reset $'docs/user-guide.md\ntests/t.sh'
dg 7 --issue 3
assert_contains "$OUT" "docs=dispatch" "docs/** PR: dispatch"
assert_eq "docs/user-guide.md" "$(cat "$PF")" "docs/** PR: the paths file holds the doc path"
cleanup_pf

reset $'scripts/pipeline-defaults.sh\ntests/t.sh'
dg 7 --issue 3
assert_contains "$OUT" "docs=dispatch" "config-key PR (pipeline-defaults.sh): dispatch"
assert_eq "scripts/pipeline-defaults.sh" "$(cat "$PF")" "config-key PR: the defaults file is in the paths file"
cleanup_pf

reset $'docs/CHANGELOG.d/546.md\nscripts/talos.sh'
dg 7 --issue 3
assert_contains "$OUT" "docs=skip reason=no-docs-paths" "a CHANGELOG fragment alone is not docs-relevant"

reset $'docs/status.d/3-7.md\nscripts/talos.sh'
dg 7 --issue 3
assert_contains "$OUT" "docs=skip reason=no-docs-paths" "a status fragment (default dir) alone is not docs-relevant"

reset $'notes/x.md\nscripts/talos.sh'
cfg_json '{"vcs": {"provider": "github"}, "comments": {"enabled": false}, "status": {"enabled": true, "fragments_dir": "docs/notes/"}}'
printf 'docs/notes/3-7.md\n' > "$STUB_DIR/pr-files.out"
dg 7 --issue 3
assert_contains "$OUT" "docs=skip reason=no-docs-paths" "a status fragment under a configured fragments_dir is not docs-relevant"

reset $'docs/CHANGELOG.d/546.md\nREADME.md\ndocs/status.d/3-7.md\ndocs/guide.md'
dg 7 --issue 3
assert_contains "$OUT" "docs=dispatch" "fragments plus README plus docs: dispatch"
assert_eq $'README.md\ndocs/guide.md' "$(cat "$PF")" "a mix: fragments are left out of the paths file"
cleanup_pf

reset $'docs-extra/x.md\nREADME.md.bak\nsub/README.md\ndocs/CHANGELOG.d.old'
dg 7 --issue 3
assert_contains "$OUT" "docs=dispatch" "docs/CHANGELOG.d.old is under docs/ and not a fragment: dispatch"
assert_eq "docs/CHANGELOG.d.old" "$(cat "$PF")" "lookalike paths (docs-extra/, README.md.bak, sub/README.md) are not docs-relevant"
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

finish
